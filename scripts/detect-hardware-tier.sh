#!/usr/bin/env bash
# detect-hardware-tier.sh — classify a machine for the local-first / cloud-fallback router.
#
# Probes (in order): NVIDIA CUDA, AMD ROCm, Intel Habana, big-CPU heuristic.
# Writes a JSON snapshot to ${OUT:-/run/jarvis/tier.json} that Hermes reads at startup
# to choose between a local LLM endpoint and an OpenRouter cloud fallback.
#
# Output schema:
# {
#   "ts": "2026-06-29T14:35:00Z",
#   "tier": "nvidia" | "amd" | "habana" | "cpu-big" | "cpu-small" | "none",
#   "recommended_mode": "local" | "cloud",
#   "devices": [ { "vendor": "...", "name": "...", "vram_gb": 24 }, ... ],
#   "total_vram_gb": 48,
#   "cpu_cores": 32,
#   "ram_gb": 128,
#   "reasons": [ "human-readable explanations" ]
# }
#
# Re-run periodically via systemd timer (every 30 min) so a GPU passthrough
# hot-add or a Vultr GPU upgrade is reflected without a reboot.
#
# Usage:
#   detect-hardware-tier.sh                      # writes to /run/jarvis/tier.json
#   OUT=/tmp/tier.json detect-hardware-tier.sh   # custom path
#   detect-hardware-tier.sh --print              # write file AND print to stdout

set -euo pipefail

OUT="${OUT:-/run/jarvis/tier.json}"
PRINT=0
[ "${1:-}" = "--print" ] && PRINT=1

mkdir -p "$(dirname "$OUT")" 2>/dev/null || OUT="/tmp/jarvis-tier.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── helpers ──────────────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }
json_escape() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# ── 1. NVIDIA ────────────────────────────────────────────────────────────────
nvidia_devices=""
total_nvidia_vram_gb=0
if have nvidia-smi && nvidia-smi >/dev/null 2>&1; then
  # Lines like: "NVIDIA GeForce RTX 3090, 24576"
  while IFS=, read -r name mem; do
    name="$(echo "$name" | sed 's/^ *//;s/ *$//' | json_escape)"
    mem_mb="$(echo "$mem" | tr -d ' ')"
    mem_gb=$(( (mem_mb + 512) / 1024 ))   # round
    total_nvidia_vram_gb=$(( total_nvidia_vram_gb + mem_gb ))
    nvidia_devices+="{\"vendor\":\"nvidia\",\"name\":\"$name\",\"vram_gb\":$mem_gb},"
  done < <(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null)
  nvidia_devices="${nvidia_devices%,}"
fi

# ── 2. AMD ROCm ──────────────────────────────────────────────────────────────
amd_devices=""
total_amd_vram_gb=0
if have rocminfo && rocminfo >/dev/null 2>&1; then
  # rocminfo lists each GPU; parse Marketing Name + VRAM
  while IFS=$'\t' read -r name vram_kb; do
    name="$(echo "$name" | json_escape)"
    vram_gb=$(( (vram_kb + 524288) / 1048576 ))   # KiB -> GiB rounded
    total_amd_vram_gb=$(( total_amd_vram_gb + vram_gb ))
    amd_devices+="{\"vendor\":\"amd\",\"name\":\"$name\",\"vram_gb\":$vram_gb},"
  done < <(rocminfo 2>/dev/null \
    | awk '/^  Name:/{name=$0; sub(/^ *Name: */,"",name)} /Size:/ && /KB/{gsub(/[^0-9]/,"",$2); if(name!=""){print name "\t" $2; name=""}}')
  amd_devices="${amd_devices%,}"
fi

# ── 3. Intel Habana (Gaudi) ──────────────────────────────────────────────────
habana_devices=""
if [ -d /dev/accel ] || [ -e /dev/hl0 ] || have hl-smi; then
  count=$(ls /dev/hl* 2>/dev/null | wc -l)
  [ "$count" -gt 0 ] && habana_devices="{\"vendor\":\"habana\",\"count\":$count}"
fi

# ── 4. CPU + RAM ─────────────────────────────────────────────────────────────
cpu_cores=$(nproc 2>/dev/null || echo 0)
ram_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
ram_gb=$(( (ram_kb + 524288) / 1048576 ))

# ── 5. classify ──────────────────────────────────────────────────────────────
tier="none"
recommended="cloud"
reasons=""

if [ -n "$nvidia_devices" ] && [ "$total_nvidia_vram_gb" -gt 0 ]; then
  tier="nvidia"; recommended="local"
  reasons+="\"nvidia: ${total_nvidia_vram_gb} GB VRAM across $(echo "$nvidia_devices" | grep -o '},' | wc -l)+1 device(s)\","
elif [ -n "$amd_devices" ] && [ "$total_amd_vram_gb" -gt 0 ]; then
  tier="amd"; recommended="local"
  reasons+="\"amd rocm: ${total_amd_vram_gb} GB VRAM\","
elif [ -n "$habana_devices" ]; then
  tier="habana"; recommended="local"
  reasons+="\"intel habana accelerator detected\","
elif [ "$cpu_cores" -ge 16 ] && [ "$ram_gb" -ge 64 ]; then
  tier="cpu-big"; recommended="local"
  reasons+="\"no accelerator; ${cpu_cores} cores + ${ram_gb} GB RAM is enough for small models locally\","
else
  tier="cpu-small"; recommended="cloud"
  reasons+="\"no accelerator; ${cpu_cores} cores + ${ram_gb} GB RAM below local-LLM threshold (need >=16c, >=64GB)\","
fi

# Build the devices array
all_devices=""
for d in "$nvidia_devices" "$amd_devices" "$habana_devices"; do
  [ -n "$d" ] && all_devices+="$d,"
done
all_devices="[${all_devices%,}]"

total_vram_gb=$(( total_nvidia_vram_gb + total_amd_vram_gb ))

# ── 6. write JSON atomically ─────────────────────────────────────────────────
tmp="$(mktemp "${OUT}.XXXXXX")"
cat > "$tmp" <<JSON
{
  "ts": "$TS",
  "tier": "$tier",
  "recommended_mode": "$recommended",
  "devices": $all_devices,
  "total_vram_gb": $total_vram_gb,
  "cpu_cores": $cpu_cores,
  "ram_gb": $ram_gb,
  "reasons": [${reasons%,}]
}
JSON
mv "$tmp" "$OUT"
chmod 644 "$OUT"

[ "$PRINT" -eq 1 ] && cat "$OUT"
exit 0
