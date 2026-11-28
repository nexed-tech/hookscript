# pre-start/10-host-nfs.pl - make sure the host's NFS mounts are up
#
# Containers get the NAS shares as bind mounts of the host's own NFS mounts
# (`src` in mounts.yaml), so those have to be mounted before the container
# starts. Each one is tried 10 times, 5 seconds apart. Fatal: if a share can't
# be mounted, the container doesn't start (rather than starting with an empty
# folder where the share should be).
#
#   Guests: containers      Config: mounts.yaml
package Hook::Step::PreStart::HostNfs;

use strict;
use warnings;
use Hook;

return {
    name  => 'host NFS mounts',
    types => ['lxc'],
    fatal => 1,
    run   => \&run,
};

sub run {
    my $mounts = managed_mounts();
    my $max_attempts = 10;
    my $interval     = 5;

    foreach my $tag (sort keys %$mounts) {
        my $src = $mounts->{$tag}{src} or next;

        for (my $i = 0; $i < $max_attempts; $i++) {
            if (system('mountpoint', '-q', $src) == 0) {
                logmsg("Mount ready: $src");
                last;
            }
            logmsg("Attempting to mount: $src (try $i)");
            system('mount', $src);
            sleep $interval;
            die "Failed to mount $src\n" if $i == $max_attempts - 1;
        }
    }
}
