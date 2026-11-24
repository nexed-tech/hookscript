#!/bin/bash
# Run inside the template VM as the very last step, then shut it down and
# convert it (qm template <vmid>). Clones then get their own machine-id (taken
# from the VM's SMBIOS UUID) and SSH host keys, and first-boot.service runs.
set -e
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
rm -f /etc/ssh/ssh_host_* /var/lib/dhcp/*.leases /root/.bash_history
find /var/log -type f -exec truncate -s 0 {} +
journalctl --rotate >/dev/null 2>&1 || true
journalctl --vacuum-time=1s >/dev/null 2>&1 || true
# "uninitialized" (not an empty file) is what makes ConditionFirstBoot=yes fire
echo uninitialized > /etc/machine-id
fstrim -v /
sync
echo "Sealed. Shut down now (no reboot, or the seal is undone)."
