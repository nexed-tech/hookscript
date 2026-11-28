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

require Exporter;

# The modules use Exporter's import without inheriting from it, so
# export_to_level is called as a function.
sub import {
    no strict 'refs';
    Exporter::export_to_level($_, 1, $_, @{"${_}::EXPORT"}) foreach @MODULES;
}

1;
