# post-stop/20-cloudflare.pl - remove the guest from the Cloudflare Tunnel
#
# Takes the guest's tunnel ingress entry and DNS CNAME away again; they're
# added back on the next start. See Hook::Cloudflare.
#
#   Guests: containers, VMs      Secrets: CF_*      Tags: cft, cft-<port>
package Hook::Step::PostStop::Cloudflare;

use strict;
use warnings;
use Hook;

return {
    name  => 'cloudflare',
    types => ['lxc', 'qemu'],
    run   => \&run,
};

sub run {
    cloudflare_deregister();
}
