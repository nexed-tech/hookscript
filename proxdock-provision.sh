#!/bin/bash
# ProxDock first-boot provisioning hookscript.
#
# Attached to the Docker template CT, so every clone inherits it. Each phase first runs the
# normal hookscript (network from VMID, mounts, ...). On post-start it starts the provisioning
# job in the background (the config is locked while post-start runs), which:
#   1. starts Hawser in the CT (/opt/stacks/hawser from the template) with a fresh token
#   2. registers it in Dockhand and deploys BASE_STACK plus one git stack per `stack-<name>`
#      tag (dockhand-register.sh, shared with hookscript.pl's docker step; stacks Dockhand already has
#      are left alone)
#   3. swaps this hookscript for the normal one in the CT config
# Until step 3 succeeds the CT keeps this hookscript, so the next start retries.
#
# Cluster-wide config: /etc/pve/proxdock/provision.conf
#   DOCKHAND_URL=http://...:3000   REPO_NAME=stacks   BASE_STACK=caddy-tunnelsync
#   NORMAL_HOOK=local:snippets/hookscript.pl   SECRET_PROVIDER=<name>  (optional)
# Optional Dockhand API token: /etc/pve/priv/proxdock/dockhand.token (read by dockhand-register.sh)

vmid=$1 phase=$2
SELF=/var/lib/vz/snippets/proxdock-provision.sh
LOG=/var/log/proxdock-provision.log
REGISTER=/var/lib/vz/snippets/dockhand-register.sh
HAWSER_DIR=/opt/stacks/hawser   # in the CT

log() { echo "$(date '+%F %T') $vmid $phase: $*" | tee -a "$LOG"; }
fail() { log "FAILED: $*"; exit 1; }

. /etc/pve/proxdock/provision.conf || { log "no provision.conf"; exit 0; }
conf=/etc/pve/lxc/$vmid.conf

run_normal_hook() {
    local normal=/var/lib/vz/snippets/${NORMAL_HOOK#*:snippets/}
    [ -n "$NORMAL_HOOK" ] && [ -x "$normal" ] && "$normal" "$vmid" "$phase"
}

provision() {
    local ip name tags token stacks t line
    ip=$(sed -nE 's/^net0:.*ip=([0-9.]+)\/.*/\1/p' "$conf")
    name=$(sed -nE 's/^hostname: *//p' "$conf")
    tags=$(sed -nE 's/^tags: *//p' "$conf" | tr ';,' '  ')
    [ -n "$ip" ] || fail "no static IP on net0"
    log "provisioning $name ($ip), tags: $tags"

    for i in $(seq 30); do pct exec "$vmid" -- docker info >/dev/null 2>&1 && break; sleep 2; done
    pct exec "$vmid" -- docker info >/dev/null 2>&1 || fail "Docker not up in CT"

    # Hawser's compose file comes with the template; only its TOKEN in .env is per CT.
    token=$(openssl rand -hex 24)
    pct exec "$vmid" -- sh -c "cd $HAWSER_DIR && [ -f compose.yaml ] && \
        { grep -v '^TOKEN=' .env 2>/dev/null; echo TOKEN=$token; } > .env.new && mv .env.new .env && \
        docker compose up -d --force-recreate --quiet-pull 2>&1" >/dev/null \
        || fail "starting Hawser from $HAWSER_DIR"

    stacks=$BASE_STACK
    for t in $tags; do [[ $t == stack-* ]] && stacks="$stacks ${t#stack-}"; done
    # shellcheck disable=SC2086  # one argument per stack
    "$REGISTER" "$name" "$ip" "$token" 1 $stacks | while IFS= read -r line; do log "$line"; done
    [ "${PIPESTATUS[0]}" -eq 0 ] || fail "registering in Dockhand"

    # Done: hand the CT over to the normal hookscript (direct edit, like hookscript.pl's mounts).
    sed "s|^hookscript: .*|hookscript: $NORMAL_HOOK|" "$conf" > "$conf.tmp" && mv "$conf.tmp" "$conf" \
        || fail "swapping hookscript"
    log "provisioned, hookscript is now $NORMAL_HOOK"
}

case $phase in
    provision) provision ;;
    *)
        run_normal_hook
        [ "$phase" = post-start ] && systemd-run --quiet --collect --no-block \
            --unit="proxdock-provision-$vmid" "$SELF" "$vmid" provision
        ;;
esac
exit 0
