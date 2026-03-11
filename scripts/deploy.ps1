# =============================================================================
# deploy.ps1 — Deploy agent-browser-remote to a remote server (Windows)
#
# Usage:
#   $env:DEPLOY_SERVER = "user@host"
#   .\scripts\deploy.ps1                          # deploy via GHCR pull
#   $env:DEPLOY_MODE = "build"
#   .\scripts\deploy.ps1                          # build + transfer
#
# Environment:
#   DEPLOY_SERVER  (required)  SSH target, e.g. user@your-server
#   DEPLOY_DIR     (optional)  Remote install dir (default: /opt/agent-browser)
#   DEPLOY_MODE    (optional)  "pull" (default) or "build"
#   DEPLOY_PORT    (optional)  Host port to bind (default: 3000)
# =============================================================================
$ErrorActionPreference = "Stop"

# ---------- Config ----------
$Server    = $env:DEPLOY_SERVER
$RemoteDir = if ($env:DEPLOY_DIR)  { $env:DEPLOY_DIR }  else { "/opt/agent-browser" }
$Mode      = if ($env:DEPLOY_MODE) { $env:DEPLOY_MODE } else { "pull" }
$HostPort  = if ($env:DEPLOY_PORT) { $env:DEPLOY_PORT } else { "3000" }
$Image     = "ghcr.io/yigitkonur/agent-browser-remote:latest"
$LocalTag  = "agent-browser-remote:local-build"

if (-not $Server) {
    Write-Error "DEPLOY_SERVER is not set. Example: `$env:DEPLOY_SERVER = 'user@your-server'"
    exit 1
}

function Info  { param($msg) Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $msg" -ForegroundColor Cyan }
function Ok    { param($msg) Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $msg" -ForegroundColor Green }

# ---------- Preflight ----------
foreach ($cmd in @("ssh", "docker")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Error "$cmd not found in PATH"
        exit 1
    }
}

Info "=== agent-browser-remote deploy ==="
Info "Server:  $Server"
Info "Dir:     $RemoteDir"
Info "Mode:    $Mode"
Info "Port:    $HostPort"
Write-Host ""

# ---------- Step 1: Build TypeScript ----------
if ($Mode -eq "build") {
    Info "[1/5] Building API server TypeScript..."
    Push-Location "$PSScriptRoot\..\api-server"
    npm ci
    npm run build
    Pop-Location
} else {
    Info "[1/3] Skipping local build (pull mode)"
}

# ---------- Step 2: Get image to server ----------
if ($Mode -eq "build") {
    Info "[2/5] Building Docker image for linux/amd64..."
    docker buildx build --platform linux/amd64 --tag $LocalTag --load "$PSScriptRoot\.."

    Info "[3/5] Transferring image to server..."
    # Use gzip for faster transfer (requires gzip on Windows PATH or WSL)
    if (Get-Command gzip -ErrorAction SilentlyContinue) {
        docker save $LocalTag | gzip | ssh $Server "gunzip | sudo docker load"
    } else {
        docker save $LocalTag | ssh $Server "sudo docker load"
    }
    # Re-tag on server so compose can find it
    ssh $Server "sudo docker tag $LocalTag $Image"
} else {
    Info "[2/3] Pulling image on server from GHCR..."
    ssh $Server "sudo docker pull $Image"
}

# ---------- Step 3: Sync configuration ----------
$StepSync  = if ($Mode -eq "build") { "4/5" } else { "3/3" }
$StepStart = if ($Mode -eq "build") { "5/5" } else { "3/3" }

Info "[$StepSync] Syncing configuration..."
ssh $Server "sudo mkdir -p $RemoteDir && sudo chown `$(whoami) $RemoteDir"

# Generate compose file locally then SCP
$ComposeContent = @"
services:
  agent-browser:
    image: $Image
    container_name: agent-browser
    restart: unless-stopped
    ports:
      - "127.0.0.1:${HostPort}:3000"
    environment:
      API_TOKEN: `$`{API_TOKEN`}
      AGENT_BROWSER_ENCRYPTION_KEY: `$`{AGENT_BROWSER_ENCRYPTION_KEY:-`}
      AGENT_BROWSER_SOCKET_DIR: /data/sockets
      AGENT_BROWSER_ARGS: "--no-sandbox,--disable-dev-shm-usage,--disable-setuid-sandbox,--disable-gpu"
      AGENT_BROWSER_STATE_EXPIRE_DAYS: `$`{STATE_EXPIRE_DAYS:-30`}
      MAX_SESSIONS: `$`{MAX_SESSIONS:-10`}
      NODE_ENV: production
    volumes:
      - ab_data:/data
    shm_size: "2gb"
    deploy:
      resources:
        limits:
          memory: 4G
          cpus: "2.0"
        reservations:
          memory: 512M
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL

volumes:
  ab_data:
"@

$TmpFile = [System.IO.Path]::GetTempFileName()
$ComposeContent | Out-File -FilePath $TmpFile -Encoding UTF8 -NoNewline
scp $TmpFile "${Server}:${RemoteDir}/docker-compose.yml"
Remove-Item $TmpFile -ErrorAction SilentlyContinue

# Create .env if it doesn't exist on remote
ssh $Server "test -f $RemoteDir/.env || { TOKEN=`$(openssl rand -hex 32); printf 'API_TOKEN=%s\nMAX_SESSIONS=10\nSTATE_EXPIRE_DAYS=30\n' `"`$TOKEN`" > $RemoteDir/.env; echo `"Generated new API token: `$TOKEN`"; }"

# ---------- Step 4: Start service ----------
Info "[$StepStart] Starting service..."
ssh $Server "cd $RemoteDir && sudo docker compose up -d --pull never"

Ok ""
Ok "=== Deploy complete ==="
Ok "Service running on $Server (port $HostPort, localhost-bound)"
Ok ""
Ok "Next steps:"
Ok "  1. Note the API token: ssh $Server 'cat $RemoteDir/.env'"
Ok "  2. Open SSH tunnel:    ssh -N -L ${HostPort}:localhost:${HostPort} $Server"
Ok "  3. Test:               curl http://localhost:${HostPort}/health"
