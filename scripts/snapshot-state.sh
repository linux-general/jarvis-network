#!/usr/bin/env bash
# snapshot-state.sh — 12h state snapshot to Vultr Object Storage.
#
# Tars up everything that's "operational state" but NOT model weights or
# secrets, compresses with zstd, uploads to s3://jarvis-backups/snapshots/.
#
# What's included:
#   ~/.config/jarvis/             configs (excluding files with secret in name)
#   ~/.hermes/profiles/           Hermes persona profiles
#   ~/.claude/projects/.../memory/  auto-memory
#   ~/call-transcripts/           call transcripts + speaker sidecars
#   $LLM_WIKI_ROOT                knowledge base (text only, .git excluded; default: $HOME/llm-wiki)
#
# What's deliberately NOT included:
#   ~/.config/jarvis/{vultr-*,hf-token*,headscale-authkey}  (secrets)
#   ~/.cache/                                               (regenerable)
#   ~/.hermes/audio_cache/                                  (regenerable)
#   model weights                                           (in jarvis-models)
#
# Retention: see retention-prune-snapshots.sh (companion). Default policy:
# keep last 14 daily snapshots + 8 weekly. Pruning is a separate timer.
#
# Idempotency: snapshots are named by timestamp; re-running within the
# same minute overwrites the same key. Otherwise additive.

set -euo pipefail

# Resolve creds (try env first, then fall back to file)
if [ -z "${VULTR_OS_HOSTNAME:-}" ] && [ -f "$HOME/.config/jarvis/vultr-os-credentials.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$HOME/.config/jarvis/vultr-os-credentials.env"
  set +a
fi
: "${VULTR_OS_HOSTNAME:?VULTR_OS_HOSTNAME unset}"
: "${VULTR_OS_ACCESS_KEY:?VULTR_OS_ACCESS_KEY unset}"
: "${VULTR_OS_SECRET_KEY:?VULTR_OS_SECRET_KEY unset}"

VENV="$HOME/.venvs/jarvis-os"
[ -x "$VENV/bin/python3" ] || {
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet boto3
}

# Pick a label
HOSTNAME_LABEL=$(hostname -s)
TS=$(date -u +%Y%m%d-%H%M)
KEY="snapshots/${HOSTNAME_LABEL}/${TS}.tar.zst"
# mktemp creates the file; zstd refuses to overwrite. Generate a unique
# name and let zstd create it.
TMP="/tmp/jarvis-snap-$(date +%s)-$$.tar.zst"
trap 'rm -f "$TMP"' EXIT

# ── 1. Build the tarball ─────────────────────────────────────────────────────
# Use --exclude to drop secrets + caches even when they sit under included
# paths. Order matters: includes are absolute paths, excludes are relative
# to the FS root.
echo "→ Building snapshot $TS for $HOSTNAME_LABEL"
INCLUDES=()
# Use a proper if/then — `[ -e ] && cmd` returns the test status, which
# bubbles up through this function and trips set -e when the path is
# missing (which is fine on machines that just don't have, say, an
# llm-wiki checkout; we want to skip, not abort).
add() { if [ -e "$1" ]; then INCLUDES+=("$1"); fi; }
add "$HOME/.config/jarvis"
add "$HOME/.hermes/profiles"
add "$HOME/.claude/projects/-home-jd/memory"
add "$HOME/call-transcripts"
add "${LLM_WIKI_ROOT:-$HOME/llm-wiki}"

if [ ${#INCLUDES[@]} -eq 0 ]; then
  echo "  ✗ Nothing to snapshot — all source paths missing" >&2
  exit 1
fi

# zstd levels: -3 is the speed/ratio sweet spot. zstd is required.
command -v zstd >/dev/null || { echo "  ✗ zstd not installed (apt install zstd)" >&2; exit 1; }

# tar may exit 1 when files change during read (Hermes is live; profile
# state.db can update mid-snapshot). We tolerate exit 1 ("some files
# differ") but treat exit 2+ as fatal. zstd is wrapped separately so its
# real error code surfaces.
set +e +o pipefail
tar \
  --exclude='*vultr-api-key*' \
  --exclude='*vultr-os-credentials*' \
  --exclude='*hf-token*' \
  --exclude='*headscale-authkey*' \
  --exclude='*.env' \
  --exclude='*/.cache/*' \
  --exclude='*/audio_cache/*' \
  --exclude='*/.git/*' \
  --exclude='*/__pycache__/*' \
  --exclude='*/.venv/*' \
  --exclude='*/node_modules/*' \
  --exclude='*.tmp' \
  -C / \
  -cf - "${INCLUDES[@]#/}" \
  | zstd -3 -T0 -o "$TMP"
# Capture PIPESTATUS atomically — accessing it after another command resets.
rc=("${PIPESTATUS[@]}")
tar_rc=${rc[0]:-0}
zstd_rc=${rc[1]:-0}
set -e -o pipefail
if [ "$tar_rc" -gt 1 ]; then echo "  ✗ tar exit $tar_rc — fatal" >&2; exit 1; fi
if [ "$zstd_rc" -ne 0 ]; then echo "  ✗ zstd exit $zstd_rc" >&2; exit 1; fi
[ "$tar_rc" -eq 1 ] && echo "  ⚠ tar exit 1 (some files changed during read) — tarball still valid"

SIZE=$(stat -c '%s' "$TMP")
echo "  ✓ Tarball: $((SIZE/1024/1024)) MiB at $TMP"

# ── 2. Upload to OS ──────────────────────────────────────────────────────────
echo "→ Uploading to s3://jarvis-backups/$KEY"
"$VENV/bin/python3" - <<PY
import os, boto3
s3 = boto3.client("s3",
    endpoint_url=f"https://{os.environ['VULTR_OS_HOSTNAME']}",
    aws_access_key_id=os.environ['VULTR_OS_ACCESS_KEY'],
    aws_secret_access_key=os.environ['VULTR_OS_SECRET_KEY'],
    region_name="atl",
)
s3.upload_file("$TMP", "jarvis-backups", "$KEY", ExtraArgs={"ContentType": "application/zstd"})
# Write a tiny "latest" marker so restore can find the newest without listing
s3.put_object(Bucket="jarvis-backups",
    Key=f"snapshots/${HOSTNAME_LABEL}/_latest.txt",
    Body=b"${KEY}\n",
    ContentType="text/plain")
PY
echo "  ✓ Uploaded $((SIZE/1024/1024)) MiB"
