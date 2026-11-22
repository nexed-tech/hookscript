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
#   4. writes a static /etc/network/interfaces from the VMID (network.yaml)
#      and brings the interface down and up again
#   5. syncs the Linux Update Dashboard SSH key
#   6. syncs APT sources/config/keys (apt.yaml)
# post-stop removes the Cloudflare tunnel entry again.
#
# Not done for VMs (LXC-only): mount points.

use strict;
use warnings;
use IO::Handle;
use POSIX qw(setsid);
use YAML::XS 'LoadFile';
use JSON::PP qw(encode_json decode_json);
use Fcntl qw(:flock);
use File::Basename qw(dirname basename);

my $vmid  = shift // '';
my $phase = shift // '';
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

sub logmsg {
    my ($msg) = @_;
    my $line = scalar(localtime) . " [vm] $msg\n";

    if (open my $log, '>>', '/tmp/hook.log') {
        print $log $line;
        close $log;
    }

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
# Phase handling
# -------------------------

# Runs `vm-hookscript.pl <vmid> <phase>` detached from the hook, so the start
# task (which holds the VM's config lock) doesn't wait for it.
sub spawn_background {
    my ($bg_phase) = @_;
    my $pid = fork();
    unless (defined $pid) {
        logmsg("Cannot fork background $bg_phase job for $vmid: $!");
        return;
    }
    return if $pid;

    setsid();
    open STDIN,  '<',  '/dev/null';
    open STDOUT, '>',  '/dev/null';
    open STDERR, '>>', '/tmp/hook.log';
    exec($^X, $0, $vmid, $bg_phase) or exit(1);
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
    spawn_background('guest-sync');
}
elsif ($phase eq 'guest-sync') {
    my $lock = lock_vm_job();
    eval { sync_net0_bridge() };
    logmsg("Bridge setup failed for $vmid: $@") if $@;
    eval { cloudflare_register() };
    logmsg("Cloudflare tunnel setup failed for $vmid: $@") if $@;

    if (!agent_enabled(read_config())) {
        logmsg("VM $vmid has no guest agent enabled (agent: 1), skipping network/SSH key/APT sync");
    }
    elsif (wait_for_agent()) {
        foreach my $step ([network => \&sync_guest_network], [ssh_key => \&sync_lud_ssh_key], [apt => \&sync_apt]) {
            eval { $step->[1]->() };
            logmsg("$step->[0] sync failed for $vmid: $@") if $@;
        }
    }
}
elsif ($phase eq 'pre-stop') {
    cloudflare_pre_stop_report();
}
elsif ($phase eq 'post-stop') {
    logmsg("$vmid stopped");
    cloudflare_post_stop();
}

exit(0);
