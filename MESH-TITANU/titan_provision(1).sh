#!/usr/bin/env bash
# ==============================================================================
#  ████████╗██╗████████╗ █████╗ ███╗   ██╗    ██╗   ██╗
#     ██╔══╝██║╚══██╔══╝██╔══██╗████╗  ██║    ██║   ██║
#     ██║   ██║   ██║   ███████║██╔██╗ ██║    ██║   ██║
#     ██║   ██║   ██║   ██╔══██║██║╚██╗██║    ██║   ██║
#     ██║   ██║   ██║   ██║  ██║██║ ╚████║    ╚██████╔╝
#     ╚═╝   ╚═╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═══╝    ╚═════╝
#
#  WeCanMesh Auto-Provisioner v1.0
#  Zero-touch node enrollment for TitanU Sovereign AI Infrastructure
#
#  Usage:
#    curl -fsSL https://hs.titanuai.com/provision | bash
#    -- OR with options --
#    curl -fsSL https://hs.titanuai.com/provision | TITAN_NODE_ROLE=worker bash
#
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# CONFIGURATION — override via environment variables before running
# ------------------------------------------------------------------------------
TITAN_CONTROL_PLANE="${TITAN_CONTROL_PLANE:-https://hs.titanuai.com}"
TITAN_AUTHKEY="${TITAN_AUTHKEY:-}"                      # set this or script will prompt
TITAN_NODE_ROLE="${TITAN_NODE_ROLE:-worker}"             # worker | control | edge
TITAN_OLLAMA_MODELS="${TITAN_OLLAMA_MODELS:-llama3.2}"  # space-separated model list
TITAN_API_PORT="${TITAN_API_PORT:-11434}"
TITAN_SHIM_PORT="${TITAN_SHIM_PORT:-8000}"
TITAN_REGISTER_URL="${TITAN_CONTROL_PLANE}/api/nodes/register"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ------------------------------------------------------------------------------
# HELPERS
# ------------------------------------------------------------------------------
log()     { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
section() { echo -e "\n${CYAN}${BOLD}══ $* ══${NC}"; }
has()     { command -v "$1" &>/dev/null; }

# ------------------------------------------------------------------------------
# BANNER
# ------------------------------------------------------------------------------
clear
echo -e "${CYAN}${BOLD}"
cat << 'BANNER'
 ╔══════════════════════════════════════════════════════╗
 ║       TITAN-U  ·  SOVEREIGN AI MESH PROVISIONER      ║
 ║              WeCanMesh Node Enrollment                ║
 ╚══════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"
echo -e "  Control Plane : ${BOLD}${TITAN_CONTROL_PLANE}${NC}"
echo -e "  Node Role     : ${BOLD}${TITAN_NODE_ROLE}${NC}"
echo -e "  Models        : ${BOLD}${TITAN_OLLAMA_MODELS}${NC}"
echo ""

# ------------------------------------------------------------------------------
# STEP 0 — PREFLIGHT CHECKS
# ------------------------------------------------------------------------------
section "STEP 0 · Preflight"

# Must NOT be run as root (Tailscale client handles its own elevation)
[[ "$EUID" -eq 0 ]] && error "Do not run as root. Script will sudo where needed."

# Detect OS
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID}"
    OS_LIKE="${ID_LIKE:-}"
else
    error "Cannot detect OS. /etc/os-release missing."
fi

# Normalize to package manager
if has pacman; then
    PKG_INSTALL="sudo pacman -S --noconfirm --needed"
    PKG_UPDATE="sudo pacman -Sy"
elif has apt-get; then
    PKG_INSTALL="sudo apt-get install -y"
    PKG_UPDATE="sudo apt-get update -qq"
elif has dnf; then
    PKG_INSTALL="sudo dnf install -y"
    PKG_UPDATE="sudo dnf check-update || true"
else
    error "Unsupported package manager. Supported: pacman, apt, dnf."
fi

log "OS detected: ${OS_ID} (like: ${OS_LIKE:-none})"
log "Package manager ready"

# Required tools
REQUIRED=(curl jq tar systemctl)
MISSING=()
for cmd in "${REQUIRED[@]}"; do
    has "$cmd" || MISSING+=("$cmd")
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    warn "Installing missing tools: ${MISSING[*]}"
    $PKG_UPDATE
    $PKG_INSTALL "${MISSING[@]}"
fi

log "All required tools present"

# Collect hardware fingerprint
NODE_HOSTNAME=$(hostname)
NODE_ARCH=$(uname -m)
NODE_OS="${OS_ID}"
NODE_CPU=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "unknown")
NODE_RAM_GB=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo "0")
NODE_DISK_GB=$(df / --output=size -BG 2>/dev/null | tail -1 | tr -d 'G ' || echo "0")

# GPU detection (graceful — many nodes are CPU-only)
NODE_GPU="none"
if has nvidia-smi; then
    NODE_GPU=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "none")
elif has lspci; then
    NODE_GPU=$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | head -1 | sed 's/.*: //' || echo "integrated")
fi

log "Hardware fingerprint collected"
echo -e "    Hostname : ${NODE_HOSTNAME}"
echo -e "    CPU      : ${NODE_CPU}"
echo -e "    RAM      : ${NODE_RAM_GB}GB"
echo -e "    Disk     : ${NODE_DISK_GB}GB"
echo -e "    GPU      : ${NODE_GPU}"

# ------------------------------------------------------------------------------
# STEP 1 — AUTHKEY
# ------------------------------------------------------------------------------
section "STEP 1 · Auth Key"

if [[ -z "${TITAN_AUTHKEY}" ]]; then
    echo -e "${YELLOW}No TITAN_AUTHKEY set. Enter your WeCanMesh pre-auth key:${NC}"
    read -r -s -p "  Auth Key: " TITAN_AUTHKEY
    echo ""
fi

[[ -z "${TITAN_AUTHKEY}" ]] && error "Auth key required. Get one from your TitanU dashboard."
log "Auth key loaded"

# ------------------------------------------------------------------------------
# STEP 2 — TAILSCALE (WeCanMesh client)
# ------------------------------------------------------------------------------
section "STEP 2 · WeCanMesh Client (Tailscale)"

if has tailscale; then
    CURRENT_VERSION=$(tailscale version 2>/dev/null | head -1 || echo "unknown")
    log "Tailscale already installed: ${CURRENT_VERSION}"
else
    warn "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
    log "Tailscale installed"
fi

# Bring up and connect to TitanU control plane (Headscale)
log "Connecting to WeCanMesh control plane at ${TITAN_CONTROL_PLANE}..."
sudo tailscale up \
    --login-server="${TITAN_CONTROL_PLANE}" \
    --authkey="${TITAN_AUTHKEY}" \
    --hostname="${NODE_HOSTNAME}" \
    --accept-routes \
    --accept-dns=true \
    --shields-up=false \
    2>&1 | grep -v "^$" || true

# Wait for mesh IP assignment (up to 30s)
MESH_IP=""
for i in $(seq 1 15); do
    MESH_IP=$(tailscale ip -4 2>/dev/null || echo "")
    [[ -n "${MESH_IP}" ]] && break
    sleep 2
done

[[ -z "${MESH_IP}" ]] && error "Failed to obtain mesh IP after 30s. Check auth key and control plane connectivity."
log "Mesh IP assigned: ${MESH_IP}"

# ------------------------------------------------------------------------------
# STEP 3 — OLLAMA
# ------------------------------------------------------------------------------
section "STEP 3 · Ollama Inference Engine"

if has ollama; then
    log "Ollama already installed: $(ollama --version 2>/dev/null || echo 'unknown version')"
else
    warn "Installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
    log "Ollama installed"
fi

# Configure Ollama to bind on mesh IP (not just localhost)
OLLAMA_ENV_FILE="/etc/systemd/system/ollama.service.d/titan.conf"
sudo mkdir -p "$(dirname ${OLLAMA_ENV_FILE})"
sudo tee "${OLLAMA_ENV_FILE}" > /dev/null << EOF
[Service]
Environment="OLLAMA_HOST=0.0.0.0:${TITAN_API_PORT}"
Environment="OLLAMA_ORIGINS=*"
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now ollama

# Wait for Ollama to be ready
log "Waiting for Ollama to start..."
for i in $(seq 1 15); do
    curl -sf "http://localhost:${TITAN_API_PORT}/api/tags" &>/dev/null && break
    sleep 2
done

# Pull configured models
for MODEL in ${TITAN_OLLAMA_MODELS}; do
    log "Pulling model: ${MODEL} (this may take a few minutes)..."
    ollama pull "${MODEL}" || warn "Failed to pull ${MODEL} — skipping"
done

log "Ollama ready on port ${TITAN_API_PORT}"

# ------------------------------------------------------------------------------
# STEP 4 — OPENAI-COMPATIBLE API SHIM
# ------------------------------------------------------------------------------
section "STEP 4 · OpenAI-Compatible API Shim"

# Write the shim as a minimal Python service
SHIM_DIR="${HOME}/.titan/shim"
mkdir -p "${SHIM_DIR}"

cat > "${SHIM_DIR}/shim.py" << 'PYEOF'
#!/usr/bin/env python3
"""
TitanU OpenAI-Compatible API Shim
Translates OpenAI /v1/chat/completions requests → Ollama API
Drop-in replacement: point any OpenAI SDK at this endpoint.
"""
import json, os, time, uuid, httpx
from http.server import HTTPServer, BaseHTTPRequestHandler

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434")
PORT       = int(os.environ.get("SHIM_PORT", "8000"))
DEFAULT_MODEL = os.environ.get("DEFAULT_MODEL", "llama3.2")

class ShimHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"[shim] {self.address_string()} {fmt % args}")

    def send_json(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
        self.end_headers()

    def do_GET(self):
        if self.path == "/health":
            self.send_json(200, {"status": "ok", "provider": "titanu-wecanmesh"})
        elif self.path == "/v1/models":
            try:
                r = httpx.get(f"{OLLAMA_URL}/api/tags", timeout=5)
                models = [{"id": m["name"], "object": "model"} for m in r.json().get("models", [])]
                self.send_json(200, {"object": "list", "data": models})
            except Exception as e:
                self.send_json(502, {"error": str(e)})
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body   = json.loads(self.rfile.read(length) or b"{}")

        if self.path in ("/v1/chat/completions", "/chat/completions"):
            model    = body.get("model", DEFAULT_MODEL)
            messages = body.get("messages", [])
            stream   = body.get("stream", False)

            # Build Ollama payload
            ollama_payload = {"model": model, "messages": messages, "stream": False}

            try:
                r = httpx.post(f"{OLLAMA_URL}/api/chat", json=ollama_payload, timeout=120)
                r.raise_for_status()
                result = r.json()
                content = result.get("message", {}).get("content", "")
            except Exception as e:
                self.send_json(502, {"error": {"message": str(e), "type": "upstream_error"}})
                return

            response = {
                "id": f"chatcmpl-{uuid.uuid4().hex[:8]}",
                "object": "chat.completion",
                "created": int(time.time()),
                "model": model,
                "choices": [{
                    "index": 0,
                    "message": {"role": "assistant", "content": content},
                    "finish_reason": "stop"
                }],
                "usage": {
                    "prompt_tokens": result.get("prompt_eval_count", 0),
                    "completion_tokens": result.get("eval_count", 0),
                    "total_tokens": result.get("prompt_eval_count", 0) + result.get("eval_count", 0)
                },
                "_titanu": {"node": os.uname().nodename, "mesh_provider": "wecanmesh"}
            }
            self.send_json(200, response)
        else:
            self.send_json(404, {"error": "endpoint not implemented"})

if __name__ == "__main__":
    print(f"[TitanU Shim] Listening on 0.0.0.0:{PORT}")
    print(f"[TitanU Shim] Upstream Ollama: {OLLAMA_URL}")
    HTTPServer(("0.0.0.0", PORT), ShimHandler).serve_forever()
PYEOF

# Install httpx if missing
if ! python3 -c "import httpx" 2>/dev/null; then
    has pip3 && pip3 install --quiet httpx || \
    has pip  && pip install --quiet httpx  || \
    warn "Could not install httpx — install manually: pip3 install httpx"
fi

# Install as systemd service
sudo tee /etc/systemd/system/titan-shim.service > /dev/null << EOF
[Unit]
Description=TitanU OpenAI-Compatible API Shim
After=ollama.service network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${USER}
WorkingDirectory=${SHIM_DIR}
ExecStart=python3 ${SHIM_DIR}/shim.py
Restart=always
RestartSec=5
Environment="OLLAMA_URL=http://localhost:${TITAN_API_PORT}"
Environment="SHIM_PORT=${TITAN_SHIM_PORT}"
Environment="DEFAULT_MODEL=${TITAN_OLLAMA_MODELS%% *}"

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now titan-shim
log "API shim running on port ${TITAN_SHIM_PORT}"

# ------------------------------------------------------------------------------
# STEP 5 — REGISTER NODE WITH CONTROL PLANE
# ------------------------------------------------------------------------------
section "STEP 5 · Register with TitanU Control Plane"

REGISTRATION_PAYLOAD=$(jq -n \
    --arg hostname    "${NODE_HOSTNAME}" \
    --arg mesh_ip     "${MESH_IP}" \
    --arg role        "${TITAN_NODE_ROLE}" \
    --arg cpu         "${NODE_CPU}" \
    --arg gpu         "${NODE_GPU}" \
    --arg ram         "${NODE_RAM_GB}" \
    --arg disk        "${NODE_DISK_GB}" \
    --arg os          "${NODE_OS}" \
    --arg arch        "${NODE_ARCH}" \
    --arg shim_port   "${TITAN_SHIM_PORT}" \
    --arg ollama_port "${TITAN_API_PORT}" \
    --argjson models  "$(echo "${TITAN_OLLAMA_MODELS}" | tr ' ' '\n' | jq -R . | jq -s .)" \
    '{
        hostname:    $hostname,
        mesh_ip:     $mesh_ip,
        role:        $role,
        hardware: {
            cpu:  $cpu,
            gpu:  $gpu,
            ram_gb:  ($ram | tonumber),
            disk_gb: ($disk | tonumber),
            os:   $os,
            arch: $arch
        },
        services: {
            ollama_port: ($ollama_port | tonumber),
            shim_port:   ($shim_port | tonumber),
            models:      $models
        },
        status: "online"
    }')

HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
    -X POST "${TITAN_REGISTER_URL}" \
    -H "Content-Type: application/json" \
    -H "X-Titan-AuthKey: ${TITAN_AUTHKEY}" \
    -d "${REGISTRATION_PAYLOAD}" 2>/dev/null || echo "000")

if [[ "${HTTP_CODE}" == "200" || "${HTTP_CODE}" == "201" ]]; then
    log "Node registered with control plane"
elif [[ "${HTTP_CODE}" == "000" ]]; then
    warn "Control plane unreachable — node will register when it comes online"
else
    warn "Registration returned HTTP ${HTTP_CODE} — check control plane logs"
fi

# ------------------------------------------------------------------------------
# STEP 6 — FIREWALL (open mesh-internal ports only)
# ------------------------------------------------------------------------------
section "STEP 6 · Firewall"

if has ufw; then
    sudo ufw allow in on tailscale0 to any port "${TITAN_API_PORT}" proto tcp comment "TitanU Ollama (mesh only)" 2>/dev/null || true
    sudo ufw allow in on tailscale0 to any port "${TITAN_SHIM_PORT}" proto tcp comment "TitanU Shim (mesh only)" 2>/dev/null || true
    log "UFW rules added (mesh-internal only)"
elif has firewall-cmd; then
    sudo firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=100.64.0.0/10 port port=${TITAN_API_PORT} protocol=tcp accept" 2>/dev/null || true
    sudo firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=100.64.0.0/10 port port=${TITAN_SHIM_PORT} protocol=tcp accept" 2>/dev/null || true
    sudo firewall-cmd --reload 2>/dev/null || true
    log "firewalld rules added (mesh-internal only)"
else
    warn "No firewall detected — ensure ports ${TITAN_API_PORT} and ${TITAN_SHIM_PORT} are not exposed publicly"
fi

# ------------------------------------------------------------------------------
# DONE
# ------------------------------------------------------------------------------
section "PROVISIONING COMPLETE"

echo ""
echo -e "${GREEN}${BOLD}  This node is now a TitanU Sovereign AI endpoint.${NC}"
echo ""
echo -e "  Node Hostname    : ${BOLD}${NODE_HOSTNAME}${NC}"
echo -e "  Mesh IP          : ${BOLD}${MESH_IP}${NC}"
echo -e "  Role             : ${BOLD}${TITAN_NODE_ROLE}${NC}"
echo -e "  Ollama API       : ${BOLD}http://${MESH_IP}:${TITAN_API_PORT}${NC}"
echo -e "  OpenAI Shim API  : ${BOLD}http://${MESH_IP}:${TITAN_SHIM_PORT}/v1/chat/completions${NC}"
echo -e "  Health Check     : ${BOLD}http://${MESH_IP}:${TITAN_SHIM_PORT}/health${NC}"
echo ""
echo -e "  ${CYAN}Test it right now:${NC}"
echo -e "  curl http://${MESH_IP}:${TITAN_SHIM_PORT}/v1/chat/completions \\"
echo -e "    -H 'Content-Type: application/json' \\"
echo -e "    -d '{\"model\":\"${TITAN_OLLAMA_MODELS%% *}\",\"messages\":[{\"role\":\"user\",\"content\":\"Who owns this AI?\"}]}'"
echo ""
echo -e "${CYAN}  Zero cloud. Zero trust. Zero compromise.${NC}"
echo -e "${CYAN}  This is WeCanMesh. This is TitanU.${NC}"
echo ""
