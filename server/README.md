# Newsfeed app backend

This is what lets anyone download the app, sign in with Apple, and get their own feed. There are
three pieces, and none of them cost anything at small scale:

| Piece | Runs on | Does |
|---|---|---|
| Ingest (`python -m briefing ingest`) | GitHub Actions, started every 10 min by the Worker (`.github/workflows/ingest.yml`) | fetches all ~175 sources in `feeds.opml` once for everyone, clusters + labels + ranks, finds breaking stories, sends pushes via APNs |
| API (`server/src`) | Cloudflare Worker + D1 (SQLite) + KV | Sign in with Apple, per-user settings, push device registry, serves the shared feed, decides who gets which push, account deletion, privacy page; its cron starts the ingest and daily-brief workflows |
| App (`ios/`) | each iPhone | onboarding, builds the person's brief from the shared feed using their settings, history, push handling |

```
Worker cron (every 10 min) ──workflow_dispatch──► GitHub Action
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
- optionally stores a GitHub token so the feed updates every 10 minutes (see
  [Keeping the feed fresh](#keeping-the-feed-fresh))

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

### 5. Keep the feed fresh (recommended)
See [Keeping the feed fresh](#keeping-the-feed-fresh) below: one GitHub token makes the feed update
every 10 minutes instead of every few hours.

### 6. Ship it
- **TestFlight**: Product → Archive → Distribute → App Store Connect. Testers install through
  the TestFlight app.
- **App Store**: in App Store Connect, add the privacy policy URL (`https://<worker>/privacy`)
  and complete the privacy "nutrition label". The data collected is a user ID and device ID,
  used for app functionality and not linked to identity for tracking. The in-app "Delete
  account" button covers Apple's account-deletion rule.

## Keeping the feed fresh

GitHub starts scheduled workflows late, often by 3 to 6 hours, so a schedule alone leaves the feed and
breaking-news pushes hours old. Runs started through GitHub's API (`workflow_dispatch`) start right
away, so the Worker's cron starts them:

- **Every 10 minutes** it checks how old the feed is. Under 5 minutes old (a run just landed), it does
  nothing. Otherwise it starts `ingest.yml`, which rebuilds the app feed, sends the app pushes, and
  also runs the personal ntfy/Pushover breaking-news check (its `alerts` job). If the feed is more
  than 3 hours old, something is failing, so it retries once an hour instead of every 10 minutes
  (each failed run sends you an email).
- **At 11:00 UTC** (7:00 New York in summer, 6:00 in winter) it starts `daily-brief.yml`. That run
  skips itself if today's brief already went out. To resend by hand, run the workflow with
  **force** ticked. To pick another time, change `"0 11 * * *"` in `wrangler.toml` and
  `DAILY_BRIEF_CRON` in `src/index.js`, and move the backstop `"41 12 * * *"` in
  `.github/workflows/daily-brief.yml` to after the new time. A backstop that fires first sends the
  day's brief early.

GitHub's own schedules stay as backstops (ingest at :07 and :37, breaking alerts every 2 hours, the
daily brief at 12:41 UTC). Without the token below, they're all that runs, and GitHub often starts
them hours late, so the feed can be several hours old.

**One-time setup (about 3 minutes):**
1. Create a fine-grained token at https://github.com/settings/personal-access-tokens/new:
   - **Repository access**: Only select repositories → `lilscuba/news-brief`.
   - **Repository permissions** → **Actions**: Read and write. (Metadata: Read-only is added
     automatically.) Nothing else.
   - **Expiration**: pick a date (GitHub may cap it at a year) and put a reminder in your
     calendar to make a new one.
2. Store it in the Worker (paste it when asked):
   ```bash
   npx wrangler secret put GITHUB_DISPATCH_TOKEN
   ```
3. Deploy, so the cron triggers start (they can take a few minutes to begin):
   ```bash
   npx wrangler deploy
   ```
4. The cron starts the workflows on `main` (`GITHUB_REF` in `wrangler.toml`), so merge the workflow
   changes there first.

`deploy.sh` and `deploy.ps1` offer to do steps 2 and 3 for you.

**Check it's working:** open `https://<worker>/v1/health`. It returns
`{"ok":true,"feed":{"generatedAt":"…","ageSeconds":312,"stale":false}}`; `stale` turns true when the
feed is more than 30 minutes old. In GitHub → Actions, "Shared feed (app backend)" runs every 10
minutes with the event `workflow_dispatch`. The Worker logs each tick (Cloudflare dashboard → Workers
→ newsfeed-api → Logs, or `npx wrangler tail`) as `cron */10 * * * *:` followed by one of:
- `dispatched` or `fresh`: working.
- `unconfigured`: the secret isn't set.
- `backoff`: the feed is over 3 hours old; look at the failed runs in GitHub Actions.
- `failed`, with a `dispatch ingest.yml: HTTP …` line just before it. 401: the token expired or was
  revoked, so make a new one and repeat step 2. 403: the token lacks Actions write access to
  this repo. 404: `GITHUB_REPO` is wrong or the workflow isn't on `main`. 422: `GITHUB_REF`
  isn't a branch.

**What the token can do:** start, cancel and re-run workflows, and delete their logs, artifacts and
caches, in this one repo. It can't push commits, change settings or read secrets. Runs it starts
email their failures to you, the token's owner.

**Test the cron locally:**
```bash
npx wrangler dev --test-scheduled
```
```bash
curl "http://localhost:8787/__scheduled?cron=*/10+*+*+*+*"
```
Without a token in `.dev.vars` it logs `unconfigured`.

## API

| Method | Path | Auth | |
|---|---|---|---|
| GET | `/v1/feed` | none | shared feed (ETag / 304, weak `W/"…"` and lists accepted) |
| POST | `/v1/auth/apple` | none | `{identityToken, timezone}` → `{token, created, user, settings}` |
| POST | `/v1/auth/logout` | session | end the session |
| GET | `/v1/me` | session | `{user, settings}` |
| PUT | `/v1/me/settings` | session | partial settings → merged + validated settings |
| POST | `/v1/me/devices` | session | `{token, environment}` register for push |
| DELETE | `/v1/me/devices/:token` | session | unregister |
| DELETE | `/v1/me` | session | delete the account |
| POST | `/v1/internal/ingest` | ingest secret | feed + alert candidates → pushes to send |
| POST | `/v1/internal/push-results` | ingest secret | forget dead device tokens |
| GET | `/v1/health` | none | `{ok, feed: {generatedAt, ageSeconds, stale}}`; stale = older than 30 min |
| GET | `/privacy` | none | privacy policy |

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
- **Cloudflare free tier**: 100k requests a day, 5 GB D1 storage, 1,000 KV writes a day and 5 cron
  triggers per account. Ingest writes the feed once per run, about 150 writes a day at the
  10-minute cadence, and the Worker uses 2 cron triggers. That's roughly several thousand daily
  users before you'd pay ($5/month Workers Paid lifts every limit).
- **GitHub Actions**: free for a public repo. Each ingest run takes a little over a minute; at
  10-minute intervals that's about 144 runs a day. On a private repo that would use up the free
  minutes quickly, so leave the token out there and rely on the backstop schedules.
- **Alert matching**: users are scanned in memory on each ingest. That's fine into the tens of
  thousands; beyond that, move it to a queue.
- **Sessions**: they don't expire on their own. Signing out or deleting the account revokes them.
