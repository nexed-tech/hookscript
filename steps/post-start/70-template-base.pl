# post-start/70-template-base.pl - disk growth + zram swap for any Debian VM
#
# Gives any Debian VM what the template has built in, so the hookscript can be
# attached to VMs that weren't cloned from it:
#   - cloud-guest-utils (growpart) + systemd-zram-generator, when missing
#   - from vm-template/: auto-extend-disk.sh + .service + udev rule (root
#     grows at boot and on a live `qm resize`), zram-generator.conf
#   - zram swap started
#   - swap on disk (partition, LVM volume or file) replaced by zram, and its
#     space given to root: vm-template/remove-disk-swap.sh, only once zram swap
#     is active. A VM tagged `keep-swap` keeps its swap on disk.
# On a template clone everything is already in place and nothing happens.
#
#   Guests: VMs (guest agent)      Tags: keep-swap
package Hook::Step::PostStart::TemplateBase;

use strict;
use warnings;
use Hook;

my @BASE_FILES = (
    # [file in vm-template/, path in the guest, mode]
    ['auto-extend-disk.sh',       '/usr/local/sbin/auto-extend-disk.sh',          '755'],
    ['remove-disk-swap.sh',       '/usr/local/sbin/remove-disk-swap.sh',          '755'],
    ['auto-extend-disk.service',  '/etc/systemd/system/auto-extend-disk.service', '644'],
    ['90-auto-extend-disk.rules', '/etc/udev/rules.d/90-auto-extend-disk.rules',  '644'],
    ['zram-generator.conf',       '/etc/systemd/zram-generator.conf',             '644'],
);
my $BASE_INSTALL_WAIT = 10 * 60;

return {
    name  => 'template base',
    types => ['qemu'],
    agent => 1,
    run   => \&run,
};

sub run {
    my $vmid = vmid();
    my $os = guest_capture('cat', '/etc/os-release');
    return unless $os =~ /^ID="?debian"?$/m;

    unless (guest_run('sh', '-c', 'command -v growpart >/dev/null && test -e /usr/lib/systemd/system-generators/zram-generator')) {
        logmsg("VM $vmid: installing cloud-guest-utils + systemd-zram-generator");
        guest_run_long('hookscript-base-install',
            'export DEBIAN_FRONTEND=noninteractive; '
          . 'apt-get -o DPkg::Lock::Timeout=600 update && '
          . 'apt-get -o DPkg::Lock::Timeout=600 install -y cloud-guest-utils systemd-zram-generator',
            $BASE_INSTALL_WAIT) or return;
    }

    my @changed;
    foreach my $f (@BASE_FILES) {
        my ($name, $dst, $mode) = @$f;
        my $src = snippets() . "/vm-template/$name";
        next unless -s $src;
        next if guest_capture('cat', $dst) eq slurp($src);
        guest_push_file($src, $dst);
        guest_run('chmod', $mode, $dst);
        push @changed, $name;
    }
    if (@changed) {
        guest_run('systemctl', 'daemon-reload');
        guest_run('udevadm', 'control', '--reload');
        guest_run('systemctl', 'enable', '--quiet', 'auto-extend-disk.service');
        logmsg("VM $vmid: installed @changed");
    }

    unless (zram_swap_active()) {
        guest_run('systemctl', 'daemon-reload');
        guest_run('systemctl', 'start', 'systemd-zram-setup@zram0.service');
        guest_run('systemctl', 'start', 'dev-zram0.swap');
        if (zram_swap_active()) {
            logmsg("VM $vmid: zram swap active");
        } else {
            logmsg("VM $vmid: zram swap didn't start, keeping any swap on disk");
            return;
        }
    }

    my $disk_swap = guest_run('sh', '-c',
        q{swapon --show=NAME --noheadings | grep -qv '^/dev/zram' || awk '$1 !~ /^#/ && $3 == "swap"' /etc/fstab | grep -q .});
    if ($disk_swap && grep { $_ eq 'keep-swap' } get_tags(read_config())) {
        return;
    }
    if ($disk_swap) {
        logmsg("VM $vmid: replacing swap on disk by zram swap");
        my $ok = guest_run_long('hookscript-remove-disk-swap', '/usr/local/sbin/remove-disk-swap.sh', $BASE_INSTALL_WAIT);
        foreach my $line (split /\n/, guest_capture('cat', '/var/log/hookscript-remove-disk-swap.log')) {
            logmsg("VM $vmid: $1") if $line =~ /^remove-disk-swap: (.*)/;
        }
        return unless $ok;
    }
    elsif (grep { $_ eq 'auto-extend-disk.sh' } @changed) {
        # just installed: grow root now instead of waiting for the next boot
        guest_run('systemctl', 'start', 'auto-extend-disk.service');
    }
}

sub zram_swap_active {
    return guest_capture('swapon', '--show=NAME', '--noheadings') =~ m{^/dev/zram}m;
}
