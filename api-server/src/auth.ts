import { createMiddleware } from "hono/factory";
import crypto from "node:crypto";

const TOKEN = process.env.API_TOKEN ?? "";

if (!TOKEN) {
  console.warn(
    "[auth] API_TOKEN is not set — all authenticated requests will be rejected"
  );
}

function timingSafeEqual(a: string, b: string): boolean {
  const ha = crypto.createHash("sha256").update(a).digest();
  const hb = crypto.createHash("sha256").update(b).digest();
  return crypto.timingSafeEqual(ha, hb);
}

export const authMiddleware = createMiddleware(async (c, next) => {
  // Skip auth on health endpoint
  if (c.req.path === "/health") {
    return next();
  }

  const header = c.req.header("Authorization");
  if (!header?.startsWith("Bearer ")) {
    return c.json({ error: "Missing Authorization: Bearer <token>" }, 401);
  }

  const token = header.slice(7);
  if (!TOKEN || !timingSafeEqual(token, TOKEN)) {
    return c.json({ error: "Invalid token" }, 401);
  }

  return next();
});
