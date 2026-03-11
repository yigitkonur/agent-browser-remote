# agent-browser-remote

Remote, multi-session browser automation over HTTP. One Docker container on a remote server, multiple isolated browser sessions (Chrome or Lightpanda), accessible via `ab-remote` CLI or raw HTTP API.

## Architecture

```
Local machine ──HTTP──> SSH tunnel ──> Docker container (remote server)
                                        ├── Session "task-1" → Chromium (default)
                                        ├── Session "task-2" → Chromium
                                        └── Session "task-3" → Lightpanda (10x faster)
```

- API server: Hono (Node.js), port 3000, Bearer token auth
- Each session: isolated daemon process + browser instance (Chrome or Lightpanda) + Unix socket
- Engine selection: per-session via `engine` field (default: `chrome`)
- IPC: JSON-over-newline protocol on Unix sockets
- State: persisted to `/data/sessions/` in container, optional AES-256-GCM encryption

## For AI Agents: How to Use agent-browser-remote

### Connection Setup

The service runs on a remote server. You access it via SSH tunnel:

```bash
# 1. Start SSH tunnel (skip if already running)
ssh -f -N -L 4100:localhost:3000 ubuntu@195.154.103.43

# 2. Set environment
export AGENT_BROWSER_REMOTE_URL="http://localhost:4100"
export AGENT_BROWSER_REMOTE_TOKEN="<token>"
```

### Core Workflow: Navigate → Snapshot → Act

Every browser interaction follows this pattern:

1. **Navigate** to a URL
2. **Snapshot** to get the accessibility tree with `[ref=eN]` markers
3. **Click/Fill/etc.** using `@eN` selectors from the snapshot
4. **Snapshot again** to see the result

```bash
# Navigate
ab-remote task-1 navigate url=https://example.com

# Get accessibility tree (this is your "eyes")
ab-remote task-1 snapshot
# Returns: - heading "Example Domain" [ref=e1]
#          - link "More information..." [ref=e2]

# Click using ref
ab-remote task-1 click selector=@e2

# See what happened
ab-remote task-1 snapshot
```

### Using ab-remote CLI

```bash
# Browser actions
ab-remote <session> navigate url=https://example.com
ab-remote <session> snapshot
ab-remote <session> click selector=@e3
ab-remote <session> fill selector=@e5 value="search query"
ab-remote <session> type text="hello"
ab-remote <session> press key=Enter
ab-remote <session> screenshot          # base64 PNG
ab-remote <session> scroll direction=down amount=500
ab-remote <session> back
ab-remote <session> forward
ab-remote <session> eval expression="document.title"

# Session management
ab-remote --sessions                    # list active sessions
ab-remote --create my-task              # create session explicitly
ab-remote --stop my-task                # close session + browser
ab-remote --health                      # check service status

# Sessions auto-create on first command — you don't need --create

# Use Lightpanda (10x faster, 10x less memory, headless only)
ab-remote --create fast-task --engine lightpanda
ab-remote fast-task navigate url=https://example.com
ab-remote fast-task snapshot

# Or set engine on first command (auto-creates with that engine)
ab-remote fast-task navigate url=https://example.com --engine lightpanda
```

### Using Raw HTTP API (curl)

```bash
TOKEN="your-token"
URL="http://localhost:4100"

# Navigate
curl -X POST "$URL/sessions/task-1/command" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"action": "navigate", "url": "https://example.com"}'

# Snapshot
curl -X POST "$URL/sessions/task-1/command" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"action": "snapshot"}'

# Click
curl -X POST "$URL/sessions/task-1/command" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"action": "click", "selector": "@e2"}'
```

### Tips for AI Agents

1. **Always snapshot after navigation or interaction** — it's your only way to see the page
2. **Use refs (`@eN`) from the LATEST snapshot** — refs change between snapshots
3. **Sessions are isolated** — `task-1` and `task-2` have completely separate browsers
4. **Sessions persist** — browser state (cookies, localStorage) survives across commands
5. **Sessions auto-create** — just send a command to any session name, no need to create first
6. **One command at a time** — commands within a session are serialized; don't fire in parallel
7. **Use meaningful session names** — `research-flights`, `check-prices`, not `session-1`
8. **Clean up when done** — `ab-remote --stop <session>` frees server memory
9. **Use Lightpanda for speed** — `--engine lightpanda` is 10x faster and uses 10x less memory, great for scraping and data extraction. Use Chrome (default) when you need full fidelity, screenshots, extensions, or persistent profiles

### Available Actions

| Category | Actions |
|-------------|---------|
| **Navigation** | `navigate`, `back`, `forward`, `reload`, `url`, `title` |
| **Interaction** | `click`, `fill`, `type`, `press`, `hover`, `select`, `check`, `uncheck`, `scroll`, `focus`, `clear`, `upload`, `drag`, `dblclick` |
| **Observation** | `snapshot`, `screenshot`, `eval`, `gettext`, `getattribute`, `isvisible`, `isenabled`, `ischecked`, `count` |
| **State** | `cookies_get`, `cookies_set`, `cookies_clear`, `storage_get`, `storage_set`, `storage_clear` |
| **Tabs** | `tab_new`, `tab_list`, `tab_close` |
| **Emulation** | `viewport`, `device`, `geolocation`, `useragent` |
| **Network** | `route`, `unroute`, `requests` |
| **Other** | `pdf`, `dialog`, `permissions` |

## Development

### Building the API server

```bash
cd api-server
npm install
npm run build    # TypeScript → dist/
```

### Building Docker image locally

```bash
docker compose -f docker-compose.yml -f docker-compose.build.yml build
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d
```

### Deploying to remote server

```bash
# Pull mode (fast, uses pre-built image from GHCR)
DEPLOY_SERVER=ubuntu@195.154.103.43 ./scripts/deploy.sh

# Build mode (local build + transfer)
DEPLOY_SERVER=ubuntu@195.154.103.43 DEPLOY_MODE=build ./scripts/deploy.sh
```

### Key files

| File | Purpose |
|------|---------|
| `api-server/src/server.ts` | HTTP API routes (Hono) |
| `api-server/src/sessions.ts` | Session lifecycle (spawn/stop daemons) |
| `api-server/src/proxy.ts` | Unix socket IPC with daemon processes |
| `api-server/src/auth.ts` | Bearer token middleware (timing-safe) |
| `Dockerfile` | Container image (node:24-slim + Chromium + Lightpanda + tini) |
| `scripts/setup.sh` | One-command server setup |
| `scripts/client-setup.sh` | One-command client setup |
| `scripts/ab-remote` | CLI wrapper (Bash) |
| `scripts/deploy.sh` | Deployment script |

### Environment variables

| Variable | Where | Description |
|----------|-------|-------------|
| `API_TOKEN` | Server (.env) | Bearer token for auth |
| `MAX_SESSIONS` | Server (.env) | Max concurrent sessions (default: 10) |
| `STATE_EXPIRE_DAYS` | Server (.env) | Session state TTL (default: 30) |
| `AGENT_BROWSER_REMOTE_URL` | Client (shell) | API URL (default: http://localhost:3000) |
| `AGENT_BROWSER_REMOTE_TOKEN` | Client (shell) | API token |
