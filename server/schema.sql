-- D1 schema. Apply with:  npx wrangler d1 execute newsfeed --remote --file=schema.sql
-- No names, emails or reading history are stored: an account is an opaque Apple user id plus
-- settings, sessions are stored hashed, and devices are push tokens.

CREATE TABLE IF NOT EXISTS users (
  id          TEXT PRIMARY KEY,
  apple_sub   TEXT NOT NULL UNIQUE,
  created_at  TEXT NOT NULL,
  settings    TEXT NOT NULL,              -- JSON, see src/settings.js
  alert_day   TEXT,                       -- user's local date the alert count applies to
  alert_count INTEGER NOT NULL DEFAULT 0,
  alert_keys  TEXT NOT NULL DEFAULT '[]', -- story ids already pushed (last 200)
  brief_day   TEXT                        -- local date the "brief ready" push last went out
);

CREATE TABLE IF NOT EXISTS sessions (
  token_hash  TEXT PRIMARY KEY,           -- SHA-256 of the bearer token
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS sessions_user ON sessions(user_id);

CREATE TABLE IF NOT EXISTS devices (
  token       TEXT PRIMARY KEY,           -- APNs device token (hex)
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  environment TEXT NOT NULL,              -- production | sandbox
  updated_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS devices_user ON devices(user_id);
