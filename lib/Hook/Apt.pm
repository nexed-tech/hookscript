# Hook::Apt - APT sources + config in Debian guests (apt.yaml).
#
#   sync_apt()   installs the guest's entries, removes ones it no longer gets
#
# apt.yaml picks the entries a guest gets: `default` for all of them, plus
# `tags` (Proxmox tag -> entries) and `hostnames` (glob on the guest's name ->
# entries). An entry is apt.sources.d/<name>.sources and/or apt.conf.d/<name>
# in the snippets folder; see profiles/home/apt.yaml for the details. Files the
# hook writes carry a marker line; when an entry stops applying, its file is
# removed. Legacy one-line sources are renamed to *.bak once a deb822 source is
# in place.
package Hook::Apt;

use strict;
use warnings;
use File::Basename qw(basename);
use Exporter 'import';
use Hook::Log;
use Hook::Util;
use Hook::Config;
use Hook::Guest;

our @EXPORT = qw(sync_apt);

my $APT_KEY_MAX_AGE = 1;    # days before a cached key is re-downloaded
my $APT_MARKER      = 'managed by hookscript (apt.yaml)';

sub sources_dir { snippets() . '/apt.sources.d' }
sub conf_dir    { snippets() . '/apt.conf.d' }
sub key_cache   { snippets() . '/.apt-keys' }

sub sync_apt {
    my $aptcfg = config('apt') or return;
    my $vmid = vmid();

    my $os = guest_capture('cat', '/etc/os-release');
    unless ($os =~ /^ID="?debian"?$/m) {
        logmsg(what() . " $vmid is not Debian, skipping APT sync");
        return;
    }
    my ($codename) = $os =~ /^VERSION_CODENAME="?([a-z]+)"?$/m;
    unless ($codename) {
        logmsg("No VERSION_CODENAME in $vmid:/etc/os-release, skipping APT sync");
        return;
    }

    my @lines = read_config();
    my @names = apt_wanted_entries($aptcfg, [ get_tags(@lines) ], guest_name(@lines));
    logmsg("APT entries for $vmid ($codename): @names");

    my %keep;
    my $installed_sources = 0;
    foreach my $name (@names) {
        my $has_source = -e sources_dir() . "/$name.sources";
        my $has_conf   = -e conf_dir() . "/$name";
        unless ($has_source || $has_conf) {
            logmsg("APT entry '$name' has no apt.sources.d/$name.sources or apt.conf.d/$name, skipping");
            next;
        }

        if ($has_source) {
            my $dst = "/etc/apt/sources.list.d/$name.sources";
            $keep{$dst} = 1;    # kept even if this push fails, so a bad key fetch doesn't drop a working repo
            eval { apt_install_source($name, $dst, $codename); $installed_sources++ };
            logmsg("APT source $name for $vmid: $@") if $@;
        }
        if ($has_conf) {
            my $dst = "/etc/apt/apt.conf.d/$name";
            $keep{$dst} = 1;
            eval { apt_install_conf($name, $dst) };
            logmsg("APT config $name for $vmid: $@") if $@;
        }
    }

    apt_remove_unwanted(\%keep);
    apt_disable_legacy() if $installed_sources;
}

sub apt_wanted_entries {
    my ($aptcfg, $tags, $fqdn) = @_;

    my @names = @{ $aptcfg->{default} || [] };
    push @names, @{ ($aptcfg->{tags} || {})->{$_} || [] } foreach @$tags;

    if (defined $fqdn && length $fqdn) {
        my ($short) = split /\./, $fqdn;
        foreach my $glob (keys %{ $aptcfg->{hostnames} || {} }) {
            next unless glob_match($glob, $fqdn) || glob_match($glob, $short);
            push @names, @{ $aptcfg->{hostnames}{$glob} || [] };
        }
    }

    my %seen;
    return grep { !$seen{$_}++ } @names;
}

# Returns the host-side path of a usable key for <name>, refreshing the cache
# when it's older than $APT_KEY_MAX_AGE. Falls back to a stale cached copy if
# the download fails, undef if there's nothing at all.
sub apt_fetch_key {
    my ($name, $keyfile) = @_;

    my ($url) = grep { /\S/ } split /\n/, slurp(sources_dir() . "/$name.gpg.link");
    $url =~ s/^\s+|\s+$//g;

    mkdir key_cache() unless -d key_cache();
    my $cached = key_cache() . "/$keyfile";
    return $cached if -s $cached && -M $cached < $APT_KEY_MAX_AGE;

    my $tmp = "$cached.tmp.$$";
    if (system('curl', '-fsSL', '--max-time', '20', '-o', $tmp, $url) == 0 && -s $tmp) {
        rename $tmp, $cached or die "rename $tmp: $!\n";
        logmsg("Fetched APT key for $name from $url");
    } else {
        unlink $tmp;
        logmsg("Failed to fetch APT key for $name from $url" . (-s $cached ? ", using cached copy" : ''));
    }
    return -s $cached ? $cached : undef;
}

sub apt_install_source {
    my ($name, $dst, $codename) = @_;
    my $vmid = vmid();

    my $body = slurp(sources_dir() . "/$name.sources");
    $body =~ s/\@CODENAME\@/$codename/g;

    foreach my $keypath (do { my %s; grep { !$s{$_}++ } $body =~ /^Signed-By:\s*(\/\S+)\s*$/mgi }) {
        if (-e sources_dir() . "/$name.gpg.link") {
            my $cached = apt_fetch_key($name, basename($keypath))
                or die "no key available for $name, leaving its source as-is\n";
            guest_push_file($cached, $keypath);
        } elsif (!guest_run('test', '-e', $keypath)) {
            die "key $keypath missing in " . lc(what()) . " and no $name.gpg.link to fetch it, leaving its source as-is\n";
        }
    }

    guest_push_content("# $APT_MARKER, do not edit\n$body", $dst);
    logmsg("Installed APT source $name into $vmid:$dst");
}

# A conf that points apt at a CA (`...::CaInfo "/path/x.crt";`, e.g. for an
# HTTPS-caching proxy) gets that cert pushed to /path/x.crt first, taken from
# apt.conf.d/x.crt. Cert before conf, so apt never sees a CaInfo pointing at
# nothing. If the cert can't be pushed the conf isn't installed either.
sub apt_install_conf {
    my ($name, $dst) = @_;
    my $vmid = vmid();
    my $body = slurp(conf_dir() . "/$name");

    my %seen;
    foreach my $line (split /\n/, $body) {
        next if $line =~ m{^\s*(?:#|//)};
        next unless $line =~ /CaInfo\s+"(\/[^"]+)"/i;
        my $ca = $1;
        next if $seen{$ca}++;

        my $src = conf_dir() . "/" . basename($ca);
        if (-s $src) {
            guest_push_file($src, $ca);
            logmsg("Installed APT CA cert " . basename($ca) . " into $vmid:$ca");
        } elsif (!guest_run('test', '-s', $ca)) {
            die "CA cert $ca missing in " . lc(what()) . " and no apt.conf.d/" . basename($ca) . " to push, leaving the config as-is\n";
        }
    }

    guest_push_content("// $APT_MARKER, do not edit\n$body", $dst);
    logmsg("Installed APT config $name into $vmid:$dst");
}

sub apt_remove_unwanted {
    my ($keep) = @_;
    my $vmid = vmid();
    my $out = guest_capture('sh', '-c',
        "grep -lsF '$APT_MARKER' /etc/apt/sources.list.d/* /etc/apt/apt.conf.d/*");
    foreach my $path (grep { length } split /\n/, $out) {
        next if $keep->{$path};
        if (guest_run('rm', '-f', $path)) {
            logmsg("Removed APT file $vmid:$path (no longer in apt.yaml for this " . lc(what()) . ")");
        } else {
            logmsg("Failed to remove APT file $vmid:$path");
        }
    }
}

sub apt_disable_legacy {
    my $vmid = vmid();
    my $out = guest_capture('sh', '-c',
        'for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do [ -e "$f" ] && echo "$f"; done');
    foreach my $path (grep { length } split /\n/, $out) {
        if (guest_run('mv', '-f', $path, "$path.bak")) {
            logmsg("Disabled legacy APT source $vmid:$path (renamed to .bak)");
        } else {
            logmsg("Failed to disable legacy APT source $vmid:$path");
        }
    }
}

1;
