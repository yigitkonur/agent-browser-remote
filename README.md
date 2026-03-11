# agent-browser-remote

Run [agent-browser](https://github.com/vercel-labs/agent-browser) as a remote, multi-session Docker service. One container, multiple isolated browser sessions, accessible via a simple HTTP API. Supports both **Chrome** (full fidelity) and **[Lightpanda](https://lightpanda.io/)** (10x faster, 10x less memory).

```
Local machine ──HTTP──> SSH tunnel ──> Docker container
                                        ├── Session "task-1" → Chromium (default)
                                        ├── Session "task-2" → Chromium
                                        └── Session "task-3" → Lightpanda (fast)
```

## Why

- **Offload browsers from your machine** — run Chromium or Lightpanda on a remote server
- **Two engines, one container** — Chrome for full fidelity, Lightpanda for speed (~10x faster, ~10x less RAM)
- **Multiple isolated sessions** — each session gets its own browser instance with separate cookies, state, and refs
- **AI-agent friendly** — same compact snapshot/ref workflow as local agent-browser, over HTTP
- **Secure** — Bearer token auth, localhost-only binding, access via SSH tunnel
- **Easy install** — one command does everything: server + client + tunnel + test

## Quick Start

### One-command install (recommended)

Run this on your **local machine** — it handles everything interactively:

```bash
curl -fsSL https://raw.githubusercontent.com/yigitkonur/agent-browser-remote/main/install.sh | bash
```

It will ask for your server IP, then automatically:

1. Verify SSH connectivity
2. Install Docker on the remote server (if needed)
3. Deploy the container and generate an API token
4. Install `agent-browser` CLI + `ab-remote` locally
5. Open an SSH tunnel (auto-detects a free port)
6. Configure your shell profile
7. Run end-to-end tests (navigate + verify remote browser IP)

**Non-interactive mode:**

```bash
curl -fsSL https://raw.githubusercontent.com/yigitkonur/agent-browser-remote/main/install.sh | bash -s -- --server user@1.2.3.4
```

With a custom port (if 3000 is taken by OrbStack, dev servers, etc.):

```bash
curl -fsSL https://raw.githubusercontent.com/yigitkonur/agent-browser-remote/main/install.sh | bash -s -- --server user@1.2.3.4 --port 4100
```

### Alternative: Two-step setup

#### Step 1: Server setup

SSH into your server and run:

```bash
curl -fsSL https://raw.githubusercontent.com/yigitkonur/agent-browser-remote/main/scripts/setup.sh | sudo bash
```

> **Note:** `sudo` is needed because the default install directory (`/opt/agent-browser`) requires root. The script auto-sets file ownership to your user.

#### Step 2: Client setup

On your local machine:

```bash
curl -fsSL https://raw.githubusercontent.com/yigitkonur/agent-browser-remote/main/scripts/client-setup.sh | bash -s -- user@your-server
```

Or manually:

```bash
# 1. Start SSH tunnel (use port 4100 if 3000 is taken)
ssh -f -N -L 3000:localhost:3000 user@your-server

# 2. Add to ~/.zshrc or ~/.bashrc
export AGENT_BROWSER_REMOTE_URL="http://localhost:3000"
export AGENT_BROWSER_REMOTE_TOKEN="your-token-here"
export PATH="$HOME/.local/bin:$PATH"

# 3. Reload and test
source ~/.zshrc
ab-remote --health
```

**Tip:** Add to `~/.ssh/config` for persistent tunnel:

```
Host agent-browser
    HostName your-server-ip
    User your-user
    LocalForward 3000 localhost:3000
```

Then just `ssh -N agent-browser`.

### 3. Use it

```bash
# Navigate (auto-creates session + browser on first command)
ab-remote my-task navigate url=https://example.com

# Snapshot — get accessibility tree with refs
ab-remote my-task snapshot
# → - heading "Example Domain" [ref=e1]
# → - link "More information..." [ref=e2]

# Click using ref from snapshot
ab-remote my-task click selector=@e2

# Fill a form field
ab-remote my-task fill selector=@e5 value="search query"

# Take a screenshot (base64 PNG)
ab-remote my-task screenshot

# Clean up
ab-remote --stop my-task
```

### Lightpanda (fast mode)

Use `--engine lightpanda` for 10x faster, 10x lighter browser sessions:

```bash
# Create a Lightpanda session
ab-remote --create fast-task --engine lightpanda
ab-remote fast-task navigate url=https://example.com
ab-remote fast-task snapshot

# Or set engine on first command (auto-creates with Lightpanda)
ab-remote fast-task navigate url=https://example.com --engine lightpanda

# Chrome is the default — no flag needed
ab-remote my-task navigate url=https://example.com
```

| | Chrome (default) | Lightpanda |
|---|---|---|
| **Memory** | ~100-300MB/session | ~10-30MB/session |
| **Speed** | Baseline | ~10x faster |
| **Screenshots** | Yes | Depends on CDP support |
| **Extensions** | Yes | No |
| **Persistent profiles** | Yes | No |
| **Best for** | Full fidelity, testing | Scraping, AI agents, CI/CD |

## CLI Reference (ab-remote)

### Browser commands

```bash
ab-remote <session> <action> [key=value ...]
```

Sessions auto-create on first command — no need to create them explicitly.

| Category | Actions |
|-------------|---------|
| **Navigation** | `navigate`, `back`, `forward`, `reload`, `url`, `title` |
| **Interaction** | `click`, `fill`, `type`, `press`, `hover`, `select`, `check`, `uncheck`, `scroll`, `focus`, `clear`, `upload`, `drag`, `dblclick` |
| **Observation** | `snapshot`, `screenshot`, `eval`, `gettext`, `getattribute`, `isvisible`, `isenabled`, `ischecked`, `count` |
| **State** | `cookies_get`, `cookies_set`, `cookies_clear`, `storage_get`, `storage_set`, `storage_clear` |
| **Tabs** | `tab_new`, `tab_list`, `tab_close`, tab switching |
| **Emulation** | `viewport`, `device`, `geolocation`, `useragent` |
| **Network** | `route`, `unroute`, `requests` |
| **Other** | `pdf`, `dialog`, `permissions` |

### Session management

```bash
ab-remote --sessions              # List active sessions
ab-remote --create <name>         # Create a session explicitly
ab-remote --stop <name>           # Stop session and close browser
```

### Connection management

```bash
ab-remote --health                # Health check (no auth required)
ab-remote --status                # Show connection status, config, and tunnel info
ab-remote --tunnel user@host      # Start SSH tunnel to remote server
ab-remote --tunnel user@host --port 4100  # Custom local port
```

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `AGENT_BROWSER_REMOTE_URL` | `http://localhost:3000` | API URL |
| `AGENT_BROWSER_REMOTE_TOKEN` | (required) | API token |

## HTTP API Reference

All endpoints except `/health` require `Authorization: Bearer <token>`.

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Health check (no auth) |
| `GET` | `/sessions` | List active sessions |
| `POST` | `/sessions` | Create session `{"session":"name"}` |
| `DELETE` | `/sessions/:id` | Stop session and close browser |
| `POST` | `/sessions/:id/command` | Execute command `{"action":"...", ...}` |

### Command format

```json
{
  "action": "navigate",
  "url": "https://example.com"
}
```

### Response format

```json
{
  "success": true,
  "data": {
    "url": "https://example.com/",
    "title": "Example Domain"
  }
}
```

On error:

```json
{
  "success": false,
  "error": "Element not found: @e99"
}
```

### curl examples

```bash
TOKEN="your-token-here"
URL="http://localhost:3000"

# Navigate
curl -X POST "$URL/sessions/my-task/command" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"action": "navigate", "url": "https://example.com"}'

# Snapshot
curl -X POST "$URL/sessions/my-task/command" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"action": "snapshot"}'

# Click
curl -X POST "$URL/sessions/my-task/command" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"action": "click", "selector": "@e2"}'

# List sessions
curl -H "Authorization: Bearer $TOKEN" "$URL/sessions"

# Stop session
curl -X DELETE -H "Authorization: Bearer $TOKEN" "$URL/sessions/my-task"
```

## Architecture

```
┌──────────────────────────────────────────────────┐
│  Docker Container                                 │
│                                                   │
│  API Server (Hono, port 3000)                     │
│    ├── Bearer token auth                          │
│    ├── Session manager (spawn/stop daemons)       │
│    └── Unix socket proxy                          │
│         │                                         │
│         ├── /data/sockets/task-1.sock             │
│         │     └── daemon.js → Chromium instance   │
│         │                                         │
│         ├── /data/sockets/task-2.sock             │
│         │     └── daemon.js → Chromium instance   │
│         │                                         │
│         └── (up to MAX_SESSIONS daemons)          │
│                                                   │
│  /data/sessions/ — persisted browser state        │
│  tini (PID 1) — reaps zombie processes            │
└──────────────────────────────────────────────────┘
```

Each session runs its own `agent-browser` daemon process with a dedicated Chromium instance. Sessions are fully isolated — separate cookies, localStorage, and browsing context.

The API server communicates with daemons via Unix sockets using agent-browser's native JSON-over-newline protocol. Daemons are spawned on-demand when the first command arrives for a session. `tini` runs as PID 1 to properly reap zombie Chromium processes.

## Alternative Setup Methods

### Manual server setup

```bash
# 1. Create a directory
mkdir -p /opt/agent-browser && cd /opt/agent-browser

# 2. Download docker-compose.yml
curl -fsSLO https://raw.githubusercontent.com/yigitkonur/agent-browser-remote/main/docker-compose.yml

# 3. Create .env
cat > .env <<EOF
API_TOKEN=$(openssl rand -hex 32)
MAX_SESSIONS=10
STATE_EXPIRE_DAYS=30
EOF

# 4. Pull and start
docker compose up -d

# 5. Verify
curl http://localhost:3000/health
# → {"status":"ok","sessions":0,"uptime":5}
```

### Build from source

```bash
git clone https://github.com/yigitkonur/agent-browser-remote.git
cd agent-browser-remote

# Build the API server
cd api-server && npm install && npm run build && cd ..

# Build and run (use both compose files so the local build is used)
docker compose -f docker-compose.yml -f docker-compose.build.yml build
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d
```

### Deploy from your machine

```bash
# macOS / Linux
DEPLOY_SERVER=user@your-server ./scripts/deploy.sh

# Windows (PowerShell)
$env:DEPLOY_SERVER = "user@your-server"
.\scripts\deploy.ps1
```

| Variable | Default | Description |
|----------|---------|-------------|
| `DEPLOY_SERVER` | (required) | SSH target, e.g. `user@your-server` |
| `DEPLOY_DIR` | `/opt/agent-browser` | Remote install directory |
| `DEPLOY_MODE` | `pull` | `pull` (from GHCR) or `build` (local build + transfer) |
| `DEPLOY_PORT` | `3000` | Host port to bind on the remote server |

## Docker Image

Pre-built images are available on GitHub Container Registry for both `linux/amd64` and `linux/arm64`:

```bash
docker pull ghcr.io/yigitkonur/agent-browser-remote:latest
```

## Configuration

### Server environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `API_TOKEN` | (required) | Bearer token for authentication |
| `MAX_SESSIONS` | `10` | Maximum concurrent browser sessions |
| `STATE_EXPIRE_DAYS` | `30` | Auto-delete session state older than N days |
| `AGENT_BROWSER_ENCRYPTION_KEY` | (optional) | AES-256-GCM key for encrypting session state |

### Resource guidelines

Each Chromium instance uses ~100-300MB RAM. Plan your `MAX_SESSIONS` and container memory accordingly:

| Sessions | Recommended memory | CPU |
|----------|-------------------|-----|
| 1-5      | 2GB               | 1   |
| 5-10     | 4GB               | 2   |
| 10-20    | 8GB               | 4   |

## Troubleshooting

### "Cannot reach http://localhost:3000"

Your SSH tunnel is not running. Start it:

```bash
ab-remote --tunnel user@your-server
# or manually:
ssh -f -N -L 3000:localhost:3000 user@your-server
```

If port 3000 is taken (e.g., by OrbStack or a dev server), use a different port:

```bash
ab-remote --tunnel user@your-server --port 4100
# then set: export AGENT_BROWSER_REMOTE_URL="http://localhost:4100"
```

### "AGENT_BROWSER_REMOTE_TOKEN is not set"

Add to your shell profile (`~/.zshrc` or `~/.bashrc`):

```bash
export AGENT_BROWSER_REMOTE_TOKEN="your-token-here"
```

Get your token from the server: `ssh user@server 'cat /opt/agent-browser/.env'`

### "401 Unauthorized"

Your token doesn't match the server. Check the server's token:

```bash
ssh user@server 'cat /opt/agent-browser/.env | grep API_TOKEN'
```

### Session commands hang or timeout

The remote Docker container may have stopped:

```bash
ssh user@server 'docker ps | grep agent-browser'
ssh user@server 'cd /opt/agent-browser && docker compose up -d'
```

### Zombie/defunct Chrome processes

Fixed in v1.0.1 by using `tini` as PID 1. If you're on an older version, update:

```bash
ssh user@server 'cd /opt/agent-browser && docker compose pull && docker compose up -d'
```

### Windows support

Use the PowerShell equivalents:
- `scripts/ab-remote.ps1` instead of `scripts/ab-remote`
- `scripts/deploy.ps1` instead of `scripts/deploy.sh`

## Security

| Layer | Measure |
|-------|---------|
| **Network** | Port bound to `127.0.0.1` — not exposed to the internet |
| **Access** | SSH tunnel required for remote access |
| **Auth** | Bearer token with timing-safe comparison |
| **Container** | Non-root user, `no-new-privileges`, all capabilities dropped |
| **Browser** | Sandboxed per-session with `--disable-dev-shm-usage` |
| **State** | Optional AES-256-GCM encryption for saved sessions |
| **IPC** | Unix sockets with mode `0700` (owner-only) |
| **Process** | tini as PID 1 for proper zombie reaping |

## Requirements

- Docker 24+ with Compose v2
- SSH client (for tunnel access)
- curl (for CLI usage)

**For building from source:**
- Node.js 20+
- `docker buildx` (for cross-platform builds from Apple Silicon)

## License

MIT
