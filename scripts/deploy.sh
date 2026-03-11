#!/usr/bin/env bash
# Deploy agent-browser-remote to the remote server.
# Usage: ./scripts/deploy.sh
set -euo pipefail

SERVER="${DEPLOY_SERVER:?Set DEPLOY_SERVER env var (e.g. DEPLOY_SERVER=user@your-server)}"
REMOTE_DIR="${DEPLOY_DIR:-/opt/agent-browser}"
LOCAL_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== agent-browser-remote deploy ==="
echo "Server:     $SERVER"
echo "Remote dir: $REMOTE_DIR"
echo ""

# 1. Build API server TypeScript
echo "[1/5] Building API server..."
cd "$LOCAL_DIR/api-server"
npm run build
cd "$LOCAL_DIR"

# 2. Build Docker image for linux/amd64 (cross-build from Apple Silicon)
echo "[2/5] Building Docker image for linux/amd64..."
docker buildx build \
  --platform linux/amd64 \
  --tag agent-browser-api:latest \
  --load \
  "$LOCAL_DIR"

# 3. Export and transfer image to server
echo "[3/5] Transferring image to server (~800MB compressed)..."
docker save agent-browser-api:latest | gzip | \
  ssh "$SERVER" "gunzip | sudo docker load"

# 4. Ensure remote directory and sync config files
echo "[4/5] Syncing configuration..."
ssh "$SERVER" "sudo mkdir -p $REMOTE_DIR && sudo chown \$(whoami) $REMOTE_DIR"
rsync -avz \
  "$LOCAL_DIR/docker-compose.yml" \
  "$SERVER:$REMOTE_DIR/"

# Copy .env if it doesn't exist on remote (don't overwrite existing)
ssh "$SERVER" "test -f $REMOTE_DIR/.env || echo 'API_TOKEN=' > $REMOTE_DIR/.env"
echo "  [!] Edit $REMOTE_DIR/.env on the server to set API_TOKEN"

# 5. Restart service
echo "[5/5] Starting service..."
ssh "$SERVER" "cd $REMOTE_DIR && sudo docker compose up -d --no-build"

echo ""
echo "=== Done ==="
echo "Service running at $SERVER (port 3000, localhost-bound)"
echo ""
echo "Connect via SSH tunnel:"
echo "  ssh -N -L 3000:localhost:3000 $SERVER"
echo ""
echo "Then test:"
echo "  curl http://localhost:3000/health"
