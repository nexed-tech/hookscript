# post-start/40-network.pl - static network inside a VM (static mode)
#
# Writes /etc/network/interfaces (ifupdown) from the VMID for the interface
# whose MAC matches net0, then brings that interface down and up again. Only
# touched when the file is still on DHCP for that interface, or was written by
# this hook before (marker line), and holds no other interfaces - anything
# hand-made is left alone. The original is kept as
# /etc/network/interfaces.vmhook.bak.
#
# DNS: the nameservers are the gateways. They go in as `dns-nameservers` (used
# when resolvconf is installed) and, when /etc/resolv.conf is a plain file
# (not a systemd-resolved/resolvconf symlink), straight into it, keeping its
# search/domain/options lines.
#
# ipam mode: nothing to do, the VM stays on DHCP and gets the address
# reserved in pre-start/30-network.pl.
#
#   Guests: VMs (guest agent)      Config: network.yaml
package Hook::Step::PostStart::Network;

use strict;
use warnings;
use JSON::PP qw(decode_json);
use Hook;

my $NET_MARKER = '# managed by vm-hookscript (network.yaml), do not edit';

return {
    name  => 'network',
    types => ['qemu'],
    agent => 1,
    run   => \&run,
};

sub run {
    my $net = derive_network() or return;
    return if $net->{mode} eq 'ipam';
    my $vmid = vmid();

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

sub guest_iface_for_mac {
    my ($mac) = @_;
    my $raw = `qm guest cmd @{[ vmid() ]} network-get-interfaces 2>/dev/null`;
    my $ifs = eval { decode_json($raw) };
    $ifs = $ifs->{result} if ref $ifs eq 'HASH';
    return undef unless ref $ifs eq 'ARRAY';
    foreach my $if (@$ifs) {
        return $if->{name} if lc($if->{'hardware-address'} // '') eq lc($mac);
    }
    return undef;
}

sub nameservers {
    my ($net) = @_;
    return grep { defined } $net->{gw}, $net->{gw6};
}

sub sync_resolv_conf {
    my ($net) = @_;
    my $vmid = vmid();
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
    my $vmid = vmid();
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
