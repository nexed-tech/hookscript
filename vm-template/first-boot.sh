#!/bin/bash
# First start of a clone of the deb13 template (first-boot.service, ConditionFirstBoot):
#   1. fresh SSH host keys (the template is sealed without any)
#   2. full upgrade with the guest's APT config, direct if that doesn't work
#
# The template has no apt proxy config: the hookscript pushes 00aptproxy when
# the host's profile wants it (profiles/<profile>/apt.yaml), so a clone on a
# host without the cache never gets it. The cache's CA cert is in the template
# (/etc/ssl/certs/apt-cacher-ultra-ca.crt) and does nothing without the proxy.
log() { echo "first-boot: $*"; }

ssh-keygen -A

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
    upgrade && { log "upgrade done"; exit 0; }
    log "upgrade failed (attempt $i), retrying in 30s"; sleep 30
done
for i in 1 2 3; do
    upgrade "${DIRECT[@]}" && { log "upgrade done (direct, without proxy)"; exit 0; }
    log "direct upgrade failed (attempt $i), retrying in 30s"; sleep 30
done
log "upgrade failed, giving up"
exit 1
