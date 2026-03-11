# agent-browser-remote

Run [agent-browser](https://github.com/vercel-labs/agent-browser) as a remote, multi-session Docker service. One container, multiple isolated browser sessions, accessible via a simple HTTP API.

```
Local machine ──HTTP──> SSH tunnel ──> Docker container
                                        ├── Session "task-1" → Chromium
                                        ├── Session "task-2" → Chromium
                                        └── Session "task-3" → Chromium
```

## Why

- **Offload browsers from your machine** — run Chromium on a remote server
- **Multiple isolated sessions** — each session gets its own browser instance with separate cookies, state, and refs
- **AI-agent friendly** — same compact snapshot/ref workflow as local agent-browser, over HTTP
- **Secure** — Bearer token auth, localhost-only binding, access via SSH tunnel
- **Easy install** — one command to set up, pre-built images on GitHub Container Registry

## Quick Start

### Option A: One-command server setup

SSH into your server and run:

```bash
curl -fsSL https://raw.githubusercontent.com/yigitkonur/agent-browser-remote/main/scripts/setup.sh | sudo bash
```

Or with custom options:

```bash
curl -fsSL https://raw.githubusercontent.com/yigitkonur/agent-browser-remote/main/scripts/setup.sh | \
  INSTALL_DIR=/opt/agent-browser PORT=3000 sudo bash
```

> **Note:** `sudo` is needed because the default install directory (`/opt/agent-browser`) requires root to create. The script automatically sets file ownership to your user so you can edit config without sudo later.

The script will pull the image, generate an API token, and start the service.

### Option B: Manual setup

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

### Option C: Build from source

```bash
git clone https://github.com/yigitkonur/agent-browser-remote.git
cd agent-browser-remote

# Build the API server
cd api-server && npm install && npm run build && cd ..

# Build and run (use both compose files so the local build is used)
docker compose -f docker-compose.yml -f docker-compose.build.yml build
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d
```

## Connect from your local machine

The service binds to `127.0.0.1` only — it's not exposed to the internet. Access it via SSH tunnel:

```bash
ssh -N -L 3000:localhost:3000 user@your-server
```

Now `http://localhost:3000` on your machine routes to the remote service.

**Tip:** If port 3000 is already in use (e.g., by a dev server), pick a different local port:

```bash
ssh -N -L 4100:localhost:3000 user@your-server
```

Then set `AGENT_BROWSER_REMOTE_URL=http://localhost:4100` for the `ab-remote` CLI.

**Tip:** Add to `~/.ssh/config` for convenience:

```
Host agent-browser
    HostName your-server-ip
    User your-user
    LocalForward 3000 localhost:3000
```

Then just `ssh -N agent-browser`.

## Usage

All endpoints except `/health` require `Authorization: Bearer <token>`.

### Navigate and snapshot

```bash
TOKEN="your-token-here"

# Navigate (auto-creates session + browser on first command)
curl -X POST http://localhost:3000/sessions/my-task/command \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"action": "navigate", "url": "https://example.com"}'
# → {"success":true,"data":{"url":"https://example.com/","title":"Example Domain"}}

# Snapshot — get accessibility tree with refs
curl -X POST http://localhost:3000/sessions/my-task/command \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"action": "snapshot"}'
# → {"success":true,"data":{"snapshot":"- heading \"Example Domain\" [ref=e1]..."}}

# Click using ref
curl -X POST http://localhost:3000/sessions/my-task/command \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"action": "click", "selector": "@e2"}'

# Fill a form field
curl -X POST http://localhost:3000/sessions/my-task/command \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"action": "fill", "selector": "@e5", "value": "search query"}'
```

### Session management

```bash
# List active sessions
curl -H "Authorization: Bearer $TOKEN" http://localhost:3000/sessions
# → {"sessions":[{"id":"my-task","pid":22,"alive":true}]}

# Create a session explicitly
curl -X POST http://localhost:3000/sessions \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"session": "scraper-1"}'
# → {"session":"scraper-1","status":"ready"}

# Stop a session (closes browser, saves state)
curl -X DELETE http://localhost:3000/sessions/my-task \
  -H "Authorization: Bearer $TOKEN"
# → {"session":"my-task","status":"stopped"}
```

### CLI wrapper (ab-remote)

For a shell-friendly experience, use the included `ab-remote` script:

**macOS / Linux:**

```bash
# Add to your shell profile (~/.zshrc or ~/.bashrc)
export AGENT_BROWSER_REMOTE_TOKEN="your-token-here"
export AGENT_BROWSER_REMOTE_URL="http://localhost:3000"  # change port if using a custom tunnel
export PATH="/path/to/agent-browser-remote/scripts:$PATH"

# Use it
ab-remote my-task navigate url=https://example.com
ab-remote my-task snapshot
ab-remote my-task click selector=@e2
ab-remote my-task fill selector=@e5 value="hello world"
ab-remote --sessions
ab-remote --create scraper-1
ab-remote --stop my-task
ab-remote --health
ab-remote --version
```

**Windows (PowerShell):**

```powershell
# Set token (or add to your PowerShell profile)
$env:AGENT_BROWSER_REMOTE_TOKEN = "your-token-here"
$env:AGENT_BROWSER_REMOTE_URL = "http://localhost:3000"  # change port if using a custom tunnel

# Add scripts to PATH (optional)
$env:PATH += ";C:\path\to\agent-browser-remote\scripts"

# Use it
.\scripts\ab-remote.ps1 my-task navigate url=https://example.com
.\scripts\ab-remote.ps1 my-task snapshot
.\scripts\ab-remote.ps1 my-task click selector=@e2
.\scripts\ab-remote.ps1 --sessions
.\scripts\ab-remote.ps1 --create scraper-1
.\scripts\ab-remote.ps1 --stop my-task
.\scripts\ab-remote.ps1 --health
```

### All supported actions

Every [agent-browser command](https://github.com/vercel-labs/agent-browser) works as an action:

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

## API Reference

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
└──────────────────────────────────────────────────┘
```

Each session runs its own `agent-browser` daemon process with a dedicated Chromium instance. Sessions are fully isolated — separate cookies, localStorage, and browsing context.

The API server communicates with daemons via Unix sockets using agent-browser's native JSON-over-newline protocol. Daemons are spawned on-demand when the first command arrives for a session.

## Docker Image

Pre-built images are available on GitHub Container Registry for both `linux/amd64` and `linux/arm64`:

```bash
docker pull ghcr.io/yigitkonur/agent-browser-remote:latest
```

Tagged releases are also available:

```bash
docker pull ghcr.io/yigitkonur/agent-browser-remote:1.0.0
```

## Configuration

### Environment variables

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

### Docker Compose settings

The default `docker-compose.yml` includes:

- **Port**: `127.0.0.1:3000:3000` (localhost-only)
- **Memory limit**: 4GB
- **CPU limit**: 2 cores
- **Shared memory**: 2GB (required for Chromium)
- **Persistent volume**: `ab_data` for session state across restarts
- **Security**: `no-new-privileges`, all capabilities dropped

## Deploying to a Remote Server

### From your local machine

**macOS / Linux:**

```bash
DEPLOY_SERVER=user@your-server ./scripts/deploy.sh
```

**Windows (PowerShell):**

```powershell
$env:DEPLOY_SERVER = "user@your-server"
.\scripts\deploy.ps1
```

The deploy script will pull the image on the server (or build and transfer if `DEPLOY_MODE=build`), sync configuration, and start the service.

| Variable | Default | Description |
|----------|---------|-------------|
| `DEPLOY_SERVER` | (required) | SSH target, e.g. `user@your-server` |
| `DEPLOY_DIR` | `/opt/agent-browser` | Remote install directory |
| `DEPLOY_MODE` | `pull` | `pull` (from GHCR) or `build` (local build + transfer) |
| `DEPLOY_PORT` | `3000` | Host port to bind on the remote server |

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

## Requirements

- Docker 24+ with Compose v2
- SSH client (for tunnel access)
- curl (for CLI usage)

**For building from source:**
- Node.js 20+
- `docker buildx` (for cross-platform builds from Apple Silicon)

## License

MIT
