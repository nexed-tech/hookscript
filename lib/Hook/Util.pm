# Hook::Util - small helpers without Proxmox or guest knowledge.
#
#   slurp($path)              file contents (dies when unreadable)
#   glob_match($glob, $str)   shell-style * and ? match, case-insensitive
#   deep_merge($base, $over)  hashes merged recursively, anything else replaced
package Hook::Util;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT = qw(slurp glob_match deep_merge);

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot open $path: $!\n";
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content;
}

sub glob_match {
    my ($glob, $str) = @_;
    my $re = join '', map { $_ eq '*' ? '.*' : $_ eq '?' ? '.' : quotemeta } split //, $glob;
    return $str =~ /^$re$/i;
}

# Returns a new structure: $over's values win; where both sides hold a hash,
# they're merged key by key.
sub deep_merge {
    my ($base, $over) = @_;
    return $over unless ref $base eq 'HASH' && ref $over eq 'HASH';
    my %out = %$base;
    $out{$_} = exists $out{$_} ? deep_merge($out{$_}, $over->{$_}) : $over->{$_} foreach keys %$over;
    return \%out;
}

1;
