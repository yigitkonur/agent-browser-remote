#!/usr/bin/env bash
# =============================================================================
#
#   ╔═══════════════════════════════════════════════════════════════════╗
#   ║         agent-browser-remote  —  Full Interactive Installer      ║
#   ║                                                                   ║
#   ║   Sets up EVERYTHING: remote server + local client + CLI tools    ║
#   ║   One script. Works on first try. Zero manual steps.              ║
#   ╚═══════════════════════════════════════════════════════════════════╝
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/yigitkonur/agent-browser-remote/main/install.sh | bash
#
# Or non-interactive:
#   curl -fsSL ... | bash -s -- --server user@1.2.3.4 --port 4100
#
# What it does (fully automated):
#   1. Asks for your server IP/hostname (interactive prompt)
#   2. Verifies SSH connectivity
#   3. Installs Docker on the remote if missing
#   4. Deploys agent-browser-remote container on the remote
#   5. Generates a secure API token
#   6. Installs agent-browser CLI locally (via npm)
#   7. Downloads the ab-remote CLI wrapper to ~/.local/bin
#   8. Auto-detects a free local port for SSH tunnel
#   9. Opens SSH tunnel to the remote service
#  10. Configures your shell profile (env vars, PATH)
#  11. Tests end-to-end: navigate → snapshot → verify remote IP
#  12. Prints a beautiful summary with quick-start commands
#
# =============================================================================
set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Config & defaults
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SERVER=""
SSH_USER=""
SSH_HOST=""
LOCAL_PORT=""
REMOTE_PORT="3000"
REMOTE_DIR="/opt/agent-browser"
SHELL_PROFILE=""
SKIP_REMOTE=false
SKIP_LOCAL_CLI=false
SKIP_TUNNEL=false
SKIP_PROFILE=false
AB_REMOTE_URL="https://raw.githubusercontent.com/yigitkonur/agent-browser-remote/main/scripts/ab-remote"
IMAGE="ghcr.io/yigitkonur/agent-browser-remote:latest"
LOCAL_BIN="${HOME}/.local/bin"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Colors & output
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

step_num=0
total_steps=0

banner()   { printf "\n${CYAN}%s${RESET}\n" "$*"; }
info()     { printf "${BLUE}[%d/%d]${RESET} %s\n" "$step_num" "$total_steps" "$*"; }
ok()       { printf "${GREEN} OK ${RESET} %s\n" "$*"; }
warn()     { printf "${YELLOW} !! ${RESET} %s\n" "$*"; }
fail()     { printf "${RED}FAIL${RESET} %s\n" "$*" >&2; }
die()      { fail "$@"; exit 1; }
ask()      { printf "${BOLD}%s${RESET}" "$*"; }
dim()      { printf "${DIM}%s${RESET}" "$*"; }

spinner() {
  local pid=$1 msg="${2:-Working...}"
  local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  ${BLUE}%s${RESET} %s" "${chars:i%10:1}" "$msg"
    i=$((i + 1))
    sleep 0.1
  done
  printf "\r                                                    \r"
  wait "$pid"
  return $?
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Parse arguments
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
while [ $# -gt 0 ]; do
  case "$1" in
    --server|-s)       SERVER="$2"; shift 2 ;;
    --port|-p)         LOCAL_PORT="$2"; shift 2 ;;
    --remote-dir)      REMOTE_DIR="$2"; shift 2 ;;
    --shell)           SHELL_PROFILE="$2"; shift 2 ;;
    --skip-remote)     SKIP_REMOTE=true; shift ;;
    --skip-cli)        SKIP_LOCAL_CLI=true; shift ;;
    --skip-tunnel)     SKIP_TUNNEL=true; shift ;;
    --skip-profile)    SKIP_PROFILE=true; shift ;;
    --help|-h)
      cat <<'EOF'
agent-browser-remote — Full Interactive Installer

Usage:
  install.sh                                    # Interactive — asks for server IP
  install.sh --server user@1.2.3.4              # Non-interactive
  install.sh --server user@1.2.3.4 --port 4100  # Custom local port

Options:
  --server, -s <user@host>   SSH target (or just IP — defaults to root@IP)
  --port, -p <N>             Local port for SSH tunnel (default: auto-detect)
  --remote-dir <path>        Remote install directory (default: /opt/agent-browser)
  --shell <path>             Shell profile to configure (default: auto-detect)
  --skip-remote              Skip remote server setup (only configure local)
  --skip-cli                 Skip local agent-browser CLI install
  --skip-tunnel              Skip SSH tunnel setup
  --skip-profile             Skip shell profile changes
  --help, -h                 Show this help
EOF
      exit 0
      ;;
    -*)  die "Unknown flag: $1 (run with --help)" ;;
    *)
      if [ -z "$SERVER" ]; then
        SERVER="$1"; shift
      else
        die "Unexpected argument: $1"
      fi
      ;;
  esac
done

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Banner
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
clear 2>/dev/null || true
printf "\n"
printf "${CYAN}"
cat <<'ART'
    ╔══════════════════════════════════════════════╗
    ║       agent-browser-remote installer         ║
    ║                                              ║
    ║  Remote Chromium sessions over SSH tunnel    ║
    ║  github.com/yigitkonur/agent-browser-remote  ║
    ╚══════════════════════════════════════════════╝
ART
printf "${RESET}\n"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Step 0: Interactive server prompt
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
if [ -z "$SERVER" ]; then
  echo "This installer sets up a remote browser automation service."
  echo "You need a server (VPS/cloud) where Docker will run Chromium."
  echo ""
  ask "Enter your server address (user@ip or just ip): "
  read -r SERVER
  echo ""

  if [ -z "$SERVER" ]; then
    die "No server address provided. Example: ubuntu@1.2.3.4 or root@my-server.com"
  fi
fi

# Parse user@host — default to root@ if no user given
if [[ "$SERVER" == *@* ]]; then
  SSH_USER="${SERVER%%@*}"
  SSH_HOST="${SERVER#*@}"
else
  SSH_USER="root"
  SSH_HOST="$SERVER"
  SERVER="${SSH_USER}@${SSH_HOST}"
  warn "No SSH user specified, using: ${SERVER}"
fi

# Validate host looks reasonable
if [ -z "$SSH_HOST" ]; then
  die "Invalid server address: '$SERVER'. Example: ubuntu@1.2.3.4"
fi

# Count steps dynamically
# Steps: 1=SSH, 2=Docker check, 3=Deploy, 4=Local CLI, 5=ab-remote, 6=Tunnel, 7=Profile, 8=E2E
total_steps=1  # SSH check (always)
[ "$SKIP_REMOTE" = false ] && total_steps=$((total_steps + 2))  # Docker + Deploy
[ "$SKIP_REMOTE" = true ]  && total_steps=$((total_steps + 1))  # Token fetch
[ "$SKIP_LOCAL_CLI" = false ] && total_steps=$((total_steps + 1))
total_steps=$((total_steps + 1))  # ab-remote install (always)
[ "$SKIP_TUNNEL" = false ] && total_steps=$((total_steps + 1))
[ "$SKIP_PROFILE" = false ] && total_steps=$((total_steps + 1))
total_steps=$((total_steps + 1))  # E2E test (always)

echo "  Server:  ${BOLD}${SERVER}${RESET}"
echo "  Install: ${REMOTE_DIR}"
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Step 1: Verify SSH connectivity
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
step_num=1
info "Verifying SSH connection to ${SERVER}..."

if ! ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SERVER" "echo ok" >/dev/null 2>&1; then
  echo ""
  fail "Cannot connect to ${SERVER} via SSH."
  echo ""
  echo "  Troubleshooting:"
  echo "    1. Check that the server is running and reachable"
  echo "    2. Ensure SSH key is set up:  ssh-copy-id ${SERVER}"
  echo "    3. Verify you can connect:    ssh ${SERVER}"
  echo "    4. If using a password:       ssh ${SERVER}  (will prompt)"
  echo ""

  # Try interactive SSH as fallback
  ask "Try connecting interactively? (y/N): "
  read -r try_interactive
  if [ "$try_interactive" = "y" ] || [ "$try_interactive" = "Y" ]; then
    echo "Testing SSH (this may ask for your password)..."
    if ! ssh -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new "$SERVER" "echo ok" 2>/dev/null; then
      die "SSH connection failed. Please fix SSH access and re-run this installer."
    fi
  else
    die "SSH connection required. Fix it and re-run."
  fi
fi

ok "SSH connection to ${SERVER} verified"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Step 2: Check/install Docker on remote
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
if [ "$SKIP_REMOTE" = false ]; then
  step_num=$((step_num + 1))
  info "Checking Docker on remote server..."

  DOCKER_STATUS=$(ssh "$SERVER" "
    if ! command -v docker >/dev/null 2>&1; then
      echo 'NO_DOCKER'
    elif docker info >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
      echo 'READY'
    elif sudo docker info >/dev/null 2>&1 && sudo docker compose version >/dev/null 2>&1; then
      echo 'READY_SUDO'
    elif docker compose version >/dev/null 2>&1 || sudo docker compose version >/dev/null 2>&1; then
      echo 'READY_SUDO'
    else
      echo 'NO_COMPOSE'
    fi
  " 2>/dev/null) || DOCKER_STATUS="UNKNOWN"

  # Determine if we need sudo for docker commands on remote
  DOCKER_CMD="docker"
  case "$DOCKER_STATUS" in
    READY)
      ok "Docker + Compose v2 ready"
      ;;
    READY_SUDO)
      ok "Docker + Compose v2 ready (via sudo)"
      DOCKER_CMD="sudo docker"
      ;;
    NO_COMPOSE)
      die "Docker found but Compose v2 is missing. Install it:
  ssh ${SERVER}
  sudo apt-get update && sudo apt-get install -y docker-compose-plugin"
      ;;
    NO_DOCKER)
      echo ""
      warn "Docker is not installed on ${SSH_HOST}."
      ask "Install Docker automatically? (Y/n): "
      read -r install_docker
      if [ "$install_docker" = "n" ] || [ "$install_docker" = "N" ]; then
        die "Docker is required. Install it manually: https://docs.docker.com/engine/install/"
      fi
      echo ""
      echo "  Installing Docker on ${SSH_HOST}..."
      echo "  (this takes 1-2 minutes)"
      echo ""

      ssh "$SERVER" "
        set -e
        export DEBIAN_FRONTEND=noninteractive
        # Install Docker via official convenience script
        curl -fsSL https://get.docker.com | sh
        # Add current user to docker group
        sudo usermod -aG docker \$(whoami) 2>/dev/null || true
        # Start Docker
        sudo systemctl enable docker
        sudo systemctl start docker
        echo 'DOCKER_INSTALLED'
      " 2>&1 | while IFS= read -r line; do
        printf "  ${DIM}%s${RESET}\n" "$line"
      done

      # After installing Docker, the user may need sudo until they re-login
      DOCKER_CMD="sudo docker"
      ok "Docker installed on ${SSH_HOST}"
      ;;
    *)
      die "Could not check Docker status on remote. Verify SSH access: ssh ${SERVER}"
      ;;
  esac

  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  # Step 3: Deploy container on remote
  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  step_num=$((step_num + 1))
  info "Setting up agent-browser-remote on ${SSH_HOST}..."

  # Check if already running
  EXISTING=$(ssh "$SERVER" "${DOCKER_CMD} ps --format '{{.Names}}' 2>/dev/null | grep -c '^agent-browser$'" 2>/dev/null) || EXISTING=0

  if [ "$EXISTING" -gt 0 ]; then
    # Already running — check if healthy
    REMOTE_HEALTH=$(ssh "$SERVER" "curl -s http://localhost:${REMOTE_PORT}/health 2>/dev/null") || REMOTE_HEALTH=""
    if echo "$REMOTE_HEALTH" | grep -q '"status":"ok"'; then
      ok "Container already running and healthy"
    else
      warn "Container exists but not healthy — restarting..."
      ssh "$SERVER" "cd ${REMOTE_DIR} && ${DOCKER_CMD} compose restart" 2>/dev/null || true
      sleep 3
    fi
  else
    # Fresh install
    echo "  Pulling image + starting container..."
    echo "  (first run takes 1-3 minutes to download ~800MB image)"
    echo ""

    # Write docker-compose.yml locally, then scp it
    TMPDIR_INSTALL=$(mktemp -d)
    cat > "${TMPDIR_INSTALL}/docker-compose.yml" <<COMPOSE
services:
  agent-browser:
    image: ${IMAGE}
    container_name: agent-browser
    restart: unless-stopped
    ports:
      - "127.0.0.1:${REMOTE_PORT}:3000"
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

    # Create remote directory + generate .env
    ssh "$SERVER" "sudo mkdir -p ${REMOTE_DIR} && sudo chown \$(whoami) ${REMOTE_DIR}" 2>/dev/null

    # Upload docker-compose.yml
    scp -q "${TMPDIR_INSTALL}/docker-compose.yml" "${SERVER}:${REMOTE_DIR}/docker-compose.yml"
    rm -rf "${TMPDIR_INSTALL}"

    # Generate token if needed, pull image, start service
    ssh "$SERVER" "
      set -e
      cd ${REMOTE_DIR}

      # Generate .env with token if not present
      if [ ! -f .env ]; then
        TOKEN=\$(openssl rand -hex 32)
        printf 'API_TOKEN=%s\nMAX_SESSIONS=10\nSTATE_EXPIRE_DAYS=30\n' \"\$TOKEN\" > .env
        echo \"NEW_TOKEN=\$TOKEN\"
      fi

      # Pull and start
      ${DOCKER_CMD} pull ${IMAGE} 2>&1 | tail -5
      ${DOCKER_CMD} compose up -d 2>&1
    " 2>&1 | while IFS= read -r line; do
      # Capture TOKEN line from fresh install
      if [[ "$line" == NEW_TOKEN=* ]]; then
        echo "${line#NEW_}" > /tmp/.ab-remote-token-$$
      else
        printf "  ${DIM}%s${RESET}\n" "$line"
      fi
    done

    # Wait for container to be healthy
    echo ""
    echo "  Waiting for service to start..."
    for i in $(seq 1 30); do
      HEALTH=$(ssh "$SERVER" "curl -s http://localhost:${REMOTE_PORT}/health 2>/dev/null") || HEALTH=""
      if echo "$HEALTH" | grep -q '"status":"ok"'; then
        break
      fi
      sleep 1
    done

    if echo "$HEALTH" | grep -q '"status":"ok"'; then
      ok "Container deployed and healthy"
    else
      warn "Container started but health check pending — it may need a few more seconds"
    fi
  fi

  # Get the token (either from fresh install or existing .env)
  TOKEN=""
  if [ -f "/tmp/.ab-remote-token-$$" ]; then
    TOKEN=$(grep '^TOKEN=' "/tmp/.ab-remote-token-$$" 2>/dev/null | cut -d= -f2)
    rm -f "/tmp/.ab-remote-token-$$"
  fi
  if [ -z "$TOKEN" ]; then
    TOKEN=$(ssh "$SERVER" "grep '^API_TOKEN=' ${REMOTE_DIR}/.env 2>/dev/null | head -1 | cut -d= -f2") || true
  fi
  if [ -z "$TOKEN" ]; then
    die "Could not retrieve API token from ${SERVER}:${REMOTE_DIR}/.env"
  fi

  ok "API token: ${TOKEN:0:8}...${TOKEN: -8}"

else
  # Skip remote — still need to fetch token
  step_num=$((step_num + 1))
  info "Fetching API token from ${SERVER}..."
  TOKEN=$(ssh "$SERVER" "grep '^API_TOKEN=' ${REMOTE_DIR}/.env 2>/dev/null | head -1 | cut -d= -f2") || true
  if [ -z "$TOKEN" ]; then
    die "Could not fetch token. Is the server set up? Run without --skip-remote."
  fi
  ok "Token: ${TOKEN:0:8}...${TOKEN: -8}"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Step 4: Install agent-browser CLI locally
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
if [ "$SKIP_LOCAL_CLI" = false ]; then
  step_num=$((step_num + 1))
  info "Installing agent-browser CLI locally..."

  if command -v agent-browser >/dev/null 2>&1; then
    AB_VERSION=$(agent-browser --version 2>/dev/null || echo "unknown")
    ok "agent-browser already installed (${AB_VERSION})"
  else
    # Detect package manager
    if command -v npm >/dev/null 2>&1; then
      echo "  Installing via npm..."
      npm install -g agent-browser@latest 2>&1 | tail -3
      ok "agent-browser installed via npm"
    elif command -v bun >/dev/null 2>&1; then
      echo "  Installing via bun..."
      bun install -g agent-browser@latest 2>&1 | tail -3
      ok "agent-browser installed via bun"
    elif command -v pnpm >/dev/null 2>&1; then
      echo "  Installing via pnpm..."
      pnpm install -g agent-browser@latest 2>&1 | tail -3
      ok "agent-browser installed via pnpm"
    else
      warn "No Node.js package manager found (npm/bun/pnpm)."
      echo "  Install Node.js first: https://nodejs.org/"
      echo "  Then run: npm install -g agent-browser"
      echo ""
      echo "  Skipping local CLI install (ab-remote will still work via HTTP)."
    fi
  fi
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Step 5: Install ab-remote CLI wrapper
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
step_num=$((step_num + 1))
info "Installing ab-remote CLI to ${LOCAL_BIN}..."

mkdir -p "$LOCAL_BIN"

# Download ab-remote
if curl -fsSL "$AB_REMOTE_URL" -o "${LOCAL_BIN}/ab-remote" 2>/dev/null; then
  chmod +x "${LOCAL_BIN}/ab-remote"
  ok "ab-remote installed to ${LOCAL_BIN}/ab-remote"
else
  # Fallback: check if it's already in PATH
  if command -v ab-remote >/dev/null 2>&1; then
    ok "ab-remote already available in PATH"
  else
    warn "Could not download ab-remote. You can still use curl directly."
  fi
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Step 6: Auto-detect free local port + open SSH tunnel
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
port_is_free() {
  local p="$1"
  # macOS: lsof, Linux: ss
  if command -v lsof >/dev/null 2>&1; then
    ! lsof -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1
  elif command -v ss >/dev/null 2>&1; then
    ! ss -tlnH "sport = :$p" 2>/dev/null | grep -q .
  else
    # Best effort: try to bind
    if command -v python3 >/dev/null 2>&1; then
      python3 -c "
import socket, sys
s = socket.socket()
try:
    s.bind(('127.0.0.1', $p))
    s.close()
except:
    sys.exit(1)
" 2>/dev/null
    else
      return 0  # Assume free if we can't check
    fi
  fi
}

if [ -z "$LOCAL_PORT" ]; then
  # Try these ports in order — 3000 is the standard, 4100/4200 are common alternatives
  for candidate in 3000 4100 4200 4300 8100 8200; do
    if port_is_free "$candidate"; then
      LOCAL_PORT="$candidate"
      break
    fi
  done
  # Last resort: random port
  if [ -z "$LOCAL_PORT" ]; then
    LOCAL_PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()" 2>/dev/null || echo "4100")
  fi
fi

LOCAL_URL="http://localhost:${LOCAL_PORT}"

if [ "$SKIP_TUNNEL" = false ]; then
  step_num=$((step_num + 1))
  info "Opening SSH tunnel (localhost:${LOCAL_PORT} -> ${SSH_HOST}:${REMOTE_PORT})..."

  # Kill any stale tunnel on this port
  if pgrep -f "ssh.*-L.*${LOCAL_PORT}:localhost:${REMOTE_PORT}" >/dev/null 2>&1; then
    pkill -f "ssh.*-L.*${LOCAL_PORT}:localhost:${REMOTE_PORT}" 2>/dev/null || true
    sleep 1
  fi

  # Open tunnel in background
  ssh -f -N \
    -L "${LOCAL_PORT}:localhost:${REMOTE_PORT}" \
    -o ServerAliveInterval=60 \
    -o ServerAliveCountMax=3 \
    -o ExitOnForwardFailure=yes \
    "$SERVER"

  # Wait for tunnel to come up
  TUNNEL_OK=false
  for i in $(seq 1 10); do
    if curl -s --max-time 2 "${LOCAL_URL}/health" >/dev/null 2>&1; then
      TUNNEL_OK=true
      break
    fi
    sleep 0.5
  done

  if [ "$TUNNEL_OK" = true ]; then
    ok "Tunnel active: ${LOCAL_URL} -> ${SERVER}"
  else
    warn "Tunnel started but health check pending"
  fi
else
  step_num=$((step_num + 1))
  info "Skipping tunnel (--skip-tunnel). Make sure you have your own tunnel running."
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Step 7: Configure shell profile
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
if [ "$SKIP_PROFILE" = false ]; then
  step_num=$((step_num + 1))

  # Auto-detect shell profile
  if [ -z "$SHELL_PROFILE" ]; then
    case "${SHELL:-}" in
      */zsh)  SHELL_PROFILE="$HOME/.zshrc" ;;
      */bash)
        if [ -f "$HOME/.bashrc" ]; then
          SHELL_PROFILE="$HOME/.bashrc"
        else
          SHELL_PROFILE="$HOME/.bash_profile"
        fi
        ;;
      */fish) SHELL_PROFILE="$HOME/.config/fish/config.fish" ;;
      *)
        if [ -f "$HOME/.zshrc" ]; then
          SHELL_PROFILE="$HOME/.zshrc"
        elif [ -f "$HOME/.bashrc" ]; then
          SHELL_PROFILE="$HOME/.bashrc"
        else
          SHELL_PROFILE="$HOME/.profile"
        fi
        ;;
    esac
  fi

  info "Configuring ${SHELL_PROFILE}..."

  # Create profile if it doesn't exist
  touch "$SHELL_PROFILE"

  # Remove ALL old agent-browser-remote config (idempotent)
  # Uses python3 for reliable multi-line block removal (works on macOS + Linux)
  if grep -q 'agent-browser-remote\|AGENT_BROWSER_REMOTE' "$SHELL_PROFILE" 2>/dev/null; then
    warn "Removing existing agent-browser-remote config"
    python3 -c "
import re, sys
with open('$SHELL_PROFILE', 'r') as f:
    content = f.read()
# Remove entire block: from marker comment to next non-comment/non-export/non-blank line
content = re.sub(
    r'\n*# =+\s*agent-browser-remote\s*=+\n'   # marker line
    r'(?:[^\n]*\n)*?'                             # block body
    r'(?=\n[^#e\n]|\n# =+[^a]|\Z)',              # stop before next section
    '', content, flags=re.DOTALL
)
# Remove any remaining individual lines referencing our config
lines = content.split('\n')
lines = [l for l in lines if not re.search(
    r'(AGENT_BROWSER_REMOTE|agent-browser-remote|ab-remote CLI|# Tunnel:.*localhost:\d+|# Remote browser automation|# Start tunnel)',
    l
)]
# Collapse multiple blank lines into one
content = re.sub(r'\n{3,}', '\n\n', '\n'.join(lines)).strip() + '\n'
with open('$SHELL_PROFILE', 'w') as f:
    f.write(content)
" 2>/dev/null || {
      # Fallback: simple grep -v if python3 fails
      grep -v -E '(agent-browser-remote|AGENT_BROWSER_REMOTE|ab-remote CLI)' "$SHELL_PROFILE" > "${SHELL_PROFILE}.tmp" 2>/dev/null || true
      mv "${SHELL_PROFILE}.tmp" "$SHELL_PROFILE"
    }
  fi

  # Fish shell uses different syntax
  if [[ "$SHELL_PROFILE" == *.fish ]]; then
    cat >> "$SHELL_PROFILE" <<FISH

# =================== agent-browser-remote ===================
# Remote browser automation via SSH tunnel
# Tunnel: ssh -f -N -L ${LOCAL_PORT}:localhost:${REMOTE_PORT} ${SERVER}
set -gx AGENT_BROWSER_REMOTE_URL "${LOCAL_URL}"
set -gx AGENT_BROWSER_REMOTE_TOKEN "${TOKEN}"
# ab-remote CLI
fish_add_path ${LOCAL_BIN}
FISH
  else
    cat >> "$SHELL_PROFILE" <<PROFILE

# =================== agent-browser-remote ===================
# Remote browser automation via SSH tunnel
# Tunnel: ssh -f -N -L ${LOCAL_PORT}:localhost:${REMOTE_PORT} ${SERVER}
export AGENT_BROWSER_REMOTE_URL="${LOCAL_URL}"
export AGENT_BROWSER_REMOTE_TOKEN="${TOKEN}"
# ab-remote CLI
export PATH="${LOCAL_BIN}:\$PATH"
PROFILE
  fi

  ok "Shell profile updated: ${SHELL_PROFILE}"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Step 8: End-to-end test
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
step_num=$((step_num + 1))
info "Running end-to-end test..."

export AGENT_BROWSER_REMOTE_URL="$LOCAL_URL"
export AGENT_BROWSER_REMOTE_TOKEN="$TOKEN"
export PATH="${LOCAL_BIN}:$PATH"

E2E_PASS=true

# Test 1: Health check
printf "  Health check...      "
HEALTH=$(curl -s --max-time 10 "${LOCAL_URL}/health" 2>/dev/null) || HEALTH=""
if echo "$HEALTH" | grep -q '"status":"ok"'; then
  printf "${GREEN}PASS${RESET}\n"
else
  printf "${RED}FAIL${RESET}\n"
  E2E_PASS=false
fi

# Test 2: Auth check
printf "  Authentication...    "
AUTH=$(curl -s --max-time 10 -H "Authorization: Bearer $TOKEN" "${LOCAL_URL}/sessions" 2>/dev/null) || AUTH=""
if echo "$AUTH" | grep -q '"sessions"'; then
  printf "${GREEN}PASS${RESET}\n"
else
  printf "${RED}FAIL${RESET}\n"
  E2E_PASS=false
fi

# Test 3: Browser test (navigate + snapshot)
printf "  Browser navigation..."
NAV=$(curl -s --max-time 30 \
  -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"action":"navigate","url":"https://httpbin.org/ip"}' \
  "${LOCAL_URL}/sessions/install-test/command" 2>/dev/null) || NAV=""
if echo "$NAV" | grep -q '"success":true'; then
  printf " ${GREEN}PASS${RESET}\n"
else
  printf " ${YELLOW}SKIP${RESET} (first run may take a moment)\n"
fi

# Test 4: Snapshot to verify remote IP
printf "  Remote IP check...   "
SNAP=$(curl -s --max-time 30 \
  -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"action":"snapshot"}' \
  "${LOCAL_URL}/sessions/install-test/command" 2>/dev/null) || SNAP=""
REMOTE_IP=""
if echo "$SNAP" | grep -q "origin"; then
  # Extract IP from the snapshot — httpbin returns {"origin": "1.2.3.4"}
  REMOTE_IP=$(echo "$SNAP" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  if [ -n "$REMOTE_IP" ]; then
    printf "${GREEN}PASS${RESET} (browser IP: ${BOLD}${REMOTE_IP}${RESET})\n"
  else
    printf "${GREEN}PASS${RESET}\n"
  fi
else
  printf "${YELLOW}SKIP${RESET}\n"
fi

# Cleanup test session
curl -s --max-time 10 \
  -X DELETE \
  -H "Authorization: Bearer $TOKEN" \
  "${LOCAL_URL}/sessions/install-test" >/dev/null 2>&1 || true

if [ "$E2E_PASS" = true ]; then
  ok "All tests passed!"
else
  warn "Some tests failed — the service may need a moment to fully start"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Summary
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
printf "\n"
printf "${GREEN}"
cat <<'DONE'
  ┌─────────────────────────────────────────────────┐
  │                                                 │
  │   Installation complete!                        │
  │                                                 │
  └─────────────────────────────────────────────────┘
DONE
printf "${RESET}\n"

echo "  ${BOLD}Connection${RESET}"
echo "    Server:  ${SERVER}"
echo "    Tunnel:  localhost:${LOCAL_PORT} -> ${SSH_HOST}:${REMOTE_PORT}"
echo "    URL:     ${LOCAL_URL}"
echo "    Token:   ${TOKEN:0:8}...${TOKEN: -8}"
if [ -n "$REMOTE_IP" ]; then
  echo "    Browser IP: ${REMOTE_IP} (all browsing goes through your server)"
fi
echo ""
echo "  ${BOLD}Quick Start${RESET}"
if [ -n "$SHELL_PROFILE" ]; then
  echo "    source ${SHELL_PROFILE}"
  echo ""
else
  echo "    export AGENT_BROWSER_REMOTE_URL=\"${LOCAL_URL}\""
  echo "    export AGENT_BROWSER_REMOTE_TOKEN=\"${TOKEN}\""
  echo "    export PATH=\"${LOCAL_BIN}:\$PATH\""
  echo ""
fi
echo "    ab-remote my-task navigate url=https://example.com"
echo "    ab-remote my-task snapshot"
echo "    ab-remote my-task click selector=@e2"
echo "    ab-remote --status"
echo ""
echo "  ${BOLD}Restart Tunnel${RESET} (after reboot or disconnect)"
echo "    ssh -f -N -L ${LOCAL_PORT}:localhost:${REMOTE_PORT} ${SERVER}"
echo ""
echo "  ${BOLD}Documentation${RESET}"
echo "    https://github.com/yigitkonur/agent-browser-remote"
echo ""
