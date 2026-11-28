# hookscript

Proxmox hookscript for containers and VMs: network from the VMID, NAS mounts,
Cloudflare Tunnel, APT sources, SSH key, and for VMs hostname, disk growth +
zram, Docker hosts managed by Dockhand.

This repo *is* the snippets folder: each node has it checked out at
`/var/lib/vz/snippets`, and hooksync (`hooksync.service` + `.timer`) pulls it
at boot and daily.

```sh
pct set <vmid> --hookscript local:snippets/hookscript.pl
qm  set <vmid> --hookscript local:snippets/hookscript.pl
```

`vm-hookscript.pl` is a shim that runs `hookscript.pl`, so guests attached to
it keep working.

## Layout

```
hookscript.pl          entry point: finds out container or VM, runs the steps
vm-hookscript.pl       shim for guests still attached to it
lib/Hook.pm            `use Hook;` = every helper below
lib/Hook/*.pm          shared code: Log, Config, Guest, Network, Ipam, Mounts,
                       Cloudflare, Apt, Util (each file's header lists its functions)
steps/<phase>/NN-*.pl  one file per step, run in file name order
profiles/<name>/       network.yaml, mounts.yaml, apt.yaml per profile
profile.json           this node's profile + overrides (gitignored)
apt.sources.d/ apt.conf.d/   APT entries, shared by all profiles
vm-template/           files for the VM template (and the template-base step)
```

## Steps

| Phase | Step | Containers | VMs |
|---|---|:-:|:-:|
| pre-start | 10-host-nfs: host's NFS mounts up (fatal) | ✓ | |
| | 20-mounts: mount tags → mount points | ✓ | |
| | 30-network: static IP / IPAM reservation | ✓ | ipam mode |
| | 40-cloudflare: tunnel + DNS | ✓ | |
| post-start | 10-bridge: net0 onto the VNet | | ✓ |
| | 20-cloudflare: tunnel + DNS | | ✓ |
| | 30-hostname | | agent |
| | 40-network: static /etc/network/interfaces | | agent |
| | 50-ssh-key: Linux Update Dashboard key | ✓ | agent |
| | 60-apt: APT sources + config | ✓ | agent |
| | 70-template-base: disk growth + zram | | agent |
| | 80-nfs: mount tags → /etc/fstab | | agent |
| | 90-docker: `docker` tag → Dockhand host | | agent |
| pre-stop | 10-mounts: report | ✓ | |
| | 20-cloudflare: report | ✓ | ✓ |
| post-stop | 10-mounts: remove mount points | ✓ | |
| | 20-cloudflare: remove tunnel + DNS | ✓ | ✓ |

Containers run post-start inline. VMs run it as a background job
(`vm-hookscript-<vmid>` unit): the start task still holds the config lock and
the guest agent isn't up yet. `agent` steps wait for the agent once, and are
skipped when the VM has none.

Every step file has the same shape:

```perl
# <phase>/NN-name.pl - one line on what it does
#
# A few lines on how and why.
#
#   Guests: containers, VMs (guest agent)      Config: x.yaml      Tags: ...
package Hook::Step::<Phase>::<Name>;

use strict;
use warnings;
use Hook;

my $CONSTANT = ...;          # above the return: code after it never runs

return {
    name  => 'name',         # used in log lines
    types => ['lxc', 'qemu'],
    agent => 1,              # optional, VMs: needs the guest agent
    fatal => 1,              # optional: failing stops the hook (and the start)
    run   => \&run,
};

sub run {
    ...
}
```

A new step is just a new file in the right phase folder; the number sets its
place. Use `guest_exec` / `guest_run` / `guest_push_content` (Hook::Guest) to
reach into the guest, and a step works for containers and VMs alike.

## Profiles

`profile.json` (next to `hookscript.pl`, gitignored) picks the profile and can
override any of its settings; overrides merge into hashes, lists and values
replace. Without it the `home` profile is used.

```json
{
  "profile": "vps",
  "overrides": { "network": { "vnets": { "2": "vnet0" } } }
}
```

- `home`: the home cluster (VLANs on SDN VNets, static IPs, NAS mounts, APT proxy)
- `vps`: the single-IP VPS hosts (IPAM mode, no mounts), see
  [profiles/vps/README.md](profiles/vps/README.md)

Secrets (Cloudflare, Linux Update Dashboard key) go in `.env.secrets`, also
gitignored; see `.env.secrets.example`.

## Logs

Every line goes to `/tmp/hook.log`, stdout (the Proxmox task log) and the
journal as `hookscript-<vmid>`:

```sh
journalctl -t hookscript-10011 -f      # one guest
journalctl HOOKSCRIPT=vm               # all VM hooks (lxc: all container hooks)
```
