# Newsfeed app backend

This is what lets anyone download the app, sign in with Apple, and get their own feed. There are
three pieces, and none of them cost anything at small scale:

| Piece | Runs on | Does |
|---|---|---|
| Ingest (`python -m briefing ingest`) | GitHub Actions, every 15 min (`.github/workflows/ingest.yml`) | fetches all 35 sources once for everyone, clusters + labels + ranks, finds breaking stories, sends pushes via APNs |
| API (`server/src`) | Cloudflare Worker + D1 (SQLite) + KV | Sign in with Apple, per-user settings, push device registry, serves the shared feed, decides who gets which push, account deletion, privacy page |
| App (`ios/`) | each iPhone | onboarding, builds the person's brief from the shared feed using their settings, history, push handling |

```
GitHub Action ──(feed + new stories)──► Worker ──► D1: users, settings, devices
      ▲                                   │
      └────── pushes to send (per user) ◄─┘
      │
      └─► APNs ─► iPhones          iPhones ──► Worker: GET /v1/feed, sign in, settings
```

The Worker decides who gets which push, but the Action sends them. APNs requires HTTP/2, which
the Python sender handles reliably.

**Privacy by design:**
- An account is an anonymous Apple user id plus settings. No name, email or reading history is
  stored.
- Session tokens are stored hashed.
- Read and unread state and history stay on the phone.
- Deleting the account (in the app) removes everything.
- The privacy policy is served at `/privacy`.

## One-time setup

### 1. Apple Developer portal (developer.apple.com, needs your paid membership)
1. **Identifiers → +**. Create an App ID with your bundle id (e.g. `com.davidr.newsfeed`) and
   tick **Sign in with Apple** and **Push Notifications**.
2. **Keys → +**. Create a key with **Apple Push Notifications service (APNs)** enabled and
   download the `.p8` file. You can only download it once. Note the **Key ID** and your
   **Team ID** (shown at the top right of the page).

### 2. Deploy the API (Cloudflare, free)
Sign up at https://dash.cloudflare.com/sign-up, then from this folder run:
```powershell
powershell -ExecutionPolicy Bypass -File .\deploy.ps1
```
The script:
- installs wrangler and logs you in
- asks for your bundle id
- creates the D1 database and KV namespace and writes their ids into `wrangler.toml`
- creates the tables and generates the ingest secret
- deploys the Worker
- stores `WORKER_URL` and `INGEST_SECRET` in the GitHub repo and starts the first ingest

On a Mac, run the same steps by hand:
```bash
npm install && npx wrangler login
```
```bash
npx wrangler d1 create newsfeed
```
```bash
npx wrangler kv namespace create FEED
```
Paste both ids into `wrangler.toml` and set `APPLE_BUNDLE_IDS`, then:
```bash
npx wrangler d1 execute newsfeed --remote --file=schema.sql
```
```bash
npx wrangler secret put INGEST_SECRET
```
```bash
npx wrangler deploy
```

### 3. Push notification secrets (GitHub → Settings → Secrets and variables → Actions)
| Name | Value |
|---|---|
| `APNS_KEY` | full contents of the `.p8` file, including the BEGIN/END lines |
| `APNS_KEY_ID` | the key's 10-character id |
| `APNS_TEAM_ID` | your team id |
| `APNS_TOPIC` | your bundle id |

`WORKER_URL` (variable) and `INGEST_SECRET` (secret) are set by `deploy.ps1`.

### 4. Point the app at the API
In `ios/project.yml`, set `PRODUCT_BUNDLE_IDENTIFIER`, `DEVELOPMENT_TEAM` and `API_BASE_URL`
(the URL `deploy.ps1` printed). Then, on a Mac:
```bash
cd ios && xcodegen && open PersonalFeed.xcodeproj
```
Run the app on a real iPhone. The simulator can sign in but can't receive push notifications.

### 5. Ship it
- **TestFlight**: Product → Archive → Distribute → App Store Connect. Testers install through
  the TestFlight app.
- **App Store**: in App Store Connect, add the privacy policy URL (`https://<worker>/privacy`)
  and complete the privacy "nutrition label". The data collected is a user ID and device ID,
  used for app functionality and not linked to identity for tracking. The in-app "Delete
  account" button covers Apple's account-deletion rule.

## API

| Method | Path | Auth | |
|---|---|---|---|
| GET | `/v1/feed` | none | shared feed (ETag / 304 supported) |
| POST | `/v1/auth/apple` | none | `{identityToken, timezone}` → `{token, created, user, settings}` |
| POST | `/v1/auth/logout` | session | end the session |
| GET | `/v1/me` | session | `{user, settings}` |
| PUT | `/v1/me/settings` | session | partial settings → merged + validated settings |
| POST | `/v1/me/devices` | session | `{token, environment}` register for push |
| DELETE | `/v1/me/devices/:token` | session | unregister |
| DELETE | `/v1/me` | session | delete the account |
| POST | `/v1/internal/ingest` | ingest secret | feed + alert candidates → pushes to send |
| POST | `/v1/internal/push-results` | ingest secret | forget dead device tokens |
| GET | `/privacy`, `/v1/health` | none | |

## Development
```bash
npm test
```
```bash
python -m briefing ingest --dry-run
```
- `npm test` runs the Worker tests on Node's built-in SQLite, with a locally generated RSA key
  standing in for Apple's.
- `ingest --dry-run` writes `server/dev/feed.json` without uploading.

## Limits and costs
- **Cloudflare free tier**: 100k requests a day, 5 GB D1 storage, and 1,000 KV writes a day.
  Ingest uses about 100 writes a day. That's roughly several thousand daily users before you'd
  pay ($5/month Workers Paid lifts every limit).
- **Alert matching**: users are scanned in memory on each ingest. That's fine into the tens of
  thousands; beyond that, move it to a queue.
- **Sessions**: they don't expire on their own. Signing out or deleting the account revokes them.
