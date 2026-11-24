#!/usr/bin/perl
#
# Proxmox hookscript for QEMU VMs - the VM counterpart of hookscript.pl (LXC).
#
# Attach with: qm set <vmid> --hookscript local:snippets/vm-hookscript.pl
#
# Everything that touches the guest goes through the QEMU guest agent
# (`qm guest exec`), so the VM needs `agent: 1` in its config and
# qemu-guest-agent installed. Without the agent only the Cloudflare tunnel
# step runs.
#
# Nothing happens at pre-start: Proxmox reads the VM config (and builds the
# cloud-init drive) before running pre-start and never re-reads it, so config
# edits made there don't apply to that start anyway. post-start, on the other
# hand, still holds the VM's config lock and the agent isn't up yet, so it
# forks a background job (phase `guest-sync`) and returns immediately. That
# job:
#   1. moves net0 to the VLAN's SDN VNet (`qm set`, applied live)
#   2. registers the VM with the Cloudflare tunnel (`cft` / `cft-<port>` tag)
#   3. waits for the guest agent
#   4. sets the guest's hostname to the VM's name
#   5. writes a static /etc/network/interfaces from the VMID (network.yaml)
#      and brings the interface down and up again
#   6. syncs the Linux Update Dashboard SSH key
#   7. syncs APT sources/config/keys (apt.yaml)
#   8. template base for VMs not cloned from the template: disk growth, zram
#      swap, swap on disk replaced (see "Template base" below)
#   9. mount tags (mounts.yaml): NFS mounts in /etc/fstab, same paths as LXC
#  10. `docker` tag: Docker + Hawser + Dockhand registration + stacks
#      (see "Docker host" below)
# post-stop removes the Cloudflare tunnel entry again.
#

use strict;
use warnings;
use IO::Handle;
use File::Spec;
use YAML::XS 'LoadFile';
use JSON::PP qw(encode_json decode_json);
use Fcntl qw(:flock);
use File::Basename qw(dirname basename);
use Sys::Syslog qw(openlog syslog);

my $vmid  = shift // '';
my $phase = shift // '';
my $LOG_ID = $vmid =~ /^\d+$/ ? "hookscript-$vmid" : 'hookscript';
openlog($LOG_ID, 'pid', 'user');
my $conf_file = "/etc/pve/qemu-server/${vmid}.conf";

my $SNIPPETS        = '/var/lib/vz/snippets';
my $CF_SECRETS_FILE = "$SNIPPETS/.env.secrets";
my $CF_LOCK_FILE    = "$SNIPPETS/.cf-tunnel.lock";
my $APT_SOURCES_DIR = "$SNIPPETS/apt.sources.d";
my $APT_CONF_DIR    = "$SNIPPETS/apt.conf.d";
my $APT_KEY_CACHE   = "$SNIPPETS/.apt-keys";
my $APT_KEY_MAX_AGE = 1;    # days before a cached key is re-downloaded
my $APT_MARKER      = 'managed by hookscript (apt.yaml)';

my $AGENT_WAIT         = 300;  # seconds to wait for the guest agent after boot
my $GUEST_EXEC_TIMEOUT = 60;   # seconds per `qm guest exec`

# Also to the journal, as `hookscript-<vmid>` (identifier shown in the GUI's
# node -> System -> Syslog; search there for hookscript-17250, or just
# hookscript for all), with fields for exact filtering on the shell:
#   journalctl -t hookscript-17250 -f       one VM
#   journalctl HOOKSCRIPT_VMID=17250        the same, by field
#   journalctl HOOKSCRIPT=vm                all VM hooks (lxc: all container hooks)
# Falls back to plain syslog when `logger --journald` isn't available.
sub journal_log {
    my ($msg, $kind) = @_;
    (my $one_line = $msg) =~ s/\s*\n\s*/ /g;
    no warnings 'exec';    # no logger: syslog fallback below
    if (open my $j, '|-', 'logger', '--journald') {
        print $j "MESSAGE=$one_line\nPRIORITY=6\nSYSLOG_IDENTIFIER=$LOG_ID\nSYSLOG_PID=$$\nHOOKSCRIPT=$kind\n"
               . ($LOG_ID ne 'hookscript' ? "HOOKSCRIPT_VMID=$vmid\n" : '');
        return if close $j;
    }
    eval { syslog('info', '%s', $one_line) };
}

# Counted for the guest-sync closing line
our $LOG_PROBLEMS = 0;

sub logmsg {
    my ($msg) = @_;
    $LOG_PROBLEMS++ if $msg =~ /\bfail|giving up|not reachable|didn't start|still running after/i;
    my $line = scalar(localtime) . " [vm] $msg\n";

    if (open my $log, '>>', '/tmp/hook.log') {
        print $log $line;
        close $log;
    }

    # The journal is the only place besides /tmp/hook.log where the post-start
    # background job shows up.
    journal_log("[vm] $msg", 'vm');

    print STDOUT $line;
    STDOUT->flush();
}

# Main section only: a VM conf also holds [snapshot] and [special:...]
# sections further down, which repeat keys like net0/tags.
sub read_config {
    open my $fh, '<', $conf_file or die "Cannot open $conf_file: $!";
    my @lines;
    while (my $line = <$fh>) {
        last if $line =~ /^\[/;
        push @lines, $line;
    }
    close $fh;
    return @lines;
}

sub get_tags {
    my @lines = @_;
    foreach my $line (@lines) {
        if ($line =~ /^tags:\s*(.*)$/) {
            return grep { length } map { s/^\s+|\s+$//gr } split(/[;,]/, $1);
        }
    }
    return ();
}

sub agent_enabled {
    my @lines = @_;
    return scalar grep { /^agent:\s*(?:enabled=)?1(?:,|\s*$)/ } @lines;
}

# -------------------------
# Guest agent
# -------------------------
#
# `qm guest exec` prints the result as JSON ({exitcode, exited, out-data,
# err-data}); its own exit status doesn't reflect the guest command's, so the
# JSON is what counts. It doesn't take the VM config lock, so it works while a
# start task still holds it. stdin (max 1 MiB) goes through --pass-stdin.

sub guest_exec {
    my ($stdin, @cmd) = @_;
    my @qm = ('qm', 'guest', 'exec', $vmid, '--timeout', $GUEST_EXEC_TIMEOUT);
    push @qm, '--pass-stdin', '1' if defined $stdin;
    push @qm, '--', @cmd;

    my $tmp;
    open(my $saved_in, '<&', \*STDIN) or die "dup STDIN: $!\n";
    if (defined $stdin) {
        $tmp = "/tmp/.vmhook-$vmid.$$";
        open my $fh, '>', $tmp or die "write $tmp: $!\n";
        print $fh $stdin;
        close $fh;
        open(STDIN, '<', $tmp) or die "open $tmp: $!\n";
    } else {
        open(STDIN, '<', '/dev/null');
    }

    my $raw = '';
    if (open(my $fh, '-|', @qm)) {
        local $/;
        $raw = <$fh> // '';
        close $fh;
    }
    open(STDIN, '<&', $saved_in);
    unlink $tmp if $tmp;

    my $res = eval { decode_json($raw) };
    $res = $res->{result} if ref $res eq 'HASH' && ref $res->{result} eq 'HASH';
    return (-1, '') unless ref $res eq 'HASH' && $res->{exited};
    return ($res->{exitcode} // -1, $res->{'out-data'} // '');
}

# Returns the command's stdout (exit code ignored).
sub guest_capture {
    my (@cmd) = @_;
    return (guest_exec(undef, @cmd))[1];
}

sub guest_run {
    my (@cmd) = @_;
    return (guest_exec(undef, @cmd))[0] == 0;
}

# Written to a temp file + mv so nothing ever reads a half-written file.
sub guest_push_content {
    my ($content, $dst) = @_;
    my $dir = dirname($dst);
    my ($rc) = guest_exec($content, 'sh', '-c',
        "mkdir -p '$dir' && cat > '$dst.tmp' && chmod 0644 '$dst.tmp' && mv -f '$dst.tmp' '$dst'");
    die "pushing $dst into VM $vmid failed\n" unless $rc == 0;
}

sub guest_push_file {
    my ($src, $dst) = @_;
    guest_push_content(slurp($src), $dst);
}

sub guest_agent_ping {
    return system("qm guest cmd $vmid ping >/dev/null 2>&1") == 0;
}

sub wait_for_agent {
    my $deadline = time + $AGENT_WAIT;
    while (time < $deadline) {
        return 1 if guest_agent_ping();
        my $status = `qm status $vmid 2>/dev/null`;
        if ($status !~ /status:\s*running/) {
            logmsg("VM $vmid is no longer running, giving up on the guest agent");
            return 0;
        }
        sleep 5;
    }
    logmsg("Guest agent in VM $vmid not reachable after ${AGENT_WAIT}s (qemu-guest-agent installed and running?)");
    return 0;
}

# -------------------------
# Network (inside the guest)
# -------------------------
#
# Same VMID scheme as the LXC hookscript (network.yaml): VMID VVOOO ->
# 192.168.VV.OOO + fd00:VV::OOO, only for VLANs listed under `vnets`.
# Written to /etc/network/interfaces (ifupdown), for the interface whose MAC
# matches net0. Only touched when that file is still on DHCP for that
# interface, or was written by this hook before (marker line), and holds no
# other interfaces - anything hand-made is left alone. The original is kept as
# /etc/network/interfaces.vmhook.bak.
#
# DNS: the nameservers are the gateways. They go in as `dns-nameservers` (used
# when resolvconf is installed) and, when /etc/resolv.conf is a plain file
# (not a systemd-resolved/resolvconf symlink), straight into it, keeping its
# search/domain/options lines.

my $NET_MARKER = '# managed by vm-hookscript (network.yaml), do not edit';
my $derived_network;

sub derive_network {
    return $derived_network if defined $derived_network;
    $derived_network = 0;

    my $path = "$SNIPPETS/network.yaml";
    return undef unless -e $path;
    my $netcfg = eval { LoadFile($path) };
    if ($@) {
        logmsg("Failed to load $path: $@");
        return undef;
    }

    my ($vlan, $host) = $vmid =~ /^(\d{2})(\d{3})$/;
    unless (defined $vlan) {
        logmsg("VMID $vmid does not match VVOOO network scheme, skipping static IP");
        return undef;
    }
    $vlan = int($vlan);
    $host = int($host);

    my $vnet = ($netcfg->{vnets} || {})->{$vlan};
    unless (defined $vnet && length $vnet) {
        logmsg("VLAN $vlan (from VMID $vmid) has no SDN VNet in network.yaml, skipping network setup");
        return undef;
    }

    my $base     = $netcfg->{network}{base};
    my $gw_octet = $netcfg->{gateway_overrides}{$vlan} // $netcfg->{network}{gateway_octet};
    my %net = (
        vnet => $vnet,
        ip   => "$base.$vlan.$host",
        cidr => $netcfg->{network}{cidr},
        gw   => "$base.$vlan.$gw_octet",
    );

    # IPv6 reuses the same numbers literally (not hex): fd00:10::75, gw fd00:10::254
    my $v6_prefix = $netcfg->{network}{ipv6_prefix};
    if (defined $v6_prefix && length $v6_prefix) {
        my $v6_cidr = $netcfg->{network}{ipv6_cidr} // 64;
        $net{ip6} = "${v6_prefix}:${vlan}::${host}/${v6_cidr}";
        $net{gw6} = "${v6_prefix}:${vlan}::${gw_octet}";
    }

    $derived_network = \%net;
    return $derived_network;
}

# Puts net0 on the VLAN's SDN VNet and drops any `tag=` (the VNet tags). Done
# with `qm set` from the background job, once the start task has let go of the
# config lock (retried while it hasn't). Proxmox switches the bridge of a
# running VM live when network hotplug is on (the default); otherwise the
# change stays pending until the next start.
sub sync_net0_bridge {
    my $net = derive_network() or return;

    my ($cur) = map { /^net0:\s*(.*?)\s*$/ ? $1 : () } read_config();
    unless (defined $cur) {
        logmsg("VM $vmid has no net0, skipping bridge setup");
        return;
    }

    my $new = $cur;
    $new =~ s/(?:^|,)\Kbridge=[^,]*/bridge=$net->{vnet}/ or $new .= ",bridge=$net->{vnet}";
    $new =~ s/,tag=\d+(?=,|$)//g;
    $new =~ s/^tag=\d+,//;
    return if $new eq $cur;

    my $out = '';
    for my $try (1 .. 10) {
        $out = `qm set $vmid --net0 '$new' 2>&1`;
        last if $? == 0;
        unless ($out =~ /lock/i) {
            $out =~ s/\s+$//;
            logmsg("Moving net0 of VM $vmid to vnet $net->{vnet} failed: $out");
            return;
        }
        sleep 3;
    }
    if ($? != 0) {
        logmsg("Moving net0 of VM $vmid to vnet $net->{vnet} failed, config stayed locked");
        return;
    }

    if (`qm pending $vmid 2>/dev/null` =~ /^new\s+net0:/m) {
        logmsg("net0 of VM $vmid set to vnet $net->{vnet}, pending until the next start (network hotplug off?)");
    } else {
        logmsg("Moved net0 of VM $vmid to vnet $net->{vnet}");
    }
}

sub net0_mac {
    my @lines = @_;
    foreach my $line (@lines) {
        next unless $line =~ /^net0:\s*(.*)$/;
        return $1 if $line =~ /=([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5})(?:,|\s*$)/;
    }
    return undef;
}

sub guest_iface_for_mac {
    my ($mac) = @_;
    my $raw = `qm guest cmd $vmid network-get-interfaces 2>/dev/null`;
    my $ifs = eval { decode_json($raw) };
    $ifs = $ifs->{result} if ref $ifs eq 'HASH';
    return undef unless ref $ifs eq 'ARRAY';
    foreach my $if (@$ifs) {
        return $if->{name} if lc($if->{'hardware-address'} // '') eq lc($mac);
    }
    return undef;
}

sub sync_guest_network {
    my $net = derive_network() or return;

    my $mac = net0_mac(read_config());
    unless ($mac) {
        logmsg("VM $vmid has no net0 MAC address, skipping network setup");
        return;
    }
    my $if = guest_iface_for_mac($mac);
    unless ($if) {
        logmsg("No interface with MAC $mac (net0) found in VM $vmid, skipping network setup");
        return;
    }

    my ($rc, $current) = guest_exec(undef, 'cat', '/etc/network/interfaces');
    if ($rc != 0) {
        logmsg("VM $vmid has no /etc/network/interfaces (not ifupdown?), skipping network setup");
        return;
    }

    my $managed = index($current, $NET_MARKER) >= 0;
    my $dhcp    = $current =~ /^\s*iface\s+\Q$if\E\s+inet\s+dhcp\b/m;
    my @others  = grep { $_ ne 'lo' && $_ ne $if } $current =~ /^\s*iface\s+(\S+)/mg;
    unless ($managed || $dhcp) {
        logmsg("VM $vmid: $if is not on DHCP in /etc/network/interfaces and not managed by this hook, leaving it alone");
        return;
    }
    if (@others) {
        logmsg("VM $vmid: /etc/network/interfaces also configures @others, leaving it alone");
        return;
    }

    my $want = "$NET_MARKER\n"
             . "# Built from the VMID on every VM start. Remove the line above to manage\n"
             . "# this file by hand.\n\n"
             . "source /etc/network/interfaces.d/*\n\n"
             . "auto lo\niface lo inet loopback\n\n"
             . "auto $if\n"
             . "iface $if inet static\n"
             . "    address $net->{ip}/$net->{cidr}\n"
             . "    gateway $net->{gw}\n"
             . "    dns-nameservers " . join(' ', nameservers($net)) . "\n";
    $want .= "\niface $if inet6 static\n"
           . "    address $net->{ip6}\n"
           . "    gateway $net->{gw6}\n" if $net->{ip6};

    apply_interfaces($if, $want, $managed, $net) if $current ne $want;
    sync_resolv_conf($net);
}

sub nameservers {
    my ($net) = @_;
    return grep { defined } $net->{gw}, $net->{gw6};
}

sub sync_resolv_conf {
    my ($net) = @_;
    unless (guest_run('sh', '-c', 'test -f /etc/resolv.conf && ! test -L /etc/resolv.conf')) {
        logmsg("VM $vmid: /etc/resolv.conf is not a plain file (resolved/resolvconf?), relying on dns-nameservers");
        return;
    }

    my $current = guest_capture('cat', '/etc/resolv.conf');
    my @keep = grep { /^\s*(?:search|domain|options)\s/ } split /^/m, $current;
    $keep[-1] .= "\n" if @keep && $keep[-1] !~ /\n$/;
    my $want = "# managed by vm-hookscript (network.yaml): nameservers are the gateways\n"
             . join('', @keep)
             . join('', map { "nameserver $_\n" } nameservers($net));
    return if $current eq $want;

    guest_push_content($want, '/etc/resolv.conf');
    logmsg("Set nameservers in VM $vmid to " . join(', ', nameservers($net)));
}

sub apply_interfaces {
    my ($if, $want, $managed, $net) = @_;
    my $new = '/etc/network/interfaces.vmhook-new';
    guest_push_content($want, $new);

    # ifdown against the old config first (releases the DHCP lease), then swap
    # the file in and bring the interface up with the static config.
    my $backup = $managed ? '' : 'cp -f /etc/network/interfaces /etc/network/interfaces.vmhook.bak && ';
    my ($up_rc, $out) = guest_exec(undef, 'sh', '-c',
        "${backup}ifdown --force $if >/dev/null 2>&1; mv -f $new /etc/network/interfaces && ifup $if 2>&1");

    my $desc = "$net->{ip}/$net->{cidr}, gw $net->{gw}" . ($net->{ip6} ? ", $net->{ip6}, gw6 $net->{gw6}" : '');
    if ($up_rc == 0) {
        logmsg("Set $if in VM $vmid to $desc");
    } else {
        $out =~ s/\s+$//;
        logmsg("Wrote static $if config ($desc) in VM $vmid but ifup failed (exit $up_rc): $out");
    }
}

# -------------------------
# Cloudflare Tunnel reverse proxy
# -------------------------
#
# A tag of `cft` exposes the VM on port 80 through the Cloudflare Tunnel;
# `cft-<port>` exposes it on <port>. The VM's `name:` conf line is used as-is
# as the public FQDN, so name the VM e.g. `app.example.com`. The IP is the
# VMID-derived one (network.yaml). The tunnel is remotely managed
# (Zero Trust dashboard), so ingress is edited via the Cloudflare API against
# the tunnel's remote configuration - no local cloudflared config or restart
# involved.

sub parse_cft_tag {
    my @tags = @_;
    foreach my $tag (@tags) {
        if ($tag =~ /^cft(?:-(\d+))?$/) {
            return defined $1 ? $1 : 80;
        }
    }
    return undef;
}

sub get_hostname_from_config {
    my @lines = @_;
    foreach my $line (@lines) {
        if ($line =~ /^name:\s*(.*?)\s*$/) {
            return $1;
        }
    }
    return undef;
}

sub is_valid_fqdn {
    my ($fqdn) = @_;
    return defined($fqdn) && $fqdn =~ /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/i;
}

sub load_secrets {
    unless (-e $CF_SECRETS_FILE) {
        logmsg("Secrets file $CF_SECRETS_FILE not found, skipping features that need it");
        return undef;
    }

    open my $fh, '<', $CF_SECRETS_FILE or do {
        logmsg("Cannot open $CF_SECRETS_FILE: $!");
        return undef;
    };

    my %secrets;
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^\s*#/ || $line =~ /^\s*$/;
        if ($line =~ /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/) {
            $secrets{$1} = $2;
        }
    }
    close $fh;

    return \%secrets;
}

sub require_secrets {
    my ($secrets, @keys) = @_;
    foreach my $key (@keys) {
        return 0 unless defined $secrets->{$key} && length $secrets->{$key};
    }
    return 1;
}

sub acquire_cf_lock {
    open my $lockfh, '>', $CF_LOCK_FILE or do {
        logmsg("Cannot open lock file $CF_LOCK_FILE: $!");
        return undef;
    };
    unless (flock($lockfh, LOCK_EX)) {
        logmsg("Cannot acquire lock on $CF_LOCK_FILE: $!");
        close $lockfh;
        return undef;
    }
    return $lockfh;
}

sub release_cf_lock {
    my ($lockfh) = @_;
    return unless $lockfh;
    flock($lockfh, LOCK_UN);
    close $lockfh;
}

sub cf_api_request {
    my ($method, $url, $token, $body) = @_;

    my @args = (
        'curl', '-s', '-S', '-X', $method,
        '-H', "Authorization: Bearer $token",
        '-H', 'Content-Type: application/json',
    );
    push @args, '-d', encode_json($body) if defined $body;
    push @args, $url;

    my $pid = open(my $fh, '-|', @args);
    unless ($pid) {
        logmsg("cf_api_request: failed to exec curl: $!");
        return undef;
    }

    local $/;
    my $raw = <$fh>;
    close $fh;

    if ($? != 0) {
        logmsg("cf_api_request: curl exited nonzero for $method $url");
        return undef;
    }

    my $data = eval { decode_json($raw) };
    if ($@ || !$data || !$data->{success}) {
        my $err = $@ || encode_json(($data && $data->{errors}) || []);
        logmsg("cf_api_request: API error for $method $url: $err");
        return undef;
    }

    return $data;
}

sub cf_zone_name_for_fqdn {
    my ($fqdn) = @_;
    my @labels = split /\./, $fqdn;
    return undef if @labels < 2;
    shift @labels;
    return join('.', @labels);
}

sub cf_lookup_zone_id {
    my ($fqdn, $secrets) = @_;
    my $zone = cf_zone_name_for_fqdn($fqdn);
    unless ($zone) {
        logmsg("Cannot derive cloudflare zone name from hostname $fqdn");
        return undef;
    }

    my $url  = "https://api.cloudflare.com/client/v4/zones?name=$zone";
    my $data = cf_api_request('GET', $url, $secrets->{CF_API_TOKEN});
    unless ($data && @{ $data->{result} || [] }) {
        logmsg("Cloudflare zone $zone not found for hostname $fqdn");
        return undef;
    }

    return $data->{result}[0]{id};
}

sub ensure_dns_record {
    my ($fqdn, $secrets) = @_;

    my $zone_id = cf_lookup_zone_id($fqdn, $secrets);
    return unless $zone_id;

    my $lookup_url = "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=CNAME&name=$fqdn";
    my $existing   = cf_api_request('GET', $lookup_url, $secrets->{CF_API_TOKEN});
    if ($existing && @{ $existing->{result} || [] }) {
        logmsg("DNS CNAME for $fqdn already exists, skipping create");
        return;
    }

    my $create_url = "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records";
    my $body = {
        type    => 'CNAME',
        name    => $fqdn,
        content => "$secrets->{CF_TUNNEL_ID}.cfargotunnel.com",
        proxied => JSON::PP::true,
        ttl     => 1,
    };

    my $created = cf_api_request('POST', $create_url, $secrets->{CF_API_TOKEN}, $body);
    if ($created) {
        logmsg("Created DNS CNAME $fqdn -> $secrets->{CF_TUNNEL_ID}.cfargotunnel.com");
    } else {
        logmsg("Failed to create DNS CNAME for $fqdn");
    }
}

sub delete_dns_record {
    my ($fqdn, $secrets) = @_;

    my $zone_id = cf_lookup_zone_id($fqdn, $secrets);
    return unless $zone_id;

    my $lookup_url = "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=CNAME&name=$fqdn";
    my $existing   = cf_api_request('GET', $lookup_url, $secrets->{CF_API_TOKEN});
    unless ($existing && @{ $existing->{result} || [] }) {
        logmsg("No DNS CNAME found for $fqdn, nothing to remove");
        return;
    }

    my $record_id  = $existing->{result}[0]{id};
    my $delete_url = "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id";
    my $deleted    = cf_api_request('DELETE', $delete_url, $secrets->{CF_API_TOKEN});
    if ($deleted) {
        logmsg("Deleted DNS CNAME for $fqdn");
    } else {
        logmsg("Failed to delete DNS CNAME for $fqdn");
    }
}

sub sync_cloudflare_ingress {
    my ($fqdn, $service, $secrets) = @_;

    my $lock = acquire_cf_lock();
    return unless $lock;

    my $url  = "https://api.cloudflare.com/client/v4/accounts/$secrets->{CF_ACCOUNT_ID}/cfd_tunnel/$secrets->{CF_TUNNEL_ID}/configurations";
    my $data = cf_api_request('GET', $url, $secrets->{CF_API_TOKEN});
    unless ($data) {
        logmsg("Failed to fetch tunnel configuration for $fqdn, skipping ingress update");
        release_cf_lock($lock);
        return;
    }

    my $ingress = $data->{result}{config}{ingress} || [];
    my $found   = 0;

    foreach my $entry (@$ingress) {
        if (defined $entry->{hostname} && $entry->{hostname} eq $fqdn) {
            $entry->{service} = $service;
            $found = 1;
            last;
        }
    }

    unless ($found) {
        if (@$ingress == 0 || defined $ingress->[-1]{hostname}) {
            logmsg("Tunnel ingress had no trailing catch-all rule, adding a default one");
            push @$ingress, { service => 'http_status:404' };
        }
        splice(@$ingress, -1, 0, { hostname => $fqdn, service => $service });
    }

    my $put_data = cf_api_request('PUT', $url, $secrets->{CF_API_TOKEN}, { config => { ingress => $ingress } });
    if ($put_data) {
        logmsg("Cloudflare tunnel ingress updated: $fqdn -> $service");
    } else {
        logmsg("Failed to update cloudflare tunnel ingress for $fqdn");
    }

    release_cf_lock($lock);
}

sub remove_cloudflare_ingress {
    my ($fqdn, $secrets) = @_;

    my $lock = acquire_cf_lock();
    return unless $lock;

    my $url  = "https://api.cloudflare.com/client/v4/accounts/$secrets->{CF_ACCOUNT_ID}/cfd_tunnel/$secrets->{CF_TUNNEL_ID}/configurations";
    my $data = cf_api_request('GET', $url, $secrets->{CF_API_TOKEN});
    unless ($data) {
        logmsg("Failed to fetch tunnel configuration for $fqdn, skipping ingress removal");
        release_cf_lock($lock);
        return;
    }

    my $ingress = $data->{result}{config}{ingress} || [];
    my @filtered = grep { !(defined $_->{hostname} && $_->{hostname} eq $fqdn) } @$ingress;

    if (@filtered == @$ingress) {
        logmsg("No cloudflare tunnel ingress entry found for $fqdn, nothing to remove");
        release_cf_lock($lock);
        return;
    }

    my $put_data = cf_api_request('PUT', $url, $secrets->{CF_API_TOKEN}, { config => { ingress => \@filtered } });
    if ($put_data) {
        logmsg("Cloudflare tunnel ingress removed for $fqdn");
    } else {
        logmsg("Failed to remove cloudflare tunnel ingress for $fqdn");
    }

    release_cf_lock($lock);
}

sub cloudflare_register {
    my @lines = read_config();
    my @tags  = get_tags(@lines);
    my $port  = parse_cft_tag(@tags);
    return unless defined $port;

    my $fqdn = get_hostname_from_config(@lines);
    unless (is_valid_fqdn($fqdn)) {
        logmsg("cft tag present for $vmid but name ('" . ($fqdn // '') . "') is missing or invalid, skipping cloudflare tunnel setup");
        return;
    }

    my $net = derive_network();
    unless ($net) {
        logmsg("cft tag present for $vmid ($fqdn) but no VMID-derived IP, skipping cloudflare tunnel setup");
        return;
    }
    my $ip = $net->{ip};

    my $secrets = load_secrets();
    return unless $secrets;
    unless (require_secrets($secrets, qw(CF_API_TOKEN CF_ACCOUNT_ID CF_TUNNEL_ID))) {
        logmsg("Secrets file missing CF_API_TOKEN/CF_ACCOUNT_ID/CF_TUNNEL_ID, skipping cloudflare tunnel step");
        return;
    }

    logmsg("Configuring cloudflare tunnel for $fqdn -> http://$ip:$port");
    ensure_dns_record($fqdn, $secrets);
    sync_cloudflare_ingress($fqdn, "http://$ip:$port", $secrets);
}

sub cloudflare_pre_stop_report {
    my @lines = read_config();
    my @tags  = get_tags(@lines);
    return unless defined parse_cft_tag(@tags);

    my $fqdn = get_hostname_from_config(@lines);
    return unless is_valid_fqdn($fqdn);

    logmsg("VM $vmid will deregister $fqdn from cloudflare tunnel + DNS on stop");
}

sub cloudflare_post_stop {
    my @lines = read_config();
    my @tags  = get_tags(@lines);
    return unless defined parse_cft_tag(@tags);

    my $fqdn = get_hostname_from_config(@lines);
    unless (is_valid_fqdn($fqdn)) {
        logmsg("cft tag present for $vmid but name ('" . ($fqdn // '') . "') is missing or invalid, nothing to deregister");
        return;
    }

    my $secrets = load_secrets();
    return unless $secrets;
    unless (require_secrets($secrets, qw(CF_API_TOKEN CF_ACCOUNT_ID CF_TUNNEL_ID))) {
        logmsg("Secrets file missing CF_API_TOKEN/CF_ACCOUNT_ID/CF_TUNNEL_ID, skipping cloudflare tunnel step");
        return;
    }

    logmsg("Removing cloudflare tunnel config for $fqdn");
    remove_cloudflare_ingress($fqdn, $secrets);
    delete_dns_record($fqdn, $secrets);
}

# -------------------------
# Hostname
# -------------------------
#
# The guest's hostname follows the VM's `name:`, the way Proxmox does it for
# containers: /etc/hostname gets the short name (first label), and the
# 127.0.1.1 line in /etc/hosts becomes "<full name> <short name>" (or just
# the short name when the VM name has no domain). Applied live with
# `hostname`, no reboot.

sub sync_guest_hostname {
    my $name = get_hostname_from_config(read_config());
    unless (defined $name && $name =~ /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$/i) {
        logmsg("VM $vmid has no usable name ('" . ($name // '') . "'), skipping hostname");
        return;
    }
    $name = lc $name;
    my ($short) = split /\./, $name;
    my $hosts_names = $name eq $short ? $short : "$name $short";

    my $cur_hostname = guest_capture('cat', '/etc/hostname') =~ s/\s+$//r;
    my ($cur_hosts)  = guest_capture('cat', '/etc/hosts') =~ /^127\.0\.1\.1[ \t]+(.*?)\s*$/m;
    $cur_hosts = join ' ', split ' ', ($cur_hosts // '');
    return if $cur_hostname eq $short && $cur_hosts eq $hosts_names;

    my ($rc, $out) = guest_exec(undef, 'sh', '-c', q{
        echo "$1" > /etc/hostname && hostname "$1" || exit 1
        if grep -q '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
            sed -i "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t$2/" /etc/hosts
        else
            printf '127.0.1.1\t%s\n' "$2" >> /etc/hosts
        fi
    }, 'sh', $short, $hosts_names);

    if ($rc == 0) {
        logmsg("Set hostname of VM $vmid to $short" . ($name ne $short ? " ($name)" : ''));
    } else {
        logmsg("Setting hostname of VM $vmid to $short failed (exit $rc): $out");
    }
}

# -------------------------
# Linux Update Dashboard SSH key sync
# -------------------------
#
# Every VM with the guest agent gets the Linux Update Dashboard's SSH public
# key merged into its authorized_keys on every start/reboot - no tag needed.
# Rotate the key by editing LUD_SSH_PUBKEY in the secrets file. The managed key
# lives inside a marked block so any other keys already present are left
# untouched. Same block markers as the LXC hookscript.

my $LUD_BEGIN = '# BEGIN lud-managed-key (hookscript, do not edit)';
my $LUD_END   = '# END lud-managed-key';

sub sync_lud_ssh_key {
    my $secrets = load_secrets();
    return unless $secrets;
    unless (require_secrets($secrets, qw(LUD_SSH_PUBKEY))) {
        logmsg("Secrets file missing LUD_SSH_PUBKEY, skipping Linux Update Dashboard SSH key sync");
        return;
    }

    my $pubkey  = $secrets->{LUD_SSH_PUBKEY};
    my $user    = $secrets->{LUD_SSH_USER} // 'root';
    my $home    = $user eq 'root' ? '/root' : "/home/$user";
    my $ssh_dir = "$home/.ssh";
    my $ak_file = "$ssh_dir/authorized_keys";

    unless (guest_run('id', '-u', $user)) {
        logmsg("User '$user' not found in VM $vmid, skipping LUD SSH key sync");
        return;
    }

    my @existing = split /^/m, guest_capture('cat', $ak_file);

    # Strip any previously-synced managed block, keep everything else.
    my @kept;
    my $in_block = 0;
    foreach my $line (@existing) {
        my $chomped = $line;
        chomp $chomped;
        if ($chomped eq $LUD_BEGIN) { $in_block = 1; next; }
        if ($chomped eq $LUD_END)   { $in_block = 0; next; }
        push @kept, $line unless $in_block;
    }
    $kept[-1] .= "\n" if @kept && $kept[-1] !~ /\n$/;
    pop @kept while @kept && $kept[-1] =~ /^\s*$/;
    push @kept, "\n" if @kept;
    push @kept, "$LUD_BEGIN\n", "$pubkey\n", "$LUD_END\n";

    eval {
        guest_push_content(join('', @kept), $ak_file);
        guest_run('chmod', '700', $ssh_dir)
            or die "chmod $ssh_dir in VM $vmid failed\n";
        guest_run('chmod', '600', $ak_file)
            or die "chmod $ak_file in VM $vmid failed\n";
        guest_run('chown', '-R', "$user:$user", $ssh_dir)
            or die "chown $ssh_dir in VM $vmid failed\n";

        logmsg("Synced Linux Update Dashboard SSH key into $vmid:$ak_file");
    };
    logmsg("Failed to sync LUD SSH key for $vmid: $@") if $@;
}

# -------------------------
# APT sources + config
# -------------------------
#
# apt.yaml picks the entries a Debian VM gets: `default` for all of
# them, plus `tags` (Proxmox tag -> entries) and `hostnames` (glob on the
# conf's name: line -> entries). An entry is apt.sources.d/<name>.sources
# and/or apt.conf.d/<name>; see apt.yaml for the details. Pushed via
# the guest agent (guest_exec), like the LUD key sync above.

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot open $path: $!\n";
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content;
}

sub glob_match {
    my ($glob, $str) = @_;
    my $re = join '', map { $_ eq '*' ? '.*' : $_ eq '?' ? '.' : quotemeta } split //, $glob;
    return $str =~ /^$re$/i;
}

sub apt_wanted_entries {
    my ($aptcfg, $tags, $fqdn) = @_;

    my @names = @{ $aptcfg->{default} || [] };
    push @names, @{ $aptcfg->{tags}{$_} || [] } foreach @$tags;

    if (defined $fqdn && length $fqdn) {
        my ($short) = split /\./, $fqdn;
        foreach my $glob (keys %{ $aptcfg->{hostnames} || {} }) {
            next unless glob_match($glob, $fqdn) || glob_match($glob, $short);
            push @names, @{ $aptcfg->{hostnames}{$glob} || [] };
        }
    }

    my %seen;
    return grep { !$seen{$_}++ } @names;
}

# Returns the host-side path of a usable key for <name>, refreshing the cache
# when it's older than $APT_KEY_MAX_AGE. Falls back to a stale cached copy if
# the download fails, undef if there's nothing at all.
sub apt_fetch_key {
    my ($name, $keyfile) = @_;

    my ($url) = grep { /\S/ } split /\n/, slurp("$APT_SOURCES_DIR/$name.gpg.link");
    $url =~ s/^\s+|\s+$//g;

    mkdir $APT_KEY_CACHE unless -d $APT_KEY_CACHE;
    my $cached = "$APT_KEY_CACHE/$keyfile";
    return $cached if -s $cached && -M $cached < $APT_KEY_MAX_AGE;

    my $tmp = "$cached.tmp.$$";
    if (system('curl', '-fsSL', '--max-time', '20', '-o', $tmp, $url) == 0 && -s $tmp) {
        rename $tmp, $cached or die "rename $tmp: $!\n";
        logmsg("Fetched APT key for $name from $url");
    } else {
        unlink $tmp;
        logmsg("Failed to fetch APT key for $name from $url" . (-s $cached ? ", using cached copy" : ''));
    }
    return -s $cached ? $cached : undef;
}

sub apt_install_source {
    my ($name, $dst, $codename) = @_;

    my $body = slurp("$APT_SOURCES_DIR/$name.sources");
    $body =~ s/\@CODENAME\@/$codename/g;

    foreach my $keypath (do { my %s; grep { !$s{$_}++ } $body =~ /^Signed-By:\s*(\/\S+)\s*$/mgi }) {
        if (-e "$APT_SOURCES_DIR/$name.gpg.link") {
            my $cached = apt_fetch_key($name, basename($keypath))
                or die "no key available for $name, leaving its source as-is\n";
            guest_push_file($cached, $keypath);
        } elsif (!guest_run('test', '-e', $keypath)) {
            die "key $keypath missing in VM and no $name.gpg.link to fetch it, leaving its source as-is\n";
        }
    }

    guest_push_content("# $APT_MARKER, do not edit\n$body", $dst);
    logmsg("Installed APT source $name into $vmid:$dst");
}

# A conf that points apt at a CA (`...::CaInfo "/path/x.crt";`, e.g. for an
# HTTPS-caching proxy) gets that cert pushed to /path/x.crt first, taken from
# apt.conf.d/x.crt. Cert before conf, so apt never sees a CaInfo pointing at
# nothing. If the cert can't be pushed the conf isn't installed either.
sub apt_install_conf {
    my ($name, $dst) = @_;
    my $body = slurp("$APT_CONF_DIR/$name");

    my %seen;
    foreach my $line (split /\n/, $body) {
        next if $line =~ m{^\s*(?:#|//)};
        next unless $line =~ /CaInfo\s+"(\/[^"]+)"/i;
        my $ca = $1;
        next if $seen{$ca}++;

        my $src = "$APT_CONF_DIR/" . basename($ca);
        if (-s $src) {
            guest_push_file($src, $ca);
            logmsg("Installed APT CA cert " . basename($ca) . " into $vmid:$ca");
        } elsif (!guest_run('test', '-s', $ca)) {
            die "CA cert $ca missing in VM and no apt.conf.d/" . basename($ca) . " to push, leaving the config as-is\n";
        }
    }

    guest_push_content("// $APT_MARKER, do not edit\n$body", $dst);
    logmsg("Installed APT config $name into $vmid:$dst");
}

sub apt_remove_unwanted {
    my ($keep) = @_;
    my $out = guest_capture('sh', '-c',
        "grep -lsF '$APT_MARKER' /etc/apt/sources.list.d/* /etc/apt/apt.conf.d/*");
    foreach my $path (grep { length } split /\n/, $out) {
        next if $keep->{$path};
        if (guest_run('rm', '-f', $path)) {
            logmsg("Removed APT file $vmid:$path (no longer in apt.yaml for this VM)");
        } else {
            logmsg("Failed to remove APT file $vmid:$path");
        }
    }
}

sub apt_disable_legacy {
    my $out = guest_capture('sh', '-c',
        'for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do [ -e "$f" ] && echo "$f"; done');
    foreach my $path (grep { length } split /\n/, $out) {
        if (guest_run('mv', '-f', $path, "$path.bak")) {
            logmsg("Disabled legacy APT source $vmid:$path (renamed to .bak)");
        } else {
            logmsg("Failed to disable legacy APT source $vmid:$path");
        }
    }
}

sub sync_apt {
    my $path = "$SNIPPETS/apt.yaml";
    return unless -e $path;
    my $aptcfg = eval { LoadFile($path) };
    if ($@) {
        logmsg("Failed to load $path: $@");
        return;
    }

    my $os = guest_capture('cat', '/etc/os-release');
    unless ($os =~ /^ID="?debian"?$/m) {
        logmsg("VM $vmid is not Debian, skipping APT sync");
        return;
    }
    my ($codename) = $os =~ /^VERSION_CODENAME="?([a-z]+)"?$/m;
    unless ($codename) {
        logmsg("No VERSION_CODENAME in $vmid:/etc/os-release, skipping APT sync");
        return;
    }

    my @lines = read_config();
    my @tags  = grep { length } map { s/^\s+|\s+$//gr } get_tags(@lines);
    my @names = apt_wanted_entries($aptcfg, \@tags, get_hostname_from_config(@lines));
    logmsg("APT entries for $vmid ($codename): @names");

    my %keep;
    my $installed_sources = 0;
    foreach my $name (@names) {
        my $has_source = -e "$APT_SOURCES_DIR/$name.sources";
        my $has_conf   = -e "$APT_CONF_DIR/$name";
        unless ($has_source || $has_conf) {
            logmsg("APT entry '$name' has no apt.sources.d/$name.sources or apt.conf.d/$name, skipping");
            next;
        }

        if ($has_source) {
            my $dst = "/etc/apt/sources.list.d/$name.sources";
            $keep{$dst} = 1;    # kept even if this push fails, so a bad key fetch doesn't drop a working repo
            eval { apt_install_source($name, $dst, $codename); $installed_sources++ };
            logmsg("APT source $name for $vmid: $@") if $@;
        }
        if ($has_conf) {
            my $dst = "/etc/apt/apt.conf.d/$name";
            $keep{$dst} = 1;
            eval { apt_install_conf($name, $dst) };
            logmsg("APT config $name for $vmid: $@") if $@;
        }
    }

    apt_remove_unwanted(\%keep);
    apt_disable_legacy() if $installed_sources;
}

# -------------------------
# Template base: disk growth + zram swap
# -------------------------
#
# Gives any Debian VM what the template has built in, so the hookscript can be
# attached to VMs that weren't cloned from it:
#   - cloud-guest-utils (growpart) + systemd-zram-generator, when missing
#   - from vm-template/: auto-extend-disk.sh + .service + udev rule (root
#     grows at boot and on a live `qm resize`), zram-generator.conf
#   - zram swap started
#   - swap on disk (partition, LVM volume or file) replaced by zram, and its
#     space given to root: vm-template/remove-disk-swap.sh, only once zram swap
#     is active. A VM tagged `keep-swap` keeps its swap on disk.
# On a template clone everything is already in place and nothing happens.

my @BASE_FILES = (
    # [file in vm-template/, path in the guest, mode]
    ['auto-extend-disk.sh',       '/usr/local/sbin/auto-extend-disk.sh',          '755'],
    ['remove-disk-swap.sh',       '/usr/local/sbin/remove-disk-swap.sh',          '755'],
    ['auto-extend-disk.service',  '/etc/systemd/system/auto-extend-disk.service', '644'],
    ['90-auto-extend-disk.rules', '/etc/udev/rules.d/90-auto-extend-disk.rules',  '644'],
    ['zram-generator.conf',       '/etc/systemd/zram-generator.conf',             '644'],
);
my $BASE_INSTALL_WAIT = 10 * 60;

sub zram_swap_active {
    return guest_capture('swapon', '--show=NAME', '--noheadings') =~ m{^/dev/zram}m;
}

sub sync_template_base {
    my $os = guest_capture('cat', '/etc/os-release');
    return unless $os =~ /^ID="?debian"?$/m;

    unless (guest_run('sh', '-c', 'command -v growpart >/dev/null && test -e /usr/lib/systemd/system-generators/zram-generator')) {
        logmsg("VM $vmid: installing cloud-guest-utils + systemd-zram-generator");
        guest_run_long('hookscript-base-install',
            'export DEBIAN_FRONTEND=noninteractive; '
          . 'apt-get -o DPkg::Lock::Timeout=600 update && '
          . 'apt-get -o DPkg::Lock::Timeout=600 install -y cloud-guest-utils systemd-zram-generator',
            $BASE_INSTALL_WAIT) or return;
    }

    my @changed;
    foreach my $f (@BASE_FILES) {
        my ($name, $dst, $mode) = @$f;
        my $src = "$SNIPPETS/vm-template/$name";
        next unless -s $src;
        next if guest_capture('cat', $dst) eq slurp($src);
        guest_push_file($src, $dst);
        guest_run('chmod', $mode, $dst);
        push @changed, $name;
    }
    if (@changed) {
        guest_run('systemctl', 'daemon-reload');
        guest_run('udevadm', 'control', '--reload');
        guest_run('systemctl', 'enable', '--quiet', 'auto-extend-disk.service');
        logmsg("VM $vmid: installed @changed");
    }

    unless (zram_swap_active()) {
        guest_run('systemctl', 'daemon-reload');
        guest_run('systemctl', 'start', 'systemd-zram-setup@zram0.service');
        guest_run('systemctl', 'start', 'dev-zram0.swap');
        if (zram_swap_active()) {
            logmsg("VM $vmid: zram swap active");
        } else {
            logmsg("VM $vmid: zram swap didn't start, keeping any swap on disk");
            return;
        }
    }

    my $disk_swap = guest_run('sh', '-c',
        q{swapon --show=NAME --noheadings | grep -qv '^/dev/zram' || awk '$1 !~ /^#/ && $3 == "swap"' /etc/fstab | grep -q .});
    if ($disk_swap && grep { $_ eq 'keep-swap' } get_tags(read_config())) {
        return;
    }
    if ($disk_swap) {
        logmsg("VM $vmid: replacing swap on disk by zram swap");
        my $ok = guest_run_long('hookscript-remove-disk-swap', '/usr/local/sbin/remove-disk-swap.sh', $BASE_INSTALL_WAIT);
        foreach my $line (split /\n/, guest_capture('cat', '/var/log/hookscript-remove-disk-swap.log')) {
            logmsg("VM $vmid: $1") if $line =~ /^remove-disk-swap: (.*)/;
        }
        return unless $ok;
    }
    elsif (grep { $_ eq 'auto-extend-disk.sh' } @changed) {
        # just installed: grow root now instead of waiting for the next boot
        guest_run('systemctl', 'start', 'auto-extend-disk.service');
    }
}

# -------------------------
# NFS mounts (mount tags from mounts.yaml)
# -------------------------
#
# The VM counterpart of the LXC mount points: same tags (mp-s, mp-a, ...),
# same target paths (`dst`), but the guest mounts the NAS export (`nfs`)
# itself instead of getting a bind mount from the host. The entries live in a
# marked block in /etc/fstab, rewritten from the tags on every start, and
# stay there across stops: a reboot from inside the guest runs no hooks, so
# the guest has to be able to mount them on its own. A tag that's removed
# gets its share unmounted and dropped from the block. Needs nfs-common
# (installed when missing) and the NAS export to allow the VM's subnet.

my $FSTAB_BEGIN = '# BEGIN vm-hookscript NFS mounts (mounts.yaml, do not edit)';
my $FSTAB_END   = '# END vm-hookscript NFS mounts';
my $NFS_INSTALL_WAIT = 10 * 60;

sub sync_nfs_mounts {
    my $path = "$SNIPPETS/mounts.yaml";
    return unless -e $path;
    my $cfg = eval { LoadFile($path) };
    if ($@) {
        logmsg("Failed to load $path: $@");
        return;
    }

    # Same merge as hookscript.pl: common, then this node's overrides
    my %mounts = %{ $cfg->{common} || {} };
    my $node = (split /\./, `hostname` // '')[0] // '';
    $node =~ s/\s+//g;
    if (my $ov = ($cfg->{hosts} || {})->{$node}) {
        @mounts{ keys %$ov } = values %$ov;
    }
    my $opts = ($cfg->{vm} || {})->{nfs_options} // 'vers=4.0,_netdev,nofail';

    my %want;    # dst -> nfs source
    foreach my $tag (get_tags(read_config())) {
        my $m = $mounts{$tag} or next;
        next unless $m->{nfs} && $m->{dst};
        $want{ $m->{dst} } = $m->{nfs};
    }

    my $fstab = guest_capture('cat', '/etc/fstab');
    my ($block) = $fstab =~ /^\Q$FSTAB_BEGIN\E\n(.*?)^\Q$FSTAB_END\E\n?/ms;
    my %have = map { (split ' ')[1] => 1 } grep { /\S/ && !/^\s*#/ } split /\n/, ($block // '');
    return unless %want || %have;

    if (%want && !guest_run('sh', '-c', 'test -x /sbin/mount.nfs || test -x /usr/sbin/mount.nfs')) {
        logmsg("VM $vmid: installing nfs-common");
        guest_run_long('hookscript-nfs-install',
            'export DEBIAN_FRONTEND=noninteractive; '
          . 'apt-get -o DPkg::Lock::Timeout=600 update && '
          . 'apt-get -o DPkg::Lock::Timeout=600 install -y nfs-common',
            $NFS_INSTALL_WAIT) or return;
    }

    foreach my $dst (sort grep { !$want{$_} } keys %have) {
        guest_run('umount', '-l', $dst);
        # rmdir only removes an empty folder, so anything written into the
        # mount point itself (not the share) stays
        my $removed = guest_run('rmdir', $dst);
        logmsg("VM $vmid: unmounted $dst (mount tag removed)"
             . ($removed ? ', folder removed' : ', folder kept (not empty)'));
    }

    my $rest = $fstab;
    $rest =~ s/^\Q$FSTAB_BEGIN\E\n.*?^\Q$FSTAB_END\E\n?//ms;
    $rest .= "\n" if length $rest && $rest !~ /\n$/;
    my $new = $rest;
    if (%want) {
        $new .= "$FSTAB_BEGIN\n"
              . join('', map { "$want{$_} $_ nfs $opts 0 0\n" } sort keys %want)
              . "$FSTAB_END\n";
    }
    if ($new ne $fstab) {
        guest_push_content($new, '/etc/fstab');
        guest_run('systemctl', 'daemon-reload');
    }

    foreach my $dst (sort keys %want) {
        next if guest_run('mountpoint', '-q', $dst);
        guest_run('mkdir', '-p', $dst);
        # timeout: a hard NFS mount to an unreachable NAS would otherwise hang
        my ($rc, $out) = guest_exec(undef, 'sh', '-c', "timeout 40 mount '$dst' 2>&1");
        if ($rc == 0) {
            logmsg("VM $vmid: mounted $want{$dst} on $dst");
        } else {
            $out =~ s/\s+/ /g;
            logmsg("VM $vmid: mounting $want{$dst} on $dst failed (exit $rc): $out");
        }
    }
}

# -------------------------
# Docker host (`docker` tag) -> Hawser -> Dockhand
# -------------------------
#
# A VM tagged `docker` turns itself into a Docker host managed by Dockhand -
# the VM counterpart of proxdock-provision.sh. Every step checks first and only
# does what's missing, so it runs on every start: add a `stack-<name>` tag,
# restart, and that stack gets deployed. Runs after the APT step, which has
# already put the Docker apt repo in place (apt.yaml: tags: docker).
#   1. wait for first-boot.service (a fresh clone's full upgrade holds dpkg)
#   2. install Docker when `docker` is missing
#   3. Hawser in /opt/stacks/hawser (compose.yaml from vm-template/hawser/);
#      a token is generated only when .env has none, so the Dockhand
#      connection survives restarts
#   4. register in Dockhand + deploy BASE_STACK and the stack-<name> tags
#      that Dockhand doesn't have yet (dockhand-register.sh, shared with LXC)
# Long-running work goes through guest_run_long, so it isn't bound by the
# agent's per-call timeout and survives the VM being restarted halfway.

my $PROVISION_CONF   = '/etc/pve/proxdock/provision.conf';
my $HAWSER_COMPOSE   = "$SNIPPETS/vm-template/hawser/compose.yaml";
my $HAWSER_DIR       = '/opt/stacks/hawser';
my $DOCKER_PACKAGES  = 'docker-ce docker-ce-cli containerd.io docker-compose-plugin';
my $FIRST_BOOT_WAIT  = 30 * 60;   # matches first-boot.service's TimeoutStartSec
my $LONG_STEP_WAIT   = 20 * 60;

# Runs a shell script in the guest as a transient systemd unit and waits for
# it. If that unit is still running (an earlier, interrupted job) it waits for
# that one instead of starting another. Output goes to /var/log/<unit>.log in
# the guest. Returns 1 when the script exited 0.
sub guest_run_long {
    my ($unit, $script, $max) = @_;
    my $rcfile = "/run/$unit.rc";
    my $state = guest_capture('systemctl', 'is-active', "$unit.service") =~ s/\s+//gr;

    unless ($state eq 'active' || $state eq 'activating') {
        my ($rc, $out) = guest_exec(undef, 'systemd-run', "--unit=$unit", '--collect', '--quiet',
            '--property=Type=oneshot', 'sh', '-c',
            "rm -f $rcfile; ( $script ) > /var/log/$unit.log 2>&1; echo \$? > $rcfile");
        if ($rc != 0) {
            logmsg("VM $vmid: starting $unit failed (exit $rc): $out");
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
        logmsg("VM $vmid: $unit still running after ${max}s, will check again on the next start");
        return 0;
    }

    my $exit = guest_capture('cat', $rcfile) =~ s/\s+//gr;
    return 1 if $exit eq '0';
    my $tail = guest_capture('tail', '-n', '5', "/var/log/$unit.log") =~ s/\s+/ /gr;
    logmsg("VM $vmid: $unit failed (exit " . ($exit eq '' ? '?' : $exit) . "): $tail");
    return 0;
}

sub wait_for_first_boot {
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
    unless (-s $HAWSER_COMPOSE) {
        logmsg("VM $vmid: $HAWSER_COMPOSE missing on the host, skipping Hawser");
        return;
    }

    my $compose_changed = guest_capture('cat', "$HAWSER_DIR/compose.yaml") ne slurp($HAWSER_COMPOSE);
    guest_push_file($HAWSER_COMPOSE, "$HAWSER_DIR/compose.yaml") if $compose_changed;

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

sub sync_docker_host {
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
    my $name = get_hostname_from_config(@lines);
    my $net  = derive_network();
    unless ($name && $net) {
        logmsg("VM $vmid: no name or no VMID-derived IP, can't register in Dockhand");
        return;
    }

    my ($base) = slurp($PROVISION_CONF) =~ /^BASE_STACK=["']?([^"'\s]*)/m;
    my @stacks = grep { length } ($base // ''), map { /^stack-(.+)$/ ? $1 : () } @tags;

    open(my $fh, '-|', "$SNIPPETS/dockhand-register.sh", $name, $net->{ip}, $token, $token_new, @stacks)
        or die "cannot run dockhand-register.sh: $!\n";
    while (my $line = <$fh>) {
        chomp $line;
        logmsg("VM $vmid: $line") if length $line;
    }
    close $fh;
    logmsg("VM $vmid: Dockhand registration failed (exit " . ($? >> 8) . ")") if $?;
}

# -------------------------
# Phase handling
# -------------------------

# Runs `vm-hookscript.pl <vmid> <phase>` as its own transient systemd unit
# (vm-hookscript-<vmid>), so neither the start task (which holds the VM's
# config lock) nor whoever ran `qm start` waits for it. A plain fork kept
# file handles of the caller open, which made e.g. `ssh host qm start` hang
# until the whole job was done. Same approach as proxdock-provision.sh.
# If the unit still exists (a job from an earlier start is running), that
# job carries on and no second one is started.
sub spawn_background {
    my ($bg_phase) = @_;
    my $unit = "vm-hookscript-$vmid";
    my $rc = system('systemd-run', '--quiet', '--collect', '--no-block', "--unit=$unit",
                    $^X, File::Spec->rel2abs($0), $vmid, $bg_phase);
    logmsg("Background $bg_phase job for $vmid not started (systemd-run exit " . ($rc >> 8)
         . "), is $unit from an earlier start still running?") if $rc;
}

# One background job per VM at a time (a quick reboot can start a second one).
sub lock_vm_job {
    open my $fh, '>', "/run/vm-hookscript-$vmid.lock" or return undef;
    flock($fh, LOCK_EX) or return undef;
    return $fh;
}

# Not a Proxmox phase: `vm-hookscript.pl apt-sync-all` (run by hooksync)
# re-runs the APT sync on every running VM with the guest agent. Each one runs
# as its own `vm-hookscript.pl <vmid> apt-sync`.
if ($vmid eq 'apt-sync-all') {
    foreach my $line (`qm list 2>/dev/null`) {
        next unless $line =~ /^\s*(\d+)\s+\S+\s+running\b/;
        system($^X, $0, $1, 'apt-sync');
    }
    exit(0);
}

if ($phase eq 'apt-sync') {
    if (agent_enabled(read_config()) && guest_agent_ping()) {
        eval { sync_apt() };
        logmsg("APT sync failed for $vmid: $@") if $@;
    }
}
elsif ($phase eq 'pre-start') {
    logmsg("$vmid is starting");
}
elsif ($phase eq 'post-start') {
    logmsg("$vmid started, guest sync running in the background (see /tmp/hook.log)");
    spawn_background('guest-sync');
}
elsif ($phase eq 'guest-sync') {
    my $lock    = lock_vm_job();
    my $started = time;
    eval { sync_net0_bridge() };
    logmsg("Bridge setup failed for $vmid: $@") if $@;
    eval { cloudflare_register() };
    logmsg("Cloudflare tunnel setup failed for $vmid: $@") if $@;

    if (!agent_enabled(read_config())) {
        logmsg("VM $vmid has no guest agent enabled (agent: 1), skipping network/SSH key/APT sync");
    }
    elsif (wait_for_agent()) {
        foreach my $step ([hostname => \&sync_guest_hostname], [network => \&sync_guest_network],
                          [ssh_key => \&sync_lud_ssh_key], [apt => \&sync_apt], [base => \&sync_template_base], [nfs => \&sync_nfs_mounts],
                          [docker => \&sync_docker_host]) {
            eval { $step->[1]->() };
            logmsg("$step->[0] sync failed for $vmid: $@") if $@;
        }
    }

    # Closing line, so the log shows the job is done (and not still busy or stuck)
    my $secs = time - $started;
    logmsg(sprintf("VM %s: guest sync done in %dm%02ds%s", $vmid, int($secs / 60), $secs % 60,
                   $LOG_PROBLEMS ? ", with $LOG_PROBLEMS problem(s), see the lines above" : ''));
}
elsif ($phase eq 'pre-stop') {
    cloudflare_pre_stop_report();
}
elsif ($phase eq 'post-stop') {
    logmsg("$vmid stopped");
    cloudflare_post_stop();
}

exit(0);
