import { spawn, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const SOCKET_DIR = process.env.AGENT_BROWSER_SOCKET_DIR ?? "/data/sockets";
const MAX_SESSIONS = parseInt(process.env.MAX_SESSIONS ?? "10", 10);
const DAEMON_PATH = getDaemonPath();

// Session name validation: only alphanumeric, underscore, hyphen
const SESSION_RE = /^[a-zA-Z0-9_-]+$/;

interface TrackedSession {
  pid: number;
  child: ChildProcess | null; // null if discovered from existing PID file
}

const sessions = new Map<string, TrackedSession>();

function getDaemonPath(): string {
  // In Docker: global install at /usr/local/lib/node_modules/agent-browser/dist/daemon.js
  // or /usr/lib/node_modules/agent-browser/dist/daemon.js
  const candidates = [
    "/usr/local/lib/node_modules/agent-browser/dist/daemon.js",
    "/usr/lib/node_modules/agent-browser/dist/daemon.js",
  ];
  for (const p of candidates) {
    if (fs.existsSync(p)) return p;
  }
  // Fallback: resolve via import.meta.resolve (ESM-compatible)
  try {
    const resolved = import.meta.resolve("agent-browser/dist/daemon.js");
    return new URL(resolved).pathname;
  } catch {
    return candidates[0]; // will fail at spawn time with a clear error
  }
}

export function isValidSessionName(name: string): boolean {
  return SESSION_RE.test(name) && name.length > 0 && name.length <= 64;
}

function socketPath(id: string): string {
  return path.join(SOCKET_DIR, `${id}.sock`);
}

function pidPath(id: string): string {
  return path.join(SOCKET_DIR, `${id}.pid`);
}

function isProcessAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

/** Check if a daemon is running for a session by reading its PID file. */
function checkDaemonAlive(id: string): boolean {
  const pf = pidPath(id);
  if (!fs.existsSync(pf)) return false;
  try {
    const pid = parseInt(fs.readFileSync(pf, "utf8").trim(), 10);
    if (isNaN(pid)) return false;
    if (isProcessAlive(pid)) {
      // Track it if not already tracked
      if (!sessions.has(id)) {
        sessions.set(id, { pid, child: null });
      }
      return true;
    }
  } catch {
    // PID file unreadable
  }
  // Stale — clean up
  try {
    fs.unlinkSync(pf);
  } catch {}
  try {
    fs.unlinkSync(socketPath(id));
  } catch {}
  sessions.delete(id);
  return false;
}

/** Wait for a file to appear on disk. */
async function waitForFile(
  filePath: string,
  timeoutMs = 15_000,
  intervalMs = 100
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (fs.existsSync(filePath)) return;
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  throw new Error(`Timeout waiting for ${filePath}`);
}

/** Ensure a daemon is running for the given session. Spawns one if not. */
export async function ensureSession(id: string): Promise<void> {
  if (checkDaemonAlive(id)) return;

  // Enforce max sessions
  const liveCount = listSessions().length;
  if (liveCount >= MAX_SESSIONS) {
    throw new Error(
      `Max sessions (${MAX_SESSIONS}) reached. Close a session first.`
    );
  }

  // Ensure socket dir exists with owner-only permissions
  fs.mkdirSync(SOCKET_DIR, { recursive: true, mode: 0o700 });

  const child = spawn("node", [DAEMON_PATH], {
    env: {
      ...process.env,
      AGENT_BROWSER_SESSION: id,
      AGENT_BROWSER_SOCKET_DIR: SOCKET_DIR,
      AGENT_BROWSER_DAEMON: "1",
    },
    stdio: "ignore",
    detached: true,
  });

  child.unref();

  // Wait for PID file to appear (daemon writes it before listening)
  await waitForFile(pidPath(id), 15_000);

  const pid = parseInt(fs.readFileSync(pidPath(id), "utf8").trim(), 10);
  sessions.set(id, { pid, child });

  // Wait for socket to appear
  await waitForFile(socketPath(id), 15_000);
}

/** Stop a session daemon. */
export async function stopSession(id: string): Promise<boolean> {
  const tracked = sessions.get(id);
  if (!tracked && !checkDaemonAlive(id)) return false;

  const entry = sessions.get(id);
  if (!entry) return false;

  // Send SIGTERM
  try {
    process.kill(entry.pid, "SIGTERM");
  } catch {
    // Already dead
    sessions.delete(id);
    return true;
  }

  // Wait up to 5s for process to exit
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    if (!isProcessAlive(entry.pid)) break;
    await new Promise((r) => setTimeout(r, 200));
  }

  // Force kill if still alive
  if (isProcessAlive(entry.pid)) {
    try {
      process.kill(entry.pid, "SIGKILL");
    } catch {}
  }

  sessions.delete(id);

  // Clean up stale files
  for (const f of [socketPath(id), pidPath(id)]) {
    try {
      fs.unlinkSync(f);
    } catch {}
  }

  return true;
}

/** List all live sessions. */
export function listSessions(): { id: string; pid: number; alive: boolean }[] {
  const result: { id: string; pid: number; alive: boolean }[] = [];

  // Scan PID files on disk (catches sessions from previous container runs)
  try {
    const files = fs.readdirSync(SOCKET_DIR);
    for (const f of files) {
      if (!f.endsWith(".pid")) continue;
      const id = f.replace(".pid", "");
      if (!isValidSessionName(id)) continue;

      const pf = path.join(SOCKET_DIR, f);
      try {
        const pid = parseInt(fs.readFileSync(pf, "utf8").trim(), 10);
        if (isNaN(pid)) continue;
        const alive = isProcessAlive(pid);
        if (alive) {
          if (!sessions.has(id)) {
            sessions.set(id, { pid, child: null });
          }
          result.push({ id, pid, alive: true });
        } else {
          // Stale — clean up
          try {
            fs.unlinkSync(pf);
          } catch {}
          try {
            fs.unlinkSync(socketPath(id));
          } catch {}
          sessions.delete(id);
        }
      } catch {
        // Unreadable PID file
      }
    }
  } catch {
    // Socket dir doesn't exist yet
  }

  return result;
}

/** Gracefully stop all sessions (for container shutdown). */
export async function stopAll(): Promise<void> {
  const live = listSessions();
  await Promise.allSettled(live.map((s) => stopSession(s.id)));
}
