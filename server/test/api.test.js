import assert from "node:assert/strict";
import { before, beforeEach, test } from "node:test";

import worker from "../src/index.js";
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
