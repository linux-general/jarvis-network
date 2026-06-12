#!/usr/bin/env bash
# =============================================================================
# bootstrap-ws48.sh — bring a fresh Kubuntu box up as a Jarvis Network
#                     brain node (full voice stack, native host install).
#
# Run on a fresh Kubuntu install as user `jd` with sudo privileges:
#
#   curl -fsSL https://raw.githubusercontent.com/linux-general/jarvis-network/main/bootstrap-ws48.sh | bash
#
# Or for repeatable re-runs after cloning the repo:
#
#   git clone https://github.com/linux-general/jarvis-network.git
#   cd jarvis-network && bash bootstrap-ws48.sh
#
# The script is IDEMPOTENT — re-running it skips anything already installed.
#
# Prompts twice for secrets at startup:
#   1. headscale authkey (hskey-auth-…) — joins the tailnet
#   2. GitHub PAT (fine-grained, read access to llm-wiki + local-llm) —
#      clones the two private repos
#
# Both can also be supplied via env vars HEADSCALE_AUTHKEY / GITHUB_PAT
# to allow non-interactive runs.
# =============================================================================

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────────
readonly TARGET_USER="jd"
readonly TARGET_HOME="/home/${TARGET_USER}"
readonly HEADSCALE_URL="https://headscale.jarvisnetwork.org"

# Model + voice asset choices. Matches what's running on ws-47 as of 2026-06-12.
readonly VLLM_MODEL_REPO="cpatonn/Qwen3-30B-A3B-Instruct-2507-AWQ-4bit"
readonly VLLM_SERVED_NAME="qwen3.6:latest"
readonly VLLM_PORT="11436"
readonly VLLM_MAX_MODEL_LEN="40960"
readonly VLLM_GPU_MEM_UTIL="0.85"
readonly VLLM_TP_SIZE="2"
readonly WHISPER_MODEL="large-v3-turbo"
readonly PIPER_VOICE="en_US-lessac-medium"

# Repos to clone (private — need PAT)
readonly LLM_WIKI_REPO="linux-general/llm-wiki"
readonly LOCAL_LLM_REPO="linux-general/local-llm"

# Repo to clone for the Hermes agent framework (public, no auth needed)
readonly HERMES_AGENT_REPO="https://github.com/NousResearch/hermes-agent.git"

# ── Output helpers ──────────────────────────────────────────────────────────
readonly C_RESET='\033[0m'
readonly C_BOLD='\033[1m'
readonly C_OK='\033[32m'
readonly C_WARN='\033[33m'
readonly C_ERR='\033[31m'
readonly C_INFO='\033[36m'

step()  { printf "\n${C_BOLD}${C_INFO}══ %s${C_RESET}\n" "$*"; }
log()   { printf "${C_OK}✓${C_RESET} %s\n" "$*"; }
warn()  { printf "${C_WARN}!${C_RESET} %s\n" "$*"; }
skip()  { printf "${C_INFO}·${C_RESET} skip: %s\n" "$*"; }
die()   { printf "${C_ERR}✗ %s${C_RESET}\n" "$*" >&2; exit 1; }

# ── Pre-flight sanity ───────────────────────────────────────────────────────
preflight() {
    step "preflight"

    [[ $EUID -ne 0 ]] || die "do not run as root; run as ${TARGET_USER} — sudo is invoked internally where needed"
    [[ "$(id -un)" == "${TARGET_USER}" ]] || die "expected user '${TARGET_USER}', running as '$(id -un)'"
    [[ -d "${TARGET_HOME}" ]] || die "no home dir at ${TARGET_HOME}"

    # Sudo sanity — bootstrap needs it for apt + docker install + tailscale up
    sudo -n true 2>/dev/null || sudo -v || die "sudo authentication failed"
    log "sudo OK"

    # Kubuntu / Ubuntu family
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID:-}${ID_LIKE:-}" in
            *ubuntu*|*debian*) log "OS family: ${PRETTY_NAME:-${ID}}";;
            *) warn "untested OS: ${PRETTY_NAME:-${ID:-unknown}} — proceeding anyway";;
        esac
    fi

    # GPU presence
    if lspci 2>/dev/null | grep -qi 'nvidia'; then
        log "NVIDIA GPU detected: $(lspci | grep -i 'nvidia' | head -1 | cut -d: -f3-)"
    else
        warn "no NVIDIA GPU detected — vLLM step will fail; install on a GPU box"
    fi
}

# ── Prompt for secrets ──────────────────────────────────────────────────────
prompt_secrets() {
    step "credentials"

    if [[ -z "${HEADSCALE_AUTHKEY:-}" ]]; then
        printf "Paste headscale authkey (hskey-auth-… — input hidden): "
        read -rs HEADSCALE_AUTHKEY
        echo
    fi
    [[ -n "${HEADSCALE_AUTHKEY:-}" ]] || die "headscale authkey is required"
    log "headscale authkey captured (${#HEADSCALE_AUTHKEY} chars)"

    if [[ -z "${GITHUB_PAT:-}" ]]; then
        printf "Paste GitHub PAT (read access to llm-wiki + local-llm — input hidden): "
        read -rs GITHUB_PAT
        echo
    fi
    [[ -n "${GITHUB_PAT:-}" ]] || die "GitHub PAT is required (needed to clone the two private repos)"
    log "GitHub PAT captured (${#GITHUB_PAT} chars)"
}

# ── 1. NVIDIA driver ────────────────────────────────────────────────────────
install_nvidia_driver() {
    step "1. NVIDIA driver"
    if command -v nvidia-smi >/dev/null && nvidia-smi >/dev/null 2>&1; then
        skip "nvidia-smi already works ($(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1))"
        return
    fi
    sudo apt-get update -y
    sudo apt-get install -y ubuntu-drivers-common
    sudo ubuntu-drivers install
    warn "driver installed; a REBOOT is required before vLLM/STT/TTS can use the GPU. Re-run this script after reboot to continue."
    log "rebooting in 10 seconds (Ctrl+C to abort)…"
    sleep 10
    sudo reboot
}

# ── 2. Docker ───────────────────────────────────────────────────────────────
install_docker() {
    step "2. Docker"
    if command -v docker >/dev/null; then
        skip "docker present: $(docker --version)"
    else
        curl -fsSL https://get.docker.com | sudo sh
        sudo usermod -aG docker "${TARGET_USER}"
        log "docker installed; you may need to log out + back in for group membership"
    fi
}

# ── 3. NVIDIA Container Toolkit ─────────────────────────────────────────────
install_nvidia_container_toolkit() {
    step "3. NVIDIA Container Toolkit"
    if dpkg -s nvidia-container-toolkit >/dev/null 2>&1; then
        skip "nvidia-container-toolkit already installed"
        return
    fi
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
    sudo apt-get update -y
    sudo apt-get install -y nvidia-container-toolkit
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker
    log "nvidia-container-toolkit installed + docker reconfigured"
}

# ── 4. Tailscale + headscale join ───────────────────────────────────────────
install_tailscale_and_join() {
    step "4. Tailscale + join jarvis-headscale"
    if ! command -v tailscale >/dev/null; then
        curl -fsSL https://tailscale.com/install.sh | sudo sh
    else
        skip "tailscale already installed: $(tailscale version | head -1)"
    fi
    if tailscale status >/dev/null 2>&1 && tailscale status | grep -q "${HEADSCALE_URL#https://}\|jarvisnetwork"; then
        skip "tailscale already up on a jarvis-* tailnet"
        log "tailnet IP: $(tailscale ip -4 | head -1)"
    else
        sudo tailscale up \
            --login-server="${HEADSCALE_URL}" \
            --authkey="${HEADSCALE_AUTHKEY}" \
            --accept-routes \
            --accept-dns=true
        log "joined jarvis-headscale tailnet; IP: $(tailscale ip -4 | head -1)"
    fi
}

# ── 5. Apt OS deps ──────────────────────────────────────────────────────────
install_apt_deps() {
    step "5. apt OS dependencies"
    sudo apt-get update -y
    sudo apt-get install -y \
        git curl ca-certificates jq \
        build-essential python3-venv python3-pip python3-dev \
        portaudio19-dev ffmpeg libasound-dev libsndfile1 \
        pipewire pipewire-pulse pulseaudio-utils \
        nginx-light
    log "apt deps installed"
}

# ── 6. Hermes agent (native install) ────────────────────────────────────────
install_hermes_agent() {
    step "6. Hermes agent (native, ~/.hermes)"
    if [[ -d "${TARGET_HOME}/.hermes/hermes-agent" ]]; then
        skip "~/.hermes/hermes-agent already exists"
        return
    fi
    mkdir -p "${TARGET_HOME}/.hermes"
    git clone "${HERMES_AGENT_REPO}" "${TARGET_HOME}/.hermes/hermes-agent"
    # setup-hermes.sh creates the venv + skill bundle + default SOUL.md.
    # This intentionally leaves SOUL/MEMORY/USER as defaults — the operator
    # is starting with an EMPTY agent (no C-3PO, no Marie). Personas can
    # be added later via `hermes profile create <name>`.
    cd "${TARGET_HOME}/.hermes/hermes-agent"
    bash setup-hermes.sh
    log "Hermes agent installed; SOUL.md / MEMORY.md left as defaults"
}

# ── 7. Clone our private helper repos ───────────────────────────────────────
clone_private_repos() {
    step "7. clone llm-wiki + local-llm"
    local clone_url_prefix="https://${GITHUB_PAT}@github.com"

    if [[ -d "${TARGET_HOME}/llm-wiki/.git" ]]; then
        skip "~/llm-wiki/ already cloned"
    else
        git clone "${clone_url_prefix}/${LLM_WIKI_REPO}.git" "${TARGET_HOME}/llm-wiki"
        log "llm-wiki cloned to ~/llm-wiki/"
    fi

    if [[ -d "${TARGET_HOME}/local-llm/.git" ]]; then
        skip "~/local-llm/ already cloned"
    else
        git clone "${clone_url_prefix}/${LOCAL_LLM_REPO}.git" "${TARGET_HOME}/local-llm"
        log "local-llm cloned to ~/local-llm/"
    fi

    # Strip the PAT from the git remotes so it doesn't sit on disk
    git -C "${TARGET_HOME}/llm-wiki"  remote set-url origin "https://github.com/${LLM_WIKI_REPO}.git"
    git -C "${TARGET_HOME}/local-llm" remote set-url origin "https://github.com/${LOCAL_LLM_REPO}.git"
    log "PAT removed from remote URLs"
}

# ── 8. Voice-stack venv (Kokoro + faster-whisper + Wyoming + WebRTC) ────────
setup_local_llm_venv() {
    step "8. ~/local-llm/.venv (voice deps)"
    local venv="${TARGET_HOME}/local-llm/.venv"
    if [[ -d "${venv}" ]]; then
        skip "local-llm venv already exists"
    else
        python3 -m venv "${venv}"
    fi
    # shellcheck disable=SC1091
    source "${venv}/bin/activate"
    pip install -q --upgrade pip wheel setuptools
    pip install -q \
        faster-whisper piper-tts \
        sounddevice soundfile pyaudio pydub \
        wyoming aiohttp scipy
    deactivate
    log "voice deps installed in ~/local-llm/.venv"
}

# ── 9. Pre-pull Whisper + Piper voice assets ────────────────────────────────
prepull_voice_models() {
    step "9. pre-pull Whisper + Piper voices"
    mkdir -p "${TARGET_HOME}/.cache/whisper/models"
    mkdir -p "${TARGET_HOME}/local-llm/piper-voices"
    # shellcheck disable=SC1091
    source "${TARGET_HOME}/local-llm/.venv/bin/activate"
    # Whisper: faster-whisper downloads on first instantiation
    python3 - <<PY
from faster_whisper import WhisperModel
import os
WhisperModel("${WHISPER_MODEL}", device="cuda", compute_type="int8_float16",
             download_root=os.path.expanduser("~/.cache/whisper/models"))
print("whisper model ready")
PY
    # Piper: voice JSON + ONNX
    python3 -m piper.download_voices "${PIPER_VOICE}" \
        --data-dir "${TARGET_HOME}/local-llm/piper-voices/" || \
        warn "piper voice prefetch failed; will fetch on first use"
    deactivate
    log "Whisper + Piper voice assets ready"
}

# ── 10. vLLM venv + Qwen model pre-pull ─────────────────────────────────────
setup_vllm() {
    step "10. vLLM (~/jarvis-vllm/.venv) + Qwen3-30B-A3B AWQ"
    local venv="${TARGET_HOME}/jarvis-vllm/.venv"
    if [[ -d "${venv}" ]]; then
        skip "vLLM venv already exists"
    else
        mkdir -p "${TARGET_HOME}/jarvis-vllm"
        python3 -m venv "${venv}"
        # shellcheck disable=SC1091
        source "${venv}/bin/activate"
        pip install -q --upgrade pip wheel setuptools
        pip install -q "vllm==0.22.0" "transformers==5.10.2" "flashinfer-python"
        deactivate
    fi

    # Pre-pull the model with hf_hub (avoids the cold-start hit later)
    # shellcheck disable=SC1091
    source "${venv}/bin/activate"
    python3 - <<PY
from huggingface_hub import snapshot_download
snapshot_download(repo_id="${VLLM_MODEL_REPO}", local_dir=None)
print("vLLM model ready")
PY
    deactivate
    log "vLLM ready, Qwen3-30B-A3B AWQ pre-pulled"
}

# ── 11. Ollama (backup only, no models) ─────────────────────────────────────
install_ollama() {
    step "11. Ollama (backup; no models pulled)"
    if command -v ollama >/dev/null; then
        skip "ollama already installed: $(ollama --version 2>&1 | head -1)"
        return
    fi
    curl -fsSL https://ollama.com/install.sh | sh
    log "ollama installed (no models pulled)"
}

# ── 12. systemd-user units (mirror ws-47) ───────────────────────────────────
write_systemd_units() {
    step "12. systemd-user units"
    local unit_dir="${TARGET_HOME}/.config/systemd/user"
    mkdir -p "${unit_dir}"

    # vLLM TP=2 -- ws-47 uses GPUs 1+3 there; ws-48 only has 2 GPUs so they
    # default to all-of-them and CUDA_DEVICE_ORDER=PCI_BUS_ID picks them.
    cat > "${unit_dir}/vllm-tp2.service" <<EOF
[Unit]
Description=vLLM TP=${VLLM_TP_SIZE} server (port ${VLLM_PORT}, ${VLLM_MODEL_REPO})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${TARGET_HOME}/jarvis-vllm/.venv/bin/vllm serve ${VLLM_MODEL_REPO} \\
    --host 0.0.0.0 --port ${VLLM_PORT} \\
    --tensor-parallel-size ${VLLM_TP_SIZE} \\
    --gpu-memory-utilization ${VLLM_GPU_MEM_UTIL} \\
    --max-model-len ${VLLM_MAX_MODEL_LEN} \\
    --served-model-name ${VLLM_SERVED_NAME} \\
    --enable-auto-tool-choice --tool-call-parser hermes \\
    --trust-remote-code
Restart=always
RestartSec=10
Environment=CUDA_DEVICE_ORDER=PCI_BUS_ID
Environment=HF_HUB_OFFLINE=1
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

    # Wyoming STT (faster-whisper)
    cat > "${unit_dir}/wyoming-stt.service" <<EOF
[Unit]
Description=Wyoming STT (faster-whisper ${WHISPER_MODEL}, port 10300)
After=network-online.target

[Service]
Type=simple
ExecStart=${TARGET_HOME}/local-llm/.venv/bin/python ${TARGET_HOME}/local-llm/wyoming/stt_server.py
Restart=always
RestartSec=5
Environment=HOME=${TARGET_HOME}
Environment=PYTHONPATH=${TARGET_HOME}/.hermes/hermes-agent
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

    # Wyoming TTS (Kokoro -> Piper fallback)
    cat > "${unit_dir}/wyoming-tts.service" <<EOF
[Unit]
Description=Wyoming TTS (Kokoro -> Piper fallback, port 10200)
After=network-online.target

[Service]
Type=simple
ExecStart=${TARGET_HOME}/local-llm/.venv/bin/python ${TARGET_HOME}/local-llm/wyoming/tts_server.py
Restart=always
RestartSec=5
Environment=HOME=${TARGET_HOME}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

    # Wyoming WebRTC gateway
    cat > "${unit_dir}/wyoming-webrtc.service" <<EOF
[Unit]
Description=Hermes WebRTC voice gateway (HTTPS port 8443)
After=network-online.target wyoming-stt.service wyoming-tts.service
Wants=wyoming-stt.service wyoming-tts.service

[Service]
Type=simple
ExecStart=${TARGET_HOME}/.hermes/hermes-agent/venv/bin/python ${TARGET_HOME}/local-llm/webrtc/ws_gateway.py
Restart=always
RestartSec=5
Environment=HOME=${TARGET_HOME}
Environment=PYTHONPATH=${TARGET_HOME}/.hermes/hermes-agent
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

    log "systemd-user units written to ~/.config/systemd/user/"
}

# ── 13. self-signed TLS cert for the WebRTC gateway ─────────────────────────
make_webrtc_certs() {
    step "13. self-signed cert for WebRTC gateway"
    local cert_dir="${TARGET_HOME}/local-llm/webrtc/certs"
    mkdir -p "${cert_dir}"
    if [[ -f "${cert_dir}/ws-48.crt" ]]; then
        skip "ws-48 cert already exists"
        return
    fi
    openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
        -subj "/CN=ws-48.jarvisnetwork.org" \
        -keyout "${cert_dir}/ws-48.key" \
        -out    "${cert_dir}/ws-48.crt" \
        2>/dev/null
    chmod 600 "${cert_dir}/ws-48.key"
    log "self-signed cert + key generated for ws-48"
}

# ── 14. Enable user lingering + start services ──────────────────────────────
start_services() {
    step "14. enable lingering + start services"
    sudo loginctl enable-linger "${TARGET_USER}"
    log "user lingering enabled (services survive logout)"

    systemctl --user daemon-reload
    for svc in vllm-tp2 wyoming-stt wyoming-tts wyoming-webrtc; do
        systemctl --user enable --now "${svc}.service" || warn "${svc} failed to start; check journalctl --user -u ${svc}"
    done
}

# ── 15. Health summary ──────────────────────────────────────────────────────
print_summary() {
    step "15. summary"
    local ts_ip
    ts_ip="$(tailscale ip -4 2>/dev/null | head -1 || echo 'unknown')"

    printf "\n${C_BOLD}=== ws-48 bootstrap complete ===${C_RESET}\n\n"
    printf "  Tailscale IP            : %s\n" "${ts_ip}"
    printf "  vLLM endpoint           : http://127.0.0.1:%s/v1   (also reachable at http://%s:%s/v1)\n" "${VLLM_PORT}" "${ts_ip}" "${VLLM_PORT}"
    printf "  Wyoming STT             : 127.0.0.1:10300\n"
    printf "  Wyoming TTS             : 127.0.0.1:10200\n"
    printf "  WebRTC voice gateway    : https://127.0.0.1:8443\n"
    printf "  Hermes home             : %s/.hermes/    (empty agent — no persona)\n" "${TARGET_HOME}"
    printf "  llm-wiki                : %s/llm-wiki/\n" "${TARGET_HOME}"
    printf "  Voice trigger (CLI)     : Ctrl+B (see ~/.hermes/config.yaml, voice.record_key)\n"
    printf "\n  Phone routing           : 770-451-5224 is currently still pointed at ws-47.\n"
    printf "                            ws-48 won't see phone traffic until nginx is\n"
    printf "                            updated to route it here via Tailscale.\n\n"
    printf "  Next steps:\n"
    printf "    • hermes              # open the Hermes CLI; default empty SOUL.\n"
    printf "    • cat %s/llm-wiki/AGENTS.md   # read the wiki contract.\n" "${TARGET_HOME}"
    printf "    • journalctl --user -u vllm-tp2 -f   # tail vLLM logs.\n\n"

    # Quick health checks
    sleep 2
    if curl -fsS -m 2 "http://127.0.0.1:${VLLM_PORT}/health" >/dev/null 2>&1; then
        log "vLLM health: OK"
    else
        warn "vLLM not responding yet (cold start ~80-100s); tail journalctl --user -u vllm-tp2"
    fi
    if curl -fsS -m 2 "http://127.0.0.1:10300" >/dev/null 2>&1; then
        log "Wyoming STT: reachable"
    else
        warn "Wyoming STT not yet listening"
    fi
}

# ── main ───────────────────────────────────────────────────────────────────
main() {
    preflight
    prompt_secrets
    install_nvidia_driver           # may reboot
    install_docker
    install_nvidia_container_toolkit
    install_tailscale_and_join
    install_apt_deps
    install_hermes_agent
    clone_private_repos
    setup_local_llm_venv
    prepull_voice_models
    setup_vllm
    install_ollama
    write_systemd_units
    make_webrtc_certs
    start_services
    print_summary
}

main "$@"
