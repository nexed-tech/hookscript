# pre-start/30-network.pl - network from the VMID (network.yaml)
#
# static mode (containers only; VMs get theirs in post-start/40-network.pl):
#   every NIC still on ip=dhcp (fresh clone) or already on the derived IP is
#   put on the VLAN's VNet (`tag=` dropped, the VNet tags) with the derived
#   ip=/gw= and, with ipv6_prefix set, ip6=/gw6=.
# ipam mode (containers and VMs):
#   net0 stays on DHCP; containers get net0 moved to the VNet, and for both the
#   derived IP is reserved for net0's MAC in SDN IPAM (Hook::Ipam). This has to
#   happen here, before Proxmox picks a pool address. A VM's net0 is moved to
#   the VNet later (post-start/10-bridge.pl): QEMU has read its config by now.
#
#   Guests: containers, VMs (ipam mode)      Config: network.yaml
package Hook::Step::PreStart::Network;

use strict;
use warnings;
use Hook;

return {
    name  => 'network',
    types => ['lxc', 'qemu'],
    run   => \&run,
};

sub run {
    # VMs only have something to do here in ipam mode
    return if is_vm() && ((config('network') || {})->{mode} // 'static') ne 'ipam';
    my $net = derive_network() or return;

    if ($net->{mode} eq 'ipam') {
        lxc_to_vnet($net) if is_lxc();
        my @lines = read_config();
        my $mac = net0_mac(@lines);
        unless ($mac) {
            logmsg(what() . " " . vmid() . " has no net0 MAC address, skipping IPAM reservation");
            return;
        }
        if (is_lxc() && !grep { /^net0:.*(?:^|[\s,])ip=dhcp(?:,|\s*$)/ } @lines) {
            logmsg("net0 of " . vmid() . " is not on ip=dhcp, ipam mode leaves it alone");
            return;
        }
        reserve_ipam_ip($net->{vnet}, $mac, $net->{ip}, $net->{gw});
    }
    elsif (is_lxc()) {
        lxc_static($net);
    }
}

# ipam mode: net0 (on ip=dhcp) onto the VNet
sub lxc_to_vnet {
    my ($net) = @_;
    edit_config(sub {
        my ($lines) = @_;
        foreach my $line (@$lines) {
            next unless $line =~ /^net0:\s*(.*?)\s*$/;
            my $rest = $1;
            return 0 unless $rest =~ /(?:^|,)ip=dhcp(?:,|$)/;

            my $orig = $rest;
            $rest =~ s/(?:^|,)\Kbridge=[^,]*/bridge=$net->{vnet}/ or $rest .= ",bridge=$net->{vnet}";
            $rest =~ s/,tag=\d+(?=,|$)//g;
            $rest =~ s/^tag=\d+,//;
            return 0 if $rest eq $orig;

            $line = "net0: $rest\n";
            logmsg("Moved net0 of " . vmid() . " to vnet $net->{vnet}");
            return 1;
        }
        logmsg("Container " . vmid() . " has no net0, skipping IPAM reservation");
        return 0;
    });
}

# static mode: a NIC is ours if it's still on DHCP (fresh clone) or already on
# the VMID-derived IP (set up earlier, possibly before the move to SDN).
sub lxc_static {
    my ($net) = @_;
    my ($vnet, $ip, $cidr, $gw, $ip6, $gw6) = @$net{qw(vnet ip cidr gw ip6 gw6)};

    edit_config(sub {
        my ($lines) = @_;
        my $changed = 0;
        foreach my $line (@$lines) {
            next unless $line =~ /^(net\d+):\s*(.*)$/;
            my ($netid, $rest) = ($1, $2);
            my $is_dhcp = $rest =~ /(?:^|,)ip=dhcp(?:,|$)/;
            my $is_ours = $rest =~ /(?:^|,)ip=\Q$ip\E\//;
            next unless $is_dhcp || $is_ours;

            my $orig = $rest;
            $rest =~ s/(?:^|,)\Kip=dhcp/ip=$ip\/$cidr,gw=$gw/ if $is_dhcp;
            $rest =~ s/(?:^|,)\Kbridge=[^,]*/bridge=$vnet/ or $rest .= ",bridge=$vnet";
            if (defined $ip6) {
                $rest =~ s/(?:^|,)\Kip6=[^,]*/ip6=$ip6/ or $rest .= ",ip6=$ip6";
                $rest =~ s/(?:^|,)\Kgw6=[^,]*/gw6=$gw6/ or $rest .= ",gw6=$gw6";
            }
            $rest =~ s/,tag=\d+(?=,|$)//g;
            $rest =~ s/^tag=\d+,//;
            next if $rest eq $orig;

            logmsg("Setting $netid for " . vmid() . " to $ip/$cidr, gw $gw"
                 . (defined $ip6 ? ", $ip6, gw6 $gw6" : '') . " on vnet $vnet");
            $line = "$netid: $rest\n";
            $changed = 1;
        }
        return $changed;
    });
}
