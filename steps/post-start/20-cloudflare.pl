# post-start/20-cloudflare.pl - Cloudflare Tunnel for VMs (`cft` tag)
#
# Registers the VM's DNS name + tunnel ingress. Needs no guest agent: the
# target IP comes from the VMID (or IPAM). Containers register before they
# start (pre-start/40-cloudflare.pl). See Hook::Cloudflare.
#
#   Guests: VMs      Secrets: CF_*      Tags: cft, cft-<port>
package Hook::Step::PostStart::Cloudflare;

use strict;
use warnings;
use Hook;

return {
    name  => 'cloudflare',
    types => ['qemu'],
    run   => \&run,
};

sub run {
    cloudflare_register();
}
