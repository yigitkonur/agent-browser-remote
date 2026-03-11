# =============================================================================
# ab-remote.ps1 — CLI wrapper for agent-browser-remote HTTP API (Windows)
#
# Usage:
#   .\ab-remote.ps1 <session> <action> [key=value ...]
#   .\ab-remote.ps1 --sessions | --stop <id> | --health | --help
#
# Environment:
#   $env:AGENT_BROWSER_REMOTE_URL    (default: http://localhost:3000)
#   $env:AGENT_BROWSER_REMOTE_TOKEN  (required)
# =============================================================================
$ErrorActionPreference = "Stop"

$Url     = if ($env:AGENT_BROWSER_REMOTE_URL)   { $env:AGENT_BROWSER_REMOTE_URL }   else { "http://localhost:3000" }
$Token   = $env:AGENT_BROWSER_REMOTE_TOKEN
$Version = "1.0.0"

function Test-Token {
    if (-not $Token) {
        Write-Error 'AGENT_BROWSER_REMOTE_TOKEN is not set. Run: $env:AGENT_BROWSER_REMOTE_TOKEN = "your-token"'
        exit 1
    }
}

function Invoke-Api {
    param(
        [string]$Method = "GET",
        [string]$Path,
        [string]$Body,
        [switch]$NoAuth,
        [int]$Timeout = 30
    )
    $headers = @{ "Content-Type" = "application/json" }
    if (-not $NoAuth) {
        Test-Token
        $headers["Authorization"] = "Bearer $Token"
    }
    $params = @{
        Uri     = "$Url$Path"
        Method  = $Method
        Headers = $headers
        TimeoutSec = $Timeout
    }
    if ($Body) { $params["Body"] = $Body }

    try {
        $response = Invoke-RestMethod @params
        $response | ConvertTo-Json -Depth 10
    } catch {
        $err = $_.Exception
        if ($err.Response) {
            $reader = [System.IO.StreamReader]::new($err.Response.GetResponseStream())
            $errBody = $reader.ReadToEnd()
            Write-Error "HTTP $($err.Response.StatusCode): $errBody"
        } else {
            Write-Error $err.Message
        }
        exit 1
    }
}

function Show-Help {
    @"
ab-remote.ps1 — CLI for agent-browser-remote (Windows)

Usage:
  .\ab-remote.ps1 <session> <action> [key=value ...]

Examples:
  .\ab-remote.ps1 task-1 navigate url=https://example.com
  .\ab-remote.ps1 task-1 snapshot
  .\ab-remote.ps1 task-1 click selector=@e2
  .\ab-remote.ps1 task-1 fill selector=@e5 value="hello world"

Session management:
  .\ab-remote.ps1 --sessions              List active sessions
  .\ab-remote.ps1 --create <name>         Create a session
  .\ab-remote.ps1 --stop <name>           Stop a session

Other:
  .\ab-remote.ps1 --health                Health check
  .\ab-remote.ps1 --version               Show version
  .\ab-remote.ps1 --help                  Show this help

Environment:
  `$env:AGENT_BROWSER_REMOTE_URL          Default: http://localhost:3000
  `$env:AGENT_BROWSER_REMOTE_TOKEN        Required for authenticated commands
"@
}

# ---------- Dispatch ----------
$cmd = $args[0]

switch ($cmd) {
    { $_ -in "--help", "-h" }  { Show-Help; return }
    { $_ -in "--version", "-v" } { "ab-remote $Version"; return }
    "--health"   { Invoke-Api -Path "/health" -NoAuth; return }
    "--sessions" { Invoke-Api -Path "/sessions"; return }
    "--create" {
        $name = $args[1]
        if (-not $name) { Write-Error "Usage: .\ab-remote.ps1 --create <session-name>"; exit 1 }
        Invoke-Api -Method POST -Path "/sessions" -Body "{`"session`":`"$name`"}" -Timeout 30
        return
    }
    "--stop" {
        $name = $args[1]
        if (-not $name) { Write-Error "Usage: .\ab-remote.ps1 --stop <session-name>"; exit 1 }
        Invoke-Api -Method DELETE -Path "/sessions/$name" -Timeout 30
        return
    }
    default {
        if (-not $cmd -or $cmd.StartsWith("-")) {
            if (-not $cmd) { Show-Help } else { Write-Error "Unknown flag: $cmd" }
            exit 1
        }

        # <session> <action> [key=value ...]
        $session = $args[0]
        $action  = $args[1]
        if (-not $action) { Write-Error "Usage: .\ab-remote.ps1 <session> <action> [key=value ...]"; exit 1 }

        # Validate session name
        if ($session -notmatch '^[a-zA-Z0-9_-]+$') {
            Write-Error "Invalid session name: '$session'. Use letters, numbers, hyphens, underscores."
            exit 1
        }

        # Build JSON from key=value pairs
        $obj = @{ action = $action }
        for ($i = 2; $i -lt $args.Count; $i++) {
            $kv = $args[$i]
            $eqIdx = $kv.IndexOf("=")
            if ($eqIdx -lt 1) { Write-Error "Invalid argument: '$kv'. Use key=value format."; exit 1 }
            $key = $kv.Substring(0, $eqIdx)
            $val = $kv.Substring($eqIdx + 1)

            # Type detection
            if ($val -match '^-?\d+(\.\d+)?$') {
                $obj[$key] = [double]$val
            } elseif ($val -eq "true") {
                $obj[$key] = $true
            } elseif ($val -eq "false") {
                $obj[$key] = $false
            } else {
                $obj[$key] = $val
            }
        }

        $body = $obj | ConvertTo-Json -Compress
        Invoke-Api -Method POST -Path "/sessions/$session/command" -Body $body -Timeout 60
    }
}
