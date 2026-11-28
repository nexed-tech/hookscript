# post-start/30-hostname.pl - VM's hostname from its name
#
# The guest's hostname follows the VM's `name:`, the way Proxmox does it for
# containers: /etc/hostname gets the short name (first label), and the
# 127.0.1.1 line in /etc/hosts becomes "<full name> <short name>" (or just
# the short name when the VM name has no domain). Applied live with
# `hostname`, no reboot.
#
#   Guests: VMs (guest agent)
package Hook::Step::PostStart::Hostname;

use strict;
use warnings;
use Hook;

return {
    name  => 'hostname',
    types => ['qemu'],
    agent => 1,
    run   => \&run,
};

sub run {
    my $vmid = vmid();
    my $name = guest_name(read_config());
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
