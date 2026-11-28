# post-start/50-ssh-key.pl - Linux Update Dashboard SSH key
#
# Every guest gets the Linux Update Dashboard's SSH public key merged into its
# authorized_keys on every start/reboot - no tag needed. Rotate the key by
# editing LUD_SSH_PUBKEY in the secrets file; each guest's next start picks it
# up. The managed key lives inside a marked block so any other keys already
# present are left untouched. Containers are reached with `pct exec` (works
# whatever the storage, and uid 0 is root inside an unprivileged container
# too), VMs through the guest agent.
#
#   Guests: containers, VMs (guest agent)      Secrets: LUD_SSH_PUBKEY, LUD_SSH_USER
package Hook::Step::PostStart::SshKey;

use strict;
use warnings;
use Hook;

my $LUD_BEGIN = '# BEGIN lud-managed-key (hookscript, do not edit)';
my $LUD_END   = '# END lud-managed-key';

return {
    name  => 'ssh key',
    types => ['lxc', 'qemu'],
    agent => 1,
    run   => \&run,
};

sub run {
    my $vmid    = vmid();
    my $secrets = load_secrets() or return;
    unless (require_secrets($secrets, qw(LUD_SSH_PUBKEY))) {
        logmsg("Secrets file missing LUD_SSH_PUBKEY, skipping Linux Update Dashboard SSH key sync");
        return;
    }

    my $pubkey  = $secrets->{LUD_SSH_PUBKEY};
    my $user    = $secrets->{LUD_SSH_USER} // 'root';
    my $home    = $user eq 'root' ? '/root' : "/home/$user";
    my $ssh_dir = "$home/.ssh";
    my $ak_file = "$ssh_dir/authorized_keys";

    unless (guest_run('id', '-u', $user)) {
        logmsg("User '$user' not found in " . lc(what()) . " $vmid, skipping LUD SSH key sync");
        return;
    }

    my @existing = split /^/m, guest_capture('cat', $ak_file);

    # Strip any previously-synced managed block, keep everything else.
    my @kept;
    my $in_block = 0;
    foreach my $line (@existing) {
        my $chomped = $line;
        chomp $chomped;
        if ($chomped eq $LUD_BEGIN) { $in_block = 1; next; }
        if ($chomped eq $LUD_END)   { $in_block = 0; next; }
        push @kept, $line unless $in_block;
    }
    $kept[-1] .= "\n" if @kept && $kept[-1] !~ /\n$/;
    pop @kept while @kept && $kept[-1] =~ /^\s*$/;
    push @kept, "\n" if @kept;
    push @kept, "$LUD_BEGIN\n", "$pubkey\n", "$LUD_END\n";

    eval {
        guest_push_content(join('', @kept), $ak_file);
        guest_run('chmod', '700', $ssh_dir)
            or die "chmod $ssh_dir in " . lc(what()) . " $vmid failed\n";
        guest_run('chmod', '600', $ak_file)
            or die "chmod $ak_file in " . lc(what()) . " $vmid failed\n";
        guest_run('chown', '-R', "$user:$user", $ssh_dir)
            or die "chown $ssh_dir in " . lc(what()) . " $vmid failed\n";

        logmsg("Synced Linux Update Dashboard SSH key into $vmid:$ak_file");
    };
    logmsg("Failed to sync LUD SSH key for $vmid: $@") if $@;
}
