# post-stop/10-mounts.pl - remove the managed mount points
#
# Takes the mount points added in pre-start/20-mounts.pl out of the config
# again, so a stopped container's config holds none of them (they're added
# back from its tags on the next start).
#
#   Guests: containers      Config: mounts.yaml
package Hook::Step::PostStop::Mounts;

use strict;
use warnings;
use Hook;

return {
    name  => 'mounts',
    types => ['lxc'],
    run   => \&run,
};

sub run {
    my %managed = map { ($_->{mp} // '') => 1 } values %{ managed_mounts() };
    return unless %managed;
    logmsg("Removing managed mountpoints.");

    edit_config(sub {
        my ($lines) = @_;
        my $before = @$lines;
        @$lines = grep {
            my $drop = /^(mp\d+):/ && $managed{$1};
            logmsg("Removing $1") if $drop;
            !$drop;
        } @$lines;
        return @$lines != $before;
    });
    logmsg("Mount cleanup complete");
}
