#!/bin/bash
# Registers a Docker host that runs Hawser in Dockhand, and deploys its stacks.
#
# Shared by proxdock-provision.sh (LXC) and vm-hookscript.pl (VMs). Runs on the
# Proxmox host and only talks to the Dockhand API, nothing in the guest.
#
#   dockhand-register.sh <name> <ip> <hawser-token> <token-is-new: 0|1> [stack...]
#
#   - environment <name> (hawser-standard, <ip>:2376): created when missing;
#     updated when its host/port differ or the token is new
#   - waits until Dockhand's connection test for it passes
#   - each stack: created and deployed (git stack <stack>/compose.yaml from
#     REPO_NAME) when Dockhand doesn't have it for this environment yet.
#     Existing stacks are left alone: keeping them current is Dockhand's job.
#
# One output line per action; exits non-zero on the first failure.
#
# Cluster-wide config: /etc/pve/proxdock/provision.conf
#   DOCKHAND_URL=http://...:3000   REPO_NAME=stacks   SECRET_PROVIDER=<name> (optional)
# Optional Dockhand API token: /etc/pve/priv/proxdock/dockhand.token

CONF=/etc/pve/proxdock/provision.conf
TOKEN_FILE=/etc/pve/priv/proxdock/dockhand.token
HAWSER_PORT=2376

name=$1 ip=$2 token=$3 token_new=$4
shift 4 2>/dev/null || { echo "usage: $0 <name> <ip> <hawser-token> <token-is-new: 0|1> [stack...]" >&2; exit 2; }
stacks=("$@")

fail() { echo "FAILED: $*"; exit 1; }

[ -r "$CONF" ] || fail "no $CONF"
. "$CONF"
[ -n "$DOCKHAND_URL" ] || fail "DOCKHAND_URL not set in $CONF"

api() {   # api METHOD PATH [JSON]
    local auth=()
    [ -s "$TOKEN_FILE" ] && auth=(-H "Authorization: Bearer $(cat "$TOKEN_FILE")")
    # Accept: application/json makes Dockhand wait for deploys and return the result,
    # instead of answering with a background jobId.
    curl -sS --max-time 900 -X "$1" "${auth[@]}" -H 'Content-Type: application/json' \
        -H 'Accept: application/json' \
        ${3:+--data "$3"} "$DOCKHAND_URL$2"
}

# Reads a JSON list on stdin, prints field `out` (default id) of the first item whose
# `field` equals `value`.
json_find() { python3 -c '
import json, sys
field, value, out = sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "id"
try:
    items = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for x in items if isinstance(items, list) else []:
    if str(x.get(field)) == value:
        print(x.get(out, "")); break' "$@"; }

# --- environment
envs=$(api GET /api/environments) || fail "Dockhand API not reachable at $DOCKHAND_URL"
env_id=$(json_find name "$name" <<<"$envs")
body="{\"name\":\"$name\",\"connectionType\":\"hawser-standard\",\"host\":\"$ip\",\"port\":$HAWSER_PORT,\"hawserToken\":\"$token\"}"

update_env() {
    api PUT "/api/environments/$env_id" "$body" >/dev/null || fail "updating environment $env_id"
    echo "updated Dockhand environment $name ($env_id) -> $ip:$HAWSER_PORT"
    updated=1
}

test_env() {   # test_env TRIES
    for i in $(seq "$1"); do
        api POST "/api/environments/$env_id/test" | grep -Eq '"success" *: *true' && return 0
        sleep 2
    done
    return 1
}

updated=
if [ -z "$env_id" ]; then
    env_id=$(api POST /api/environments "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' 2>/dev/null)
    [ -n "$env_id" ] || fail "creating environment $name"
    echo "created Dockhand environment $name ($env_id) -> $ip:$HAWSER_PORT"
    updated=1
else
    cur_host=$(json_find name "$name" host <<<"$envs")
    cur_port=$(json_find name "$name" port <<<"$envs")
    if [ "$token_new" = 1 ] || [ "$cur_host" != "$ip" ] || [ "$cur_port" != "$HAWSER_PORT" ]; then
        update_env
    fi
fi

# Dockhand doesn't hand out the stored token, so a stale one (e.g. a new token
# generated while Dockhand was unreachable) only shows as a failing test: push
# host/port/token once more before giving up.
if ! test_env 15; then
    [ -z "$updated" ] && update_env
    test_env 15 || fail "Dockhand can't reach Hawser on $name ($ip:$HAWSER_PORT)"
fi

[ ${#stacks[@]} -gt 0 ] || exit 0

# --- stacks
repo_id=$(api GET /api/git/repositories | json_find name "$REPO_NAME")
[ -n "$repo_id" ] || fail "repository '$REPO_NAME' not found in Dockhand"
provider_id=null
if [ -n "$SECRET_PROVIDER" ]; then
    provider_id=$(api GET /api/secret-providers | json_find name "$SECRET_PROVIDER")
    [ -n "$provider_id" ] || fail "secret provider '$SECRET_PROVIDER' not found"
fi

existing=$(api GET "/api/git/stacks?env=$env_id") || fail "listing stacks of $name"
for s in "${stacks[@]}"; do
    [ -n "$(json_find stackName "$s" stackName <<<"$existing")" ] && continue
    body="{\"stackName\":\"$s\",\"environmentId\":$env_id,\"repositoryId\":$repo_id,\
\"composePath\":\"$s/compose.yaml\",\"envFilePath\":\"$s/.env\",\"secretProviderId\":$provider_id,\
\"envVars\":[{\"key\":\"HOST_IP\",\"value\":\"$ip\"}],\"deployNow\":true}"
    result=$(api POST /api/git/stacks "$body")
    # Prints "ok", or "<stack id or empty> <error>". Dockhand answers with the
    # stack plus deployResult; older/other answers have a top-level success.
    verdict=$(python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    print(" not JSON: " + sys.argv[1][-300:]); sys.exit()
r = d.get("deployResult") if isinstance(d.get("deployResult"), dict) else d
if r.get("success"):
    print("ok")
else:
    print("%s %s" % (d.get("id") or "", r.get("error") or r.get("message") or json.dumps(r)[-300:]))' "$result" <<<"$result")
    if [ "$verdict" != ok ]; then
        stack_id=${verdict%% *}
        # Dockhand keeps a stack whose first deploy failed; remove it so the next
        # start creates and deploys it again instead of skipping it as existing.
        [ -n "$stack_id" ] && api DELETE "/api/git/stacks/$stack_id" >/dev/null
        fail "deploying $s: ${verdict#* }${stack_id:+ (stack $stack_id removed again, retried on the next start)}"
    fi
    echo "deployed stack $s"
done
exit 0
