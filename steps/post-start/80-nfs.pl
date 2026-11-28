# post-start/80-nfs.pl - NAS shares inside VMs (mount tags)
#
# The VM counterpart of the container mount points: same tags (mp-s, mp-a,
# ...), same target paths (`dst`), but the guest mounts the NAS export
# (`nfs`) itself instead of getting a bind mount from the host. The entries
# live in a marked block in /etc/fstab, rewritten from the tags on every
# start, and stay there across stops: a reboot from inside the guest runs no
# hooks, so the guest has to be able to mount them on its own. A tag that's
# removed gets its share unmounted and dropped from the block. Needs
# nfs-common (installed when missing) and the NAS export to allow the VM's
# subnet.
#
#   Guests: VMs (guest agent)      Config: mounts.yaml      Tags: the keys of mounts.yaml
package Hook::Step::PostStart::Nfs;

use strict;
use warnings;
use Hook;

my $FSTAB_BEGIN      = '# BEGIN vm-hookscript NFS mounts (mounts.yaml, do not edit)';
my $FSTAB_END        = '# END vm-hookscript NFS mounts';
my $NFS_INSTALL_WAIT = 10 * 60;

return {
    name  => 'nfs',
    types => ['qemu'],
    agent => 1,
    run   => \&run,
};

sub run {
    # no mounts.yaml (or an unreadable profile): leave the guest's fstab alone
    # rather than taking down the shares it has
    return unless config('mounts');
    my $vmid   = vmid();
    my $mounts = managed_mounts();
    my $opts   = vm_nfs_options();

    my %want;    # dst -> nfs source
    foreach my $tag (get_tags(read_config())) {
        my $m = $mounts->{$tag} or next;
        next unless $m->{nfs} && $m->{dst};
        $want{ $m->{dst} } = $m->{nfs};
    }

    my $fstab = guest_capture('cat', '/etc/fstab');
    my ($block) = $fstab =~ /^\Q$FSTAB_BEGIN\E\n(.*?)^\Q$FSTAB_END\E\n?/ms;
    my %have = map { (split ' ')[1] => 1 } grep { /\S/ && !/^\s*#/ } split /\n/, ($block // '');
    return unless %want || %have;

    if (%want && !guest_run('sh', '-c', 'test -x /sbin/mount.nfs || test -x /usr/sbin/mount.nfs')) {
        logmsg("VM $vmid: installing nfs-common");
        guest_run_long('hookscript-nfs-install',
            'export DEBIAN_FRONTEND=noninteractive; '
          . 'apt-get -o DPkg::Lock::Timeout=600 update && '
          . 'apt-get -o DPkg::Lock::Timeout=600 install -y nfs-common',
            $NFS_INSTALL_WAIT) or return;
    }

    foreach my $dst (sort grep { !$want{$_} } keys %have) {
        guest_run('umount', '-l', $dst);
        # rmdir only removes an empty folder, so anything written into the
        # mount point itself (not the share) stays
        my $removed = guest_run('rmdir', $dst);
        logmsg("VM $vmid: unmounted $dst (mount tag removed)"
             . ($removed ? ', folder removed' : ', folder kept (not empty)'));
    }

    my $rest = $fstab;
    $rest =~ s/^\Q$FSTAB_BEGIN\E\n.*?^\Q$FSTAB_END\E\n?//ms;
    $rest .= "\n" if length $rest && $rest !~ /\n$/;
    my $new = $rest;
    if (%want) {
        $new .= "$FSTAB_BEGIN\n"
              . join('', map { "$want{$_} $_ nfs $opts 0 0\n" } sort keys %want)
              . "$FSTAB_END\n";
    }
    if ($new ne $fstab) {
        guest_push_content($new, '/etc/fstab');
        guest_run('systemctl', 'daemon-reload');
    }

    foreach my $dst (sort keys %want) {
        next if guest_run('mountpoint', '-q', $dst);
        guest_run('mkdir', '-p', $dst);
        # timeout: a hard NFS mount to an unreachable NAS would otherwise hang
        my ($rc, $out) = guest_exec(undef, 'sh', '-c', "timeout 40 mount '$dst' 2>&1");
        if ($rc == 0) {
            logmsg("VM $vmid: mounted $want{$dst} on $dst");
        } else {
            $out =~ s/\s+/ /g;
            logmsg("VM $vmid: mounting $want{$dst} on $dst failed (exit $rc): $out");
        }
    }
}
