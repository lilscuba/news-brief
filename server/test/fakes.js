// In-memory stand-ins for the Cloudflare bindings, backed by Node's built-in SQLite so the real
// schema.sql and SQL statements are exercised.
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";

class Stmt {
  constructor(db, sql, params = []) {
    this.db = db;
    this.sql = sql;
    this.params = params;
  }
  bind(...params) {
    return new Stmt(this.db, this.sql, params);
  }
  async first() {
    return this.db.prepare(this.sql).get(...this.params) ?? null;
  }
  async all() {
    return { results: this.db.prepare(this.sql).all(...this.params) };
  }
  async run() {
    this.db.prepare(this.sql).run(...this.params);
    return { success: true };
  }
}

export function fakeD1() {
  const db = new DatabaseSync(":memory:");
  db.exec("PRAGMA foreign_keys = ON");
  db.exec(readFileSync(new URL("../schema.sql", import.meta.url), "utf8"));
  return {
    raw: db,
    prepare: (sql) => new Stmt(db, sql),
    async batch(stmts) {
      db.exec("BEGIN");
      try {
        for (const s of stmts) await s.run();
        db.exec("COMMIT");
      } catch (e) {
        db.exec("ROLLBACK");
        throw e;
      }
    },
  };
}

export function fakeKV() {
  const store = new Map();
  return {
    async get(key, type) {
      const v = store.get(key);
      if (!v) return null;
      return type === "json" ? JSON.parse(v.value) : v.value;
    },
    async getWithMetadata(key) {
      const v = store.get(key);
      return v ? { value: v.value, metadata: v.metadata } : { value: null, metadata: null };
    },
    async put(key, value, opts = {}) {
      store.set(key, { value, metadata: opts.metadata ?? null });
    },
  };
}

/** An RSA key pair standing in for Apple's, plus a signer for identity tokens. */
export async function fakeApple(audience = "com.test.newsfeed") {
  const { publicKey, privateKey } = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true, ["sign", "verify"],
  );
  const jwk = { ...(await crypto.subtle.exportKey("jwk", publicKey)), kid: "test-kid", use: "sig" };
  const enc = (obj) => Buffer.from(JSON.stringify(obj)).toString("base64url");
  async function token(claims = {}, header = {}) {
    const now = Math.floor(Date.now() / 1000);
    const h = enc({ alg: "RS256", kid: "test-kid", ...header });
    const p = enc({ iss: "https://appleid.apple.com", aud: audience, sub: "apple-user-1", iat: now, exp: now + 600, ...claims });
    const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", privateKey, new TextEncoder().encode(`${h}.${p}`));
    return `${h}.${p}.${Buffer.from(sig).toString("base64url")}`;
  }
  return { jwks: { keys: [jwk] }, token, audience };
}
