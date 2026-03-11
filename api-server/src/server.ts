import { Hono } from "hono";
import { serve } from "@hono/node-server";
import { authMiddleware } from "./auth.js";
import {
  ensureSession,
  stopSession,
  listSessions,
  isValidSessionName,
  stopAll,
} from "./sessions.js";
import { sendCommand } from "./proxy.js";

const app = new Hono();
const startTime = Date.now();

// Auth middleware (skips /health)
app.use("*", authMiddleware);

// --- Health ---
app.get("/health", (c) => {
  const live = listSessions();
  return c.json({
    status: "ok",
    sessions: live.length,
    uptime: Math.floor((Date.now() - startTime) / 1000),
  });
});

// --- List sessions ---
app.get("/sessions", (c) => {
  return c.json({ sessions: listSessions() });
});

// --- Create / ensure session ---
app.post("/sessions", async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as {
    session?: string;
  };
  const id = body.session ?? "default";

  if (!isValidSessionName(id)) {
    return c.json(
      { error: "Invalid session name. Use [a-zA-Z0-9_-], max 64 chars." },
      400
    );
  }

  try {
    await ensureSession(id);
    return c.json({ session: id, status: "ready" }, 201);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return c.json({ error: msg }, 503);
  }
});

// --- Stop session ---
app.delete("/sessions/:id", async (c) => {
  const id = c.req.param("id");
  if (!isValidSessionName(id)) {
    return c.json({ error: "Invalid session name" }, 400);
  }

  // Send close command to the daemon first (triggers graceful shutdown with state save)
  try {
    await sendCommand(id, { action: "close" });
  } catch {
    // If socket is already gone, fall through to stopSession
  }

  const stopped = await stopSession(id);
  if (!stopped) {
    return c.json({ error: "Session not found" }, 404);
  }
  return c.json({ session: id, status: "stopped" });
});

// --- Execute command ---
app.post("/sessions/:id/command", async (c) => {
  const id = c.req.param("id");
  if (!isValidSessionName(id)) {
    return c.json({ error: "Invalid session name" }, 400);
  }

  const body = await c.req.json<Record<string, unknown>>().catch(() => null);
  if (!body || !body.action) {
    return c.json(
      { error: 'Request body must include "action" field' },
      400
    );
  }

  // Don't allow close via command endpoint — use DELETE /sessions/:id
  if (body.action === "close") {
    return c.json(
      { error: "Use DELETE /sessions/:id to close a session" },
      400
    );
  }

  try {
    // Auto-start daemon if needed
    await ensureSession(id);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return c.json({ error: `Failed to start session: ${msg}` }, 503);
  }

  try {
    const resp = await sendCommand(id, body);
    if (resp.success) {
      return c.json({ success: true, data: resp.data });
    } else {
      return c.json({ success: false, error: resp.error }, 500);
    }
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);

    // If connection refused, daemon may have crashed — clean up
    if (msg.includes("ECONNREFUSED") || msg.includes("ENOENT")) {
      return c.json(
        { error: `Session daemon unavailable: ${msg}. Try again.` },
        503
      );
    }

    return c.json({ error: msg }, 500);
  }
});

// --- Graceful shutdown ---
function handleShutdown(signal: string) {
  console.log(`[server] Received ${signal}, shutting down...`);
  stopAll()
    .then(() => {
      console.log("[server] All sessions stopped. Exiting.");
      process.exit(0);
    })
    .catch((err) => {
      console.error("[server] Error during shutdown:", err);
      process.exit(1);
    });
}

process.on("SIGTERM", () => handleShutdown("SIGTERM"));
process.on("SIGINT", () => handleShutdown("SIGINT"));

// --- Start server ---
const port = parseInt(process.env.PORT ?? "3000", 10);
console.log(`[server] Starting on port ${port}`);

serve({ fetch: app.fetch, port }, (info) => {
  console.log(`[server] Listening on http://localhost:${info.port}`);
});
