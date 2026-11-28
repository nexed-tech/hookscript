# Hook - everything a step needs, in one `use Hook;`.
#
# Loads the helper modules below and exports all their functions into the
# caller. See each module's header for what it offers:
#   Hook::Util        slurp, glob_match, deep_merge
#   Hook::Log         logmsg
#   Hook::Config      snippets, profile_name, config, load_secrets, require_secrets
#   Hook::Guest       the guest (container or VM): config, tags, name, commands inside it
#   Hook::Network     derive_network, guest_ip
#   Hook::Ipam        reserve_ipam_ip, ipam_ip_for_mac
#   Hook::Cloudflare  cloudflare_register, cloudflare_stop_report, cloudflare_deregister
#   Hook::Mounts      managed_mounts, vm_nfs_options
#   Hook::Apt         sync_apt
package Hook;

use strict;
use warnings;

our @MODULES = qw(Hook::Util Hook::Log Hook::Config Hook::Guest Hook::Ipam Hook::Network Hook::Mounts
                  Hook::Cloudflare Hook::Apt);

foreach my $module (@MODULES) {
    (my $file = "$module.pm") =~ s{::}{/}g;
    require $file;
}

# Puts every module's @EXPORT functions into the package that says `use Hook;`
sub import {
    my $caller = caller;
    no strict 'refs';
    foreach my $module (@MODULES) {
        *{"${caller}::$_"} = \&{"${module}::$_"} foreach @{"${module}::EXPORT"};
    }
}

1;
