#!/usr/bin/env bash
# =============================================================================
# setup.sh — One-command server setup for agent-browser-remote
#
# Usage (on the server):
#   curl -fsSL https://raw.githubusercontent.com/yigitkonur/agent-browser-remote/main/scripts/setup.sh | bash
#
# Or with sudo (required when INSTALL_DIR is under /opt or another root-owned path):
#   curl -fsSL ... | sudo bash
#
# With custom options:
#   curl -fsSL ... | INSTALL_DIR=/opt/agent-browser PORT=3000 sudo bash
#
# What it does:
#   1. Checks Docker is installed
#   2. Creates install directory with docker-compose.yml and .env
#   3. Generates a secure API token
#   4. Pulls the image from GHCR
#   5. Starts the service
# =============================================================================
set -euo pipefail

# ---------- Config ----------
INSTALL_DIR="${INSTALL_DIR:-/opt/agent-browser}"
PORT="${PORT:-3000}"
IMAGE="ghcr.io/yigitkonur/agent-browser-remote:latest"

# Detect the real user when running under sudo
REAL_USER="${SUDO_USER:-$(whoami)}"

# ---------- Helpers ----------
info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
err()   { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; }
die()   { err "$@"; exit 1; }

# ---------- Preflight ----------
info "agent-browser-remote setup"
echo ""

# Check Docker
if ! command -v docker >/dev/null 2>&1; then
  die "Docker is not installed. Install it first: https://docs.docker.com/engine/install/"
fi

# Check docker compose
if ! docker compose version >/dev/null 2>&1; then
  die "Docker Compose v2 is required. Update Docker: https://docs.docker.com/compose/install/"
fi

# ---------- Create directory ----------
info "Creating $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"

# If running as root (via sudo), chown the directory to the real user
# so they can edit .env and docker-compose.yml without sudo later
if [ "$(id -u)" = "0" ] && [ "$REAL_USER" != "root" ]; then
  chown "$REAL_USER" "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"

# ---------- Generate .env ----------
if [ -f .env ]; then
  info "Existing .env found, keeping it"
else
  info "Generating API token..."
  API_TOKEN=$(openssl rand -hex 32)
  cat > .env <<ENV
API_TOKEN=$API_TOKEN
MAX_SESSIONS=10
STATE_EXPIRE_DAYS=30
ENV

  # Make .env owned by the real user
  if [ "$(id -u)" = "0" ] && [ "$REAL_USER" != "root" ]; then
    chown "$REAL_USER" .env
  fi

  ok "API token generated: $API_TOKEN"
  echo "  (save this — you'll need it to connect)"
fi

# ---------- Write docker-compose.yml ----------
info "Writing docker-compose.yml..."
cat > docker-compose.yml <<COMPOSE
services:
  agent-browser:
    image: $IMAGE
    container_name: agent-browser
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT}:3000"
    environment:
      API_TOKEN: \${API_TOKEN}
      AGENT_BROWSER_ENCRYPTION_KEY: \${AGENT_BROWSER_ENCRYPTION_KEY:-}
      AGENT_BROWSER_SOCKET_DIR: /data/sockets
      AGENT_BROWSER_ARGS: "--no-sandbox,--disable-dev-shm-usage,--disable-setuid-sandbox,--disable-gpu"
      AGENT_BROWSER_STATE_EXPIRE_DAYS: \${STATE_EXPIRE_DAYS:-30}
      MAX_SESSIONS: \${MAX_SESSIONS:-10}
      NODE_ENV: production
    volumes:
      - ab_data:/data
    shm_size: "2gb"
    deploy:
      resources:
        limits:
          memory: 4G
          cpus: "2.0"
        reservations:
          memory: 512M
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL

volumes:
  ab_data:
COMPOSE

# Make docker-compose.yml owned by the real user
if [ "$(id -u)" = "0" ] && [ "$REAL_USER" != "root" ]; then
  chown "$REAL_USER" docker-compose.yml
fi

# ---------- Pull and start ----------
info "Pulling Docker image..."
docker pull "$IMAGE"

info "Starting service..."
docker compose up -d

echo ""
ok "agent-browser-remote is running!"
echo ""
echo "  Port:  $PORT (localhost only)"
echo "  Dir:   $INSTALL_DIR"
echo "  Token: $(grep API_TOKEN .env | head -1 | cut -d= -f2)"
echo ""
echo "Connect from your machine:"
echo "  ssh -N -L ${PORT}:localhost:${PORT} user@your-server"
echo ""
echo "Test:"
echo "  curl http://localhost:${PORT}/health"
