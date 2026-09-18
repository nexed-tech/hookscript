#!/usr/bin/perl

use strict;
use warnings;
use Sys::Hostname;
use IO::Handle;
use YAML::XS 'LoadFile';
use JSON::PP qw(encode_json decode_json);
use Fcntl qw(:flock);

my $vmid  = shift;
my $phase = shift;
my $conf_file = "/etc/pve/lxc/${vmid}.conf";
my $hostname  = hostname();

my $CF_SECRETS_FILE = '/var/lib/vz/snippets/.env.secrets';
my $CF_LOCK_FILE    = '/var/lib/vz/snippets/.cf-tunnel.lock';

# Load YAML config
my $config = LoadFile('/var/lib/vz/snippets/mounts.yaml');

# Start with common mounts
my %mounts = %{ $config->{common} };

# Merge host-specific overrides if present
if (exists $config->{hosts}{$hostname}) {
    my $overrides = $config->{hosts}{$hostname};
    @mounts{ keys %$overrides } = values %$overrides;
}

sub logmsg {
    my ($msg) = @_;
    my $line = scalar(localtime) . " $msg\n";

    open my $log, '>>', '/tmp/hook.log';
    print $log $line;
    close $log;

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

sub load_network_config {
    my $path = '/var/lib/vz/snippets/network.yaml';
    return undef unless -e $path;
    my $netcfg = eval { LoadFile($path) };
    if ($@) {
        logmsg("Failed to load $path: $@");
        return undef;
    }
    return $netcfg;
}

sub set_static_network {
    my $netcfg = load_network_config();
    return unless $netcfg;

    my ($vlan, $host) = $vmid =~ /^(\d{2})(\d{3})$/;
    unless (defined $vlan) {
        logmsg("VMID $vmid does not match VVOOO network scheme, skipping static IP");
        return;
    }
    $vlan = int($vlan);
    $host = int($host);

    my @allowed_vlans = @{ $netcfg->{vlans} || [] };
    unless (grep { $_ == $vlan } @allowed_vlans) {
        logmsg("VLAN $vlan (from VMID $vmid) not in allowed vlans list, skipping static IP");
        return;
    }

    my $base        = $netcfg->{network}{base};
    my $cidr        = $netcfg->{network}{cidr};
    my $gw_octet    = $netcfg->{gateway_overrides}{$vlan} // $netcfg->{network}{gateway_octet};
    my %untagged    = map { $_ => 1 } @{ $netcfg->{untagged} || [] };

    my $ip = "$base.$vlan.$host";
    my $gw = "$base.$vlan.$gw_octet";
    my $tag_part = $untagged{$vlan} ? '' : ",tag=$vlan";

    my @lines = read_config();
    my $changed = 0;

    foreach my $line (@lines) {
        if ($line =~ /^(net\d+):\s*(.*)$/) {
            my ($netid, $rest) = ($1, $2);
            next unless $rest =~ /(?:^|,)ip=dhcp(?:,|$)/;

            $rest =~ s/(?:^|,)\Kip=dhcp/ip=$ip\/$cidr,gw=$gw/;
            $rest .= $tag_part if $tag_part && $rest !~ /(?:^|,)tag=/;

            logmsg("Setting $netid for $vmid to $ip/$cidr, gw $gw" . ($tag_part ? " (vlan $vlan)" : " (untagged, vlan $vlan)"));
            $line = "$netid: $rest\n";
            $changed = 1;
        }
    }

    write_config(@lines) if $changed;
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
        logmsg("Cloudflare secrets file $CF_SECRETS_FILE not found, skipping cloudflare tunnel step");
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

    foreach my $key (qw(CF_API_TOKEN CF_ACCOUNT_ID CF_TUNNEL_ID)) {
        unless (defined $secrets{$key} && length $secrets{$key}) {
            logmsg("Cloudflare secrets file $CF_SECRETS_FILE missing $key, skipping cloudflare tunnel step");
            return undef;
        }
    }

    return \%secrets;
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
    unless ($ip) {
        logmsg("cft tag present for $vmid ($fqdn) but no static IP configured, skipping cloudflare tunnel setup");
        return;
    }

    my $secrets = load_secrets();
    return unless $secrets;

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

    logmsg("Removing cloudflare tunnel config for $fqdn");
    remove_cloudflare_ingress($fqdn, $secrets);
    delete_dns_record($fqdn, $secrets);
}

# -------------------------
# Phase handling
# -------------------------

if ($phase eq 'pre-start') {
    logmsg("$vmid is starting");
    check_and_mount_nfs();
    add_mounts();
    set_static_network();
    cloudflare_pre_start();
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
