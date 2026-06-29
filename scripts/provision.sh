#!/usr/bin/env bash
# provision.sh — spin a Vultr instance for the Jarvis Network stack by profile.
#
# Wraps the Vultr API: queries OS id, substitutes the cloud-init template, POSTs
# the instance, polls until active. Idempotent on label match — re-running with
# the same --hostname returns the existing instance instead of duplicating.
#
# Profiles (default plans, override with --plan; prices from atl 2026-06):
#   edge          $20/mo  vc2-2c-4gb        — Twilio terminator nodes
#   nginx         $10/mo  vc2-1c-2gb        — reverse proxy + voice-bridge
#   voice-bridge  $20/mo  vc2-2c-4gb        — dialog state holder (off ws-47)
#   seeder        $40/mo  vc2-4c-8gb        — one-shot model mirror, --destroy-on-done
#                                             (hourly billed; full seed ~$0.50)
#   brain         varies  query GPU plans   — pick interactively from --list-plans
#
# Required environment / files:
#   VULTR_API_KEY            or ~/.config/jarvis/vultr-api-key
#   HEADSCALE_AUTHKEY        or ~/.config/jarvis/headscale-authkey  (30-min one-shot)
#   ~/.config/jarvis/vultr-os-credentials.env   (for cloud-init to fetch configs)
#
# Generate a headscale one-shot authkey on the control server:
#   ssh root@100.64.0.1 'headscale preauthkeys create --reusable=false --expiration=30m --tags=tag:jarvis'
#
# Usage:
#   ./scripts/provision.sh --profile edge --hostname vx-test-02
#   ./scripts/provision.sh --profile seeder --hostname jarvis-seeder-01 --destroy-on-done
#   ./scripts/provision.sh --list-plans                # show GPU + recommended plans
#   ./scripts/provision.sh --destroy <hostname>        # delete an instance by label

set -euo pipefail

API="https://api.vultr.com/v2"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="${REPO_ROOT}/cloud-init/user-data.yaml.tmpl"

REGION="atl"
PROFILE=""
HOSTNAME_REQ=""
PLAN_OVERRIDE=""
DESTROY_ON_DONE=0
LIST_PLANS=0
DESTROY_HOST=""

# ── plans by profile ─────────────────────────────────────────────────────────
declare -A PROFILE_PLAN=(
  [edge]="vc2-2c-4gb"
  [nginx]="vc2-1c-2gb"
  [voice-bridge]="vc2-2c-4gb"
  [seeder]="vc2-4c-8gb"
  [brain]=""  # forces interactive GPU selection
)

# ── helpers ──────────────────────────────────────────────────────────────────
step() { printf "\033[36m→\033[0m %s\n" "$*"; }
ok()   { printf "\033[32m✓\033[0m %s\n" "$*"; }
err()  { printf "\033[31m✗\033[0m %s\n" "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ── args ─────────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --profile)           PROFILE="$2"; shift 2 ;;
    --hostname)          HOSTNAME_REQ="$2"; shift 2 ;;
    --region)            REGION="$2"; shift 2 ;;
    --plan)              PLAN_OVERRIDE="$2"; shift 2 ;;
    --destroy-on-done)   DESTROY_ON_DONE=1; shift ;;
    --list-plans)        LIST_PLANS=1; shift ;;
    --destroy)           DESTROY_HOST="$2"; shift 2 ;;
    -h|--help)           usage 0 ;;
    *) err "Unknown arg: $1"; usage 1 ;;
  esac
done

# ── resolve secrets ──────────────────────────────────────────────────────────
if [ -z "${VULTR_API_KEY:-}" ] && [ -f "$HOME/.config/jarvis/vultr-api-key" ]; then
  VULTR_API_KEY="$(tr -d '[:space:]' < "$HOME/.config/jarvis/vultr-api-key")"
fi
[ -n "${VULTR_API_KEY:-}" ] || { err "VULTR_API_KEY not set and ~/.config/jarvis/vultr-api-key missing"; exit 1; }

curl_v() { curl -fsS -H "Authorization: Bearer ${VULTR_API_KEY}" "$@"; }

have jq || { err "jq required: apt install jq"; exit 1; }

# ── --list-plans ─────────────────────────────────────────────────────────────
if [ $LIST_PLANS -eq 1 ]; then
  step "Recommended plans (cloud compute)"
  curl_v "${API}/plans" | jq -r --arg r "$REGION" '
    .plans[]
    | select(.locations | index($r))
    | select(.id | test("^(vc2|vhf|voc)-"))
    | "\(.id)\t$\(.monthly_cost)/mo\t\(.vcpu_count)vCPU\t\(.ram)MB RAM\t\(.disk)GB disk"' \
    | column -t -s $'\t' | head -20
  echo
  step "GPU plans (bare-metal + cloud GPU)"
  curl_v "${API}/plans" | jq -r --arg r "$REGION" '
    .plans[]
    | select(.locations | index($r))
    | select(.id | test("^(vbm|vcg)-"))
    | "\(.id)\t$\(.monthly_cost)/mo\t\(.vcpu_count)vCPU\t\(.ram)MB RAM\t\(.disk)GB disk\t\(.gpu_vram_gb // 0)GB VRAM"' \
    | column -t -s $'\t' | head -30
  exit 0
fi

# ── --destroy <hostname> ─────────────────────────────────────────────────────
if [ -n "$DESTROY_HOST" ]; then
  step "Looking up instance with label=$DESTROY_HOST"
  iid=$(curl_v "${API}/instances" | jq -r --arg h "$DESTROY_HOST" '.instances[] | select(.label == $h) | .id' | head -1)
  if [ -z "$iid" ] || [ "$iid" = "null" ]; then err "No instance with label '$DESTROY_HOST'"; exit 1; fi
  step "Destroying $iid"
  curl_v -X DELETE "${API}/instances/${iid}"
  ok "Destroyed."
  exit 0
fi

# ── normal create path ───────────────────────────────────────────────────────
[ -n "$PROFILE" ] || { err "--profile required"; usage 1; }
[ -n "$HOSTNAME_REQ" ] || { err "--hostname required"; usage 1; }
[ -n "${PROFILE_PLAN[$PROFILE]+x}" ] || { err "Unknown profile '$PROFILE'. Valid: ${!PROFILE_PLAN[*]}"; exit 1; }

PLAN="${PLAN_OVERRIDE:-${PROFILE_PLAN[$PROFILE]}}"
if [ -z "$PLAN" ]; then
  err "Profile '$PROFILE' has no default plan. Pass --plan <id> or run --list-plans"
  exit 1
fi

# Resolve headscale authkey
if [ -z "${HEADSCALE_AUTHKEY:-}" ] && [ -f "$HOME/.config/jarvis/headscale-authkey" ]; then
  HEADSCALE_AUTHKEY="$(tr -d '[:space:]' < "$HOME/.config/jarvis/headscale-authkey")"
fi
[ -n "${HEADSCALE_AUTHKEY:-}" ] || {
  err "HEADSCALE_AUTHKEY not set. Generate one with:"
  err "  ssh root@100.64.0.1 'headscale preauthkeys create --reusable=false --expiration=30m --tags=tag:jarvis'"
  exit 1
}

# Resolve Vultr OS credentials (for the bucket, not the API)
[ -f "$HOME/.config/jarvis/vultr-os-credentials.env" ] || {
  err "Missing ~/.config/jarvis/vultr-os-credentials.env (run scripts/provision-vultr-os.sh first)"
  exit 1
}
# shellcheck disable=SC1091
set -a; . "$HOME/.config/jarvis/vultr-os-credentials.env"; set +a

# HF token (only required for seeder profile; optional otherwise — gated
# models like pyannote/* need it, ungated models don't).
HF_TOKEN=""
if [ -f "$HOME/.config/jarvis/hf-token" ]; then
  HF_TOKEN="$(tr -d '[:space:]' < "$HOME/.config/jarvis/hf-token")"
fi
if [ "$PROFILE" = "seeder" ] && [ -z "$HF_TOKEN" ]; then
  err "Seeder profile needs HF_TOKEN. Put it in ~/.config/jarvis/hf-token (chmod 600)."
  exit 1
fi
export HF_TOKEN

# Idempotency: existing instance with same label?
existing=$(curl_v "${API}/instances" | jq -r --arg h "$HOSTNAME_REQ" \
  '.instances[] | select(.label == $h) | .id' | head -1)
if [ -n "$existing" ] && [ "$existing" != "null" ]; then
  ok "Instance '$HOSTNAME_REQ' already exists ($existing). Use --destroy to remove."
  curl_v "${API}/instances/${existing}" | jq '{id, label, plan, region, main_ip, status, power_status}'
  exit 0
fi

# Resolve Ubuntu 22.04 LTS os_id
step "Looking up Ubuntu 22.04 LTS os_id"
OS_ID=$(curl_v "${API}/os" | jq -r '.os[] | select(.name | test("Ubuntu 22.04"; "i")) | .id' | head -1)
[ -n "$OS_ID" ] && [ "$OS_ID" != "null" ] || { err "Could not find Ubuntu 22.04 os_id"; exit 1; }
ok "os_id=$OS_ID"

# Render template
step "Rendering cloud-init user-data"
JARVIS_NETWORK_REPO="https://github.com/linux-general/jarvis-network.git"
USER_DATA=$(
  PROFILE="$PROFILE" \
  HOSTNAME="$HOSTNAME_REQ" \
  HEADSCALE_AUTHKEY="$HEADSCALE_AUTHKEY" \
  JARVIS_NETWORK_REPO="$JARVIS_NETWORK_REPO" \
  VULTR_OS_HOSTNAME="$VULTR_OS_HOSTNAME" \
  VULTR_OS_ACCESS_KEY="$VULTR_OS_ACCESS_KEY" \
  VULTR_OS_SECRET_KEY="$VULTR_OS_SECRET_KEY" \
  HF_TOKEN="$HF_TOKEN" \
    envsubst '$PROFILE $HOSTNAME $HEADSCALE_AUTHKEY $JARVIS_NETWORK_REPO $VULTR_OS_HOSTNAME $VULTR_OS_ACCESS_KEY $VULTR_OS_SECRET_KEY $HF_TOKEN' < "$TEMPLATE"
)
USER_DATA_B64=$(printf '%s' "$USER_DATA" | base64 -w0)

# Create
step "POST /instances  region=$REGION plan=$PLAN label=$HOSTNAME_REQ"
create_json=$(curl_v -X POST "${API}/instances" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg region "$REGION" --arg plan "$PLAN" \
    --arg os_id "$OS_ID" --arg label "$HOSTNAME_REQ" \
    --arg host "$HOSTNAME_REQ" --arg ud "$USER_DATA_B64" \
    '{region:$region, plan:$plan, os_id:($os_id|tonumber), label:$label, hostname:$host,
      user_data:$ud, enable_ipv6:true, backups:"disabled"}')")

iid=$(echo "$create_json" | jq -r '.instance.id')
[ "$iid" != "null" ] || { echo "$create_json" | jq >&2; err "Create failed"; exit 1; }
ok "Created: $iid"

# Wait for active
step "Waiting for instance to become active"
for i in $(seq 1 60); do
  sleep 10
  st=$(curl_v "${API}/instances/${iid}" | jq -r '.instance.server_status, .instance.status' | paste -sd/ -)
  echo "  [${i}0s] $st"
  if echo "$st" | grep -qE '/active'; then break; fi
  [ $i -eq 60 ] && { err "Timeout (10min) waiting for active"; exit 1; }
done

step "Final details"
curl_v "${API}/instances/${iid}" | jq '.instance | {id, label, plan, region, main_ip, internal_ip, status, power_status, server_status}'

# Seeder one-shot lifecycle. Tailscale ACL blocks ws-47 -> seeder SSH by
# default, so we can't poll /run/jarvis/seeder-done over SSH. Instead the
# seeder uploads a status JSON to s3://jarvis-backups/seeder-markers/<host>.json
# when its run completes (cloud-init step 6 in user-data.yaml.tmpl).
if [ "$PROFILE" = "seeder" ] && [ $DESTROY_ON_DONE -eq 1 ]; then
  step "Waiting for seeder marker s3://jarvis-backups/seeder-markers/${HOSTNAME_REQ}.json"
  python3 -c 'import boto3' 2>/dev/null || PYTHON_S3="$HOME/.venvs/jarvis-os/bin/python3"
  PYTHON_S3="${PYTHON_S3:-python3}"
  # Stage the marker-poll script in a temp file (avoids gnarly heredoc-inside-
  # command-substitution-with-|| parsing in bash).
  POLL_PY=$(mktemp /tmp/jarvis-seeder-poll-XXXXXX.py)
  trap 'rm -f "$POLL_PY"' EXIT
  cat > "$POLL_PY" <<PY
import os, sys, json, boto3
from botocore.exceptions import ClientError
s3 = boto3.client("s3",
    endpoint_url=f"https://{os.environ['VULTR_OS_HOSTNAME']}",
    aws_access_key_id=os.environ['VULTR_OS_ACCESS_KEY'],
    aws_secret_access_key=os.environ['VULTR_OS_SECRET_KEY'],
    region_name="atl")
host = os.environ["HOSTNAME_REQ"]
try:
    o = s3.get_object(Bucket="jarvis-backups", Key=f"seeder-markers/{host}.json")
    print(json.loads(o["Body"].read())["status"])
except ClientError:
    pass
PY

  export HOSTNAME_REQ
  for i in $(seq 1 720); do  # up to 120 min (large repos can take a while)
    sleep 10
    status=$("$PYTHON_S3" "$POLL_PY" 2>/dev/null)
    if [ -n "$status" ]; then
      ok "Seeder finished with status=$status"
      if [ "$status" = "success" ]; then
        step "Destroying instance $iid"
        curl_v -X DELETE "${API}/instances/${iid}"
        ok "Destroyed."
      else
        err "Seeder failed — instance LEFT RUNNING for inspection (id=$iid, ip=$(curl_v "${API}/instances/${iid}" | jq -r '.instance.main_ip'))"
      fi
      exit 0
    fi
  done
  err "Seeder did not finish within 120 minutes. Instance left running for inspection."
  exit 1
fi

ok "Done. ssh root@${HOSTNAME_REQ} (over Tailscale) once headscale syncs."
