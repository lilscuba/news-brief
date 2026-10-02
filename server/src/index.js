// Newsfeed API (Cloudflare Worker).
//
//   GET    /v1/feed                  shared feed (public; same for everyone, cached)
//   POST   /v1/auth/apple            {identityToken} -> {token, user, settings}  (sign up / log in)
//   POST   /v1/auth/logout           end this session
//   GET    /v1/me                    {user, settings}
//   PUT    /v1/me/settings           partial settings -> merged settings
//   POST   /v1/me/devices            {token, environment} register for push
//   DELETE /v1/me/devices/:token     unregister
//   DELETE /v1/me                    delete the account and everything attached to it
//   POST   /v1/internal/ingest       (INGEST_SECRET) feed + alert candidates -> pushes to send
//   POST   /v1/internal/push-results (INGEST_SECRET) {invalidTokens} -> forget dead devices
//
// Bindings (wrangler.toml): DB (D1), FEED (KV), APPLE_BUNDLE_IDS (var), INGEST_SECRET (secret).

import { APPLE_JWKS_URL, AuthError, verifyAppleToken } from "./apple.js";
import { alertsForUser, briefPush } from "./matching.js";
import { DEFAULT_SETTINGS, SettingsError, mergeSettings, parseStoredSettings } from "./settings.js";

const JSON_HEADERS = { "content-type": "application/json; charset=utf-8" };
const MAX_BODY = 5_000_000; // the ingest payload is ~200 KB; leave lots of room
const JWKS_TTL = 6 * 3600;
let jwksMemo = null;

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

const json = (data, status = 200, headers = {}) =>
  new Response(JSON.stringify(data), { status, headers: { ...JSON_HEADERS, ...headers } });

const nowIso = () => new Date().toISOString().replace(/\.\d{3}Z$/, "Z");

async function readJson(request) {
  const text = await request.text();
  if (text.length > MAX_BODY) throw new HttpError(413, "request too large");
  try {
    return JSON.parse(text || "{}");
  } catch {
    throw new HttpError(400, "invalid JSON");
  }
}

async function sha256Hex(text) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function randomToken() {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function timingSafeEqual(a, b) {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  if (x.length !== y.length) return false;
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

function bearer(request) {
  const h = request.headers.get("authorization") ?? "";
  return h.startsWith("Bearer ") ? h.slice(7).trim() : null;
}

async function appleJwks(env) {
  if (jwksMemo && jwksMemo.expires > Date.now()) return jwksMemo.value;
  let value = await env.FEED.get("apple_jwks", "json");
  if (!value) {
    const r = await fetch(APPLE_JWKS_URL);
    if (!r.ok) throw new HttpError(502, "couldn't reach Apple to verify sign-in");
    value = await r.json();
    await env.FEED.put("apple_jwks", JSON.stringify(value), { expirationTtl: JWKS_TTL });
  }
  jwksMemo = { value, expires: Date.now() + 600_000 };
  return value;
}

async function currentUser(request, env) {
  const token = bearer(request);
  if (!token) throw new HttpError(401, "sign in required");
  const row = await env.DB.prepare(
    "SELECT u.* FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.token_hash = ?",
  ).bind(await sha256Hex(token)).first();
  if (!row) throw new HttpError(401, "session expired; sign in again");
  return row;
}

const publicUser = (row) => ({ id: row.id, createdAt: row.created_at });

// --- handlers --------------------------------------------------------------------------------

async function getFeed(request, env) {
  const { value, metadata } = await env.FEED.getWithMetadata("feed", "text");
  if (!value) throw new HttpError(503, "feed not built yet");
  const etag = `"${metadata?.generatedAt ?? "0"}"`;
  const cache = { "cache-control": "public, max-age=60", etag };
  if (request.headers.get("if-none-match") === etag) return new Response(null, { status: 304, headers: cache });
  return new Response(value, { headers: { ...JSON_HEADERS, ...cache } });
}

async function signInWithApple(request, env) {
  const body = await readJson(request);
  const audiences = (env.APPLE_BUNDLE_IDS ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  let claims;
  try {
    claims = await verifyAppleToken(body.identityToken, audiences, () => appleJwks(env));
  } catch (e) {
    if (e instanceof AuthError) throw new HttpError(401, e.message);
    throw e;
  }
  let user = await env.DB.prepare("SELECT * FROM users WHERE apple_sub = ?").bind(claims.sub).first();
  const created = !user;
  if (!user) {
    const id = crypto.randomUUID();
    const settings = structuredClone(DEFAULT_SETTINGS);
    if (typeof body.timezone === "string") {
      try {
        Object.assign(settings, mergeSettings(settings, { brief: { timezone: body.timezone } }));
      } catch { /* keep the default zone */ }
    }
    await env.DB.prepare(
      "INSERT INTO users (id, apple_sub, created_at, settings) VALUES (?, ?, ?, ?)",
    ).bind(id, claims.sub, nowIso(), JSON.stringify(settings)).run();
    user = await env.DB.prepare("SELECT * FROM users WHERE id = ?").bind(id).first();
  }
  const token = randomToken();
  await env.DB.prepare("INSERT INTO sessions (token_hash, user_id, created_at) VALUES (?, ?, ?)")
    .bind(await sha256Hex(token), user.id, nowIso()).run();
  return json({ token, created, user: publicUser(user), settings: parseStoredSettings(user.settings) });
}

async function logout(request, env) {
  const token = bearer(request);
  if (token) await env.DB.prepare("DELETE FROM sessions WHERE token_hash = ?").bind(await sha256Hex(token)).run();
  return json({ ok: true });
}

async function getMe(request, env) {
  const user = await currentUser(request, env);
  return json({ user: publicUser(user), settings: parseStoredSettings(user.settings) });
}

async function putSettings(request, env) {
  const user = await currentUser(request, env);
  let settings;
  try {
    settings = mergeSettings(parseStoredSettings(user.settings), await readJson(request));
  } catch (e) {
    if (e instanceof SettingsError) throw new HttpError(400, e.message);
    throw e;
  }
  await env.DB.prepare("UPDATE users SET settings = ? WHERE id = ?").bind(JSON.stringify(settings), user.id).run();
  return json({ settings });
}

async function registerDevice(request, env) {
  const user = await currentUser(request, env);
  const body = await readJson(request);
  const token = String(body.token ?? "");
  if (!/^[0-9a-fA-F]{32,200}$/.test(token)) throw new HttpError(400, "invalid device token");
  const environment = body.environment === "sandbox" ? "sandbox" : "production";
  // A token belongs to one phone; if someone else signs in on it, it moves to them.
  await env.DB.prepare(
    `INSERT INTO devices (token, user_id, environment, updated_at) VALUES (?, ?, ?, ?)
     ON CONFLICT(token) DO UPDATE SET user_id = excluded.user_id,
       environment = excluded.environment, updated_at = excluded.updated_at`,
  ).bind(token.toLowerCase(), user.id, environment, nowIso()).run();
  return json({ ok: true });
}

async function removeDevice(request, env, token) {
  const user = await currentUser(request, env);
  await env.DB.prepare("DELETE FROM devices WHERE token = ? AND user_id = ?").bind(token.toLowerCase(), user.id).run();
  return json({ ok: true });
}

async function deleteAccount(request, env) {
  const user = await currentUser(request, env);
  await env.DB.batch([
    env.DB.prepare("DELETE FROM devices WHERE user_id = ?").bind(user.id),
    env.DB.prepare("DELETE FROM sessions WHERE user_id = ?").bind(user.id),
    env.DB.prepare("DELETE FROM users WHERE id = ?").bind(user.id),
  ]);
  return json({ deleted: true });
}

function requireIngestSecret(request, env) {
  const token = bearer(request);
  // trim(): a secret piped in from a Windows shell can carry a trailing newline.
  const expected = (env.INGEST_SECRET ?? "").trim();
  if (!expected || !token || !timingSafeEqual(token, expected)) {
    throw new HttpError(401, "bad ingest secret");
  }
}

async function ingest(request, env) {
  requireIngestSecret(request, env);
  const { feed, candidates = [] } = await readJson(request);
  if (!feed || feed.version !== 1 || !Array.isArray(feed.stories)) throw new HttpError(400, "bad feed");
  await env.FEED.put("feed", JSON.stringify(feed), { metadata: { generatedAt: feed.generatedAt } });

  const now = new Date();
  const users = (await env.DB.prepare(
    "SELECT u.* FROM users u WHERE EXISTS (SELECT 1 FROM devices d WHERE d.user_id = u.id)",
  ).all()).results;
  const devices = (await env.DB.prepare("SELECT token, user_id, environment FROM devices").all()).results;
  const byUser = new Map();
  for (const d of devices) byUser.set(d.user_id, [...(byUser.get(d.user_id) ?? []), d]);

  const pushes = [];
  const updates = [];
  for (const u of users) {
    const settings = parseStoredSettings(u.settings);
    const state = {
      alertDay: u.alert_day, alertCount: u.alert_count ?? 0,
      alertKeys: JSON.parse(u.alert_keys || "[]"), briefDay: u.brief_day,
    };
    const result = alertsForUser(settings, state, candidates, feed.watchlist ?? [], now);
    const userPushes = [...result.pushes];
    const brief = briefPush(settings, state, feed, now);
    if (brief) userPushes.push(brief.push);
    if (!userPushes.length) continue;
    for (const d of byUser.get(u.id) ?? []) {
      for (const p of userPushes) pushes.push({ ...p, token: d.token, environment: d.environment });
    }
    updates.push(env.DB.prepare(
      "UPDATE users SET alert_day = ?, alert_count = ?, alert_keys = ?, brief_day = ? WHERE id = ?",
    ).bind(result.state.alertDay, result.state.alertCount, JSON.stringify(result.state.alertKeys),
      brief ? brief.briefDay : state.briefDay ?? null, u.id));
  }
  if (updates.length) await env.DB.batch(updates);
  return json({ stored: feed.stories.length, users: users.length, pushes });
}

async function pushResults(request, env) {
  requireIngestSecret(request, env);
  const { invalidTokens = [] } = await readJson(request);
  const stmts = invalidTokens.slice(0, 10_000).map((t) =>
    env.DB.prepare("DELETE FROM devices WHERE token = ?").bind(String(t).toLowerCase()));
  if (stmts.length) await env.DB.batch(stmts);
  return json({ removed: stmts.length });
}

// The App Store needs a privacy policy URL; this serves one: https://<worker>/privacy
function privacyPage(env) {
  const contact = env.CONTACT_EMAIL ? `<p>Questions: ${env.CONTACT_EMAIL}</p>` : "";
  return new Response(`<!doctype html><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Privacy</title>
<style>body{font:16px/1.5 -apple-system,system-ui,sans-serif;max-width:640px;margin:2rem auto;padding:0 16px}</style>
<h1>Privacy policy</h1>
<p>When you sign in with Apple, we receive an anonymous Apple user id. We do not ask for or
store your name or email address.</p>
<p>We store: that id, your feed settings (topics, sources, muted and boosted words, alert and
notification preferences, time zone), a hashed session token, your device's push token, and which
alerts we've already sent you (so you don't get duplicates).</p>
<p>We do not store what you read or tap. Your reading history and read/unread state stay on your
phone. News comes from public RSS feeds and public Bluesky posts; tapping a story opens the
publisher's site, which has its own privacy policy.</p>
<p>We don't sell or share your data, and there are no ads or third-party trackers. Data is hosted
on Cloudflare; push notifications are delivered by Apple.</p>
<p>Delete your account any time in the app (Settings → Delete account). This permanently removes
everything above.</p>
${contact}`, { headers: { "content-type": "text/html; charset=utf-8" } });
}

// --- router ----------------------------------------------------------------------------------

export async function handle(request, env) {
  const url = new URL(request.url);
  const { pathname: path } = url;
  const m = request.method;
  if (m === "GET" && path === "/v1/health") return json({ ok: true });
  if (m === "GET" && path === "/privacy") return privacyPage(env);
  if (m === "GET" && path === "/v1/feed") return getFeed(request, env);
  if (m === "POST" && path === "/v1/auth/apple") return signInWithApple(request, env);
  if (m === "POST" && path === "/v1/auth/logout") return logout(request, env);
  if (m === "GET" && path === "/v1/me") return getMe(request, env);
  if (m === "DELETE" && path === "/v1/me") return deleteAccount(request, env);
  if (m === "PUT" && path === "/v1/me/settings") return putSettings(request, env);
  if (m === "POST" && path === "/v1/me/devices") return registerDevice(request, env);
  const dev = path.match(/^\/v1\/me\/devices\/([0-9a-fA-F]+)$/);
  if (m === "DELETE" && dev) return removeDevice(request, env, dev[1]);
  if (m === "POST" && path === "/v1/internal/ingest") return ingest(request, env);
  if (m === "POST" && path === "/v1/internal/push-results") return pushResults(request, env);
  throw new HttpError(404, "not found");
}

export default {
  async fetch(request, env) {
    try {
      return await handle(request, env);
    } catch (e) {
      if (e instanceof HttpError) return json({ error: e.message }, e.status);
      console.error(e);
      return json({ error: "internal error" }, 500);
    }
  },
};
