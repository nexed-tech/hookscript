#!/usr/bin/perl
#
# Kept so guests attached as `hookscript: local:snippets/vm-hookscript.pl` keep
# working: hookscript.pl handles containers and VMs now, this just runs it.
# New guests can use hookscript.pl directly.
#
# `vm-hookscript.pl apt-sync-all` does nothing: `hookscript.pl apt-sync-all`
# covers VMs too (hooksync used to call both).

use strict;
use warnings;
use FindBin;

exit 0 if ($ARGV[0] // '') eq 'apt-sync-all';
exec $^X, "$FindBin::RealBin/hookscript.pl", @ARGV
    or die "cannot run $FindBin::RealBin/hookscript.pl: $!\n";
