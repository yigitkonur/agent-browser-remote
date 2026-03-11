# 02 — setup.sh shows wrong hostname in SSH tunnel command

## Problem
The setup output shows:
```
Connect from your machine:
  ssh -N -L 3000:localhost:3000 root@coolify
```

`root@coolify` is the hostname inside the server, not the external IP/host the user SSHed from.
A user seeing this would be confused — they SSHed in as `ubuntu@195.154.103.43` but the script says `root@coolify`.

## Root Cause
Line 117: `$(whoami)@$(hostname -f 2>/dev/null || hostname)` — when run with `sudo`, `whoami` returns `root`, and `hostname` returns the machine's internal hostname.

## Fix
Either:
1. Use `$SUDO_USER` instead of `$(whoami)` when running under sudo
2. Simply print a placeholder like `user@your-server` since the script can't reliably know the external address
3. Detect `$SSH_CLIENT` env var to extract the user's connection info
