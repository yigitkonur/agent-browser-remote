# 04 — Port 3000 commonly conflicts with other services

## Problem
The README says to use port 3000 for the SSH tunnel:
```
ssh -N -L 3000:localhost:3000 user@your-server
```

Port 3000 is extremely commonly used (OrbStack, React dev servers, Rails, etc.).
On this machine, OrbStack is already bound to 3000.

## Impact
Users will get "Address already in use" when trying to set up the tunnel.

## Fix Options
1. Use a less common default port (e.g., 4100, 9222, or similar)
2. Add a note to the README: "If port 3000 is already in use, pick a different local port: `ssh -N -L 4100:localhost:3000 ...`"
3. Make ab-remote CLI support `AGENT_BROWSER_REMOTE_URL` env var to use any port

## Recommendation
Add a troubleshooting note AND document the `AGENT_BROWSER_REMOTE_URL` override in the CLI section.
