# 01 — setup.sh fails: Permission denied on /opt/agent-browser

## Problem
Running the one-command setup as a non-root user (ubuntu) fails immediately:
```
mkdir: cannot create directory '/opt/agent-browser': Permission denied
```

## Root Cause
`setup.sh` uses `mkdir -p "$INSTALL_DIR"` where `INSTALL_DIR=/opt/agent-browser`.
`/opt` is owned by root, so a regular user can't create directories there.

## Fix Options
1. Add `sudo` to mkdir and chown to the current user afterward
2. Use a user-writable default like `~/agent-browser` instead of `/opt/agent-browser`
3. Detect if running as root and suggest `sudo` if not

## Recommendation
Use `sudo mkdir -p` + `sudo chown $(whoami)` for the install dir, then continue as regular user. This matches what deploy.sh already does.
