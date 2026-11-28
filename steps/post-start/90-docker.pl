# post-start/90-docker.pl - `docker` tag: Docker host managed by Dockhand
#
# A VM tagged `docker` turns itself into a Docker host managed by Dockhand -
# the VM counterpart of proxdock-provision.sh. Every step checks first and
# only does what's missing, so it runs on every start: add a `stack-<name>`
# tag, restart, and that stack gets deployed. Runs after the APT step, which
# has already put the Docker apt repo in place (apt.yaml: tags: docker).
#   1. wait for first-boot.service (a fresh clone's full upgrade holds dpkg)
#   2. install Docker when `docker` is missing
#   3. Hawser in /opt/stacks/hawser (compose.yaml from vm-template/hawser/);
#      a token is generated only when .env has none, so the Dockhand
#      connection survives restarts
#   4. register in Dockhand + deploy BASE_STACK and the stack-<name> tags
#      that Dockhand doesn't have yet (dockhand-register.sh, shared with
#      proxdock-provision.sh)
#
#   Guests: VMs (guest agent)      Config: /etc/pve/proxdock/provision.conf
#   Tags: docker, stack-<name>
package Hook::Step::PostStart::Docker;

use strict;
use warnings;
use Hook;

my $PROVISION_CONF  = '/etc/pve/proxdock/provision.conf';
my $HAWSER_DIR      = '/opt/stacks/hawser';
my $DOCKER_PACKAGES = 'docker-ce docker-ce-cli containerd.io docker-compose-plugin';
my $FIRST_BOOT_WAIT = 30 * 60;   # matches first-boot.service's TimeoutStartSec
my $LONG_STEP_WAIT  = 20 * 60;

return {
    name  => 'docker',
    types => ['qemu'],
    agent => 1,
    run   => \&run,
};

sub run {
    my $vmid  = vmid();
    my @lines = read_config();
    my @tags  = get_tags(@lines);
    return unless grep { $_ eq 'docker' } @tags;

    wait_for_first_boot() or return;
    ensure_docker() or return;
    my ($token, $token_new) = ensure_hawser() or return;

    unless (-r $PROVISION_CONF) {
        logmsg("VM $vmid: no $PROVISION_CONF, Docker + Hawser are up but not registering in Dockhand");
        return;
    }
    my $name = guest_name(@lines);
    my $ip   = guest_ip();
    unless ($name && $ip) {
        logmsg("VM $vmid: no name or no known IP, can't register in Dockhand");
        return;
    }

    my ($base) = slurp($PROVISION_CONF) =~ /^BASE_STACK=["']?([^"'\s]*)/m;
    my @stacks = grep { length } ($base // ''), map { /^stack-(.+)$/ ? $1 : () } @tags;

    open(my $fh, '-|', snippets() . '/dockhand-register.sh', $name, $ip, $token, $token_new, @stacks)
        or die "cannot run dockhand-register.sh: $!\n";
    while (my $line = <$fh>) {
        chomp $line;
        logmsg("VM $vmid: $line") if length $line;
    }
    close $fh;
    logmsg("VM $vmid: Dockhand registration failed (exit " . ($? >> 8) . ")") if $?;
}

sub wait_for_first_boot {
    my $vmid = vmid();
    my $deadline = time + $FIRST_BOOT_WAIT;
    my $logged;
    while (time < $deadline) {
        my $state = guest_capture('systemctl', 'is-active', 'first-boot.service') =~ s/\s+//gr;
        return 1 unless $state eq 'activating';
        logmsg("VM $vmid: waiting for first-boot.service (upgrade) to finish") unless $logged++;
        sleep 15;
    }
    logmsg("VM $vmid: first-boot.service still running after ${FIRST_BOOT_WAIT}s, skipping Docker setup this time");
    return 0;
}

sub ensure_docker {
    my $vmid = vmid();
    return 1 if guest_run('sh', '-c', 'command -v docker >/dev/null && docker info >/dev/null 2>&1');

    unless (guest_run('sh', '-c', 'command -v docker >/dev/null')) {
        logmsg("VM $vmid: installing Docker");
        guest_run_long('hookscript-docker-install',
            'export DEBIAN_FRONTEND=noninteractive; '
          . 'apt-get -o DPkg::Lock::Timeout=600 update && '
          . "apt-get -o DPkg::Lock::Timeout=600 install -y $DOCKER_PACKAGES && "
          . 'systemctl enable --now docker',
            $LONG_STEP_WAIT) or return 0;
    } else {
        guest_run('systemctl', 'enable', '--now', 'docker');
    }

    for (1 .. 30) {
        if (guest_run('docker', 'info')) {
            logmsg("VM $vmid: Docker is up");
            return 1;
        }
        sleep 2;
    }
    logmsg("VM $vmid: Docker installed but `docker info` keeps failing");
    return 0;
}

# Returns (token, token_is_new) once Hawser is running, or () on failure.
sub ensure_hawser {
    my $vmid = vmid();
    my $compose = snippets() . '/vm-template/hawser/compose.yaml';
    unless (-s $compose) {
        logmsg("VM $vmid: $compose missing on the host, skipping Hawser");
        return;
    }

    my $compose_changed = guest_capture('cat', "$HAWSER_DIR/compose.yaml") ne slurp($compose);
    guest_push_file($compose, "$HAWSER_DIR/compose.yaml") if $compose_changed;

    my $env = guest_capture('cat', "$HAWSER_DIR/.env");
    my ($token) = $env =~ /^TOKEN=([0-9a-f]{16,})\s*$/m;
    my $token_new = 0;
    unless ($token) {
        open my $rnd, '<:raw', '/dev/urandom' or die "open /dev/urandom: $!\n";
        read($rnd, my $bytes, 24) == 24 or die "read /dev/urandom failed\n";
        close $rnd;
        $token = unpack('H*', $bytes);
        my $rest = join '', grep { !/^TOKEN=/ } split /^/m, $env;
        $rest .= "\n" if length $rest && $rest !~ /\n$/;
        guest_push_content("${rest}TOKEN=$token\n", "$HAWSER_DIR/.env");
        guest_run('chmod', '600', "$HAWSER_DIR/.env");
        $token_new = 1;
        logmsg("VM $vmid: generated a new Hawser token");
    }

    my $running = guest_capture('docker', 'inspect', '-f', '{{.State.Running}}', 'hawser') =~ /true/;
    if (!$running || $compose_changed || $token_new) {
        guest_run_long('hookscript-hawser',
            "cd $HAWSER_DIR && docker compose up -d --quiet-pull" . ($token_new ? ' --force-recreate' : ''),
            $LONG_STEP_WAIT) or return;
        logmsg("VM $vmid: Hawser " . ($running ? 'restarted' : 'started'));
    }
    return ($token, $token_new);
}
