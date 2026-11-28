# pre-stop/20-cloudflare.pl - report the Cloudflare Tunnel deregistration
#
# Logs that the guest's tunnel entry + DNS name go after the stop
# (post-stop/20-cloudflare.pl). See Hook::Cloudflare.
#
#   Guests: containers, VMs      Tags: cft, cft-<port>
package Hook::Step::PreStop::Cloudflare;

use strict;
use warnings;
use Hook;

return {
    name  => 'cloudflare',
    types => ['lxc', 'qemu'],
    run   => \&run,
};

sub run {
    cloudflare_stop_report();
}
