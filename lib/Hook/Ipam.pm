# Hook::Ipam - SDN IPAM reservations (network.yaml `mode: ipam`).
#
#   reserve_ipam_ip($vnet, $mac, $ip, $gw)   reserve $ip for $mac (logged)
#   ipam_ip_for_mac($vnet, $mac)             the IPv4 IPAM holds for $mac, or undef
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
# Refused (guest keeps its pool address): the gateway, an address inside the
# subnet's DHCP range, an address IPAM holds for another MAC.
package Hook::Ipam;

use strict;
use warnings;
use JSON::PP qw(decode_json);
use Exporter 'import';
use Hook::Log;
use Hook::Util;
use Hook::Guest;

our @EXPORT = qw(reserve_ipam_ip ipam_ip_for_mac);

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
    return {} unless -e $IPAM_STATE;
    my $state = eval { decode_json(slurp($IPAM_STATE)) } || {};
    my %entries;
    foreach my $subnet (values %{ $state->{zones}{$zone}{subnets} || {} }) {
        while (my ($ip, $e) = each %{ $subnet->{ips} || {} }) {
            $entries{$ip} = $e if $ip =~ /^\d+\.\d+\.\d+\.\d+$/;
        }
    }
    return \%entries;
}

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
    my $vmid = vmid();
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

1;
