import { spawn, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { startLp, stopLp, isLpAlive } from "./lightpanda.js";

const SOCKET_DIR = process.env.AGENT_BROWSER_SOCKET_DIR ?? "/data/sockets";
const MAX_SESSIONS = parseInt(process.env.MAX_SESSIONS ?? "10", 10);
const DAEMON_PATH = getDaemonPath();

// Session name validation: only alphanumeric, underscore, hyphen
const SESSION_RE = /^[a-zA-Z0-9_-]+$/;

export type Engine = "chrome" | "lightpanda";

interface TrackedSession {
  pid: number;
  child: ChildProcess | null; // null if discovered from existing PID file
  engine: Engine;
}

const sessions = new Map<string, TrackedSession>();

function getDaemonPath(): string {
  const candidates = [
    "/usr/local/lib/node_modules/agent-browser/dist/daemon.js",
    "/usr/lib/node_modules/agent-browser/dist/daemon.js",
  ];
  for (const p of candidates) {
    if (fs.existsSync(p)) return p;
  }
  try {
    const resolved = import.meta.resolve("agent-browser/dist/daemon.js");
    return new URL(resolved).pathname;
  } catch {
    return candidates[0];
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

function enginePath(id: string): string {
  return path.join(SOCKET_DIR, `${id}.engine`);
}

function isProcessAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

/** Read persisted engine for a session, defaulting to "chrome". */
function readEngine(id: string): Engine {
  try {
    const e = fs.readFileSync(enginePath(id), "utf8").trim();
    if (e === "lightpanda") return "lightpanda";
  } catch {}
  return "chrome";
}

/** Check if a daemon is running for a session by reading its PID file. */
function checkDaemonAlive(id: string): boolean {
  // For Lightpanda, use the LP module's check
  if (readEngine(id) === "lightpanda") {
    if (isLpAlive(id)) {
      if (!sessions.has(id)) {
        try {
          const pid = parseInt(
            fs.readFileSync(pidPath(id), "utf8").trim(),
            10
          );
          sessions.set(id, { pid, child: null, engine: "lightpanda" });
        } catch {}
      }
      return true;
    }
    sessions.delete(id);
    return false;
  }

  // Chrome: check PID file
  const pf = pidPath(id);
  if (!fs.existsSync(pf)) return false;
  try {
    const pid = parseInt(fs.readFileSync(pf, "utf8").trim(), 10);
    if (isNaN(pid)) return false;
    if (isProcessAlive(pid)) {
      if (!sessions.has(id)) {
        sessions.set(id, { pid, child: null, engine: "chrome" });
      }
      return true;
    }
  } catch {}

  // Stale — clean up
  for (const f of [pf, socketPath(id), enginePath(id)]) {
    try {
      fs.unlinkSync(f);
    } catch {}
  }
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
export async function ensureSession(
  id: string,
  engine: Engine = "chrome"
): Promise<void> {
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

  if (engine === "lightpanda") {
    // Lightpanda: spawn via the LP module (lightpanda serve)
    const { pid } = await startLp(id);
    sessions.set(id, { pid, child: null, engine: "lightpanda" });
    return;
  }

  // Chrome: use the Node.js daemon with Playwright
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

  // Wait for PID file to appear
  await waitForFile(pidPath(id), 15_000);
  const pid = parseInt(fs.readFileSync(pidPath(id), "utf8").trim(), 10);
  fs.writeFileSync(enginePath(id), engine, "utf8");
  sessions.set(id, { pid, child, engine });

  // Wait for socket to appear
  await waitForFile(socketPath(id), 15_000);
}

/** Stop a session daemon. */
export async function stopSession(id: string): Promise<boolean> {
  const tracked = sessions.get(id);
  if (!tracked && !checkDaemonAlive(id)) return false;

  const entry = sessions.get(id);
  if (!entry) return false;

  if (entry.engine === "lightpanda") {
    stopLp(id);
    sessions.delete(id);
    return true;
  }

  // Chrome: SIGTERM → wait → SIGKILL
  try {
    process.kill(entry.pid, "SIGTERM");
  } catch {
    sessions.delete(id);
    return true;
  }

  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    if (!isProcessAlive(entry.pid)) break;
    await new Promise((r) => setTimeout(r, 200));
  }

  if (isProcessAlive(entry.pid)) {
    try {
      process.kill(entry.pid, "SIGKILL");
    } catch {}
  }

  sessions.delete(id);

  // Clean up stale files
  for (const f of [socketPath(id), pidPath(id), enginePath(id)]) {
    try {
      fs.unlinkSync(f);
    } catch {}
  }

  return true;
}

/** List all live sessions. */
export function listSessions(): {
  id: string;
  pid: number;
  alive: boolean;
  engine: Engine;
}[] {
  const result: { id: string; pid: number; alive: boolean; engine: Engine }[] =
    [];

  // Scan PID files on disk
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
          const engine = readEngine(id);
          if (!sessions.has(id)) {
            sessions.set(id, { pid, child: null, engine });
          }
          result.push({ id, pid, alive: true, engine });
        } else {
          // Stale — clean up
          const engine = readEngine(id);
          if (engine === "lightpanda") {
            stopLp(id);
          }
          for (const stale of [pf, socketPath(id), enginePath(id)]) {
            try {
              fs.unlinkSync(stale);
            } catch {}
          }
          // Also remove .cdp-port for LP sessions
          try {
            fs.unlinkSync(path.join(SOCKET_DIR, `${id}.cdp-port`));
          } catch {}
          sessions.delete(id);
        }
      } catch {}
    }
  } catch {}

  return result;
}

/** Gracefully stop all sessions (for container shutdown). */
export async function stopAll(): Promise<void> {
  const live = listSessions();
  await Promise.allSettled(live.map((s) => stopSession(s.id)));
}
