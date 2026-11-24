#!/bin/bash
# First start of a clone of the deb13 template (first-boot.service, ConditionFirstBoot):
#   1. fresh SSH host keys (the template is sealed without any)
#   2. apt proxy config + its CA cert pulled from GitHub (nexed-tech/hookscript)
#   3. full upgrade, through the proxy first, direct if the proxy doesn't work
REPO=https://raw.githubusercontent.com/nexed-tech/hookscript/main/apt.conf.d
log() { echo "first-boot: $*"; }

ssh-keygen -A

fetch() {
    curl -fsSL --max-time 20 -o "$tmp/00aptproxy" "$REPO/00aptproxy" &&
    curl -fsSL --max-time 20 -o "$tmp/ca.crt" "$REPO/apt-cacher-ultra-ca.crt"
}

# network-online can be reached before DHCP/DNS actually work, so keep trying for ~2 minutes
tmp=$(mktemp -d)
for i in $(seq 12); do fetch && break; sleep 10; done
if [ -s "$tmp/00aptproxy" ] && [ -s "$tmp/ca.crt" ]; then
    install -m 644 "$tmp/ca.crt" /etc/ssl/certs/apt-cacher-ultra-ca.crt
    install -m 644 "$tmp/00aptproxy" /etc/apt/apt.conf.d/00aptproxy
    log "apt proxy config pulled from GitHub"
else
    log "could not fetch apt proxy config from GitHub, keeping the current one"
fi
rm -rf "$tmp"

export DEBIAN_FRONTEND=noninteractive
# Recover from an install that was interrupted earlier (power loss, reboot mid-upgrade)
dpkg --configure -a
# --error-on=any: apt-get update otherwise exits 0 even when every download failed.
# Short timeouts so a dead proxy fails fast instead of retrying for minutes.
upgrade() {
    local opts=(-o Acquire::Retries=1 -o Acquire::http::Timeout=15 -o Acquire::https::Timeout=15 "$@")
    apt-get "${opts[@]}" update --error-on=any &&
    apt-get "${opts[@]}" -y -o Dpkg::Options::=--force-confold full-upgrade
}
DIRECT=(-o Acquire::http::Proxy=false -o Acquire::https::Proxy=false
        -o Acquire::https::CaInfo=/etc/ssl/certs/ca-certificates.crt)

# The hookscript may still be reconfiguring the network right after boot, hence the retries
for i in 1 2; do
    upgrade && { log "upgrade done (via proxy)"; exit 0; }
    log "upgrade via proxy failed (attempt $i), retrying in 30s"; sleep 30
done
for i in 1 2 3; do
    upgrade "${DIRECT[@]}" && { log "upgrade done (direct, proxy unavailable)"; exit 0; }
    log "direct upgrade failed (attempt $i), retrying in 30s"; sleep 30
done
log "upgrade failed, giving up"
exit 1
