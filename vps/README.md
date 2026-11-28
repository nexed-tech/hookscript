# Hookscripts on the VPS hosts

Per-host config for the single-IP VPS Proxmox hosts (vps1, vps2, ...). Guests sit
on an SDN Simple zone behind SNAT; their address is reserved in SDN IPAM from the
VMID (`network.yaml` `mode: ipam`).

## Setup on a VPS host

```sh
# hookscripts + nightly update (same as the home cluster)
apt-get install -y git libyaml-libyaml-perl
pvesm set local --content iso,vztmpl,backup,import,snippets
rm -rf /var/lib/vz/snippets && git clone https://github.com/nexed-tech/hookscript.git /var/lib/vz/snippets
cp /var/lib/vz/snippets/hooksync.service /var/lib/vz/snippets/hooksync.timer /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now hooksync.timer

# this host's config (not in git, so hooksync's pull never overwrites it)
mkdir -p /etc/pve/hookscript
cp /var/lib/vz/snippets/vps/{network,mounts,apt}.yaml /etc/pve/hookscript/
# then set the network number in /etc/pve/hookscript/network.yaml (`vnets:`)
```

SDN (Datacenter -> SDN): Simple zone with DHCP `dnsmasq` + IPAM `pve`, VNet
`vnet0`, subnet `10.0.<n>.0/24`, gateway `10.0.<n>.1`, SNAT on, DHCP range at
the top of the /24 (e.g. `.200`-`.210`). VMIDs whose last three digits fall in
that range keep a pool address.

Attach to guests as usual:

```sh
pct set <vmid> --hookscript local:snippets/hookscript.pl
qm  set <vmid> --hookscript local:snippets/vm-hookscript.pl
```

Without `.env.secrets` in the snippets folder, the Cloudflare tunnel (`cft`) and
Linux Update Dashboard key steps are skipped. Put one there (from
`.env.secrets.example`) to use the tunnel.

VM templates for a VPS host should already have net0 on the VNet: QEMU reads
its config before pre-start, so the move to the VNet only happens after the
first DHCP request.
