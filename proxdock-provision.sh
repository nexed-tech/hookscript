#!/bin/bash
# ProxDock first-boot provisioning hookscript.
#
# Attached to the Docker template CT, so every clone inherits it. Each phase first runs the
# normal hookscript (network from VMID, mounts, ...). On post-start it starts the provisioning
# job in the background (the config is locked while post-start runs), which:
#   1. starts Hawser in the CT (/opt/stacks/hawser from the template) with a fresh token
#   2. registers (or updates) the CT as a hawser-standard environment in Dockhand
#   3. deploys BASE_STACK plus one git stack per `stack-<name>` tag, from <name>/ in REPO_NAME
#   4. swaps this hookscript for the normal one in the CT config
# Until step 4 succeeds the CT keeps this hookscript, so the next start retries.
#
# Cluster-wide config: /etc/pve/proxdock/provision.conf
#   DOCKHAND_URL=http://...:3000   REPO_NAME=stacks   BASE_STACK=caddy-tunnelsync
#   NORMAL_HOOK=local:snippets/hookscript.pl   SECRET_PROVIDER=<name>  (optional)
# Optional Dockhand API token: /etc/pve/priv/proxdock/dockhand.token

vmid=$1 phase=$2
SELF=/var/lib/vz/snippets/proxdock-provision.sh
LOG=/var/log/proxdock-provision.log
TOKEN_FILE=/etc/pve/priv/proxdock/dockhand.token
HAWSER_DIR=/opt/stacks/hawser   # in the CT

log() { echo "$(date '+%F %T') $vmid $phase: $*" | tee -a "$LOG"; }
fail() { log "FAILED: $*"; exit 1; }

. /etc/pve/proxdock/provision.conf || { log "no provision.conf"; exit 0; }
conf=/etc/pve/lxc/$vmid.conf

run_normal_hook() {
    local normal=/var/lib/vz/snippets/${NORMAL_HOOK#*:snippets/}
    [ -n "$NORMAL_HOOK" ] && [ -x "$normal" ] && "$normal" "$vmid" "$phase"
}

api() {   # api METHOD PATH [JSON]
    local auth=()
    [ -s "$TOKEN_FILE" ] && auth=(-H "Authorization: Bearer $(cat "$TOKEN_FILE")")
    # Accept: application/json makes Dockhand wait for deploys and return the result,
    # instead of answering with a background jobId.
    curl -sS --max-time 900 -X "$1" "${auth[@]}" -H 'Content-Type: application/json' \
        -H 'Accept: application/json' \
        ${3:+--data "$3"} "$DOCKHAND_URL$2"
}

# Reads JSON on stdin, prints the id of the item whose `field` equals `value`.
json_find_id() { python3 -c '
import json, sys
for x in json.load(sys.stdin):
    if x.get(sys.argv[1]) == sys.argv[2]: print(x["id"]); break' "$1" "$2"; }

provision() {
    local ip name tags env_id token repo_id provider_id stacks s body result
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

    env_id=$(api GET /api/environments | json_find_id name "$name")
    body="{\"name\":\"$name\",\"connectionType\":\"hawser-standard\",\"host\":\"$ip\",\"port\":2376,\"hawserToken\":\"$token\"}"
    if [ -n "$env_id" ]; then
        api PUT "/api/environments/$env_id" "$body" >/dev/null || fail "updating environment $env_id"
        log "updated Dockhand environment $env_id"
    else
        env_id=$(api POST /api/environments "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])') \
            || fail "creating environment"
        log "created Dockhand environment $env_id"
    fi

    for i in $(seq 15); do
        api POST "/api/environments/$env_id/test" | grep -q '"success":true' && break; sleep 2
    done || true

    repo_id=$(api GET /api/git/repositories | json_find_id name "$REPO_NAME")
    [ -n "$repo_id" ] || fail "repository '$REPO_NAME' not found in Dockhand"
    provider_id=null
    if [ -n "$SECRET_PROVIDER" ]; then
        provider_id=$(api GET /api/secret-providers | json_find_id name "$SECRET_PROVIDER")
        [ -n "$provider_id" ] || fail "secret provider '$SECRET_PROVIDER' not found"
    fi

    stacks=$BASE_STACK
    for t in $tags; do [[ $t == stack-* ]] && stacks="$stacks ${t#stack-}"; done
    for s in $stacks; do
        local existing
        existing=$(api GET "/api/git/stacks?env=$env_id" | json_find_id stackName "$s")
        if [ -n "$existing" ]; then
            result=$(api POST "/api/git/stacks/$existing/deploy")
        else
            body="{\"stackName\":\"$s\",\"environmentId\":$env_id,\"repositoryId\":$repo_id,\
\"composePath\":\"$s/compose.yaml\",\"envFilePath\":\"$s/.env\",\"secretProviderId\":$provider_id,\
\"envVars\":[{\"key\":\"HOST_IP\",\"value\":\"$ip\"}],\"deployNow\":true}"
            result=$(api POST /api/git/stacks "$body")
        fi
        echo "$result" | grep -q '"success":true' || fail "deploying $s: $(echo "$result" | tail -c 400)"
        log "deployed $s"
    done

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
