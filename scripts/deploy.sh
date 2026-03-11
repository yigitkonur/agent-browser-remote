#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Deploy agent-browser-remote to a remote server
#
# Usage:
#   DEPLOY_SERVER=user@host ./scripts/deploy.sh          # deploy via GHCR pull
#   DEPLOY_SERVER=user@host DEPLOY_MODE=build ./scripts/deploy.sh  # build + transfer
#
# Environment:
#   DEPLOY_SERVER  (required)  SSH target, e.g. user@your-server
#   DEPLOY_DIR     (optional)  Remote install dir (default: /opt/agent-browser)
#   DEPLOY_MODE    (optional)  "pull" (default) or "build"
#     pull  — docker pull from ghcr.io (fast, ~30s)
#     build — local docker build + docker save/load transfer (~5min)
#   DEPLOY_PORT    (optional)  Host port to bind (default: 3000)
# =============================================================================
set -euo pipefail

# ---------- Config ----------
SERVER="${DEPLOY_SERVER:?Error: set DEPLOY_SERVER, e.g. DEPLOY_SERVER=user@your-server}"
REMOTE_DIR="${DEPLOY_DIR:-/opt/agent-browser}"
MODE="${DEPLOY_MODE:-pull}"
HOST_PORT="${DEPLOY_PORT:-3000}"
LOCAL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="ghcr.io/yigitkonur/agent-browser-remote:latest"
LOCAL_TAG="agent-browser-remote:local-build"

# ---------- Helpers ----------
info()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()    { printf '\033[1;32m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
err()   { printf '\033[1;31m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()   { err "$@"; exit 1; }

# ---------- Preflight checks ----------
command -v ssh  >/dev/null 2>&1 || die "ssh not found"
command -v docker >/dev/null 2>&1 || die "docker not found"

info "=== agent-browser-remote deploy ==="
info "Server:  $SERVER"
info "Dir:     $REMOTE_DIR"
info "Mode:    $MODE"
info "Port:    $HOST_PORT"
echo ""

# ---------- Step 1: Build TypeScript ----------
if [ "$MODE" = "build" ]; then
  info "[1/5] Building API server TypeScript..."
  (cd "$LOCAL_DIR/api-server" && npm ci && npm run build)
else
  info "[1/3] Skipping local build (pull mode)"
fi

# ---------- Step 2: Get image to server ----------
if [ "$MODE" = "build" ]; then
  info "[2/5] Building Docker image for linux/amd64..."
  docker buildx build \
    --platform linux/amd64 \
    --tag "$LOCAL_TAG" \
    --load \
    "$LOCAL_DIR"

  info "[3/5] Transferring image to server..."
  docker save "$LOCAL_TAG" | gzip | ssh "$SERVER" "gunzip | sudo docker load"
  # Re-tag on server so compose can find it
  ssh "$SERVER" "sudo docker tag $LOCAL_TAG $IMAGE"
else
  info "[2/3] Pulling image on server from GHCR..."
  ssh "$SERVER" "sudo docker pull $IMAGE"
fi

# ---------- Step 3: Sync configuration ----------
STEP_SYNC="3/3"
STEP_START="3/3"
if [ "$MODE" = "build" ]; then
  STEP_SYNC="4/5"
  STEP_START="5/5"
fi

info "[$STEP_SYNC] Syncing configuration..."
ssh "$SERVER" "sudo mkdir -p $REMOTE_DIR && sudo chown \$(whoami) $REMOTE_DIR"

# Generate docker-compose.yml with the correct port on the fly
cat > /tmp/agent-browser-compose.yml <<COMPOSE
services:
  agent-browser:
    image: $IMAGE
    container_name: agent-browser
    restart: unless-stopped
    ports:
      - "127.0.0.1:${HOST_PORT}:3000"
    environment:
      API_TOKEN: \${API_TOKEN}
      AGENT_BROWSER_ENCRYPTION_KEY: \${AGENT_BROWSER_ENCRYPTION_KEY:-}
      AGENT_BROWSER_SOCKET_DIR: /data/sockets
      AGENT_BROWSER_ARGS: "--no-sandbox,--disable-dev-shm-usage,--disable-setuid-sandbox,--disable-gpu"
      AGENT_BROWSER_STATE_EXPIRE_DAYS: \${STATE_EXPIRE_DAYS:-30}
      MAX_SESSIONS: \${MAX_SESSIONS:-10}
      LIGHTPANDA_PATH: \${LIGHTPANDA_PATH:-/usr/local/bin/lightpanda}
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

scp /tmp/agent-browser-compose.yml "$SERVER:$REMOTE_DIR/docker-compose.yml"
rm -f /tmp/agent-browser-compose.yml

# Create .env if it doesn't exist on remote
ssh "$SERVER" "test -f $REMOTE_DIR/.env || { TOKEN=\$(openssl rand -hex 32); printf 'API_TOKEN=%s\nMAX_SESSIONS=10\nSTATE_EXPIRE_DAYS=30\n' \"\$TOKEN\" > $REMOTE_DIR/.env; echo \"Generated new API token: \$TOKEN\"; }"

# ---------- Step 4: Start service ----------
info "[$STEP_START] Starting service..."
ssh "$SERVER" "cd $REMOTE_DIR && sudo docker compose up -d --pull never"

ok ""
ok "=== Deploy complete ==="
ok "Service running on $SERVER (port $HOST_PORT, localhost-bound)"
ok ""
ok "Next steps:"
ok "  1. Note the API token: ssh $SERVER 'cat $REMOTE_DIR/.env'"
ok "  2. Open SSH tunnel:    ssh -N -L ${HOST_PORT}:localhost:${HOST_PORT} $SERVER"
ok "  3. Test:               curl http://localhost:${HOST_PORT}/health"
