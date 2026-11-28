# pre-start/20-mounts.pl - bind-mount NAS shares into containers (mount tags)
#
# A container tagged with a mount tag (mp-s, mp-a, ...) gets that share as a
# mount point: `<mp>: <src>,mp=<dst>,...` in its config. Mount points the
# container already has are left alone. They're removed again after the
# container stops (post-stop/10-mounts.pl), so the config only holds them
# while it runs.
#
#   Guests: containers      Config: mounts.yaml      Tags: the keys of mounts.yaml
package Hook::Step::PreStart::Mounts;

use strict;
use warnings;
use Hook;

return {
    name  => 'mounts',
    types => ['lxc'],
    run   => \&run,
};

sub run {
    my $mounts = managed_mounts();
    my $vmid   = vmid();
    my @tags   = get_tags(read_config());
    logmsg("Tags for $vmid: @tags");

    edit_config(sub {
        my ($lines) = @_;
        my $changed = 0;
        foreach my $tag (@tags) {
            my $m = $mounts->{$tag} or next;
            my ($mpid, $src, $dst) = @$m{qw(mp src dst)};
            next unless $mpid && $src && $dst;
            next if grep { /^\Q$mpid\E:/ } @$lines;

            logmsg("Adding $mpid ($src → $dst)");
            append_line($lines, "$mpid: $src,mp=$dst,replicate=0,backup=0,shared=1\n");
            $changed = 1;
        }
        return $changed;
    });
}
