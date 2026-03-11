# 07 — README doesn't explain how to use a different local port for SSH tunnel

## Problem
The README only shows `ssh -N -L 3000:localhost:3000`. If a user's port 3000 is taken (OrbStack, React dev server, etc.), they need to know they can use a different local port:
```
ssh -N -L 4100:localhost:3000 user@server
```
And then set `AGENT_BROWSER_REMOTE_URL=http://localhost:4100`.

## Fix
Add a "Tip" box after the SSH tunnel example explaining alternate ports and the env var.
