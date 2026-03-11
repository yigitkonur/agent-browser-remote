# agent-browser-remote

Run [agent-browser](https://github.com/vercel-labs/agent-browser) as a remote, multi-session Docker service. One container, multiple isolated browser sessions, accessible via a simple HTTP API.

```
Local machine ──HTTP──▶ SSH tunnel ──▶ Docker container
                                         ├── Session "task-1" → Chromium
                                         ├── Session "task-2" → Chromium
                                         └── Session "task-3" → Chromium
```

## Why

- **Offload browsers from your machine** — run Chromium on a remote server
- **Multiple isolated sessions** — each session gets its own browser instance with separate cookies, state, and refs
- **AI-agent friendly** — same compact snapshot/ref workflow as local agent-browser, over HTTP
- **Secure** — Bearer token auth, localhost-only binding, access via SSH tunnel

## Quick Start

### 1. Clone and build

```bash
git clone https://github.com/yigitkonur/agent-browser-remote.git
cd agent-browser-remote

# Install API server dependencies and build
cd api-server && npm install && npm run build && cd ..

# Build Docker image
docker compose build
```

### 2. Configure

```bash
# Generate an API token
openssl rand -hex 32

# Create .env file
cp .env.example .env
# Edit .env and paste your token
```

### 3. Run locally

```bash
docker compose up -d

# Test
curl http://localhost:3000/health
# → {"status":"ok","sessions":0,"uptime":5}
```

### 4. Deploy to a remote server

Edit `scripts/deploy.sh` and set your server address, then:

```bash
./scripts/deploy.sh
```

Or deploy manually:

```bash
# Build for linux/amd64 (if your local machine is ARM)
docker buildx build --platform linux/amd64 --tag agent-browser-api:latest --load .

# Transfer image
docker save agent-browser-api:latest | gzip | ssh user@server "gunzip | sudo docker load"

# Copy files
scp docker-compose.yml .env user@server:/opt/agent-browser/

# Start
ssh user@server "cd /opt/agent-browser && sudo docker compose up -d"
```

### 5. Connect via SSH tunnel

```bash
ssh -N -L 3000:localhost:3000 user@server
```

Now `http://localhost:3000` routes to your remote agent-browser.

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

# Stop a session (closes browser, saves state)
curl -X DELETE http://localhost:3000/sessions/my-task \
  -H "Authorization: Bearer $TOKEN"
```

### All supported actions

Every [agent-browser command](https://github.com/vercel-labs/agent-browser) works as an action:

| Category | Actions |
|----------|---------|
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

The API wraps this into agent-browser's internal protocol, sends it to the session daemon, and returns the response.

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

## Configuration

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `API_TOKEN` | (required) | Bearer token for authentication |
| `MAX_SESSIONS` | `10` | Maximum concurrent browser sessions |
| `STATE_EXPIRE_DAYS` | `30` | Auto-delete session state older than N days |
| `AGENT_BROWSER_ENCRYPTION_KEY` | (optional) | AES-256-GCM key for encrypting session state |

### Docker Compose settings

The default `docker-compose.yml` includes:

- **Port**: `127.0.0.1:3000:3000` (localhost-only)
- **Memory limit**: 4GB
- **CPU limit**: 2 cores
- **Shared memory**: 2GB (required for Chromium)
- **Persistent volume**: `ab_data` for session state across restarts
- **Security**: `no-new-privileges`, all capabilities dropped

Adjust resource limits based on your expected session count. Each Chromium instance uses ~100-300MB.

### Deploy script configuration

Edit `scripts/deploy.sh` or override via environment:

```bash
DEPLOY_SERVER=user@your-server DEPLOY_DIR=/opt/agent-browser ./scripts/deploy.sh
```

## Connecting agent-browser CLI to the Remote Server

You can also point your **local** `agent-browser` CLI at the remote Chromium instances via CDP. This gives you the full CLI experience while the browser runs remotely.

### Option 1: Use the HTTP API directly

This is the primary method. All commands go through the REST API as shown above.

### Option 2: SSH + remote CLI execution

Run agent-browser commands directly on the server:

```bash
ssh user@server "docker exec agent-browser node -e \"
  const net = require('net');
  const sock = net.createConnection('/data/sockets/my-session.sock');
  sock.write(JSON.stringify({id:'1',action:'snapshot'}) + '\n');
  sock.on('data', d => { process.stdout.write(d); sock.destroy(); });
\""
```

### Option 3: Configure as a system-wide remote browser

Add to your shell profile (`~/.zshrc` or `~/.bashrc`):

```bash
# Remote agent-browser via SSH tunnel
# Start tunnel: ssh -N -L 3000:localhost:3000 user@server
export AGENT_BROWSER_REMOTE_URL="http://localhost:3000"
export AGENT_BROWSER_REMOTE_TOKEN="your-token"
```

Then use a wrapper script (see `scripts/ab-remote` in this repo).

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
- Node.js 20+ (for building the API server)
- `docker buildx` (for cross-platform builds from Apple Silicon)

## License

MIT
