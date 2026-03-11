import net from "node:net";
import path from "node:path";
import crypto from "node:crypto";
import fs from "node:fs";
import type { Engine } from "./sessions.js";
import { sendLpCommand } from "./lightpanda.js";

const SOCKET_DIR = process.env.AGENT_BROWSER_SOCKET_DIR ?? "/data/sockets";
const COMMAND_TIMEOUT = 30_000;

interface DaemonResponse {
  id: string;
  success: boolean;
  data?: Record<string, unknown>;
  error?: string;
}

/**
 * Get the engine for a session by reading the .engine sidecar file.
 */
function getSessionEngine(sessionId: string): Engine {
  try {
    const e = fs
      .readFileSync(path.join(SOCKET_DIR, `${sessionId}.engine`), "utf8")
      .trim();
    if (e === "lightpanda") return "lightpanda";
  } catch {}
  return "chrome";
}

/**
 * Send a command to a Chrome session's daemon via Unix socket.
 * The daemon speaks newline-delimited JSON.
 */
function sendSocketCommand(
  sessionId: string,
  command: Record<string, unknown>
): Promise<DaemonResponse> {
  return new Promise((resolve, reject) => {
    const socketFile = path.join(SOCKET_DIR, `${sessionId}.sock`);
    const id = crypto.randomUUID();
    const payload = JSON.stringify({ id, ...command }) + "\n";

    const socket = net.createConnection(socketFile);
    let buffer = "";
    let settled = false;

    const timer = setTimeout(() => {
      if (!settled) {
        settled = true;
        socket.destroy();
        reject(new Error(`Command timed out after ${COMMAND_TIMEOUT}ms`));
      }
    }, COMMAND_TIMEOUT);

    function settle(fn: () => void) {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      fn();
    }

    socket.on("connect", () => {
      socket.write(payload);
    });

    socket.on("data", (chunk) => {
      buffer += chunk.toString();
      const nlIdx = buffer.indexOf("\n");
      if (nlIdx === -1) return;

      const line = buffer.substring(0, nlIdx);
      settle(() => {
        socket.destroy();
        try {
          const resp = JSON.parse(line) as DaemonResponse;
          resolve(resp);
        } catch (err) {
          reject(
            new Error(`Invalid JSON from daemon: ${line.slice(0, 200)}`)
          );
        }
      });
    });

    socket.on("error", (err) => {
      settle(() => reject(err));
    });

    socket.on("close", () => {
      settle(() => reject(new Error("Socket closed before response")));
    });
  });
}

/**
 * Send a command to a session, routing to the appropriate backend:
 * - Chrome: Unix socket IPC with daemon.js
 * - Lightpanda: Playwright CDP connection via lightpanda.ts
 */
export function sendCommand(
  sessionId: string,
  command: Record<string, unknown>
): Promise<DaemonResponse> {
  const engine = getSessionEngine(sessionId);

  if (engine === "lightpanda") {
    return sendLpCommand(sessionId, command);
  }

  return sendSocketCommand(sessionId, command);
}
