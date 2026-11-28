# post-start/10-bridge.pl - VM's net0 onto the VLAN's SDN VNet
#
# Puts net0 on the VNet from the VMID and drops any `tag=` (the VNet tags).
# Done with `qm set` from the background job, once the start task has let go
# of the config lock (retried while it hasn't). Proxmox switches the bridge of
# a running VM live when network hotplug is on (the default); otherwise the
# change stays pending until the next start. Containers get this in
# pre-start/30-network.pl.
#
#   Guests: VMs      Config: network.yaml
package Hook::Step::PostStart::Bridge;

use strict;
use warnings;
use Hook;

return {
    name  => 'bridge',
    types => ['qemu'],
    run   => \&run,
};

sub run {
    my $net  = derive_network() or return;
    my $vmid = vmid();

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
