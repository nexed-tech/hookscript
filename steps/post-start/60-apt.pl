# post-start/60-apt.pl - APT sources + config in Debian guests
#
# Installs the guest's apt.yaml entries and removes ones it no longer gets.
# Also run outside of starts by `hookscript.pl apt-sync-all` (hooksync, daily),
# so key rotations and apt.yaml changes reach guests that rarely restart. See
# Hook::Apt.
#
#   Guests: containers, VMs (guest agent)      Config: apt.yaml
package Hook::Step::PostStart::Apt;

use strict;
use warnings;
use Hook;

return {
    name  => 'apt',
    types => ['lxc', 'qemu'],
    agent => 1,
    run   => \&run,
};

sub run {
    sync_apt();
}
