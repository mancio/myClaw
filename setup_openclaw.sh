#!/usr/bin/env bash
#
# setup_openclaw.sh — One-click OpenClaw setup for Ubuntu (Hyper-V guest)
#
# Automates steps 4-14 from open_claw_hyper_v_ubuntu_setup_readme.md
#
# Usage:
#   chmod +x setup_openclaw.sh
#   sudo ./setup_openclaw.sh            # uses defaults
#   sudo ./setup_openclaw.sh --repo-url https://github.com/org/openclaw.git
#
# The script is idempotent — safe to re-run if something fails midway.

set -euo pipefail

# ── Configuration (override via environment or flags) ──────────────────────────
REPO_URL="${OPENCLAW_REPO_URL:-}"          # Git clone URL for OpenClaw
INSTALL_DIR="${OPENCLAW_INSTALL_DIR:-/opt/openclaw}"
DATA_DIR="${OPENCLAW_DATA_DIR:-$HOME/.openclaw}"
NGINX_DIR="${OPENCLAW_NGINX_DIR:-$HOME/openclaw-nginx}"
NGINX_PORT="${OPENCLAW_NGINX_PORT:-8080}"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
TARGET_USER="${SUDO_USER:-$USER}"          # the real (non-root) user

# ── Parse CLI arguments ───────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        --repo-url)  REPO_URL="$2"; shift 2 ;;
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        --data-dir) DATA_DIR="$2"; shift 2 ;;
        --nginx-port) NGINX_PORT="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: sudo $0 [--repo-url URL] [--install-dir DIR] [--data-dir DIR] [--nginx-port PORT]"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'
step()  { echo -e "\n${CYAN}>> $1${NC}"; }
ok()    { echo -e "   ${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "   ${YELLOW}[WARN]${NC} $1"; }
fail()  { echo -e "   ${RED}[FAIL]${NC} $1"; exit 1; }

# ── Pre-flight ─────────────────────────────────────────────────────────────────
step "Pre-flight checks"

if [[ $EUID -ne 0 ]]; then
    fail "This script must be run with sudo / as root."
fi

if [[ -z "$REPO_URL" ]]; then
    fail "OpenClaw repository URL is required.\n   Set OPENCLAW_REPO_URL or pass --repo-url <URL>"
fi

VM_IP=$(hostname -I | awk '{print $1}')
ok "VM IP detected: $VM_IP"
ok "Target user: $TARGET_USER"

# ── Step 1: System update ─────────────────────────────────────────────────────
step "Step 1/9 — Updating system packages"
apt-get update -qq
apt-get upgrade -y -qq
ok "System updated"

# ── Step 2: Install Docker & Docker Compose ───────────────────────────────────
step "Step 2/9 — Installing Docker & Docker Compose"

if command -v docker &>/dev/null; then
    ok "Docker already installed: $(docker --version)"
else
    apt-get install -y -qq docker.io docker-compose-plugin
    ok "Docker installed"
fi

# Add target user to docker group (idempotent)
usermod -aG docker "$TARGET_USER" 2>/dev/null || true
ok "User '$TARGET_USER' added to docker group"

# Ensure Docker is running
systemctl enable --now docker
ok "Docker service running"

DOCKER_COMPOSE="docker compose"
if ! $DOCKER_COMPOSE version &>/dev/null; then
    # Fallback to standalone docker-compose
    if command -v docker-compose &>/dev/null; then
        DOCKER_COMPOSE="docker-compose"
    else
        fail "docker compose plugin not found"
    fi
fi
ok "Compose: $($DOCKER_COMPOSE version 2>/dev/null | head -1)"

# ── Step 3: Clone OpenClaw ────────────────────────────────────────────────────
step "Step 3/9 — Cloning OpenClaw repository"

if [[ -d "$INSTALL_DIR/.git" ]]; then
    ok "Repository already cloned at $INSTALL_DIR — pulling latest"
    git -C "$INSTALL_DIR" pull --ff-only || warn "Pull failed; using existing code"
else
    git clone "$REPO_URL" "$INSTALL_DIR"
    ok "Cloned to $INSTALL_DIR"
fi
chown -R "$TARGET_USER":"$TARGET_USER" "$INSTALL_DIR"

# ── Step 4: Create data directories ──────────────────────────────────────────
step "Step 4/9 — Creating data directories"

mkdir -p "$DATA_DIR/config" "$DATA_DIR/workspace"
chmod -R 777 "$DATA_DIR"
chown -R "$TARGET_USER":"$TARGET_USER" "$DATA_DIR"
ok "$DATA_DIR/config"
ok "$DATA_DIR/workspace"

# ── Step 5: Generate token & .env ─────────────────────────────────────────────
step "Step 5/9 — Generating gateway token & .env file"

ENV_FILE="$INSTALL_DIR/.env"

if [[ -f "$ENV_FILE" ]]; then
    # Preserve existing token
    GATEWAY_TOKEN=$(grep -oP 'OPENCLAW_GATEWAY_TOKEN=\K.*' "$ENV_FILE" || true)
    if [[ -z "$GATEWAY_TOKEN" ]]; then
        GATEWAY_TOKEN=$(openssl rand -hex 32)
    fi
    warn ".env already exists — preserving existing values"
else
    GATEWAY_TOKEN=$(openssl rand -hex 32)
fi

TARGET_HOME=$(eval echo "~$TARGET_USER")

cat > "$ENV_FILE" <<EOF
OPENCLAW_CONFIG_DIR=${DATA_DIR}/config
OPENCLAW_WORKSPACE_DIR=${DATA_DIR}/workspace
OPENCLAW_GATEWAY_TOKEN=${GATEWAY_TOKEN}
EOF

chown "$TARGET_USER":"$TARGET_USER" "$ENV_FILE"
chmod 600 "$ENV_FILE"
ok ".env written (token: ${GATEWAY_TOKEN:0:8}...)"

# ── Step 6: Build & start OpenClaw ────────────────────────────────────────────
step "Step 6/9 — Building & starting OpenClaw containers"

cd "$INSTALL_DIR"
sudo -u "$TARGET_USER" $DOCKER_COMPOSE up -d --build 2>&1 | tail -5
ok "Containers started"

# Wait a moment for gateway to initialise
echo "   Waiting 10s for gateway to initialise..."
sleep 10

# ── Step 7: Run config wizard (non-interactive) ──────────────────────────────
step "Step 7/9 — Configuring gateway (local mode)"

# Try running config set; if the CLI container doesn't exist, skip gracefully
if $DOCKER_COMPOSE run --rm openclaw-cli config set gateway.mode local 2>/dev/null; then
    ok "gateway.mode = local"
else
    warn "Could not set gateway.mode automatically — you may need to run:"
    echo "   cd $INSTALL_DIR && docker compose run --rm openclaw-cli config"
fi

# Set allowed origins for Control UI
ORIGINS="[\"http://127.0.0.1:${GATEWAY_PORT}\",\"http://${VM_IP}:${GATEWAY_PORT}\",\"http://${VM_IP}:${NGINX_PORT}\"]"
if $DOCKER_COMPOSE run --rm openclaw-cli config set gateway.controlUi.allowedOrigins "$ORIGINS" 2>/dev/null; then
    ok "allowedOrigins set for $VM_IP"
else
    warn "Could not set allowedOrigins automatically"
fi

# Restart to apply config
$DOCKER_COMPOSE restart 2>&1 | tail -3
sleep 5
ok "Gateway restarted"

# ── Step 8: Setup Nginx reverse proxy ─────────────────────────────────────────
step "Step 8/9 — Setting up Nginx reverse proxy (token auto-injection)"

mkdir -p "$NGINX_DIR"

cat > "$NGINX_DIR/nginx.conf" <<NGINX_EOF
events {}

http {
    server {
        listen ${NGINX_PORT};

        location / {
            proxy_pass         http://${VM_IP}:${GATEWAY_PORT};
            proxy_set_header   Host \$host;
            proxy_set_header   Authorization "Bearer ${GATEWAY_TOKEN}";
            proxy_set_header   Upgrade \$http_upgrade;
            proxy_set_header   Connection "upgrade";
            proxy_http_version 1.1;
        }
    }
}
NGINX_EOF

chown -R "$TARGET_USER":"$TARGET_USER" "$NGINX_DIR"

# Remove old nginx container if running
docker rm -f openclaw-nginx 2>/dev/null || true

docker run -d \
    --name openclaw-nginx \
    --restart unless-stopped \
    -p "${NGINX_PORT}:${NGINX_PORT}" \
    -v "$NGINX_DIR/nginx.conf:/etc/nginx/nginx.conf:ro" \
    nginx:stable-alpine

ok "Nginx proxy running on port $NGINX_PORT"

# ── Step 9: Verification ──────────────────────────────────────────────────────
step "Step 9/9 — Verifying installation"

PASS=true

# Check containers
if docker ps --format '{{.Names}}' | grep -q openclaw; then
    ok "OpenClaw containers running"
else
    warn "OpenClaw containers not detected — check 'docker ps'"
    PASS=false
fi

if docker ps --format '{{.Names}}' | grep -q openclaw-nginx; then
    ok "Nginx proxy running"
else
    warn "Nginx container not running"
    PASS=false
fi

# Test gateway via nginx (with token auto-injection)
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${NGINX_PORT}/__openclaw__/canvas/" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "304" ]]; then
    ok "Canvas UI accessible (HTTP $HTTP_CODE)"
else
    warn "Canvas UI returned HTTP $HTTP_CODE — gateway may still be starting"
    PASS=false
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}============================================${NC}"
echo -e "${YELLOW} OpenClaw Setup Complete!                   ${NC}"
echo -e "${YELLOW}============================================${NC}"
echo ""
echo -e " VM IP:           ${GREEN}${VM_IP}${NC}"
echo -e " Install dir:     ${INSTALL_DIR}"
echo -e " Data dir:        ${DATA_DIR}"
echo -e " Gateway port:    ${GATEWAY_PORT}"
echo -e " Nginx port:      ${NGINX_PORT}"
echo -e " Gateway token:   ${GATEWAY_TOKEN:0:8}... (see ${ENV_FILE})"
echo ""
echo -e " ${GREEN}Canvas UI:${NC}  http://${VM_IP}:${NGINX_PORT}/__openclaw__/canvas/"
echo ""

if [[ "$PASS" == "false" ]]; then
    echo -e " ${YELLOW}Some checks did not pass. Review warnings above.${NC}"
    echo -e " Useful commands:"
    echo "   docker ps"
    echo "   docker logs <container>"
    echo "   cd $INSTALL_DIR && docker compose logs -f"
fi

echo -e " ${CYAN}To test the agent:${NC}"
echo "   cd $INSTALL_DIR && docker compose run --rm openclaw-cli agent \"Create hello.txt with content: Hello from OpenClaw\""
echo ""
