# pre-start/40-cloudflare.pl - Cloudflare Tunnel for containers (`cft` tag)
#
# Registers the container's DNS name + tunnel ingress before it starts; its
# IP is known from the config by now (static ip=, or the IPAM reservation made
# in 30-network.pl). VMs register after starting (post-start/20-cloudflare.pl).
# See Hook::Cloudflare.
#
#   Guests: containers      Secrets: CF_*      Tags: cft, cft-<port>
package Hook::Step::PreStart::Cloudflare;

use strict;
use warnings;
use Hook;

return {
    name  => 'cloudflare',
    types => ['lxc'],
    run   => \&run,
};

sub run {
    cloudflare_register();
}
