# pre-stop/10-mounts.pl - report the mount points that go after the stop
#
# Logs which managed mount points (mounts.yaml) the container has; they're
# removed in post-stop/10-mounts.pl.
#
#   Guests: containers      Config: mounts.yaml
package Hook::Step::PreStop::Mounts;

use strict;
use warnings;
use Hook;

return {
    name  => 'mounts',
    types => ['lxc'],
    run   => \&run,
};

sub run {
    my $vmid    = vmid();
    my %managed = map { ($_->{mp} // '') => 1 } values %{ managed_mounts() };

    my @to_remove;
    foreach my $line (read_config()) {
        push @to_remove, "$1 ($2)" if $line =~ /^(mp\d+):\s*(.*?)\s*$/ && $managed{$1};
    }

    if (@to_remove) {
        logmsg("Container $vmid is shutting down.");
        logmsg("The following mountpoints will be removed after stop:");
        logmsg("  - $_") foreach @to_remove;
    } else {
        logmsg("Container $vmid is shutting down. No managed mountpoints found.");
    }
}
