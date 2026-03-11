/**
 * Lightpanda session manager.
 *
 * Spawns `lightpanda serve` as a CDP server and connects via Playwright's
 * connectOverCDP. Maintains a persistent connection per session so that
 * refs and page state survive between commands.
 *
 * Architecture:
 *   API request → sendLpCommand(sessionId, cmd)
 *     → reuse or create CDP connection
 *     → execute command on persistent page
 *     → return result (connection stays alive)
 */

import { spawn, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { chromium, type Browser, type Page } from "playwright-core";

const SOCKET_DIR = process.env.AGENT_BROWSER_SOCKET_DIR ?? "/data/sockets";
const LP_PATH = process.env.LIGHTPANDA_PATH ?? "/usr/local/bin/lightpanda";
const COMMAND_TIMEOUT = 30_000;

// Port range for Lightpanda CDP servers (one per session)
const LP_PORT_MIN = 19222;
const LP_PORT_MAX = 19999;
const usedPorts = new Set<number>();

interface LpSession {
  child: ChildProcess;
  port: number;
  /** Persistent Playwright browser connection (null until first command). */
  browser: Browser | null;
  /** Persistent page (null until first navigate). */
  page: Page | null;
}

const lpSessions = new Map<string, LpSession>();

interface DaemonResponse {
  id: string;
  success: boolean;
  data?: Record<string, unknown>;
  error?: string;
}

function ok(data: Record<string, unknown>): DaemonResponse {
  return { id: crypto.randomUUID(), success: true, data };
}

function fail(error: string): DaemonResponse {
  return { id: crypto.randomUUID(), success: false, error };
}

function pickPort(): number {
  for (let i = LP_PORT_MIN; i <= LP_PORT_MAX; i++) {
    if (!usedPorts.has(i)) {
      usedPorts.add(i);
      return i;
    }
  }
  throw new Error("No free ports for Lightpanda CDP server");
}

/** Start a Lightpanda CDP server for a session. */
export async function startLp(sessionId: string): Promise<{
  pid: number;
  port: number;
}> {
  if (lpSessions.has(sessionId)) {
    const s = lpSessions.get(sessionId)!;
    return { pid: s.child.pid!, port: s.port };
  }

  const port = pickPort();
  const child = spawn(
    LP_PATH,
    [
      "serve",
      "--host",
      "127.0.0.1",
      "--port",
      String(port),
      "--timeout",
      "600", // 10 min inactivity timeout
      "--cdp_max_connections",
      "32",
    ],
    { stdio: "ignore", detached: true }
  );

  child.unref();

  // Write PID file
  const pidFile = path.join(SOCKET_DIR, `${sessionId}.pid`);
  fs.writeFileSync(pidFile, String(child.pid), "utf8");

  // Write port file for reconnection
  const portFile = path.join(SOCKET_DIR, `${sessionId}.cdp-port`);
  fs.writeFileSync(portFile, String(port), "utf8");

  // Write engine file
  const engineFile = path.join(SOCKET_DIR, `${sessionId}.engine`);
  fs.writeFileSync(engineFile, "lightpanda", "utf8");

  lpSessions.set(sessionId, { child, port, browser: null, page: null });

  // Wait for Lightpanda to start listening
  const deadline = Date.now() + 10_000;
  const http = await import("node:http");

  while (Date.now() < deadline) {
    const alive = await new Promise<boolean>((resolve) => {
      const req = http.get(`http://127.0.0.1:${port}/json/version`, (res) => {
        let d = "";
        res.on("data", (c: Buffer) => (d += c.toString()));
        res.on("end", () => resolve(d.includes("webSocketDebuggerUrl")));
      });
      req.on("error", () => resolve(false));
      req.setTimeout(1000, () => {
        req.destroy();
        resolve(false);
      });
    });
    if (alive) break;
    await new Promise((r) => setTimeout(r, 200));
  }

  return { pid: child.pid!, port };
}

/** Stop a Lightpanda session. */
export function stopLp(sessionId: string): void {
  const session = lpSessions.get(sessionId);
  if (session) {
    // Close Playwright connection
    if (session.browser) {
      session.browser.close().catch(() => {});
    }
    // Kill Lightpanda process
    try {
      process.kill(session.child.pid!, "SIGTERM");
    } catch {
      // Already dead
    }
    usedPorts.delete(session.port);
    lpSessions.delete(sessionId);
  }

  // Clean up files
  for (const ext of [".pid", ".cdp-port", ".engine"]) {
    try {
      fs.unlinkSync(path.join(SOCKET_DIR, `${sessionId}${ext}`));
    } catch {}
  }
}

/** Check if a Lightpanda session is alive. */
export function isLpAlive(sessionId: string): boolean {
  const session = lpSessions.get(sessionId);
  if (!session) {
    // Try to recover from PID file
    const pidFile = path.join(SOCKET_DIR, `${sessionId}.pid`);
    const portFile = path.join(SOCKET_DIR, `${sessionId}.cdp-port`);
    if (fs.existsSync(pidFile) && fs.existsSync(portFile)) {
      try {
        const pid = parseInt(fs.readFileSync(pidFile, "utf8").trim(), 10);
        const port = parseInt(fs.readFileSync(portFile, "utf8").trim(), 10);
        process.kill(pid, 0); // Check alive
        usedPorts.add(port);
        lpSessions.set(sessionId, {
          child: { pid } as unknown as ChildProcess,
          port,
          browser: null,
          page: null,
        });
        return true;
      } catch {
        stopLp(sessionId);
        return false;
      }
    }
    return false;
  }
  try {
    process.kill(session.child.pid!, 0);
    return true;
  } catch {
    lpSessions.delete(sessionId);
    return false;
  }
}

// ─── Persistent connection management ───────────────────────────────────────

/**
 * Get or create a persistent CDP connection + page for a session.
 * For `navigate`, pass forceNew=true to create a fresh connection+page.
 */
async function getPage(
  session: LpSession,
  forceNew: boolean = false
): Promise<Page> {
  // Close existing connection if forcing new (navigate)
  if (forceNew && session.browser) {
    try {
      await session.browser.close();
    } catch {}
    session.browser = null;
    session.page = null;
  }

  // Return existing page if available and not closed
  if (session.page && !session.page.isClosed() && session.browser) {
    return session.page;
  }

  // Create new connection
  const browser = await chromium.connectOverCDP(
    `http://127.0.0.1:${session.port}`,
    { timeout: 10_000 }
  );

  const ctx = browser.contexts()[0];
  if (!ctx) {
    await browser.close();
    throw new Error("No browser context available from Lightpanda");
  }

  const page = await ctx.newPage();

  session.browser = browser;
  session.page = page;
  return page;
}

// ─── Snapshot: build ref-annotated accessibility tree ───────────────────────

const SNAPSHOT_SCRIPT = `(() => {
  let refCounter = 0;
  const INTERACTIVE = new Set([
    "A", "BUTTON", "INPUT", "SELECT", "TEXTAREA", "DETAILS", "SUMMARY",
  ]);
  const INTERACTIVE_ROLES = new Set([
    "button", "link", "checkbox", "radio", "textbox", "combobox",
    "menuitem", "tab", "switch", "slider", "spinbutton", "searchbox",
    "option", "menuitemcheckbox", "menuitemradio", "treeitem",
  ]);

  function isInteractive(el) {
    if (INTERACTIVE.has(el.tagName)) return true;
    const role = el.getAttribute("role");
    if (role && INTERACTIVE_ROLES.has(role)) return true;
    if (el.hasAttribute("tabindex") && el.getAttribute("tabindex") !== "-1") return true;
    if (el.hasAttribute("onclick") || el.hasAttribute("contenteditable")) return true;
    return false;
  }

  function getRole(el) {
    const explicit = el.getAttribute("role");
    if (explicit) return explicit;
    const tag = el.tagName;
    switch (tag) {
      case "A": return el.hasAttribute("href") ? "link" : null;
      case "BUTTON": return "button";
      case "INPUT": {
        const t = (el.type || "text").toLowerCase();
        if (t === "checkbox") return "checkbox";
        if (t === "radio") return "radio";
        if (t === "submit" || t === "button" || t === "reset") return "button";
        return "textbox";
      }
      case "SELECT": return "combobox";
      case "TEXTAREA": return "textbox";
      case "IMG": return "img";
      case "H1": case "H2": case "H3": case "H4": case "H5": case "H6":
        return "heading";
      case "NAV": return "navigation";
      case "MAIN": return "main";
      case "HEADER": return "banner";
      case "FOOTER": return "contentinfo";
      case "FORM": return "form";
      case "TABLE": return "table";
      case "UL": case "OL": return "list";
      case "LI": return "listitem";
      default: return null;
    }
  }

  function getName(el) {
    const label = el.getAttribute("aria-label");
    if (label) return label;
    const labelledBy = el.getAttribute("aria-labelledby");
    if (labelledBy) {
      const parts = labelledBy.split(/\\s+/).map(id => {
        const ref = document.getElementById(id);
        return ref ? ref.textContent.trim() : "";
      }).filter(Boolean);
      if (parts.length) return parts.join(" ");
    }
    if (el.tagName === "IMG") return el.alt || "";
    if (el.title) return el.title;
    if (el.tagName === "INPUT" && (el.type === "submit" || el.type === "button")) {
      return el.value || "";
    }
    if (el.placeholder) return el.placeholder;
    const directText = Array.from(el.childNodes)
      .filter(n => n.nodeType === 3)
      .map(n => n.textContent.trim())
      .join(" ")
      .trim();
    if (directText) return directText;
    return el.textContent ? el.textContent.trim().substring(0, 80) : "";
  }

  function walk(el, depth) {
    if (!el || el.nodeType !== 1) return [];
    if (el.hidden || el.getAttribute("aria-hidden") === "true") return [];
    const tag = el.tagName;
    if (tag === "SCRIPT" || tag === "STYLE" || tag === "NOSCRIPT" || tag === "SVG") return [];

    const lines = [];
    const indent = "  ".repeat(depth);
    const role = getRole(el);
    const interactive = isInteractive(el);

    let refTag = "";
    if (interactive) {
      const ref = "e" + (++refCounter);
      el.setAttribute("data-agent-ref", ref);
      refTag = " [ref=" + ref + "]";
    }

    const name = getName(el);
    let printed = false;

    if (role) {
      let extra = "";
      if (role === "heading") {
        const level = el.tagName.match(/H(\\d)/);
        if (level) extra = " [level=" + level[1] + "]";
      }
      if (role === "textbox" || role === "combobox") {
        const val = el.value || "";
        if (val) extra = " value=\\"" + val.substring(0, 50) + "\\"";
      }
      if (role === "checkbox" || role === "radio") {
        extra = el.checked ? " [checked]" : "";
      }
      if (role === "link" && el.href) {
        lines.push(indent + "- " + role + " \\"" + (name || "").substring(0, 60) + "\\"" + refTag + extra);
        lines.push(indent + "  - /url: " + el.href);
        printed = true;
      } else {
        lines.push(indent + "- " + role + " \\"" + (name || "").substring(0, 60) + "\\"" + refTag + extra);
        printed = true;
      }
    } else if (tag === "P" || tag === "SPAN" || tag === "DIV" || tag === "SECTION" || tag === "ARTICLE") {
      const text = name;
      if (text && text.length > 0) {
        lines.push(indent + "- " + (tag === "P" ? "paragraph" : "group") + ": " + text.substring(0, 120) + refTag);
        printed = true;
      }
    }

    if (!printed || el.children.length > 0) {
      for (const child of el.children) {
        lines.push(...walk(child, printed ? depth + 1 : depth));
      }
    }

    return lines;
  }

  return walk(document.body, 0).join("\\n");
})()`;

// Script to only assign refs (without returning snapshot text)
const ASSIGN_REFS_SCRIPT = `(() => {
  let refCounter = 0;
  const INTERACTIVE = new Set([
    "A", "BUTTON", "INPUT", "SELECT", "TEXTAREA", "DETAILS", "SUMMARY",
  ]);
  const INTERACTIVE_ROLES = new Set([
    "button", "link", "checkbox", "radio", "textbox", "combobox",
    "menuitem", "tab", "switch", "slider", "spinbutton", "searchbox",
    "option", "menuitemcheckbox", "menuitemradio", "treeitem",
  ]);

  function isInteractive(el) {
    if (INTERACTIVE.has(el.tagName)) return true;
    const role = el.getAttribute("role");
    if (role && INTERACTIVE_ROLES.has(role)) return true;
    if (el.hasAttribute("tabindex") && el.getAttribute("tabindex") !== "-1") return true;
    if (el.hasAttribute("onclick") || el.hasAttribute("contenteditable")) return true;
    return false;
  }

  function walk(el) {
    if (!el || el.nodeType !== 1) return;
    if (el.hidden || el.getAttribute("aria-hidden") === "true") return;
    const tag = el.tagName;
    if (tag === "SCRIPT" || tag === "STYLE" || tag === "NOSCRIPT" || tag === "SVG") return;
    if (isInteractive(el)) {
      el.setAttribute("data-agent-ref", "e" + (++refCounter));
    }
    for (const child of el.children) walk(child);
  }

  walk(document.body);
  return refCounter;
})()`;

// ─── Command execution ─────────────────────────────────────────────────────

/**
 * Execute a command against a Lightpanda session.
 * Uses persistent CDP connection — refs and page state survive between commands.
 */
export async function sendLpCommand(
  sessionId: string,
  command: Record<string, unknown>
): Promise<DaemonResponse> {
  const session = lpSessions.get(sessionId);
  if (!session) return fail("Lightpanda session not found: " + sessionId);

  const action = String(command.action);

  try {
    // Navigate creates a fresh connection (Lightpanda can't goto on existing page)
    if (action === "navigate") {
      const url = String(command.url ?? "");
      if (!url) return fail("Missing url parameter");

      const page = await getPage(session, true); // force new connection
      await page.goto(url, {
        timeout: COMMAND_TIMEOUT,
        waitUntil: "domcontentloaded",
      });
      // Auto-assign refs after navigation
      await page.evaluate(ASSIGN_REFS_SCRIPT);
      return ok({ url: page.url(), title: await page.title() });
    }

    // All other commands use the existing connection
    const page = await getPage(session);

    if (page.url() === "" || page.url() === "about:blank") {
      return fail("No page loaded. Use navigate first.");
    }

    switch (action) {
      case "snapshot": {
        const snapshot = await page.evaluate(SNAPSHOT_SCRIPT);
        return ok({ snapshot });
      }

      case "url":
        return ok({ url: page.url() });

      case "title":
        return ok({ title: await page.title() });

      case "eval": {
        const expr = String(command.expression ?? "");
        if (!expr) return fail("Missing expression parameter");
        const result = await page.evaluate(expr);
        return ok({ result });
      }

      case "click": {
        const sel = resolveSelector(String(command.selector ?? ""));
        await page.locator(sel).click({ timeout: COMMAND_TIMEOUT });
        await new Promise((r) => setTimeout(r, 500));
        return ok({ clicked: sel, url: page.url() });
      }

      case "dblclick": {
        const sel = resolveSelector(String(command.selector ?? ""));
        await page.locator(sel).dblclick({ timeout: COMMAND_TIMEOUT });
        return ok({ clicked: sel });
      }

      case "fill": {
        const sel = resolveSelector(String(command.selector ?? ""));
        const value = String(command.value ?? "");
        await page.locator(sel).fill(value, { timeout: COMMAND_TIMEOUT });
        return ok({ filled: sel, value });
      }

      case "type": {
        const text = String(command.text ?? command.value ?? "");
        await page.keyboard.type(text);
        return ok({ typed: text });
      }

      case "press": {
        const key = String(command.key ?? "");
        await page.keyboard.press(key);
        return ok({ pressed: key });
      }

      case "hover": {
        const sel = resolveSelector(String(command.selector ?? ""));
        await page.locator(sel).hover({ timeout: COMMAND_TIMEOUT });
        return ok({ hovered: sel });
      }

      case "focus": {
        const sel = resolveSelector(String(command.selector ?? ""));
        await page.locator(sel).focus({ timeout: COMMAND_TIMEOUT });
        return ok({ focused: sel });
      }

      case "select": {
        const sel = resolveSelector(String(command.selector ?? ""));
        const value = String(command.value ?? "");
        await page.locator(sel).selectOption(value, {
          timeout: COMMAND_TIMEOUT,
        });
        return ok({ selected: sel, value });
      }

      case "check": {
        const sel = resolveSelector(String(command.selector ?? ""));
        await page.locator(sel).check({ timeout: COMMAND_TIMEOUT });
        return ok({ checked: sel });
      }

      case "uncheck": {
        const sel = resolveSelector(String(command.selector ?? ""));
        await page.locator(sel).uncheck({ timeout: COMMAND_TIMEOUT });
        return ok({ unchecked: sel });
      }

      case "clear": {
        const sel = resolveSelector(String(command.selector ?? ""));
        await page.locator(sel).clear({ timeout: COMMAND_TIMEOUT });
        return ok({ cleared: sel });
      }

      case "scroll": {
        const dir = String(command.direction ?? "down");
        const amount = parseInt(String(command.amount ?? "500"), 10);
        const dy = dir === "up" ? -amount : amount;
        const dx = dir === "left" ? -amount : dir === "right" ? amount : 0;
        await page.mouse.wheel(dx, dy);
        return ok({ scrolled: dir, amount });
      }

      case "back":
        await page.goBack({ timeout: COMMAND_TIMEOUT });
        return ok({ url: page.url() });

      case "forward":
        await page.goForward({ timeout: COMMAND_TIMEOUT });
        return ok({ url: page.url() });

      case "reload":
        await page.reload({ timeout: COMMAND_TIMEOUT });
        // Re-assign refs after reload
        await page.evaluate(ASSIGN_REFS_SCRIPT);
        return ok({ url: page.url() });

      case "screenshot": {
        try {
          const buf = await page.screenshot({ timeout: COMMAND_TIMEOUT });
          return ok({ screenshot: buf.toString("base64") });
        } catch {
          return fail(
            "Screenshots are not supported with the Lightpanda engine. Use snapshot instead."
          );
        }
      }

      case "content": {
        const html = await page.content();
        return ok({ content: html });
      }

      case "gettext": {
        const sel = resolveSelector(String(command.selector ?? "body"));
        const text = await page.locator(sel).textContent({
          timeout: COMMAND_TIMEOUT,
        });
        return ok({ text: text ?? "" });
      }

      case "getattribute": {
        const sel = resolveSelector(String(command.selector ?? ""));
        const attr = String(command.attribute ?? "");
        const val = await page.locator(sel).getAttribute(attr, {
          timeout: COMMAND_TIMEOUT,
        });
        return ok({ value: val ?? "" });
      }

      case "isvisible": {
        const sel = resolveSelector(String(command.selector ?? ""));
        const visible = await page.locator(sel).isVisible();
        return ok({ visible });
      }

      case "count": {
        const sel = resolveSelector(String(command.selector ?? ""));
        const count = await page.locator(sel).count();
        return ok({ count });
      }

      case "wait": {
        const target = String(command.selector ?? command.ms ?? "1000");
        if (/^\d+$/.test(target)) {
          await new Promise((r) => setTimeout(r, parseInt(target, 10)));
        } else {
          const sel = resolveSelector(target);
          await page.locator(sel).waitFor({ timeout: COMMAND_TIMEOUT });
        }
        return ok({ waited: target });
      }

      default:
        return fail(
          `Action "${action}" is not supported with Lightpanda engine`
        );
    }
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    const clean = msg.split("\nCall log:")[0].trim();

    // If connection died, clean up so next command reconnects
    if (
      clean.includes("closed") ||
      clean.includes("ECONNREFUSED") ||
      clean.includes("Target page")
    ) {
      session.browser = null;
      session.page = null;
    }

    return fail(clean);
  }
}

/** Convert @eN refs to CSS selectors. */
function resolveSelector(selector: string): string {
  if (selector.startsWith("@")) {
    const ref = selector.slice(1);
    return `[data-agent-ref="${ref}"]`;
  }
  return selector;
}
