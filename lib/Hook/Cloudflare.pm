# Hook::Cloudflare - expose a guest through the Cloudflare Tunnel (`cft` tag).
#
#   cloudflare_register()     DNS CNAME + tunnel ingress for the guest
#   cloudflare_stop_report()  logs that the guest will be deregistered
#   cloudflare_deregister()   removes the ingress entry + DNS CNAME
#
# A tag of `cft` exposes the guest on port 80, `cft-<port>` on <port>. The
# guest's name (a container's hostname:, a VM's name:) is used as-is as the
# public FQDN, so name it e.g. `app.example.com`. The target is guest_ip(). The
# tunnel is remotely managed (Zero Trust dashboard), so ingress is edited via
# the Cloudflare API against the tunnel's remote configuration - no local
# cloudflared config or restart involved. Needs CF_API_TOKEN, CF_ACCOUNT_ID
# and CF_TUNNEL_ID in .env.secrets (see .env.secrets.example).
package Hook::Cloudflare;

use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use Fcntl qw(:flock);
use Exporter 'import';
use Hook::Log;
use Hook::Config;
use Hook::Guest;
use Hook::Network;

our @EXPORT = qw(cloudflare_register cloudflare_stop_report cloudflare_deregister);

sub parse_cft_tag {
    my @tags = @_;
    foreach my $tag (@tags) {
        return defined $1 ? $1 : 80 if $tag =~ /^cft(?:-(\d+))?$/;
    }
    return undef;
}

sub is_valid_fqdn {
    my ($fqdn) = @_;
    return defined($fqdn) && $fqdn =~ /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/i;
}

# The guest's FQDN when it has a cft tag (undef otherwise, logged when the
# name is unusable), plus the port.
sub cft_target {
    my ($action) = @_;
    my @lines = read_config();
    my $port  = parse_cft_tag(get_tags(@lines));
    return unless defined $port;

    my $fqdn = guest_name(@lines);
    unless (is_valid_fqdn($fqdn)) {
        logmsg("cft tag present for " . vmid() . " but name ('" . ($fqdn // '') . "') is missing or invalid, $action");
        return;
    }
    return ($fqdn, $port);
}

sub cf_secrets {
    my $secrets = load_secrets() or return undef;
    unless (require_secrets($secrets, qw(CF_API_TOKEN CF_ACCOUNT_ID CF_TUNNEL_ID))) {
        logmsg("Secrets file missing CF_API_TOKEN/CF_ACCOUNT_ID/CF_TUNNEL_ID, skipping cloudflare tunnel step");
        return undef;
    }
    return $secrets;
}

sub cloudflare_register {
    my ($fqdn, $port) = cft_target('skipping cloudflare tunnel setup') or return;
    my $ip = guest_ip();
    unless ($ip) {
        logmsg("cft tag present for " . vmid() . " ($fqdn) but no IP known, skipping cloudflare tunnel setup");
        return;
    }
    my $secrets = cf_secrets() or return;

    logmsg("Configuring cloudflare tunnel for $fqdn -> http://$ip:$port");
    ensure_dns_record($fqdn, $secrets);
    sync_cloudflare_ingress($fqdn, "http://$ip:$port", $secrets);
}

sub cloudflare_stop_report {
    my @lines = read_config();
    return unless defined parse_cft_tag(get_tags(@lines));
    my $fqdn = guest_name(@lines);
    return unless is_valid_fqdn($fqdn);
    logmsg(what() . " " . vmid() . " will deregister $fqdn from cloudflare tunnel + DNS on stop");
}

sub cloudflare_deregister {
    my ($fqdn) = cft_target('nothing to deregister') or return;
    my $secrets = cf_secrets() or return;

    logmsg("Removing cloudflare tunnel config for $fqdn");
    remove_cloudflare_ingress($fqdn, $secrets);
    delete_dns_record($fqdn, $secrets);
}

# -------------------------
# Cloudflare API
# -------------------------

sub lock_file { snippets() . '/.cf-tunnel.lock' }

sub acquire_cf_lock {
    my $file = lock_file();
    open my $lockfh, '>', $file or do {
        logmsg("Cannot open lock file $file: $!");
        return undef;
    };
    unless (flock($lockfh, LOCK_EX)) {
        logmsg("Cannot acquire lock on $file: $!");
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

1;
