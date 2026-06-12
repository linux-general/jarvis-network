#!/usr/bin/env bash
# =============================================================================
# bootstrap-ws48.sh — bring a fresh Kubuntu box up as a Jarvis Network brain
#                     node. Host installs the heavy runtime (NVIDIA, Docker,
#                     vLLM, Ollama, Tailscale); the voice stack runs as four
#                     containers via docker compose.
#
# Run on a fresh Kubuntu install as user `jd` with sudo privileges:
#
#   curl -fsSL https://raw.githubusercontent.com/linux-general/jarvis-network/main/bootstrap-ws48.sh | bash
#
# The script is IDEMPOTENT — re-running it skips anything already installed.
#
# Prompts twice at startup:
#   1. headscale authkey (hskey-auth-…)
#   2. GitHub PAT (needs `repo` for llm-wiki/local-llm clones AND
#                   `read:packages` for GHCR image pulls)
#
# Both can be supplied via env vars HEADSCALE_AUTHKEY / GITHUB_PAT for
# non-interactive use.
# =============================================================================

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────────
readonly TARGET_USER="jd"
readonly TARGET_HOME="/home/${TARGET_USER}"
readonly HEADSCALE_URL="https://headscale.jarvisnetwork.org"

# Host vLLM (model + endpoint shared with the containers via host.docker.internal)
readonly VLLM_MODEL_REPO="cpatonn/Qwen3-30B-A3B-Instruct-2507-AWQ-4bit"
readonly VLLM_SERVED_NAME="qwen3.6:latest"
readonly VLLM_PORT="11436"
readonly VLLM_MAX_MODEL_LEN="40960"
readonly VLLM_GPU_MEM_UTIL="0.85"
readonly VLLM_TP_SIZE="2"

# Repos
readonly JARVIS_NETWORK_REPO="https://github.com/linux-general/jarvis-network.git"
readonly LLM_WIKI_REPO="linux-general/llm-wiki"
readonly LOCAL_LLM_REPO="linux-general/local-llm"
readonly HERMES_AGENT_REPO="https://github.com/NousResearch/hermes-agent.git"

# Where the compose file lives, relative to the cloned jarvis-network repo
readonly COMPOSE_FILE_REL="compose/ws48.yml"

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

# ── Pre-flight ──────────────────────────────────────────────────────────────
preflight() {
    step "preflight"

    [[ $EUID -ne 0 ]] || die "do not run as root; run as ${TARGET_USER} — sudo is invoked internally where needed"
    [[ "$(id -un)" == "${TARGET_USER}" ]] || die "expected user '${TARGET_USER}', running as '$(id -un)'"
    [[ -d "${TARGET_HOME}" ]] || die "no home dir at ${TARGET_HOME}"

    sudo -n true 2>/dev/null || sudo -v || die "sudo authentication failed"
    log "sudo OK"

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID:-}${ID_LIKE:-}" in
            *ubuntu*|*debian*) log "OS family: ${PRETTY_NAME:-${ID}}";;
            *) warn "untested OS: ${PRETTY_NAME:-${ID:-unknown}} — proceeding anyway";;
        esac
    fi

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
        read -rs HEADSCALE_AUTHKEY; echo
    fi
    [[ -n "${HEADSCALE_AUTHKEY:-}" ]] || die "headscale authkey is required"
    log "headscale authkey captured (${#HEADSCALE_AUTHKEY} chars)"

    if [[ -z "${GITHUB_PAT:-}" ]]; then
        printf "Paste GitHub PAT (scopes: repo + read:packages — input hidden): "
        read -rs GITHUB_PAT; echo
    fi
    [[ -n "${GITHUB_PAT:-}" ]] || die "GitHub PAT is required (clones private repos + pulls GHCR images)"
    log "GitHub PAT captured (${#GITHUB_PAT} chars)"
}

# ── 1. NVIDIA driver ────────────────────────────────────────────────────────
install_nvidia_driver() {
    step "1. NVIDIA driver"
    if command -v nvidia-smi >/dev/null && nvidia-smi >/dev/null 2>&1; then
        skip "nvidia-smi works ($(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1))"
        return
    fi
    sudo apt-get update -y
    sudo apt-get install -y ubuntu-drivers-common
    sudo ubuntu-drivers install
    warn "driver installed; REBOOT required, then re-run this script to continue."
    log "rebooting in 10s (Ctrl+C to abort)…"
    sleep 10
    sudo reboot
}

# ── 2. Docker ───────────────────────────────────────────────────────────────
install_docker() {
    step "2. Docker"
    if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
        skip "docker + compose v2 present: $(docker --version)"
    else
        curl -fsSL https://get.docker.com | sudo sh
        sudo usermod -aG docker "${TARGET_USER}"
        warn "you may need to log out + back in for the docker group membership to take effect"
        warn "this script will use 'sudo docker' for the rest of this run as a workaround"
    fi
}

# ── 3. NVIDIA Container Toolkit ─────────────────────────────────────────────
install_nvidia_container_toolkit() {
    step "3. NVIDIA Container Toolkit"
    if dpkg -s nvidia-container-toolkit >/dev/null 2>&1; then
        skip "nvidia-container-toolkit installed"
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
    log "nvidia-container-toolkit installed + docker reconfigured for GPU containers"
}

# ── 4. Tailscale + headscale join ───────────────────────────────────────────
install_tailscale_and_join() {
    step "4. Tailscale + jarvis-headscale"
    if ! command -v tailscale >/dev/null; then
        curl -fsSL https://tailscale.com/install.sh | sudo sh
    else
        skip "tailscale installed: $(tailscale version | head -1)"
    fi
    if tailscale status >/dev/null 2>&1 && tailscale status | grep -q "jarvisnetwork\|100.64."; then
        skip "tailscale already up on a jarvis-* tailnet"
    else
        sudo tailscale up \
            --login-server="${HEADSCALE_URL}" \
            --authkey="${HEADSCALE_AUTHKEY}" \
            --accept-routes \
            --accept-dns=true
    fi
    log "tailnet IP: $(tailscale ip -4 2>/dev/null | head -1 || echo 'pending')"
}

# ── 5. Host apt deps ────────────────────────────────────────────────────────
install_apt_deps() {
    step "5. apt OS dependencies (host-side)"
    sudo apt-get update -y
    sudo apt-get install -y \
        git curl ca-certificates jq openssl \
        build-essential python3-venv python3-pip python3-dev \
        pipewire pipewire-pulse pulseaudio-utils
    log "apt deps installed (audio is PipeWire/PulseAudio so the hermes container can use the host mic)"
}

# ── 6. Clone the orchestrating repos ────────────────────────────────────────
clone_repos() {
    step "6. clone jarvis-network + local-llm + llm-wiki"
    local clone_url_prefix="https://${GITHUB_PAT}@github.com"

    # jarvis-network (public, but cheaper to clone via PAT to avoid rate limits)
    if [[ -d "${TARGET_HOME}/jarvis-network/.git" ]]; then
        skip "~/jarvis-network/ already cloned"
    else
        git clone "${JARVIS_NETWORK_REPO}" "${TARGET_HOME}/jarvis-network"
    fi
    if [[ -d "${TARGET_HOME}/local-llm/.git" ]]; then
        skip "~/local-llm/ already cloned"
    else
        git clone "${clone_url_prefix}/${LOCAL_LLM_REPO}.git" "${TARGET_HOME}/local-llm"
    fi
    if [[ -d "${TARGET_HOME}/llm-wiki/.git" ]]; then
        skip "~/llm-wiki/ already cloned"
    else
        git clone "${clone_url_prefix}/${LLM_WIKI_REPO}.git" "${TARGET_HOME}/llm-wiki"
    fi

    # Strip the PAT from the git remotes (it's still in shell history but not on disk)
    git -C "${TARGET_HOME}/local-llm" remote set-url origin "https://github.com/${LOCAL_LLM_REPO}.git"
    git -C "${TARGET_HOME}/llm-wiki"  remote set-url origin "https://github.com/${LLM_WIKI_REPO}.git"
    log "repos cloned; PAT removed from remote URLs"
}

# ── 7. vLLM on host (systemd-user) + model pre-pull ─────────────────────────
setup_vllm_host() {
    step "7. vLLM (~/jarvis-vllm/.venv) + Qwen3-30B-A3B AWQ"
    local venv="${TARGET_HOME}/jarvis-vllm/.venv"
    if [[ ! -d "${venv}" ]]; then
        mkdir -p "${TARGET_HOME}/jarvis-vllm"
        python3 -m venv "${venv}"
        # shellcheck disable=SC1091
        source "${venv}/bin/activate"
        pip install -q --upgrade pip wheel setuptools
        pip install -q "vllm==0.22.0" "transformers==5.10.2" "huggingface_hub" "flashinfer-python"
        deactivate
        log "vLLM venv created"
    else
        skip "vLLM venv exists"
    fi

    # Pre-pull the model (one-time ~17GB download)
    # shellcheck disable=SC1091
    source "${venv}/bin/activate"
    python3 - <<PY
from huggingface_hub import snapshot_download
snapshot_download(repo_id="${VLLM_MODEL_REPO}")
print("vLLM model ready")
PY
    deactivate

    # systemd-user unit
    local unit_dir="${TARGET_HOME}/.config/systemd/user"
    mkdir -p "${unit_dir}"
    cat > "${unit_dir}/vllm-tp2.service" <<EOF
[Unit]
Description=vLLM TP=${VLLM_TP_SIZE} (port ${VLLM_PORT}, ${VLLM_MODEL_REPO})
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

    sudo loginctl enable-linger "${TARGET_USER}"
    systemctl --user daemon-reload
    systemctl --user enable --now vllm-tp2.service
    log "vLLM systemd-user unit enabled + started (warm-up ~80-100s on cold cache)"
}

# ── 8. Ollama (backup only, no models) ──────────────────────────────────────
install_ollama() {
    step "8. Ollama (backup only)"
    if command -v ollama >/dev/null; then
        skip "ollama installed: $(ollama --version 2>&1 | head -1)"
        return
    fi
    curl -fsSL https://ollama.com/install.sh | sh
    log "ollama installed (no models pulled)"
}

# ── 9. Generate self-signed cert for the WebRTC gateway ─────────────────────
make_webrtc_certs() {
    step "9. self-signed cert for the WebRTC gateway"
    local cert_dir="${TARGET_HOME}/local-llm/webrtc/certs"
    mkdir -p "${cert_dir}"
    if [[ -f "${cert_dir}/ws-48.crt" && -f "${cert_dir}/ws-48.key" ]]; then
        skip "ws-48 cert + key already exist"
        return
    fi
    openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
        -subj "/CN=ws-48.jarvisnetwork.org" \
        -keyout "${cert_dir}/ws-48.key" \
        -out    "${cert_dir}/ws-48.crt" \
        2>/dev/null
    chmod 600 "${cert_dir}/ws-48.key"
    log "self-signed cert + key generated (mounted read-only into the webrtc container)"
}

# ── 10. Log in to GHCR + pull the four images ───────────────────────────────
docker_login_and_pull() {
    step "10. docker login GHCR + pull container images"
    echo "${GITHUB_PAT}" | sudo docker login ghcr.io -u "$(git config --global user.name 2>/dev/null || echo linux-general)" --password-stdin 2>&1 | tail -1
    log "GHCR login OK"
    cd "${TARGET_HOME}/jarvis-network"
    sudo docker compose -f "${COMPOSE_FILE_REL}" pull
    log "all images pulled"
}

# ── 11. Bring up the stack ──────────────────────────────────────────────────
compose_up() {
    step "11. docker compose up -d"
    cd "${TARGET_HOME}/jarvis-network"
    sudo docker compose -f "${COMPOSE_FILE_REL}" up -d
    log "containers started"
    sleep 4
    sudo docker compose -f "${COMPOSE_FILE_REL}" ps
}

# ── 12. Configure Hermes CLI inside the container ───────────────────────────
configure_hermes_cli() {
    step "12. configure Hermes CLI inside the hermes container"
    # Wait for hermes container to be up
    for _ in 1 2 3 4 5; do
        if sudo docker exec hermes true 2>/dev/null; then break; fi
        sleep 2
    done
    # Point Hermes CLI at host vLLM and at the container-network STT/TTS hosts.
    # These are the canonical config keys per ~/.hermes/config.yaml on ws-47.
    sudo docker exec -u hermes hermes bash -lc "
        hermes config set model.base_url http://host.docker.internal:11436/v1 || true
        hermes config set model.default qwen3.6:latest || true
        hermes config set tts.provider wyoming || true
        hermes config set stt.provider wyoming || true
        hermes config set voice.record_key ctrl+b || true
    " 2>&1 | tail -6 || warn "couldn't fully configure Hermes CLI in container — try again with 'docker exec -it hermes hermes'"
    log "Hermes CLI configured (model.base_url, providers, ctrl+b record key)"
}

# ── 13. Summary + health probes ─────────────────────────────────────────────
print_summary() {
    step "13. summary"
    local ts_ip
    ts_ip="$(tailscale ip -4 2>/dev/null | head -1 || echo 'unknown')"

    printf "\n${C_BOLD}=== ws-48 bootstrap complete ===${C_RESET}\n\n"
    printf "  Tailscale IP            : %s\n" "${ts_ip}"
    printf "  Host vLLM endpoint      : http://127.0.0.1:%s/v1\n" "${VLLM_PORT}"
    printf "  Containers              : stt, tts, hermes, webrtc (docker compose ps)\n"
    printf "  STT (Wyoming)           : 127.0.0.1:10300  (also reachable as stt:10300 inside voice-net)\n"
    printf "  TTS (Wyoming)           : 127.0.0.1:10200  (also reachable as tts:10200 inside voice-net)\n"
    printf "  WebRTC gateway          : https://%s:8443  (self-signed cert — accept the browser warning)\n" "${ts_ip}"
    printf "  llm-wiki                : %s/llm-wiki/\n" "${TARGET_HOME}"
    printf "\n  Open the Hermes CLI:\n"
    printf "    docker exec -it hermes hermes\n"
    printf "  Voice trigger inside the CLI: Ctrl+B (see ~/.hermes/config.yaml)\n\n"
    printf "  Phone routing           : 770-451-5224 still hits ws-47. ws-48 won't get phone\n"
    printf "                            traffic until the nginx side is updated to route the\n"
    printf "                            number to ws-48 over the tailnet.\n\n"

    # Quick health checks
    if curl -fsS -m 2 "http://127.0.0.1:${VLLM_PORT}/health" >/dev/null 2>&1; then
        log "vLLM /health: OK"
    else
        warn "vLLM not yet responding (cold start ~80-100s); tail journalctl --user -u vllm-tp2"
    fi
    for svc in stt tts hermes webrtc; do
        if sudo docker ps --format '{{.Names}}' | grep -q "^${svc}$"; then
            log "container ${svc}: running"
        else
            warn "container ${svc}: NOT running — check 'sudo docker compose -f ${TARGET_HOME}/jarvis-network/${COMPOSE_FILE_REL} logs ${svc}'"
        fi
    done
}

# ── main ───────────────────────────────────────────────────────────────────
main() {
    preflight
    prompt_secrets
    install_nvidia_driver               # may reboot
    install_docker
    install_nvidia_container_toolkit
    install_tailscale_and_join
    install_apt_deps
    clone_repos
    setup_vllm_host
    install_ollama
    make_webrtc_certs
    docker_login_and_pull
    compose_up
    configure_hermes_cli
    print_summary
}

main "$@"
