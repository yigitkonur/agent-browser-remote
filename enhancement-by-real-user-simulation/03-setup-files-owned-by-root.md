# 03 — setup.sh with sudo creates files owned by root

## Problem
Running `curl ... | sudo bash` creates `/opt/agent-browser/.env` and `docker-compose.yml` owned by root.
If a user later wants to edit `.env` or docker-compose.yml without sudo, they can't.

## Root Cause
`sudo bash` runs the entire script as root. `mkdir -p`, `cat > .env`, `cat > docker-compose.yml` all create files as root.

## Fix
After creating the directory as root, chown it to the actual user:
```bash
REAL_USER="${SUDO_USER:-$(whoami)}"
sudo mkdir -p "$INSTALL_DIR"
sudo chown "$REAL_USER" "$INSTALL_DIR"
```
Then the rest of the script runs in a user-owned directory.
Or better: only use sudo for mkdir, then drop privileges for the rest.
