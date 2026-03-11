#!/usr/bin/env bash
# =============================================================================
# client-setup.sh — One-liner client setup for agent-browser-remote
#
# Run this on your local machine AFTER the server is set up (via setup.sh).
# It fetches the token from the remote, sets up SSH tunnel config, configures
# your shell profile, and tests the connection.
#
# Usage:
#   ./scripts/client-setup.sh user@your-server
#
# Or as a one-liner (from repo root):
#   curl -fsSL https://raw.githubusercontent.com/yigitkonur/agent-browser-remote/main/scripts/client-setup.sh | bash -s -- user@your-server
#
# Options:
#   --port <N>     Local port for SSH tunnel (default: auto-detect free port, prefer 3000)
#   --dir <path>   Remote install directory (default: /opt/agent-browser)
#   --shell <path> Shell profile to configure (default: auto-detect ~/.zshrc or ~/.bashrc)
#   --no-profile   Skip shell profile changes (just print export commands)
#   --no-tunnel    Skip SSH tunnel setup (just configure shell profile)
#   --repo <path>  Path to local agent-browser-remote repo (for adding ab-remote to PATH)
# =============================================================================
set -euo pipefail

# ---------- Config ----------
SERVER=""
LOCAL_PORT=""
REMOTE_DIR="/opt/agent-browser"
REMOTE_PORT="3000"
SHELL_PROFILE=""
NO_PROFILE=false
NO_TUNNEL=false
REPO_DIR=""

# ---------- Helpers ----------
info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m==>\033[0m %s\n' "$*"; }
err()   { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; }
die()   { err "$@"; exit 1; }

# ---------- Parse args ----------
while [ $# -gt 0 ]; do
  case "$1" in
    --port)    LOCAL_PORT="$2"; shift 2 ;;
    --dir)     REMOTE_DIR="$2"; shift 2 ;;
    --shell)   SHELL_PROFILE="$2"; shift 2 ;;
    --no-profile) NO_PROFILE=true; shift ;;
    --no-tunnel)  NO_TUNNEL=true; shift ;;
    --repo)    REPO_DIR="$2"; shift 2 ;;
    --help|-h)
      sed -n '2,/^# ====/{ /^# ====/d; s/^# //; s/^#//; p; }' "$0"
      exit 0
      ;;
    -*)        die "Unknown flag: $1. Run with --help for usage." ;;
    *)
      if [ -z "$SERVER" ]; then
        SERVER="$1"; shift
      else
        die "Unexpected argument: $1"
      fi
      ;;
  esac
done

[ -n "$SERVER" ] || die "Usage: client-setup.sh user@your-server [--port N] [--dir /path]
Run with --help for all options."

# ---------- Preflight ----------
info "agent-browser-remote client setup"
echo ""

command -v ssh  >/dev/null 2>&1 || die "ssh is required but not found"
command -v curl >/dev/null 2>&1 || die "curl is required but not found"

# ---------- Step 1: Fetch token from remote ----------
info "Fetching API token from $SERVER..."

TOKEN=$(ssh "$SERVER" "cat $REMOTE_DIR/.env 2>/dev/null | grep '^API_TOKEN=' | head -1 | cut -d= -f2" 2>/dev/null) || true

if [ -z "$TOKEN" ]; then
  die "Could not fetch API token from $SERVER:$REMOTE_DIR/.env
  Is the server set up? Run this on the server first:
    curl -fsSL https://raw.githubusercontent.com/yigitkonur/agent-browser-remote/main/scripts/setup.sh | sudo bash"
fi

ok "Got token: ${TOKEN:0:8}...${TOKEN: -8}"

# ---------- Step 2: Detect local port ----------
find_free_port() {
  # Try preferred ports first, then find any free one
  for port in 3000 4100 4200 8100; do
    if ! lsof -i ":$port" >/dev/null 2>&1 && ! ss -ltn "sport = :$port" >/dev/null 2>&1; then
      echo "$port"
      return 0
    fi
  done
  # Last resort: let the OS pick
  python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()" 2>/dev/null || echo "4100"
}

if [ -z "$LOCAL_PORT" ]; then
  LOCAL_PORT=$(find_free_port)
  info "Auto-detected free local port: $LOCAL_PORT"
else
  info "Using specified local port: $LOCAL_PORT"
fi

# ---------- Step 3: Test SSH connectivity ----------
info "Verifying SSH connection to $SERVER..."
if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$SERVER" "echo ok" >/dev/null 2>&1; then
  die "Cannot connect to $SERVER via SSH. Check your SSH config and keys."
fi
ok "SSH connection verified"

# ---------- Step 4: Verify remote service ----------
info "Checking remote service status..."
REMOTE_HEALTH=$(ssh "$SERVER" "curl -s http://localhost:$REMOTE_PORT/health 2>/dev/null") || true

if [ -z "$REMOTE_HEALTH" ]; then
  die "Remote service is not responding on port $REMOTE_PORT.
  Is the container running? Check with:
    ssh $SERVER 'docker ps | grep agent-browser'"
fi

ok "Remote service is healthy: $REMOTE_HEALTH"

# ---------- Step 5: Set up SSH tunnel ----------
if [ "$NO_TUNNEL" = false ]; then
  info "Setting up SSH tunnel (localhost:$LOCAL_PORT → $SERVER:$REMOTE_PORT)..."

  # Kill any existing tunnel to the same port
  if pgrep -f "ssh.*-L.*${LOCAL_PORT}:localhost:${REMOTE_PORT}.*${SERVER}" >/dev/null 2>&1; then
    warn "Killing existing tunnel on port $LOCAL_PORT..."
    pkill -f "ssh.*-L.*${LOCAL_PORT}:localhost:${REMOTE_PORT}.*${SERVER}" 2>/dev/null || true
    sleep 1
  fi

  # Start background tunnel
  ssh -f -N -L "${LOCAL_PORT}:localhost:${REMOTE_PORT}" "$SERVER" \
    -o ServerAliveInterval=60 \
    -o ServerAliveCountMax=3 \
    -o ExitOnForwardFailure=yes

  # Wait and verify
  sleep 1
  if curl -s --max-time 5 "http://localhost:${LOCAL_PORT}/health" >/dev/null 2>&1; then
    ok "Tunnel active: http://localhost:${LOCAL_PORT} → $SERVER"
  else
    warn "Tunnel started but health check failed. It may need a moment to connect."
  fi
fi

# ---------- Step 6: Configure shell profile ----------
URL="http://localhost:${LOCAL_PORT}"

if [ "$NO_PROFILE" = true ]; then
  echo ""
  info "Shell profile update skipped. Add these to your shell profile:"
  echo ""
  echo "  export AGENT_BROWSER_REMOTE_URL=\"$URL\""
  echo "  export AGENT_BROWSER_REMOTE_TOKEN=\"$TOKEN\""
  if [ -n "$REPO_DIR" ]; then
    echo "  export PATH=\"$REPO_DIR/scripts:\$PATH\""
  fi
else
  # Auto-detect shell profile
  if [ -z "$SHELL_PROFILE" ]; then
    if [ -f "$HOME/.zshrc" ]; then
      SHELL_PROFILE="$HOME/.zshrc"
    elif [ -f "$HOME/.bashrc" ]; then
      SHELL_PROFILE="$HOME/.bashrc"
    elif [ -f "$HOME/.bash_profile" ]; then
      SHELL_PROFILE="$HOME/.bash_profile"
    else
      SHELL_PROFILE="$HOME/.profile"
    fi
  fi

  info "Configuring $SHELL_PROFILE..."

  # Remove old agent-browser-remote config block if present
  if grep -q "agent-browser-remote" "$SHELL_PROFILE" 2>/dev/null; then
    warn "Removing existing agent-browser-remote config from $SHELL_PROFILE"
    # Remove the block between markers
    sed -i.bak '/# ===* agent-browser-remote/,/^$/d' "$SHELL_PROFILE" 2>/dev/null || \
    sed -i '' '/# ===* agent-browser-remote/,/^$/d' "$SHELL_PROFILE" 2>/dev/null || true
    # Also remove standalone lines
    sed -i.bak '/AGENT_BROWSER_REMOTE/d' "$SHELL_PROFILE" 2>/dev/null || \
    sed -i '' '/AGENT_BROWSER_REMOTE/d' "$SHELL_PROFILE" 2>/dev/null || true
    rm -f "${SHELL_PROFILE}.bak"
  fi

  # Build the config block
  BLOCK="
# =================== agent-browser-remote ===================
# Remote browser automation via SSH tunnel.
# Start tunnel: ssh -f -N -L ${LOCAL_PORT}:localhost:${REMOTE_PORT} ${SERVER}
export AGENT_BROWSER_REMOTE_URL=\"$URL\"
export AGENT_BROWSER_REMOTE_TOKEN=\"$TOKEN\""

  if [ -n "$REPO_DIR" ]; then
    BLOCK="$BLOCK
# ab-remote CLI wrapper
export PATH=\"$REPO_DIR/scripts:\$PATH\""
  fi

  BLOCK="$BLOCK
"

  echo "$BLOCK" >> "$SHELL_PROFILE"
  ok "Added config to $SHELL_PROFILE"
fi

# ---------- Step 7: Test end-to-end ----------
info "Testing end-to-end connection..."

export AGENT_BROWSER_REMOTE_URL="$URL"
export AGENT_BROWSER_REMOTE_TOKEN="$TOKEN"

HEALTH=$(curl -s --max-time 10 -H "Authorization: Bearer $TOKEN" "$URL/sessions" 2>/dev/null) || true

if echo "$HEALTH" | grep -q "sessions"; then
  ok "End-to-end test passed!"
else
  warn "End-to-end test inconclusive (tunnel may still be connecting)"
fi

# ---------- Done ----------
echo ""
ok "========================================="
ok "  agent-browser-remote client is ready!"
ok "========================================="
echo ""
echo "  URL:    $URL"
echo "  Token:  ${TOKEN:0:8}...${TOKEN: -8}"
echo "  Tunnel: localhost:${LOCAL_PORT} → ${SERVER}:${REMOTE_PORT}"
echo ""
echo "Quick start:"
echo "  source $SHELL_PROFILE"
echo "  ab-remote test navigate url=https://example.com"
echo "  ab-remote test snapshot"
echo ""
echo "Start tunnel (if not running):"
echo "  ssh -f -N -L ${LOCAL_PORT}:localhost:${REMOTE_PORT} ${SERVER}"
echo ""
