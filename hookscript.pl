#!/usr/bin/perl

use strict;
use warnings;
use IO::Handle;
use Sys::Hostname;

my $vmid  = shift;
my $phase = shift;

my $conf_file = "/etc/pve/lxc/${vmid}.conf";
my $hostname  = hostname();

# Common mounts for all hosts
my %mounts = (
    'mp-s' => { mp => 'mp0', src => '/mnt/pve/nas01-shares',      dst => '/mnt/Shares' },
    'mp-b' => { mp => 'mp1', src => '/mnt/pve/nas01-backups',     dst => '/mnt/Backups' },
    'mp-p' => { mp => 'mp2', src => '/mnt/pve/nas01-backups-pbs', dst => '/mnt/Backups-PBS' },
);

# Host-specific differences
if ($hostname eq 'pve1') {
    $mounts{'mp-u'} = { mp => 'mp3', src => '/usbssd/download_tmp', dst => '/mnt/download_tmp' };
}
#elsif ($hostname eq 'pve2') {
#    $mounts{'mp-u'} = { mp => 'mp3', src => '/otherusb/download_tmp', dst => '/mnt/download_tmp' };
#}

sub logmsg {
    my ($msg) = @_;
    my $line = scalar(localtime) . " $msg\n";

    open my $log, '>>', '/tmp/hook.log';
    print $log $line;
    close $log;

    print STDOUT $line;
    STDOUT->flush();
}

sub read_config {
    open my $fh, '<', $conf_file or die "Cannot open $conf_file: $!";
    my @lines = <$fh>;
    close $fh;
    return @lines;
}

sub write_config {
    my (@lines) = @_;
    my $tmp = "$conf_file.tmp";
    open my $fh, '>', $tmp or die "Cannot write $tmp: $!";
    print $fh @lines;
    close $fh;
    rename $tmp, $conf_file or die "Cannot rename $tmp to $conf_file: $!";
}

sub get_tags {
    my @lines = @_;
    foreach my $line (@lines) {
        if ($line =~ /^tags:\s*(.*)$/) {
            return split(/[;,]/, $1);
        }
    }
    return ();
}

sub add_mounts {
    my @lines = read_config();
    my @tags  = get_tags(@lines);

    logmsg("Tags for $vmid: @tags");

    foreach my $tag (@tags) {
        next unless exists $mounts{$tag};

        my $mount = $mounts{$tag};
        my ($mpid, $src, $dst) = ($mount->{mp}, $mount->{src}, $mount->{dst});

        # Check if mount already exists
        my $exists = grep { /^$mpid:/ } @lines;
        next if $exists;

        logmsg("Adding $mpid ($src → $dst)");
        push @lines, "$mpid: $src,mp=$dst\n";
    }

    write_config(@lines);
}

sub remove_mounts {
    open my $in,  '<', $conf_file or die "Cannot open $conf_file: $!";
    my @lines = <$in>;
    close $in;

    my %managed = map { $mounts{$_}{mp} => 1 } keys %mounts;

    my @new;
    foreach my $line (@lines) {
        if ($line =~ /^(mp\d+):/) {
            my $mpid = $1;
            if (exists $managed{$mpid}) {
                logmsg("Removing $mpid");
                next;
            }
        }
        push @new, $line;
    }

    open my $out, '>', $conf_file or die "Cannot write $conf_file: $!";
    print $out @new;
    close $out;

    logmsg("Mount cleanup complete");
}

sub check_and_mount_nfs {
    my $max_attempts = 10;
    my $interval     = 5;

    foreach my $tag (keys %mounts) {
        my $src = $mounts{$tag}{src};

        for (my $i = 0; $i < $max_attempts; $i++) {
            if (system("mountpoint -q $src") == 0) {
                logmsg("Mount ready: $src");
                last;
            }
            logmsg("Attempting to mount: $src (try $i)");
            system("mount $src");
            sleep $interval;
            die "Failed to mount $src\n" if $i == $max_attempts - 1;
        }
    }
}

sub pre_stop_report {
    open my $in, '<', $conf_file or die "Cannot open $conf_file: $!";
    my @lines = <$in>;
    close $in;

    my %managed = map { $mounts{$_}{mp} => 1 } keys %mounts;

    my @to_remove;
    foreach my $line (@lines) {
        if ($line =~ /^(mp\d+):\s*(.*)$/) {
            my ($mpid, $rest) = ($1, $2);
            if (exists $managed{$mpid}) {
                push @to_remove, "$mpid ($rest)";
            }
        }
    }

    if (@to_remove) {
        logmsg("Container $vmid is shutting down.");
        logmsg("The following mountpoints will be removed after stop:");
        foreach my $entry (@to_remove) {
            logmsg("  - $entry");
        }
    } else {
        logmsg("Container $vmid is shutting down. No managed mountpoints found.");
    }
}

# -------------------------
# Phase handling
# -------------------------

if ($phase eq 'pre-start') {
    logmsg("$vmid is starting");
    check_and_mount_nfs();
    add_mounts();
}
elsif ($phase eq 'pre-stop') {
    pre_stop_report();
}
elsif ($phase eq 'post-stop') {
    logmsg("$vmid stopped. Removing managed mountpoints.");
    remove_mounts();
}

exit(0);