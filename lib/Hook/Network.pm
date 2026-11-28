# Hook::Network - the guest's network, derived from its VMID (network.yaml).
#
#   derive_network()  { mode, vlan, host, vnet, ip, cidr, gw, ip6, gw6 }, or undef
#                     (logged) when the VMID isn't in the scheme or its VLAN has
#                     no VNet; computed once per run
#   guest_ip()        the IPv4 address the guest is reachable on (Cloudflare
#                     tunnel, Dockhand), or undef
#
# VMID VVOOO (or VOOO for a one-digit network number): VV picks the VNet and is
# the 3rd octet, OOO the 4th. See profiles/*/network.yaml.
package Hook::Network;

use strict;
use warnings;
use Exporter 'import';
use Hook::Log;
use Hook::Config;
use Hook::Guest;
use Hook::Ipam;

our @EXPORT = qw(derive_network guest_ip);

my $derived;

sub derive_network {
    return $derived || undef if defined $derived;
    $derived = 0;

    my $netcfg = config('network') or return undef;
    my $vmid = vmid();

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
    my $gw_octet = ($netcfg->{gateway_overrides} || {})->{$vlan} // $netcfg->{network}{gateway_octet};
    my %net = (
        mode => $netcfg->{mode} // 'static',
        vlan => $vlan,
        host => $host,
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

    $derived = \%net;
    return $derived;
}

# Containers: a static ip= on any NIC wins (also outside the VMID scheme).
# ipam mode: what IPAM holds for net0's MAC (normally the derived IP, a pool
# address when the reservation was refused). Otherwise VMs use the derived IP.
sub guest_ip {
    my @lines = read_config();
    if (is_lxc()) {
        foreach my $line (@lines) {
            return $1 if $line =~ /^net\d+:.*?(?:^|[\s,])ip=(\d+\.\d+\.\d+\.\d+)\/\d+/;
        }
    }
    my $net = derive_network() or return undef;
    if ($net->{mode} eq 'ipam') {
        my $mac = net0_mac(@lines) or return undef;
        return ipam_ip_for_mac($net->{vnet}, $mac);
    }
    return is_vm() ? $net->{ip} : undef;
}

1;
