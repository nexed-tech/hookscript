# Hook::Mounts - the mount tags of mounts.yaml.
#
#   managed_mounts()   { tag => { mp, src, nfs, dst } }: `common`, then this
#                      node's entries under `hosts:` on top
#   vm_nfs_options()   mount options for VMs' NFS entries
#
# Same tag, same target path in containers and VMs: containers get a bind
# mount of the host's NFS mount (`mp` + `src` -> `dst`), VMs mount the NAS
# export themselves (`nfs` -> `dst`, /etc/fstab). See profiles/home/mounts.yaml.
package Hook::Mounts;

use strict;
use warnings;
use Sys::Hostname;
use Exporter 'import';
use Hook::Config;

our @EXPORT = qw(managed_mounts vm_nfs_options);

sub managed_mounts {
    my $cfg = config('mounts') or return {};
    my %mounts = %{ $cfg->{common} || {} };

    my $node  = hostname();
    my $short = (split /\./, $node)[0];
    my $hosts = $cfg->{hosts} || {};
    my $ov    = $hosts->{$node} || $hosts->{$short};
    @mounts{ keys %$ov } = values %$ov if ref $ov eq 'HASH';
    return \%mounts;
}

sub vm_nfs_options {
    my $cfg = config('mounts') || {};
    return ($cfg->{vm} || {})->{nfs_options} // 'vers=4.0,_netdev,nofail';
}

1;
