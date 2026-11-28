# Hook::Guest - the guest this run is about, container or VM, behind one API.
#
#   vmid()  guest_type() ('lxc'|'qemu')  is_lxc()  is_vm()  what() ('Container'|'VM')
#
# Config (/etc/pve/lxc/<vmid>.conf or /etc/pve/qemu-server/<vmid>.conf), main
# section only - snapshot and pending sections further down repeat keys like
# net0 and mp0 and are never read or changed:
#   read_config()             main-section lines
#   edit_config(sub {...})    the sub gets an arrayref of the main-section lines
#                             and returns true when it changed them; written back
#                             with the other sections untouched
#   append_line(\@lines, $l)  adds a line at the end of the main section
#   get_tags(@lines)  guest_name(@lines) (hostname: / name:)  net0_mac(@lines)
#   agent_enabled(@lines)     VMs: `agent: 1`; containers: always true
#
# Inside the guest - containers through `pct exec`, VMs through the QEMU guest
# agent (`qm guest exec`). Neither takes the config lock, so both work while a
# start task still holds it:
#   guest_exec($stdin, @cmd)       (exit code, stdout); -1 when it didn't run
#   guest_capture(@cmd)            stdout, exit code ignored
#   guest_run(@cmd)                true when it exited 0
#   guest_push_content($text, $dst), guest_push_file($src, $dst)
#                                  via a temp file + mv, mode 0644
#   guest_run_long($unit, $script, $max)
#                                  long jobs as a transient systemd unit in the guest
#   guest_agent_ping()  wait_for_agent()   VMs only; true for containers
package Hook::Guest;

use strict;
use warnings;
use JSON::PP qw(decode_json);
use File::Basename qw(dirname);
use Exporter 'import';
use Hook::Log;
use Hook::Util;

our @EXPORT = qw(vmid guest_type is_lxc is_vm what conf_file
                 read_config edit_config append_line get_tags guest_name net0_mac agent_enabled
                 guest_exec guest_capture guest_run guest_push_content guest_push_file guest_run_long
                 guest_agent_ping wait_for_agent);

my $AGENT_WAIT         = 300;  # seconds to wait for the guest agent after boot
my $GUEST_EXEC_TIMEOUT = 60;   # seconds per `qm guest exec`

my ($VMID, $TYPE) = ('', '');

# 'lxc' or 'qemu' from which config exists. VMIDs are unique in the cluster,
# and a hook runs on the node that holds the guest, so this is unambiguous.
sub detect_type {
    my ($vmid) = @_;
    return 'lxc'  if -e "/etc/pve/lxc/$vmid.conf";
    return 'qemu' if -e "/etc/pve/qemu-server/$vmid.conf";
    return undef;
}

sub init { ($VMID, $TYPE) = @_ }

sub vmid       { $VMID }
sub guest_type { $TYPE }
sub is_lxc     { $TYPE eq 'lxc' }
sub is_vm      { $TYPE eq 'qemu' }
sub what       { is_vm() ? 'VM' : 'Container' }
sub conf_file  { is_vm() ? "/etc/pve/qemu-server/$VMID.conf" : "/etc/pve/lxc/$VMID.conf" }

# -------------------------
# Config
# -------------------------

sub read_config {
    my $file = conf_file();
    open my $fh, '<', $file or die "Cannot open $file: $!\n";
    my @lines;
    while (my $line = <$fh>) {
        last if $line =~ /^\[/;
        push @lines, $line;
    }
    close $fh;
    return @lines;
}

sub edit_config {
    my ($code) = @_;
    my $file = conf_file();
    open my $fh, '<', $file or die "Cannot open $file: $!\n";
    my (@main, @rest);
    my $in_rest = 0;
    while (my $line = <$fh>) {
        $in_rest ||= $line =~ /^\[/;
        push @{ $in_rest ? \@rest : \@main }, $line;
    }
    close $fh;

    return 0 unless $code->(\@main);

    my $tmp = "$file.tmp.$$";
    open my $out, '>', $tmp or die "Cannot write $tmp: $!\n";
    print $out @main, @rest;
    close $out or die "Cannot write $tmp: $!\n";
    rename $tmp, $file or do { unlink $tmp; die "Cannot rename $tmp to $file: $!\n" };
    return 1;
}

# Before the blank line(s) that separate the main section from a snapshot
sub append_line {
    my ($lines, $line) = @_;
    my $i = @$lines;
    $i-- while $i > 0 && $lines->[$i - 1] =~ /^\s*$/;
    splice @$lines, $i, 0, $line;
}

sub get_tags {
    my @lines = @_;
    foreach my $line (@lines) {
        return grep { length } map { s/^\s+|\s+$//gr } split(/[;,]/, $1) if $line =~ /^tags:\s*(.*)$/;
    }
    return ();
}

# A container's hostname: line, a VM's name: line
sub guest_name {
    my @lines = @_;
    my $key = is_vm() ? 'name' : 'hostname';
    foreach my $line (@lines) {
        return $1 if $line =~ /^\Q$key\E:\s*(.*?)\s*$/;
    }
    return undef;
}

# hwaddr=<mac> (container) or <model>=<mac> (VM)
sub net0_mac {
    my @lines = @_;
    foreach my $line (@lines) {
        next unless $line =~ /^net0:\s*(.*)$/;
        return $1 if $line =~ /=([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5})(?:,|\s*$)/;
    }
    return undef;
}

sub agent_enabled {
    my @lines = @_;
    return 1 if is_lxc();
    return scalar grep { /^agent:\s*(?:enabled=)?1(?:,|\s*$)/ } @lines;
}

# -------------------------
# Inside the guest
# -------------------------

# Runs @cmd on the host with $stdin (or /dev/null) as input and stderr
# dropped; returns (exit code, stdout).
sub run_capture {
    my ($stdin, @cmd) = @_;
    my $tmp;
    if (defined $stdin) {
        $tmp = "/tmp/.hook-$VMID.$$";
        open my $fh, '>', $tmp or die "write $tmp: $!\n";
        print $fh $stdin;
        close $fh;
    }
    my $pid = open(my $fh, '-|');
    unless (defined $pid) {
        unlink $tmp if $tmp;
        return (-1, '');
    }
    if (!$pid) {
        open STDIN, '<', ($tmp // '/dev/null');
        open STDERR, '>', '/dev/null';
        exec @cmd or exit 127;
    }
    local $/;
    my $out = <$fh> // '';
    close $fh;
    unlink $tmp if $tmp;
    my $rc = ($? == -1 || $? & 127) ? -1 : $? >> 8;
    return ($rc, $out);
}

# `qm guest exec` prints the result as JSON ({exitcode, exited, out-data,
# err-data}); its own exit status doesn't reflect the guest command's, so the
# JSON is what counts. stdin (max 1 MiB) goes through --pass-stdin.
sub guest_exec {
    my ($stdin, @cmd) = @_;
    return run_capture($stdin, 'pct', 'exec', $VMID, '--', @cmd) if is_lxc();

    my @qm = ('qm', 'guest', 'exec', $VMID, '--timeout', $GUEST_EXEC_TIMEOUT);
    push @qm, '--pass-stdin', '1' if defined $stdin;
    my (undef, $raw) = run_capture($stdin, @qm, '--', @cmd);

    my $res = eval { decode_json($raw) };
    $res = $res->{result} if ref $res eq 'HASH' && ref $res->{result} eq 'HASH';
    return (-1, '') unless ref $res eq 'HASH' && $res->{exited};
    return ($res->{exitcode} // -1, $res->{'out-data'} // '');
}

sub guest_capture {
    my (@cmd) = @_;
    return (guest_exec(undef, @cmd))[1];
}

sub guest_run {
    my (@cmd) = @_;
    return (guest_exec(undef, @cmd))[0] == 0;
}

# Not `pct push`: that takes the container's config lock, which Proxmox still
# holds while post-start runs. Temp file + mv, so nothing (apt, sshd) ever
# reads a half-written file.
sub guest_push_content {
    my ($content, $dst) = @_;
    my $dir = dirname($dst);
    my ($rc) = guest_exec($content, 'sh', '-c',
        "mkdir -p '$dir' && cat > '$dst.tmp' && chmod 0644 '$dst.tmp' && mv -f '$dst.tmp' '$dst'");
    die "pushing $dst into " . lc(what()) . " $VMID failed\n" unless $rc == 0;
}

sub guest_push_file {
    my ($src, $dst) = @_;
    guest_push_content(slurp($src), $dst);
}

# Runs a shell script in the guest as a transient systemd unit and waits for
# it, so it isn't bound by the guest agent's per-call timeout and survives the
# guest being restarted halfway. If that unit is still running (an earlier,
# interrupted job) it waits for that one instead of starting another. Output
# goes to /var/log/<unit>.log in the guest. Returns 1 when the script exited 0.
sub guest_run_long {
    my ($unit, $script, $max) = @_;
    my $rcfile = "/run/$unit.rc";
    my $state = guest_capture('systemctl', 'is-active', "$unit.service") =~ s/\s+//gr;

    unless ($state eq 'active' || $state eq 'activating') {
        my ($rc, $out) = guest_exec(undef, 'systemd-run', "--unit=$unit", '--collect', '--quiet',
            '--property=Type=oneshot', 'sh', '-c',
            "rm -f $rcfile; ( $script ) > /var/log/$unit.log 2>&1; echo \$? > $rcfile");
        if ($rc != 0) {
            logmsg(what() . " $VMID: starting $unit failed (exit $rc): $out");
            return 0;
        }
    }

    my $deadline = time + $max;
    while (time < $deadline) {
        $state = guest_capture('systemctl', 'is-active', "$unit.service") =~ s/\s+//gr;
        last unless $state eq 'active' || $state eq 'activating';
        sleep 10;
    }
    if ($state eq 'active' || $state eq 'activating') {
        logmsg(what() . " $VMID: $unit still running after ${max}s, will check again on the next start");
        return 0;
    }

    my $exit = guest_capture('cat', $rcfile) =~ s/\s+//gr;
    return 1 if $exit eq '0';
    my $tail = guest_capture('tail', '-n', '5', "/var/log/$unit.log") =~ s/\s+/ /gr;
    logmsg(what() . " $VMID: $unit failed (exit " . ($exit eq '' ? '?' : $exit) . "): $tail");
    return 0;
}

sub guest_agent_ping {
    return 1 if is_lxc();
    return system("qm guest cmd $VMID ping >/dev/null 2>&1") == 0;
}

sub wait_for_agent {
    return 1 if is_lxc();
    my $deadline = time + $AGENT_WAIT;
    while (time < $deadline) {
        return 1 if guest_agent_ping();
        my $status = `qm status $VMID 2>/dev/null`;
        if ($status !~ /status:\s*running/) {
            logmsg("VM $VMID is no longer running, giving up on the guest agent");
            return 0;
        }
        sleep 5;
    }
    logmsg("Guest agent in VM $VMID not reachable after ${AGENT_WAIT}s (qemu-guest-agent installed and running?)");
    return 0;
}

1;
