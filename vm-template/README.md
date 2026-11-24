# Debian 13 VM template (deb13-template, VMID 999001)

Base template for VMs on LINSTOR. Clone it, resize the disk to what the VM
needs, start it, and `vm-hookscript.pl` does the rest (network, hostname,
keys, APT sources).

## What's in the template

| File in this folder | Installed at | Purpose |
|---|---|---|
| `auto-extend-disk.sh` | `/usr/local/sbin/` | Grows the root partition + filesystem to fill the disk. Finds the disk itself (vda/sda/nvme), handles plain ext4/xfs and LVM. |
| `auto-extend-disk.service` | `/etc/systemd/system/` (enabled) | Runs the script at boot. No `RemainAfterExit`, so it can be started again. |
| `90-auto-extend-disk.rules` | `/etc/udev/rules.d/` | Starts the service on a live resize (`qm resize` → kernel `RESIZE=1` change event). No reboot needed. |
| `zram-generator.conf` | `/etc/systemd/` | Swap on zram (half of RAM, zstd). Needs `systemd-zram-generator`. No swapfile/partition: nothing replicated by DRBD, nothing in backups, nothing in the way of growing the disk. |
| `first-boot.sh` | `/usr/local/sbin/` | First start of a clone: SSH host keys, apt proxy config + CA cert from GitHub (`apt.conf.d/` in this repo), full upgrade (proxy first, direct fallback). |
| `first-boot.service` | `/etc/systemd/system/` (enabled) | `ConditionFirstBoot=yes`: only runs while `/etc/machine-id` says `uninitialized`, i.e. on a fresh clone. |
| `ssh-hostkeys.conf` | `/etc/systemd/system/ssh.service.d/hostkeys.conf` | `ssh-keygen -A` before sshd starts, so sshd never fails on a sealed image. |
| `seal.sh` | (run once, not installed) | Last step before `qm template`: clears machine-id, SSH host keys, apt cache, logs, DHCP leases. |

Packages on top of a minimal netinst: `qemu-guest-agent`, `cloud-guest-utils`
(growpart), `systemd-zram-generator`, `curl`, `rsync`.

VM config: SeaBIOS, i440fx, `virtio0` on `linstor` (4 GB, `iothread=1`),
`agent: 1`, `hookscript: local:snippets/vm-hookscript.pl`, boot `order=virtio0`.

## Rebuilding / updating the template

1. Full-clone 999001 to a temporary VM, start it, make the changes.
2. Copy changed files from this folder into the VM (paths above).
3. Run `seal.sh` inside the VM, then **shut it down** (a reboot undoes the seal).
4. `qm template <vmid>` and swap it in for the old one.

## Known issues / TODO

- **Proxy path of `first-boot.sh` untested.** At build time the apt cache
  (`192.168.10.11:3142`, apt-cacher-ultra) answered 502; the direct fallback
  was tested end to end.
- **`ci-debian.yaml` is outdated** for this template: it creates a 4 GB
  swapfile, and its apt proxy line is malformed (`http:/aptcache...`, one
  slash). The template doesn't use cloud-init; either fix or remove it.
- **`first-boot.sh` races the hookscript.** `vm-hookscript.pl` reconfigures the
  network in the background right after boot; the script retries the GitHub
  fetch (~2 min) and the upgrade to ride that out. Cleaner: have the hookscript
  trigger the upgrade once it's done with the network.
- **The GitHub raw URL is hardcoded** (`nexed-tech/hookscript`, `main`). The
  Proxmox hosts pull this repo from Gitea (`hooksync.service`); if GitHub is
  only a mirror, consider pointing `first-boot.sh` at Gitea instead.
- **Building the template is manual.** A script that does steps 1–4 above
  through the Proxmox API + guest agent would make it reproducible.
