# Hook::Log - logging for every step.
#
#   logmsg($msg)   one line to /tmp/hook.log, the journal and stdout (the
#                  Proxmox task log, for the phases Proxmox waits for)
#
# Journal: identifier `hookscript-<vmid>` (shown in the GUI's node -> System ->
# Syslog; search for hookscript-10011, or just hookscript for all), with fields
# for exact filtering on the shell:
#   journalctl -t hookscript-10011 -f       one guest
#   journalctl HOOKSCRIPT_VMID=10011        the same, by field
#   journalctl HOOKSCRIPT=lxc               all container hooks (vm: all VM hooks)
# Falls back to plain syslog when `logger --journald` isn't available. VM lines
# start with [vm].
package Hook::Log;

use strict;
use warnings;
use IO::Handle;
use Sys::Syslog qw(openlog syslog);
use Exporter 'import';

our @EXPORT = qw(logmsg);

# Counted for the closing line of a VM's background job
our $PROBLEMS = 0;

my $VMID   = '';
my $KIND   = 'lxc';
my $LOG_ID = 'hookscript';

sub init {
    my ($vmid, $kind) = @_;
    $VMID   = $vmid // '';
    $KIND   = $kind // 'lxc';
    $LOG_ID = $VMID =~ /^\d+$/ ? "hookscript-$VMID" : 'hookscript';
    openlog($LOG_ID, 'pid', 'user');
}

sub journal_log {
    my ($msg) = @_;
    (my $one_line = $msg) =~ s/\s*\n\s*/ /g;
    no warnings 'exec';    # no logger: syslog fallback below
    if (open my $j, '|-', 'logger', '--journald') {
        print $j "MESSAGE=$one_line\nPRIORITY=6\nSYSLOG_IDENTIFIER=$LOG_ID\nSYSLOG_PID=$$\nHOOKSCRIPT=$KIND\n"
               . ($LOG_ID ne 'hookscript' ? "HOOKSCRIPT_VMID=$VMID\n" : '');
        return if close $j;
    }
    eval { syslog('info', '%s', $one_line) };
}

sub logmsg {
    my ($msg) = @_;
    $PROBLEMS++ if $msg =~ /\bfail|giving up|not reachable|didn't start|still running after/i;
    $msg = "[vm] $msg" if $KIND eq 'vm';
    my $line = scalar(localtime) . " $msg\n";

    if (open my $log, '>>', '/tmp/hook.log') {
        print $log $line;
        close $log;
    }
    journal_log($msg);

    print STDOUT $line;
    STDOUT->flush();
}

1;
