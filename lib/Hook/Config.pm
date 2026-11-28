# Hook::Config - profile, config files and secrets.
#
#   snippets()                 the snippets folder (this repo's checkout)
#   profile_name()             active profile, from profile.json (default: home)
#   config($name)              profiles/<profile>/<name>.yaml with profile.json's
#                              overrides for <name> merged in; undef if neither exists
#   load_secrets()             .env.secrets as a hash (undef when missing)
#   require_secrets($s, @keys) true when all keys are set
#
# profile.json (next to hookscript.pl, gitignored, one per node) picks the
# profile and can override any setting of its files, e.g.
#   { "profile": "vps", "overrides": { "network": { "vnets": { "2": "vnet0" } } } }
# Overrides merge into hashes key by key; lists and values replace. Without
# profile.json the `home` profile is used. A profile.json that can't be read
# turns all config off (logged) rather than falling back to another profile.
package Hook::Config;

use strict;
use warnings;
use JSON::PP qw(decode_json);
use YAML::XS 'LoadFile';
use Exporter 'import';
use Hook::Log;
use Hook::Util;

our @EXPORT = qw(snippets profile_name config load_secrets require_secrets);

my $SNIPPETS = '/var/lib/vz/snippets';
my $DEFAULT_PROFILE = 'home';
my ($profile, %config_cache, $secrets, $secrets_loaded);

sub init {
    my ($dir) = @_;
    $SNIPPETS = $dir if defined $dir;
}

sub snippets { $SNIPPETS }

sub profile {
    return $profile if defined $profile;
    my $file = "$SNIPPETS/profile.json";
    unless (-e $file) {
        $profile = { profile => $DEFAULT_PROFILE, overrides => {} };
        return $profile;
    }
    my $data = eval { decode_json(slurp($file)) };
    if ($@ || ref $data ne 'HASH' || ($data->{profile} // '') !~ /^[\w.-]+$/) {
        logmsg("profile.json is unreadable or has no valid \"profile\", running without network/mounts/apt config: "
             . ($@ || 'bad content'));
        $profile = { profile => '', overrides => {} };
        return $profile;
    }
    $data->{overrides} = {} unless ref $data->{overrides} eq 'HASH';
    $profile = $data;
    return $profile;
}

sub profile_name { profile()->{profile} }

sub config {
    my ($name) = @_;
    return $config_cache{$name} if exists $config_cache{$name};

    my $p = profile();
    my ($base, $over);
    if (length $p->{profile}) {
        my $path = "$SNIPPETS/profiles/$p->{profile}/$name.yaml";
        if (-e $path) {
            $base = eval { LoadFile($path) };
            if ($@) {
                logmsg("Failed to load $path: $@");
                $base = undef;
            }
        }
        $over = $p->{overrides}{$name};
    }

    my $cfg;
    if (ref $base eq 'HASH' || ref $over eq 'HASH') {
        $cfg = deep_merge(ref $base eq 'HASH' ? $base : {}, ref $over eq 'HASH' ? $over : {});
    }
    return $config_cache{$name} = $cfg;
}

sub load_secrets {
    return $secrets if $secrets_loaded++;
    my $file = "$SNIPPETS/.env.secrets";
    unless (-e $file) {
        logmsg("Secrets file $file not found, skipping features that need it");
        return $secrets = undef;
    }
    open my $fh, '<', $file or do {
        logmsg("Cannot open $file: $!");
        return $secrets = undef;
    };
    my %s;
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^\s*#/ || $line =~ /^\s*$/;
        $s{$1} = $2 if $line =~ /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/;
    }
    close $fh;
    return $secrets = \%s;
}

sub require_secrets {
    my ($s, @keys) = @_;
    foreach my $key (@keys) {
        return 0 unless defined $s->{$key} && length $s->{$key};
    }
    return 1;
}

1;
