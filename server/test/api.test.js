import assert from "node:assert/strict";
import { before, beforeEach, test } from "node:test";

import worker, { etagMatches, onSchedule } from "../src/index.js";
import { fakeApple, fakeD1, fakeKV } from "./fakes.js";

let apple;
let env;
const BASE = "https://api.test";
const DEVICE = "a".repeat(64);

before(async () => {
  apple = await fakeApple();
});

beforeEach(async () => {
  env = { DB: fakeD1(), FEED: fakeKV(), APPLE_BUNDLE_IDS: apple.audience, INGEST_SECRET: "s3cret" };
  await env.FEED.put("apple_jwks", JSON.stringify(apple.jwks)); // no network in tests
});

async function call(method, path, { body, token } = {}) {
  const headers = { "content-type": "application/json" };
  if (token) headers.authorization = `Bearer ${token}`;
  const res = await worker.fetch(new Request(BASE + path, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  }), env);
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : null, headers: res.headers };
}

async function signIn(claims = {}) {
  const r = await call("POST", "/v1/auth/apple", {
    body: { identityToken: await apple.token(claims), timezone: "Europe/London" },
  });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return r.body;
}

function feed(stories = []) {
  return {
    version: 1, generatedAt: "2026-10-01T12:00:00Z", sections: ["AI", "Tech", "Gaming", "Deals"],
    sources: [], watchlist: [{ name: "Nintendo Direct", match: [["nintendo direct"]] }], stories,
  };
}

test("sign up creates an account with default settings, sign in finds it again", async () => {
  const first = await signIn();
  assert.equal(first.created, true);
  assert.equal(first.settings.brief.timezone, "Europe/London");
  assert.deepEqual(first.settings.categories, ["AI", "Tech", "Gaming", "Deals"]);
  const again = await signIn();
  assert.equal(again.created, false);
  assert.equal(again.user.id, first.user.id);
  assert.notEqual(again.token, first.token);
});

test("bad identity tokens are rejected", async () => {
  for (const claims of [{ aud: "com.someone.else" }, { iss: "https://evil.example" },
    { exp: Math.floor(Date.now() / 1000) - 3600 }]) {
    const r = await call("POST", "/v1/auth/apple", { body: { identityToken: await apple.token(claims) } });
    assert.equal(r.status, 401, JSON.stringify(claims));
  }
  const good = await apple.token();
  const tampered = good.slice(0, -4) + (good.endsWith("AAAA") ? "BBBB" : "AAAA");
  assert.equal((await call("POST", "/v1/auth/apple", { body: { identityToken: tampered } })).status, 401);
  assert.equal((await call("POST", "/v1/auth/apple", { body: { identityToken: "nope" } })).status, 401);
});

test("settings are validated and merged", async () => {
  const { token } = await signIn();
  const ok = await call("PUT", "/v1/me/settings", {
    token, body: { categories: ["Gaming"], mutedWords: ["fortnite", " "], alerts: { maxPerDay: 2 } },
  });
  assert.equal(ok.status, 200);
  assert.deepEqual(ok.body.settings.categories, ["Gaming"]);
  assert.deepEqual(ok.body.settings.mutedWords, ["fortnite"]);
  assert.equal(ok.body.settings.alerts.maxPerDay, 2);
  assert.equal(ok.body.settings.alerts.official, true); // untouched fields keep their values

  for (const bad of [{ categories: ["Sports"] }, { alerts: { maxPerDay: 99 } },
    { brief: { timezone: "Mars/Olympus" } }, { brief: { hour: 24 } }, []]) {
    assert.equal((await call("PUT", "/v1/me/settings", { token, body: bad })).status, 400, JSON.stringify(bad));
  }
  const me = await call("GET", "/v1/me", { token });
  assert.deepEqual(me.body.settings.categories, ["Gaming"]);
});

test("disabled sources can cover the whole catalog; word lists stay at 100", async () => {
  const { token } = await signIn();
  const keys = (n) => Array.from({ length: n }, (_, i) => `source-${i}`);
  const ok = await call("PUT", "/v1/me/settings", { token, body: { disabledSources: keys(500) } });
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  assert.equal(ok.body.settings.disabledSources.length, 500);
  const tooMany = await call("PUT", "/v1/me/settings", { token, body: { disabledSources: keys(501) } });
  assert.equal(tooMany.status, 400);
  assert.match(tooMany.body.error, /disabledSources is limited to 500/);
  for (const field of ["mutedWords", "boosts"]) {
    const r = await call("PUT", "/v1/me/settings", { token, body: { [field]: keys(101) } });
    assert.equal(r.status, 400, field);
  }
  const words = await call("PUT", "/v1/me/settings", { token, body: { alerts: { keywords: keys(101) } } });
  assert.equal(words.status, 400);
  const me = await call("GET", "/v1/me", { token });
  assert.equal(me.body.settings.disabledSources.length, 500); // rejected saves changed nothing
});

test("region topics are accepted but opt-in", async () => {
  const { token, settings } = await signIn();
  assert.ok(!settings.categories.some((c) => ["US", "World", "Europe", "Japan", "Korea"].includes(c)));
  const r = await call("PUT", "/v1/me/settings", { token, body: { categories: ["AI", "US", "World", "Europe", "Japan", "Korea"] } });
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.settings.categories, ["AI", "US", "World", "Europe", "Japan", "Korea"]);
});

test("endpoints need a session; logout ends it", async () => {
  assert.equal((await call("GET", "/v1/me")).status, 401);
  assert.equal((await call("GET", "/v1/me", { token: "made-up" })).status, 401);
  const { token } = await signIn();
  assert.equal((await call("POST", "/v1/auth/logout", { token })).status, 200);
  assert.equal((await call("GET", "/v1/me", { token })).status, 401);
});

test("feed is served after ingest, with ETag caching", async () => {
  assert.equal((await call("GET", "/v1/feed")).status, 503);
  assert.equal((await call("POST", "/v1/internal/ingest", { body: { feed: feed() } })).status, 401);
  const r = await call("POST", "/v1/internal/ingest", { token: "s3cret", body: { feed: feed() } });
  assert.equal(r.status, 200);
  const f = await call("GET", "/v1/feed");
  assert.equal(f.status, 200);
  assert.equal(f.body.generatedAt, "2026-10-01T12:00:00Z");
  const etag = f.headers.get("etag");
  const cached = await worker.fetch(new Request(BASE + "/v1/feed", { headers: { "if-none-match": etag } }), env);
  assert.equal(cached.status, 304);
});

test("feed revalidation accepts the weak ETag Cloudflare sends after compressing, and lists", async () => {
  await call("POST", "/v1/internal/ingest", { token: "s3cret", body: { feed: feed() } });
  const etag = (await call("GET", "/v1/feed")).headers.get("etag");
  assert.equal(etag, '"2026-10-01T12:00:00Z"');
  const get = (inm) => worker.fetch(new Request(BASE + "/v1/feed", { headers: { "if-none-match": inm } }), env);
  for (const inm of [`W/${etag}`, `"older", W/${etag}`, `${etag} ,"x"`, "*"]) {
    const r = await get(inm);
    assert.equal(r.status, 304, inm);
    assert.equal(r.headers.get("etag"), etag);
    assert.equal(await r.text(), "");
  }
  for (const inm of ['"2026-09-30T00:00:00Z"', 'W/"2026-09-30T00:00:00Z"', "2026-10-01T12:00:00Z", ""]) {
    const r = await get(inm);
    assert.equal(r.status, 200, inm);
    assert.equal(JSON.parse(await r.text()).generatedAt, "2026-10-01T12:00:00Z");
  }
});

test("ETag comparison is weak, per RFC 9110", () => {
  assert.equal(etagMatches('W/"a"', '"a"'), true);
  assert.equal(etagMatches(' "b" , W/"a" ', '"a"'), true);
  assert.equal(etagMatches('"b"', '"a"'), false);
  assert.equal(etagMatches(null, '"a"'), false);
});

test("health reports how old the feed is", async () => {
  const before = await call("GET", "/v1/health");
  assert.equal(before.status, 200);
  assert.deepEqual(before.body, { ok: true, feed: { generatedAt: null, ageSeconds: null, stale: true } });

  const isoAgo = (ms) => new Date(Date.now() - ms).toISOString().replace(/\.\d{3}Z$/, "Z");
  const old = isoAgo(2 * 3600e3);
  await call("POST", "/v1/internal/ingest", { token: "s3cret", body: { feed: { ...feed(), generatedAt: old } } });
  const stale = await call("GET", "/v1/health");
  assert.equal(stale.status, 200);
  assert.equal(stale.body.ok, true);
  assert.equal(stale.body.feed.generatedAt, old);
  assert.ok(Math.abs(stale.body.feed.ageSeconds - 7200) <= 5, String(stale.body.feed.ageSeconds));
  assert.equal(stale.body.feed.stale, true);

  const recent = isoAgo(5 * 60e3);
  await call("POST", "/v1/internal/ingest", { token: "s3cret", body: { feed: { ...feed(), generatedAt: recent } } });
  const fresh = await call("GET", "/v1/health");
  assert.equal(fresh.body.feed.generatedAt, recent);
  assert.equal(fresh.body.feed.stale, false);
});

// --- cron: dispatching the GitHub workflows -------------------------------------------------

const TICK = "*/10 * * * *";
const DAILY_BRIEF_CRON = "0 11 * * *"; // the two crons in wrangler.toml
const at = (hhmm, day = "2026-10-01") => new Date(`${day}T${hhmm}:00Z`);

/** Stands in for fetch: records each call and answers with `status`. */
function stubFetch(status = 204, body = "") {
  const calls = [];
  const f = async (url, init) => {
    calls.push({ url, init });
    return new Response(status === 204 ? null : body, { status });
  };
  f.calls = calls;
  return f;
}

async function ingestFeed(generatedAt = "2026-10-01T12:00:00Z") {
  const r = await call("POST", "/v1/internal/ingest", { token: "s3cret", body: { feed: { ...feed(), generatedAt } } });
  assert.equal(r.status, 200);
}

test("cron does nothing until a GitHub token is configured", async (t) => {
  const warn = t.mock.method(console, "warn", () => {});
  await ingestFeed();
  const f = stubFetch();
  assert.equal(await onSchedule(TICK, env, at("12:20"), f), "unconfigured");
  assert.equal(await onSchedule(DAILY_BRIEF_CRON, { ...env, GITHUB_REPO: "o/r", GITHUB_DISPATCH_TOKEN: " \n" },
    at("11:00"), f), "unconfigured");
  assert.equal(await onSchedule(TICK, { ...env, GITHUB_DISPATCH_TOKEN: "t" }, at("12:20"), f), "unconfigured");
  assert.equal(f.calls.length, 0);
  assert.equal(warn.mock.callCount(), 3);
});

test("cron starts ingest once the feed is 5 minutes old", async () => {
  Object.assign(env, { GITHUB_DISPATCH_TOKEN: "t\n", GITHUB_REPO: "o/r" });
  await ingestFeed();
  const f = stubFetch();
  assert.equal(await onSchedule(TICK, env, at("12:04"), f), "fresh");
  assert.equal(f.calls.length, 0);
  // The run started at the previous tick landed ~2 min later, so this tick sees an 8-min-old feed.
  assert.equal(await onSchedule(TICK, env, at("12:08"), f), "dispatched");
  assert.equal(f.calls.length, 1);
  const [{ url, init }] = f.calls;
  assert.equal(url, "https://api.github.com/repos/o/r/actions/workflows/ingest.yml/dispatches");
  assert.equal(init.method, "POST");
  assert.deepEqual(JSON.parse(init.body), { ref: "main" });
  assert.equal(init.headers.authorization, "Bearer t"); // trimmed, like INGEST_SECRET
  assert.equal(init.headers.accept, "application/vnd.github+json");
  assert.equal(init.headers["user-agent"], "newsfeed-api-worker");

  const branch = stubFetch();
  assert.equal(await onSchedule(TICK, { ...env, GITHUB_REF: "beta" }, at("12:30"), branch), "dispatched");
  assert.deepEqual(JSON.parse(branch.calls[0].init.body), { ref: "beta" });
});

test("cron reports failures instead of throwing", async (t) => {
  const error = t.mock.method(console, "error", () => {});
  Object.assign(env, { GITHUB_DISPATCH_TOKEN: "t", GITHUB_REPO: "o/r" });
  await ingestFeed();
  assert.equal(await onSchedule(TICK, env, at("12:20"), stubFetch(401, '{"message":"Bad credentials"}')), "failed");
  assert.match(error.mock.calls[0].arguments[0], /ingest\.yml: HTTP 401 .*Bad credentials/);
  const offline = async () => { throw new TypeError("fetch failed"); };
  assert.equal(await onSchedule(TICK, env, at("12:20"), offline), "failed");
  assert.equal(await onSchedule(DAILY_BRIEF_CRON, env, at("11:00"), stubFetch(404, "Not Found")), "failed");
  const brokenKV = { ...env, FEED: { getWithMetadata: async () => { throw new Error("KV unavailable"); } } };
  assert.equal(await onSchedule(TICK, brokenKV, at("12:20"), stubFetch()), "failed");
  assert.equal(error.mock.callCount(), 4);
});

test("cron retries a broken pipeline hourly instead of every 10 minutes", async () => {
  Object.assign(env, { GITHUB_DISPATCH_TOKEN: "t", GITHUB_REPO: "o/r" });
  const f = stubFetch();
  assert.equal(await onSchedule(TICK, env, at("17:20"), f), "backoff"); // no feed at all yet
  assert.equal(await onSchedule(TICK, env, at("17:00"), f), "dispatched");
  await ingestFeed(); // 12:00, so 5 h old below
  assert.equal(await onSchedule(TICK, env, at("17:25"), f), "backoff");
  assert.equal(await onSchedule(TICK, env, at("17:03"), f), "dispatched");
  assert.equal(await onSchedule(TICK, env, at("14:50"), f), "dispatched"); // under 3 h: every tick
  assert.equal(f.calls.length, 3);
});

test("the 11:00 UTC cron starts the daily brief", async () => {
  Object.assign(env, { GITHUB_DISPATCH_TOKEN: "t", GITHUB_REPO: "o/r" });
  await ingestFeed("2026-10-01T10:58:00Z"); // a fresh feed doesn't hold the brief back
  const f = stubFetch();
  assert.equal(await onSchedule(DAILY_BRIEF_CRON, env, at("11:00"), f), "dispatched");
  assert.deepEqual(f.calls.map((c) => c.url),
    ["https://api.github.com/repos/o/r/actions/workflows/daily-brief.yml/dispatches"]);
});

test("the scheduled handler runs the tick in the background", async (t) => {
  const log = t.mock.method(console, "log", () => {});
  t.mock.method(console, "warn", () => {});
  const pending = [];
  await worker.scheduled({ cron: TICK, scheduledTime: Date.now() }, env, { waitUntil: (p) => pending.push(p) });
  assert.equal(pending.length, 1);
  await Promise.all(pending);
  assert.equal(log.mock.calls[0].arguments[0], `cron ${TICK}: unconfigured`);
});

test("ingest returns pushes for matching users only, once per story", async () => {
  const gamer = await signIn({ sub: "gamer" });
  await call("PUT", "/v1/me/settings", { token: gamer.token, body: { categories: ["Gaming"] } });
  await call("POST", "/v1/me/devices", { token: gamer.token, body: { token: DEVICE, environment: "sandbox" } });
  const aiOnly = await signIn({ sub: "ai-person" });
  await call("PUT", "/v1/me/settings", { token: aiOnly.token, body: { categories: ["AI"] } });
  await call("POST", "/v1/me/devices", { token: aiOnly.token, body: { token: "b".repeat(64) } });
  await signIn({ sub: "no-device" }); // no device registered: never pushed

  const candidate = {
    id: "story1", title: "Nintendo Direct announced for tomorrow", url: "https://vgc.example/nd",
    category: "Gaming", label: "REPORTED", corroboration: 2, official: false, trustedNew: true,
    alertAllNew: false, sourceKeys: ["vgc", "ign"], titles: ["Nintendo Direct announced for tomorrow"],
  };
  const r = await call("POST", "/v1/internal/ingest", { token: "s3cret", body: { feed: feed(), candidates: [candidate] } });
  assert.equal(r.status, 200);
  assert.equal(r.body.pushes.length, 1);
  const [p] = r.body.pushes;
  assert.equal(p.token, DEVICE);
  assert.equal(p.environment, "sandbox");
  assert.equal(p.title, "Nintendo Direct [REPORTED]");
  assert.equal(p.url, "https://vgc.example/nd");

  const again = await call("POST", "/v1/internal/ingest", { token: "s3cret", body: { feed: feed(), candidates: [candidate] } });
  assert.equal(again.body.pushes.length, 0); // same story isn't pushed twice
});

test("invalid device tokens are removed; account deletion removes everything", async () => {
  const { token } = await signIn();
  await call("POST", "/v1/me/devices", { token, body: { token: DEVICE } });
  assert.equal((await call("POST", "/v1/me/devices", { token, body: { token: "zz" } })).status, 400);
  await call("POST", "/v1/internal/push-results", { token: "s3cret", body: { invalidTokens: [DEVICE] } });
  assert.equal(env.DB.raw.prepare("SELECT COUNT(*) n FROM devices").get().n, 0);

  await call("POST", "/v1/me/devices", { token, body: { token: DEVICE } });
  const del = await call("DELETE", "/v1/me", { token });
  assert.equal(del.status, 200);
  for (const table of ["users", "sessions", "devices"]) {
    assert.equal(env.DB.raw.prepare(`SELECT COUNT(*) n FROM ${table}`).get().n, 0, table);
  }
  assert.equal((await call("GET", "/v1/me", { token })).status, 401);
});

test("privacy policy page is served", async () => {
  const res = await worker.fetch(new Request(BASE + "/privacy"), env);
  assert.equal(res.status, 200);
  assert.match(await res.text(), /Delete account/);
});

test("unknown routes 404", async () => {
  assert.equal((await call("GET", "/v1/nope")).status, 404);
});
