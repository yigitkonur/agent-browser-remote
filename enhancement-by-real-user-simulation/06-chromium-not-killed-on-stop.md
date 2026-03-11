# 06 — Chromium processes linger after session stop

## Problem
After stopping all sessions via `DELETE /sessions/:id`, 5 chrome-headless-shell processes still exist in the container:
```
ps aux | grep -c chrome → 5
```
Expected: 0 chrome processes after all sessions are stopped.

## Impact
Memory leak — over time, orphaned Chromium processes accumulate and consume RAM. This is critical for a multi-session service with limited resources.

## Root Cause
The chrome-headless-shell processes are **zombies** (`<defunct>` state). They've exited but their parent
didn't call `wait()`. Since daemon.js spawns chromium via Playwright, and daemon.js itself was spawned
with `detached: true` + `child.unref()`, the daemon process exits and the zombies are reparented to PID 1
(our API server). The API server (Node.js) doesn't call `waitpid` on these orphaned children.

## Fix
Add a zombie reaper to the API server (server.ts). Since the API server runs as PID 1 in the container,
it inherits all orphaned children. Use `process.on('SIGCHLD', ...)` or an init process like `tini`:

**Option A**: Add `tini` as PID 1 in Dockerfile:
```dockerfile
RUN apt-get update && apt-get install -y tini
ENTRYPOINT ["tini", "--"]
CMD ["node", "dist/server.js"]
```

**Option B**: Add periodic zombie reap in server.ts (less clean but works)
