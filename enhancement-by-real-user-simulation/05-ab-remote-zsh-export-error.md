# 05 — ab-remote produces zsh export error when piped

## Problem
When piping ab-remote output through another command, we sometimes get:
```
(eval):export:1: not valid in this context: /path/to/ab-remote
```

## Root Cause
ab-remote uses `#!/usr/bin/env bash` shebang but when called with `export VAR=x && /path/ab-remote`,
zsh's `&&` chaining can cause issues with how env vars are inherited. The error occurs
intermittently when zsh interprets the export in eval context.

## Fix
Not a script bug per se — it's a shell interaction issue. The workaround is to use
subshell invocation or env command:
```
env AGENT_BROWSER_REMOTE_TOKEN=... /path/ab-remote ...
```
Or source the exports in a separate statement.
