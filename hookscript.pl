#!/usr/bin/perl

use strict;
use warnings;
use Sys::Hostname;
use IO::Handle;
use YAML::XS 'LoadFile';
use JSON::PP qw(encode_json decode_json);
use Fcntl qw(:flock);
use File::Basename qw(dirname basename);
use Sys::Syslog qw(openlog syslog);

my $vmid  = shift;
my $phase = shift;
my $LOG_ID = defined $vmid && $vmid =~ /^\d+$/ ? "hookscript-$vmid" : 'hookscript';
openlog($LOG_ID, 'pid', 'user');
my $conf_file = "/etc/pve/lxc/${vmid}.conf";
my $hostname  = hostname();

my $CF_SECRETS_FILE = '/var/lib/vz/snippets/.env.secrets';
my $CF_LOCK_FILE    = '/var/lib/vz/snippets/.cf-tunnel.lock';

# Per-cluster config overrides: a file in /etc/pve/hookscript/ wins over the
# repo copy in the snippets folder. That folder is a git checkout that hooksync
# pulls every night, so hosts that need different settings (e.g. the VPS hosts:
# no NAS mounts, no internal APT proxy, network.yaml in ipam mode) keep their
# own copy there.
my $LOCAL_CONF_DIR = '/etc/pve/hookscript';
sub conf_path {
    my ($name) = @_;
    my $local = "$LOCAL_CONF_DIR/$name";
    return -e $local ? $local : "/var/lib/vz/snippets/$name";
}

# Load YAML config (optional: without mounts.yaml there are no managed mounts)
my $mounts_file = conf_path('mounts.yaml');
my $config = -e $mounts_file ? LoadFile($mounts_file) : {};

# Start with common mounts
my %mounts = %{ $config->{common} || {} };

# Merge host-specific overrides if present
if (exists $config->{hosts}{$hostname}) {
    my $overrides = $config->{hosts}{$hostname};
    @mounts{ keys %$overrides } = values %$overrides;
}

# Also to the journal, as `hookscript-<vmid>` (identifier shown in the GUI's
# node -> System -> Syslog; search there for hookscript-10011, or just
# hookscript for all), with fields for exact filtering on the shell:
#   journalctl -t hookscript-10011 -f       one guest
#   journalctl HOOKSCRIPT_VMID=10011        the same, by field
#   journalctl HOOKSCRIPT=lxc               all container hooks (vm: all VM hooks)
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

sub logmsg {
    my ($msg) = @_;
    my $line = scalar(localtime) . " $msg\n";

    open my $log, '>>', '/tmp/hook.log';
    print $log $line;
    close $log;

    journal_log($msg, 'lxc');

    print STDOUT $line;
    STDOUT->flush();
}

sub read_config {
    open my $fh, '<', $conf_file or die "Cannot open $conf_file: $!";
    my @lines = <$fh>;
    close $fh;
    return @lines;
}

sub write_config {
    my (@lines) = @_;
    my $tmp = "$conf_file.tmp";
    open my $fh, '>', $tmp or die "Cannot write $tmp: $!";
    print $fh @lines;
    close $fh;
    rename $tmp, $conf_file or die "Cannot rename $tmp to $conf_file: $!";
}

sub get_tags {
    my @lines = @_;
    foreach my $line (@lines) {
        if ($line =~ /^tags:\s*(.*)$/) {
            return split(/[;,]/, $1);
        }
    }
    return ();
}

# VMID -> network, from network.yaml (see the comments there). Returns undef
# (after logging why) when the VMID isn't in the scheme or its VLAN has no
# VNet; computed once per run.
my $derived_network;

sub derive_network {
    return $derived_network || undef if defined $derived_network;
    $derived_network = 0;

    my $path = conf_path('network.yaml');
    return undef unless -e $path;
    my $netcfg = eval { LoadFile($path) };
    if ($@) {
        logmsg("Failed to load $path: $@");
        return undef;
    }

    # VVOOO, or VOOO for a one-digit network number (VPS hosts: VMID 2075)
    my ($vlan, $host) = $vmid =~ /^(\d{1,2})(\d{3})$/;
    unless (defined $vlan) {
        logmsg("VMID $vmid does not match VVOOO network scheme, skipping static IP");
        return undef;
    }
    $vlan = int($vlan);
    $host = int($host);

    my $vnet = ($netcfg->{vnets} || {})->{$vlan};
    unless (defined $vnet && length $vnet) {
        logmsg("VLAN $vlan (from VMID $vmid) has no SDN VNet in network.yaml, skipping static IP");
        return undef;
    }

    my $base     = $netcfg->{network}{base};
    my $gw_octet = $netcfg->{gateway_overrides}{$vlan} // $netcfg->{network}{gateway_octet};
    my %net = (
        mode => $netcfg->{mode} // 'static',
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

sub set_static_network {
    my $net = derive_network() or return;
    return set_ipam_network($net) if $net->{mode} eq 'ipam';

    my ($vnet, $ip, $cidr, $gw, $ip6, $gw6) = @$net{qw(vnet ip cidr gw ip6 gw6)};

    my @lines = read_config();
    my $changed = 0;

    # A NIC is ours if it's still on DHCP (fresh clone) or already on the
    # VMID-derived IP (set up earlier, possibly before the move to SDN). Both
    # get put on the VLAN's VNet (the VNet tags, so any old `tag=` goes) and
    # get the VMID-derived static IPv6.
    foreach my $line (@lines) {
        next unless $line =~ /^(net\d+):\s*(.*)$/;
        my ($netid, $rest) = ($1, $2);
        my $is_dhcp = $rest =~ /(?:^|,)ip=dhcp(?:,|$)/;
        my $is_ours = $rest =~ /(?:^|,)ip=\Q$ip\E\//;
        next unless $is_dhcp || $is_ours;

        my $orig = $rest;
        $rest =~ s/(?:^|,)\Kip=dhcp/ip=$ip\/$cidr,gw=$gw/ if $is_dhcp;
        if ($rest =~ /(?:^|,)bridge=/) {
            $rest =~ s/(?:^|,)\Kbridge=[^,]*/bridge=$vnet/;
        } else {
            $rest .= ",bridge=$vnet";
        }
        if (defined $ip6) {
            $rest =~ s/(?:^|,)\Kip6=[^,]*/ip6=$ip6/ or $rest .= ",ip6=$ip6";
            $rest =~ s/(?:^|,)\Kgw6=[^,]*/gw6=$gw6/ or $rest .= ",gw6=$gw6";
        }
        $rest =~ s/,tag=\d+(?=,|$)//g;
        $rest =~ s/^tag=\d+,//;
        next if $rest eq $orig;

        logmsg("Setting $netid for $vmid to $ip/$cidr, gw $gw" . (defined $ip6 ? ", $ip6, gw6 $gw6" : '') . " on vnet $vnet");
        $line = "$netid: $rest\n";
        $changed = 1;
    }

    write_config(@lines) if $changed;
}

# network.yaml `mode: ipam`: net0 stays on DHCP, is put on the VNet, and the
# VMID-derived IP is reserved for its MAC in the SDN zone's IPAM (see "SDN IPAM
# reservation" below). Only net0, only when it's on ip=dhcp; IPv6 is left alone.
sub set_ipam_network {
    my ($net) = @_;

    my @lines = read_config();
    my ($idx) = grep { $lines[$_] =~ /^net0:/ } 0 .. $#lines;
    unless (defined $idx) {
        logmsg("Container $vmid has no net0, skipping IPAM reservation");
        return;
    }
    my ($rest) = $lines[$idx] =~ /^net0:\s*(.*?)\s*$/;
    unless ($rest =~ /(?:^|,)ip=dhcp(?:,|$)/) {
        logmsg("net0 of $vmid is not on ip=dhcp, ipam mode leaves it alone");
        return;
    }

    my $orig = $rest;
    $rest =~ s/(?:^|,)\Kbridge=[^,]*/bridge=$net->{vnet}/ or $rest .= ",bridge=$net->{vnet}";
    $rest =~ s/,tag=\d+(?=,|$)//g;
    $rest =~ s/^tag=\d+,//;
    if ($rest ne $orig) {
        $lines[$idx] = "net0: $rest\n";
        write_config(@lines);
        logmsg("Moved net0 of $vmid to vnet $net->{vnet}");
    }

    my ($mac) = $rest =~ /(?:^|,)hwaddr=([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5})/;
    unless ($mac) {
        logmsg("net0 of $vmid has no hwaddr, skipping IPAM reservation");
        return;
    }
    reserve_ipam_ip($net->{vnet}, $mac, $net->{ip}, $net->{gw});
}

# -------------------------
# SDN IPAM reservation (network.yaml `mode: ipam`)
# -------------------------
#
# For hosts whose guests get their address from an SDN zone with DHCP
# (dnsmasq) + PVE IPAM, e.g. the single-IP VPS hosts behind SNAT. The guest
# keeps ip=dhcp; the hook reserves the VMID-derived IP for the NIC's MAC, so
# dnsmasq always hands out that address. Has to run at pre-start: Proxmox only
# picks a pool address when the MAC has no IPv4 in IPAM yet
# (PVE::Network::SDN::Vnets::add_dhcp_mapping), and does that after pre-start
# for containers (lxc-pve-prestart-hook) and VMs (pve-bridge). It already
# reserves a pool address at create time, so normally an entry gets moved:
# delete the pool address, create the derived one, then set the vmid on it
# (`create` doesn't take one). Destroying the guest frees the entry as usual.
# Same code in hookscript.pl and vm-hookscript.pl.

my $IPAM_STATE = '/etc/pve/sdn/pve-ipam-state.json';

sub ip4_to_int {
    my @o = split /\./, shift;
    return (($o[0] * 256 + $o[1]) * 256 + $o[2]) * 256 + $o[3];
}

sub sdn_vnet_zone {
    my ($vnet) = @_;
    open my $fh, '<', '/etc/pve/sdn/vnets.cfg' or return undef;
    my ($cur, $zone);
    while (my $l = <$fh>) {
        if ($l =~ /^\S+:\s*(\S+)/) { $cur = $1; next; }
        if (defined $cur && $cur eq $vnet && $l =~ /^\s+zone\s+(\S+)/) { $zone = $1; last; }
    }
    close $fh;
    return $zone;
}

# DHCP ranges ([start, end]) of the VNet's subnets
sub sdn_dhcp_ranges {
    my ($vnet) = @_;
    open my $fh, '<', '/etc/pve/sdn/subnets.cfg' or return ();
    my (@sections, $s);
    while (my $l = <$fh>) {
        if ($l =~ /^\S+:\s*\S+/) { $s = { ranges => [] }; push @sections, $s; next; }
        next unless $s;
        $s->{vnet} = $1 if $l =~ /^\s+vnet\s+(\S+)/;
        if ($l =~ /^\s+dhcp-range\s+(\S+)/) {
            my %kv = map { split /=/, $_, 2 } split /,/, $1;
            push @{ $s->{ranges} }, [ $kv{'start-address'}, $kv{'end-address'} ]
                if $kv{'start-address'} && $kv{'end-address'};
        }
    }
    close $fh;
    return map { @{ $_->{ranges} } } grep { ($_->{vnet} // '') eq $vnet } @sections;
}

# IPv4 entries of the zone's IPAM: { ip => { mac, vmid, gateway, ... } }
sub ipam_entries {
    my ($zone) = @_;
    open my $fh, '<', $IPAM_STATE or return {};
    local $/;
    my $state = eval { decode_json(<$fh>) } || {};
    close $fh;
    my %entries;
    foreach my $subnet (values %{ $state->{zones}{$zone}{subnets} || {} }) {
        while (my ($ip, $e) = each %{ $subnet->{ips} || {} }) {
            $entries{$ip} = $e if $ip =~ /^\d+\.\d+\.\d+\.\d+$/;
        }
    }
    return \%entries;
}

# The IPv4 address IPAM holds for this MAC on the VNet (undef if none)
sub ipam_ip_for_mac {
    my ($vnet, $mac) = @_;
    my $zone = sdn_vnet_zone($vnet) or return undef;
    my $entries = ipam_entries($zone);
    my ($ip) = grep { uc($entries->{$_}{mac} // '') eq uc($mac) } sort keys %$entries;
    return $ip;
}

sub pvesh_ipam {
    my ($action, $vnet, %opt) = @_;
    my @cmd = ('pvesh', $action, "/cluster/sdn/vnets/$vnet/ips",
               map { ("--$_", $opt{$_}) } sort keys %opt);
    my $pid = open(my $fh, '-|');
    return (1, "fork failed: $!") unless defined $pid;
    if (!$pid) {
        open STDERR, '>&', \*STDOUT;
        exec @cmd or exit 127;
    }
    local $/;
    my $out = <$fh> // '';
    close $fh;
    $out =~ s/\s+$//;
    return ($? >> 8, $out);
}

sub reserve_ipam_ip {
    my ($vnet, $mac, $ip, $gw) = @_;
    $mac = uc $mac;

    my $zone = sdn_vnet_zone($vnet);
    unless ($zone) {
        logmsg("VNet $vnet not found in /etc/pve/sdn/vnets.cfg, skipping IPAM reservation");
        return;
    }
    if ($ip eq $gw) {
        logmsg("$ip (from VMID $vmid) is the gateway of $vnet, not reserving it");
        return;
    }
    foreach my $r (sdn_dhcp_ranges($vnet)) {
        my $n = ip4_to_int($ip);
        if ($n >= ip4_to_int($r->[0]) && $n <= ip4_to_int($r->[1])) {
            logmsg("$ip (from VMID $vmid) is inside the DHCP range $r->[0]-$r->[1] of $vnet, not reserving it; $vmid keeps a pool address");
            return;
        }
    }

    my $entries = ipam_entries($zone);
    my $holder  = $entries->{$ip};
    if ($holder && uc($holder->{mac} // '') ne $mac) {
        my $who = $holder->{gateway} ? 'the gateway'
                : 'MAC ' . ($holder->{mac} // '?') . (defined $holder->{vmid} ? " (VMID $holder->{vmid})" : '');
        logmsg("$ip is already reserved in IPAM for $who, leaving $vmid on its pool address");
        return;
    }

    my @old = grep { $_ ne $ip && uc($entries->{$_}{mac} // '') eq $mac } sort keys %$entries;
    foreach my $old (@old) {
        my ($rc, $out) = pvesh_ipam('delete', $vnet, ip => $old, mac => $mac, zone => $zone);
        if ($rc) {
            logmsg("Removing IPAM entry $old for $mac failed: $out");
            return;
        }
    }

    unless ($holder) {
        my ($rc, $out) = pvesh_ipam('create', $vnet, ip => $ip, mac => $mac, zone => $zone);
        if ($rc) {
            logmsg("Reserving $ip for $mac in IPAM failed: $out");
            return;
        }
    }
    if (!$holder || ($holder->{vmid} // '') ne $vmid) {
        my ($rc, $out) = pvesh_ipam('set', $vnet, ip => $ip, mac => $mac, zone => $zone, vmid => $vmid);
        logmsg("Setting vmid $vmid on IPAM entry $ip failed: $out") if $rc;
    }

    if ($holder && !@old) {
        logmsg("$ip is reserved for $mac in IPAM (zone $zone, vnet $vnet)");
        return;
    }
    logmsg("Reserved $ip for $mac in IPAM (zone $zone, vnet $vnet)" . (@old ? ", was @old" : ''));
}

sub add_mounts {
    my @lines = read_config();
    my @tags  = get_tags(@lines);

    logmsg("Tags for $vmid: @tags");

    foreach my $tag (@tags) {
        next unless exists $mounts{$tag};

        my $mount = $mounts{$tag};
        my ($mpid, $src, $dst) = ($mount->{mp}, $mount->{src}, $mount->{dst});

        # Check if mount already exists
        my $exists = grep { /^$mpid:/ } @lines;
        next if $exists;

        logmsg("Adding $mpid ($src → $dst)");
        push @lines, "$mpid: $src,mp=$dst,replicate=0,backup=0,shared=1\n";
    }

    write_config(@lines);
}

sub remove_mounts {
    open my $in,  '<', $conf_file or die "Cannot open $conf_file: $!";
    my @lines = <$in>;
    close $in;

    my %managed = map { $mounts{$_}{mp} => 1 } keys %mounts;

    my @new;
    foreach my $line (@lines) {
        if ($line =~ /^(mp\d+):/) {
            my $mpid = $1;
            if (exists $managed{$mpid}) {
                logmsg("Removing $mpid");
                next;
            }
        }
        push @new, $line;
    }

    open my $out, '>', $conf_file or die "Cannot write $conf_file: $!";
    print $out @new;
    close $out;

    logmsg("Mount cleanup complete");
}

sub check_and_mount_nfs {
    my $max_attempts = 10;
    my $interval     = 5;

    foreach my $tag (keys %mounts) {
        my $src = $mounts{$tag}{src};

        for (my $i = 0; $i < $max_attempts; $i++) {
            if (system("mountpoint -q $src") == 0) {
                logmsg("Mount ready: $src");
                last;
            }
            logmsg("Attempting to mount: $src (try $i)");
            system("mount $src");
            sleep $interval;
            die "Failed to mount $src\n" if $i == $max_attempts - 1;
        }
    }
}

sub pre_stop_report {
    open my $in, '<', $conf_file or die "Cannot open $conf_file: $!";
    my @lines = <$in>;
    close $in;

    my %managed = map { $mounts{$_}{mp} => 1 } keys %mounts;

    my @to_remove;
    foreach my $line (@lines) {
        if ($line =~ /^(mp\d+):\s*(.*)$/) {
            my ($mpid, $rest) = ($1, $2);
            if (exists $managed{$mpid}) {
                push @to_remove, "$mpid ($rest)";
            }
        }
    }

    if (@to_remove) {
        logmsg("Container $vmid is shutting down.");
        logmsg("The following mountpoints will be removed after stop:");
        foreach my $entry (@to_remove) {
            logmsg("  - $entry");
        }
    } else {
        logmsg("Container $vmid is shutting down. No managed mountpoints found.");
    }
}

# -------------------------
# Cloudflare Tunnel reverse proxy
# -------------------------
#
# A tag of `cft` exposes the container on port 80 through the Cloudflare
# Tunnel; `cft-<port>` exposes it on <port>. The container's own `hostname:`
# conf line is used as-is as the public FQDN. The tunnel is remotely managed
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
        if ($line =~ /^hostname:\s*(.*?)\s*$/) {
            return $1;
        }
    }
    return undef;
}

sub is_valid_fqdn {
    my ($fqdn) = @_;
    return defined($fqdn) && $fqdn =~ /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/i;
}

sub get_container_ip {
    my @lines = @_;
    foreach my $line (@lines) {
        if ($line =~ /^net\d+:\s*(.*)$/) {
            my $rest = $1;
            if ($rest =~ /(?:^|,)ip=(\d+\.\d+\.\d+\.\d+)\/\d+/) {
                return $1;
            }
        }
    }
    return undef;
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

sub cloudflare_pre_start {
    my @lines = read_config();
    my @tags  = get_tags(@lines);
    my $port  = parse_cft_tag(@tags);
    return unless defined $port;

    my $fqdn = get_hostname_from_config(@lines);
    unless (is_valid_fqdn($fqdn)) {
        logmsg("cft tag present for $vmid but hostname ('" . ($fqdn // '') . "') is missing or invalid, skipping cloudflare tunnel setup");
        return;
    }

    my $ip = get_container_ip(@lines);
    # ipam mode: no ip= in the config; use what IPAM holds for net0's MAC
    # (normally the VMID-derived IP, reserved just before this in pre-start)
    my $net = derive_network();
    if (!$ip && $net && $net->{mode} eq 'ipam') {
        my ($mac) = map { /^net0:.*?(?:^|,|\s)hwaddr=([0-9A-Fa-f:]{17})/ ? $1 : () } @lines;
        $ip = ipam_ip_for_mac($net->{vnet}, $mac) if $mac;
    }
    unless ($ip) {
        logmsg("cft tag present for $vmid ($fqdn) but no static IP configured, skipping cloudflare tunnel setup");
        return;
    }

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

    logmsg("Container $vmid will deregister $fqdn from cloudflare tunnel + DNS on stop");
}

sub cloudflare_post_stop {
    my @lines = read_config();
    my @tags  = get_tags(@lines);
    return unless defined parse_cft_tag(@tags);

    my $fqdn = get_hostname_from_config(@lines);
    unless (is_valid_fqdn($fqdn)) {
        logmsg("cft tag present for $vmid but hostname ('" . ($fqdn // '') . "') is missing or invalid, nothing to deregister");
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
# Every container gets the Linux Update Dashboard's SSH public key merged
# into its authorized_keys on every start/reboot - no tag needed. Rotate the
# key by editing LUD_SSH_PUBKEY in the secrets file; the next start/reboot of
# any container picks it up. The managed key lives inside a marked block so
# any other keys already present are left untouched.

my $LUD_BEGIN = '# BEGIN lud-managed-key (hookscript, do not edit)';
my $LUD_END   = '# END lud-managed-key';

# Storage backends put a running container's rootfs in different places on
# the host (bind mount, ZFS dataset mountpoint, LVM-thin device, ...), so
# there's no single host-side path to guess. `pct exec` (lxc-attach) reaches
# into the container's own namespace instead, sidestepping that entirely -
# and since commands run as the container sees itself, "root" is just uid 0
# to it, no host/guest uid-shift math needed for unprivileged containers.
sub sync_lud_ssh_key {
    my $secrets = load_secrets();
    return unless $secrets;
    unless (require_secrets($secrets, qw(LUD_SSH_PUBKEY))) {
        logmsg("Secrets file missing LUD_SSH_PUBKEY, skipping Linux Update Dashboard SSH key sync");
        return;
    }

    my $pubkey = $secrets->{LUD_SSH_PUBKEY};
    my $user   = $secrets->{LUD_SSH_USER} // 'root';
    my $home   = $user eq 'root' ? '/root' : "/home/$user";
    my $ssh_dir = "$home/.ssh";
    my $ak_file = "$ssh_dir/authorized_keys";

    my $id_out = `pct exec $vmid -- id -u $user 2>/dev/null`;
    if ($? != 0 || $id_out !~ /^\d+/) {
        logmsg("User '$user' not found in container $vmid, skipping LUD SSH key sync");
        return;
    }

    my @existing = `pct exec $vmid -- cat $ak_file 2>/dev/null`;

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
    pop @kept while @kept && $kept[-1] =~ /^\s*$/;
    push @kept, "\n" if @kept;
    push @kept, "$LUD_BEGIN\n", "$pubkey\n", "$LUD_END\n";

    my $tmp = "/tmp/.lud-ak-$vmid.$$";
    eval {
        open my $fh, '>', $tmp or die "write $tmp: $!";
        print $fh @kept;
        close $fh;

        system("pct exec $vmid -- mkdir -p $ssh_dir") == 0
            or die "mkdir $ssh_dir in container $vmid failed\n";
        system("pct exec $vmid -- sh -c 'cat > $ak_file' < $tmp") == 0
            or die "writing $ak_file in container $vmid failed\n";
        system("pct exec $vmid -- chmod 700 $ssh_dir") == 0
            or die "chmod $ssh_dir in container $vmid failed\n";
        system("pct exec $vmid -- chmod 600 $ak_file") == 0
            or die "chmod $ak_file in container $vmid failed\n";
        system("pct exec $vmid -- chown -R $user:$user $ssh_dir") == 0
            or die "chown $ssh_dir in container $vmid failed\n";

        logmsg("Synced Linux Update Dashboard SSH key into $vmid:$ak_file");
    };
    logmsg("Failed to sync LUD SSH key for $vmid: $@") if $@;
    unlink $tmp;
}

# -------------------------
# APT sources + config
# -------------------------
#
# apt.yaml picks the entries a Debian container gets: `default` for all of
# them, plus `tags` (Proxmox tag -> entries) and `hostnames` (glob on the
# conf's hostname: line -> entries). An entry is apt.sources.d/<name>.sources
# and/or apt.conf.d/<name>; see apt.yaml for the details. Pushed via
# `pct push`/`pct exec` for the same reason as the LUD key sync above.

my $SNIPPETS        = '/var/lib/vz/snippets';
my $APT_SOURCES_DIR = "$SNIPPETS/apt.sources.d";
my $APT_CONF_DIR    = "$SNIPPETS/apt.conf.d";
my $APT_KEY_CACHE   = "$SNIPPETS/.apt-keys";
my $APT_KEY_MAX_AGE = 1;    # days before a cached key is re-downloaded
my $APT_MARKER      = 'managed by hookscript (apt.yaml)';

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

# Runs a command inside the container, returns its stdout (exit code ignored).
sub pct_capture {
    my (@cmd) = @_;
    open(my $fh, '-|', 'pct', 'exec', $vmid, '--', @cmd) or return '';
    local $/;
    my $out = <$fh> // '';
    close $fh;
    return $out;
}

sub pct_run {
    my (@cmd) = @_;
    return system('pct', 'exec', $vmid, '--', @cmd) == 0;
}

# Not `pct push`: that takes the container's config lock, which Proxmox still
# holds while the post-start hook runs, so it times out. `pct exec` doesn't.
# Written to a temp file + mv so apt never sees a half-written file.
sub pct_push_file {
    my ($src, $dst) = @_;
    pct_run('mkdir', '-p', dirname($dst)) or die "mkdir " . dirname($dst) . " in container $vmid failed\n";
    system("pct exec $vmid -- sh -c 'cat > $dst.tmp && chmod 0644 $dst.tmp && mv -f $dst.tmp $dst' < $src") == 0
        or die "pushing $dst into container $vmid failed\n";
}

sub pct_push_content {
    my ($content, $dst) = @_;
    my $tmp = "/tmp/.apt-$vmid.$$";
    open my $fh, '>', $tmp or die "write $tmp: $!\n";
    print $fh $content;
    close $fh;
    eval { pct_push_file($tmp, $dst) };
    my $err = $@;
    unlink $tmp;
    die $err if $err;
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
            pct_push_file($cached, $keypath);
        } elsif (!pct_run('test', '-e', $keypath)) {
            die "key $keypath missing in container and no $name.gpg.link to fetch it, leaving its source as-is\n";
        }
    }

    pct_push_content("# $APT_MARKER, do not edit\n$body", $dst);
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
            pct_push_file($src, $ca);
            logmsg("Installed APT CA cert " . basename($ca) . " into $vmid:$ca");
        } elsif (!pct_run('test', '-s', $ca)) {
            die "CA cert $ca missing in container and no apt.conf.d/" . basename($ca) . " to push, leaving the config as-is\n";
        }
    }

    pct_push_content("// $APT_MARKER, do not edit\n$body", $dst);
    logmsg("Installed APT config $name into $vmid:$dst");
}

sub apt_remove_unwanted {
    my ($keep) = @_;
    my $out = pct_capture('sh', '-c',
        "grep -lsF '$APT_MARKER' /etc/apt/sources.list.d/* /etc/apt/apt.conf.d/*");
    foreach my $path (grep { length } split /\n/, $out) {
        next if $keep->{$path};
        if (pct_run('rm', '-f', $path)) {
            logmsg("Removed APT file $vmid:$path (no longer in apt.yaml for this container)");
        } else {
            logmsg("Failed to remove APT file $vmid:$path");
        }
    }
}

sub apt_disable_legacy {
    my $out = pct_capture('sh', '-c',
        'for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do [ -e "$f" ] && echo "$f"; done');
    foreach my $path (grep { length } split /\n/, $out) {
        if (pct_run('mv', '-f', $path, "$path.bak")) {
            logmsg("Disabled legacy APT source $vmid:$path (renamed to .bak)");
        } else {
            logmsg("Failed to disable legacy APT source $vmid:$path");
        }
    }
}

sub sync_apt {
    my $path = conf_path('apt.yaml');
    return unless -e $path;
    my $aptcfg = eval { LoadFile($path) };
    if ($@) {
        logmsg("Failed to load $path: $@");
        return;
    }

    my $os = pct_capture('cat', '/etc/os-release');
    unless ($os =~ /^ID="?debian"?$/m) {
        logmsg("Container $vmid is not Debian, skipping APT sync");
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

# Not a Proxmox phase: `hookscript.pl apt-sync-all` (run daily by hooksync)
# re-runs the APT sync on every running container, so key rotations and
# apt.yaml changes reach containers that rarely restart. Each one runs as its
# own `hookscript.pl <vmid> apt-sync` so the per-container globals stay simple.
if ($vmid eq 'apt-sync-all') {
    foreach my $line (`pct list`) {
        next unless $line =~ /^\s*(\d+)\s+running\b/;
        system($^X, $0, $1, 'apt-sync');
    }
    exit(0);
}

$phase //= '';

if ($phase eq 'apt-sync') {
    sync_apt();
}
elsif ($phase eq 'pre-start') {
    logmsg("$vmid is starting");
    check_and_mount_nfs();
    add_mounts();
    set_static_network();
    cloudflare_pre_start();
}
elsif ($phase eq 'post-start') {
    sync_lud_ssh_key();
    eval { sync_apt() };
    logmsg("APT sync failed for $vmid: $@") if $@;
}
elsif ($phase eq 'pre-stop') {
    pre_stop_report();
    cloudflare_pre_stop_report();
}
elsif ($phase eq 'post-stop') {
    logmsg("$vmid stopped. Removing managed mountpoints.");
    remove_mounts();
    cloudflare_post_stop();
}

exit(0);
