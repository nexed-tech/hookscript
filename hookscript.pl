#!/usr/bin/perl
#
# Proxmox hookscript for containers and VMs.
#
# Attach with:  pct set <vmid> --hookscript local:snippets/hookscript.pl
#               qm  set <vmid> --hookscript local:snippets/hookscript.pl
# (vm-hookscript.pl still works too: it just runs this script.)
#
# Proxmox calls it as `hookscript.pl <vmid> <phase>`. It works out whether
# <vmid> is a container or a VM, then runs the step files in steps/<phase>/ in
# file name order - each step says which guest types it's for. Everything the
# steps share lives in lib/Hook/; settings come from profiles/<profile>/,
# picked (and overridden) by profile.json. See README.md.
#
# Phases:
#   pre-start   containers and VMs, inline (Proxmox waits for it)
#   post-start  containers: inline. VMs: as a background job (`guest-sync`,
#               systemd unit vm-hookscript-<vmid>) - the start task still holds
#               the VM's config lock and the guest agent isn't up yet. Steps
#               marked `agent` wait for the agent first, and are skipped when
#               the VM has none.
#   pre-stop, post-stop   inline
# Not Proxmox phases:
#   hookscript.pl apt-sync-all     re-run the APT step on every running guest
#                                  (hooksync, daily)
#   hookscript.pl <vmid> apt-sync  the same for one guest
#
# A step that dies is logged and the others still run - except a step marked
# `fatal` (the host's NFS mounts), which fails the hook and so the start.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::RealBin/lib";
use File::Spec;
use Fcntl qw(:flock);
use Hook;

my $SELF = File::Spec->catfile($FindBin::RealBin, 'hookscript.pl');
my ($vmid, $phase) = (shift // '', shift // '');

Hook::Config::init($FindBin::RealBin);

# -------------------------
# apt-sync-all: every running container and VM
# -------------------------

if ($vmid eq 'apt-sync-all') {
    Hook::Log::init('', 'lxc');
    my @running;
    foreach my $line (`pct list 2>/dev/null`) {
        push @running, $1 if $line =~ /^\s*(\d+)\s+running\b/;
    }
    foreach my $line (`qm list 2>/dev/null`) {
        push @running, $1 if $line =~ /^\s*(\d+)\s+\S+\s+running\b/;
    }
    system($^X, $SELF, $_, 'apt-sync') foreach @running;
    exit 0;
}

# -------------------------
# The guest
# -------------------------

my $type = Hook::Guest::detect_type($vmid);
unless ($vmid =~ /^\d+$/ && $type) {
    Hook::Log::init($vmid, 'lxc');
    logmsg("No container or VM $vmid on this node, nothing to do ($phase)");
    exit 0;
}
Hook::Guest::init($vmid, $type);
Hook::Log::init($vmid, $type eq 'qemu' ? 'vm' : 'lxc');

# -------------------------
# Steps
# -------------------------

# The steps in steps/<phase>/ for this guest type, in file name order. Each
# step file returns { name, types, agent?, fatal?, run }.
sub load_steps {
    my ($step_phase) = @_;
    my $dir = "$FindBin::RealBin/steps/$step_phase";
    opendir(my $dh, $dir) or return ();
    my @files = sort grep { /^\d+-[\w.-]+\.pl$/ } readdir $dh;
    closedir $dh;

    my @steps;
    foreach my $file (@files) {
        my $step = do "$dir/$file";
        unless (ref $step eq 'HASH' && ref $step->{run} eq 'CODE') {
            my $why = $@ || $! || 'did not return a step';
            $why =~ s/\s+$//;
            logmsg("Step $step_phase/$file can't be loaded, skipping it: $why");
            next;
        }
        next unless grep { $_ eq $type } @{ $step->{types} || [] };
        $step->{file} = "$step_phase/$file";
        push @steps, $step;
    }
    return @steps;
}

# Runs the steps; on VMs, `agent` steps wait for the guest agent (once) and
# are skipped without one.
sub run_steps {
    my (@steps) = @_;
    my $agent;    # undef: not checked yet
    foreach my $step (@steps) {
        if ($step->{agent} && is_vm()) {
            unless (defined $agent) {
                if (!agent_enabled(read_config())) {
                    logmsg("VM $vmid has no guest agent enabled (agent: 1), skipping the steps that need it");
                    $agent = 0;
                } else {
                    $agent = wait_for_agent() ? 1 : 0;
                }
            }
            next unless $agent;
        }

        eval { $step->{run}->() };
        next unless $@;
        if ($step->{fatal}) {
            logmsg("$step->{name} step failed for $vmid, stopping the hook: $@");
            die "$step->{name} ($step->{file}) failed for $vmid: $@";
        }
        logmsg("$step->{name} step failed for $vmid: $@");
    }
}

# Runs `hookscript.pl <vmid> guest-sync` as its own transient systemd unit
# (vm-hookscript-<vmid>), so neither the start task (which holds the VM's
# config lock) nor whoever ran `qm start` waits for it. A plain fork kept
# file handles of the caller open, which made e.g. `ssh host qm start` hang
# until the whole job was done. If the unit still exists (a job from an
# earlier start is running), that job carries on and no second one starts.
sub spawn_guest_sync {
    my $unit = "vm-hookscript-$vmid";
    my $rc = system('systemd-run', '--quiet', '--collect', '--no-block', "--unit=$unit",
                    $^X, $SELF, $vmid, 'guest-sync');
    logmsg("Background guest-sync job for $vmid not started (systemd-run exit " . ($rc >> 8)
         . "), is $unit from an earlier start still running?") if $rc;
}

# One background job per VM at a time (a quick reboot can start a second one).
sub lock_vm_job {
    open my $fh, '>', "/run/vm-hookscript-$vmid.lock" or return undef;
    flock($fh, LOCK_EX) or return undef;
    return $fh;
}

# -------------------------
# Phases
# -------------------------

if ($phase eq 'pre-start') {
    logmsg("$vmid is starting");
    run_steps(load_steps('pre-start'));
}
elsif ($phase eq 'post-start' && is_vm()) {
    logmsg("$vmid started, guest sync running in the background (see /tmp/hook.log)");
    spawn_guest_sync();
}
elsif ($phase eq 'post-start') {
    run_steps(load_steps('post-start'));
}
elsif ($phase eq 'guest-sync' && is_vm()) {
    my $lock    = lock_vm_job();
    my $started = time;
    run_steps(load_steps('post-start'));

    # Closing line, so the log shows the job is done (and not still busy or stuck)
    my $secs = time - $started;
    my $problems = $Hook::Log::PROBLEMS;
    logmsg(sprintf("VM %s: guest sync done in %dm%02ds%s", $vmid, int($secs / 60), $secs % 60,
                   $problems ? ", with $problems problem(s), see the lines above" : ''));
}
elsif ($phase eq 'pre-stop') {
    run_steps(load_steps('pre-stop'));
}
elsif ($phase eq 'post-stop') {
    logmsg("$vmid stopped");
    run_steps(load_steps('post-stop'));
}
elsif ($phase eq 'apt-sync') {
    if (agent_enabled(read_config()) && guest_agent_ping()) {
        eval { sync_apt() };
        logmsg("APT sync failed for $vmid: $@") if $@;
    }
}

exit 0;
