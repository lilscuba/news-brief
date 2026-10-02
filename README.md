# Personal Feed

A gaming / tech / AI news feed built to replace scrolling Reddit. It runs in two modes:

- **The app, for anyone.** People download Brief, tap **Sign in with Apple**, pick their topics,
  sources and alerts, and get their own feed plus push notifications. One shared backend serves
  everyone: GitHub Actions for ingest, a Cloudflare Worker for accounts. To deploy and ship it,
  follow **[server/README.md](server/README.md)**.
- **Just for you**, with no app or accounts: a daily brief web page plus email and ntfy alerts
  from your own GitHub repo, described below.

Both modes use the same pipeline in `briefing/`.

## Start here: one guided launcher

**On a Mac (recommended, because only a Mac can build the iPhone app):** unzip the folder,
then double-click **`Launch Brief.command`**. The first time, macOS blocks scripts it hasn't
seen before: right-click the file → **Open** → **Open**. Or, in Terminal, run:
```bash
bash launch.sh
```
The Mac launcher goes further than the Windows one:
- installs Homebrew, the GitHub CLI, Node and XcodeGen
- reads your Team ID from Xcode
- lets Xcode register the app with Apple automatically
- builds the app and installs it on your plugged-in iPhone

**On Windows** (everything except building the app), right-click the folder background →
**Open in Terminal**, then run:
```powershell
powershell -ExecutionPolicy Bypass -File .\launch.ps1
```
It walks through everything one step at a time ("Step 3 of 8"). Each screen says what will
happen, what you'll need, and how long it takes. Press Enter to do the step, `s` to skip it, or
`q` to stop. It remembers where you stopped; run it again to continue, or add `-Status` to just
see the checklist.

**Accounts: it checks what you're already signed in to and skips those.** For the rest it opens
the right page and tells you what to click. Each new account signs in with one you already have,
so there are no new passwords:

| Account | How |
|---|---|
| Apple ID | you already have it (the one with your developer membership) |
| GitHub | **Continue with Apple** |
| Cloudflare (app mode) | **Continue with GitHub** |
| Google (optional: Gemini key, Gmail) | your existing Gmail |
| ntfy | no account; just install the app |

It also fills in the config files for you (app id, Apple Team ID, server URL), finds your
downloaded Apple push key in Downloads, and stores it as an encrypted GitHub secret.

## Personal mode

It runs free on GitHub and has three parts:

1. **Daily brief** (GitHub Actions, once a day). It reads 35 sources: outlet RSS feeds, official
   company feeds, two newsletters and eight gaming/tech journalists on Bluesky. It drops
   headlines matching your mute words, clusters the same story across outlets, ranks stories
   (coverage, official sources, Hacker News points, your keyword boosts) and gives each one a
   reliability label. The result is published to GitHub Pages as `brief.json` and a mobile web
   page, and a "your brief is ready" push and email go out.

   **AI summaries are off for now.** The brief lists every new article under AI / Tech / Gaming
   / Deals with its original headline and the feed's snippet, with the 5 highest-ranked stories
   on top. Turn on summaries (free with Gemini) and the model writes the brief instead.
2. **Breaking alerts** (GitHub Actions, every 15 min). These are push notifications through ntfy,
   in four tiers (below), capped at 5 a day.
3. **Web page**: the brief at your GitHub Pages URL. Add it to your Home Screen. (The iOS app
   in `ios/` is the multi-user app above.)

```
feeds.opml ──► fetch (RSS + Bluesky API) ──► mute ──► cluster (URL + headline) ──► rank + label
                                                                                      │
             docs/brief.json ◄── attach real links ◄── [optional] Gemini / Claude ◄──┘
             docs/index.html, docs/archive/ ──► GitHub Pages ──► iPhone app / browser / email
```

## Setup (about 10 minutes)

### 1. Sign-ups (all free; the script can't do these for you)

These need CAPTCHAs, phone or email verification and passwords, so you do them yourself.

| | Link | Needed for |
|---|---|---|
| GitHub account | https://github.com/signup | everything |
| ntfy app on iPhone | App Store, search "ntfy" (no account) | push alerts |
| Gemini API key | https://aistudio.google.com/apikey → Create API key | AI summaries (optional, free tier) |
| Google 2-Step Verification | https://myaccount.google.com/signinoptions/twosv | Gmail app password |
| Gmail app password | https://myaccount.google.com/apppasswords → name it `news-brief` | emailing the brief (optional) |
| NetNewsWire | App Store (no account) | browsing every source yourself (optional) |

### 2. Run the setup script

**Windows** (from this folder in PowerShell):
```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```
**Mac**:
```bash
chmod +x setup.sh && ./setup.sh
```

The script:
- installs the GitHub CLI if needed and logs you in through the browser
- creates a **public** repo (default name `news-brief`) and pushes this folder to it
- asks for your Gemini key, Gmail address and app password. Input is hidden, any of them can be
  skipped, and each is stored as an encrypted GitHub secret
- generates a private ntfy topic
- turns on GitHub Pages, starts the first brief and sends a test push

At the end it prints your ntfy topic. In the ntfy app, tap **+** and subscribe to it.

It's safe to re-run. To change a key later, re-run it or edit the secrets in **Settings →
Secrets and variables → Actions**.

**Why public?** GitHub Pages and unlimited Actions minutes are free only for public repos, and
the 15-minute alert job alone uses about 2,900 minutes a month. Nothing secret lives in the
files.

### 3. Read it on your phone
Open the brief URL in Safari and use Share → Add to Home Screen. For the real app, with sign-in
and push for anyone, see [server/README.md](server/README.md).

### Turning on AI summaries
Set the repo variable `SUMMARIZE` to `true` in **Settings → Secrets and variables → Actions →
Variables**. The setup script offers this if you gave it a Gemini key. The default provider is
Gemini (`gemini-3.8-flash`, free tier). Set the `AI_PROVIDER` variable to `claude` and add an
`ANTHROPIC_API_KEY` secret to use Claude instead (paid, roughly $1–12 a month depending on the
model). If the AI call ever fails, the plain list is published instead.

When summaries are on, the model only sees numbered story clusters and returns cluster ids.
Every link in the brief comes from the feeds, so it can't invent URLs. It also assigns the
reliability labels and is told to write rumors as rumors.

## Sources

| Folder | Sources |
|---|---|
| Tech | Techmeme, The Verge, Ars Technica, TechCrunch, 9to5Mac, Hacker News (100+ points) |
| AI | OpenAI, Google DeepMind, Google AI (official); Anthropic and Meta AI (community mirrors); Verge AI, Ars AI, HN Claude/Anthropic, arXiv cs.AI (capped at 12) |
| Gaming | VGC, Eurogamer, IGN, Gematsu, Insider Gaming, GoNintendo; PlayStation Blog, Xbox Wire, Nintendo of Europe (official); Steam News; Game File (Totilo) and The Game Business (Dring) newsletters |
| Social (Bluesky) | Wario64, billbil-kun, Jeff Grubb, Jason Schreier, Stephen Totilo, Christopher Dring, Mat Piscatella, Tom Warren |

Notes on the sources:
- **Bluesky** posts come from the public API with no account. Replies, reposts and posts with no
  link or news marker (EXCLUSIVE, BREAKING, NEW:) are dropped, so you get scoops and article
  shares rather than sports takes. The handles were checked against follower counts and recent
  activity because lookalike accounts exist, especially for Wario64.
- **Skipped on purpose:**
  - X/Twitter: free access is effectively dead, and the paid API costs money.
  - Daniel Ahmad: no Bluesky account found.
  - Tom Henderson: his Bluesky has been inactive since March. Insider Gaming's feed covers his
    reporting.
  - Tom Warren's Notepad: paywalled, with no feed. His Bluesky covers it.
- **No scraping.** Anthropic's and Meta's sites disallow automated collection (robots.txt / ToS),
  so they come from community mirrors. Nintendo has an official feed.

## Labels

Every story carries one label, in the brief, the app and alerts:

| Label | Meaning |
|---|---|
| CONFIRMED | an official / first-party source published it |
| REPORTED | an outlet reports it, not confirmed by the company |
| RUMOR-CREDIBLE | a leak from a source with a strong track record (`pfTrusted`), or several outlets |
| RUMOR-UNVERIFIED | a leak from a single source without that track record |
| DEAL | a sale or discount; deals go in their own section and never alert |

In list mode the labels come from keyword rules (`briefing/labels.py`). With AI summaries on,
the model assigns them, using the rules' guess as a hint.

## Alert tiers

| Tier | Fires when | Example |
|---|---|---|
| 1 Official | an official lab feed marked `pfAlert="all"` posts anything | OpenAI publishes a post |
| 2 Trusted | a trusted source (`pfTrusted`) posts a headline matching a watchlist rule; one source is enough | billbil-kun: "Nintendo Direct next week" |
| 3 Corroborated | a watchlist headline is covered by 2+ outlets (official counts double) | Verge + Ars on "Gemini 5 launch" |
| 4 Digest | everything else waits for the daily brief | |

Each watchlist rule cools down for 12 hours after firing, there are at most 5 alerts a day
(official alerts go first), and every alert shows its label. The watchlist lives in
`config.toml` under `[[alerts.watch]]`.

## Tuning

- **`feeds.opml`**: add or remove sources. It also imports into NetNewsWire or any RSS reader.
  Attributes:
  - `pfOfficial="true"`: first-party source; gets a ranking boost, CONFIRMED label, and counts
    double for alerts
  - `pfTrusted="true"`: proven scoop record; its leaks are RUMOR-CREDIBLE and it can alert solo
  - `pfAlert="all" | "watch" | "never"`
  - `pfMaxItems="N"`: cap a firehose feed
  - `pfCategory="Gaming"`: the section for a feed in another folder (used by Social)
  - `pfMirror="true"`: unofficial mirror, flagged if it goes stale

  To add a Bluesky account, use `xmlUrl="https://bsky.app/profile/HANDLE/rss"`.
- **`config.toml`**:
  - mute words
  - keyword boosts
  - watchlist rules
  - daily alert cap
  - timezone
  - sections
  - AI provider and model
- **Delivery time**: the cron in `.github/workflows/daily-brief.yml`. It defaults to 11:00 UTC,
  which is 7am Eastern in summer.

| Repo variable / secret | What |
|---|---|
| `SUMMARIZE` (variable) | `true` turns on AI summaries |
| `AI_PROVIDER`, `GEMINI_MODEL`, `CLAUDE_MODEL` (variables) | override `config.toml` |
| `GEMINI_API_KEY` / `ANTHROPIC_API_KEY` (secrets) | AI provider keys |
| `GMAIL_ADDRESS`, `GMAIL_APP_PASSWORD` (secrets) | email the brief to yourself |
| `NTFY_TOPIC` (secret) | push alerts; unguessable, because anyone with the name can read them |
| `PAGES_URL` (variable) | the brief URL that tapping a push opens |
| `PUSHOVER_TOKEN`, `PUSHOVER_USER`, `SMTP_*`, `NTFY_SERVER`, `NTFY_TOKEN` | alternatives |

## Running locally

```bash
pip install -r requirements.txt pytest
```
```bash
python -m briefing feeds
```
```bash
python -m briefing digest --dry-run
```
```bash
python -m briefing alerts --dry-run
```
```bash
python -m pytest -q
```

- `feeds` checks every source.
- `digest --dry-run` prints the brief without writing files. `--no-llm` forces the plain list.
- `alerts --dry-run` prints alerts it would send.

`python -m briefing digest` writes the real thing into `docs/` (open `docs/index.html`).

## Health checks
The brief's footer (and the app's) lists any source that's erroring or hasn't produced anything
new in 14 days. The Anthropic and Meta AI mirrors are the most likely to break. Meta posts
rarely, so a quiet Meta feed isn't necessarily broken.

Reddit's RSS ends November 13, 2026; nothing here depends on it.

## Layout
```
setup.ps1 / setup.sh  one-shot GitHub setup (repo, secrets, Pages, first run)
briefing/             Python pipeline
  feeds.py            OPML loading, concurrent fetch with retry, RSS parsing
  bluesky.py          Bluesky accounts via the public getAuthorFeed API
  dedupe.py           URL + IDF-weighted headline clustering
  rank.py             scoring, mute filter
  labels.py           CONFIRMED / REPORTED / RUMOR-* / DEAL rules
  summarize.py        Gemini or Claude (structured output) + plain-list brief
  digest.py           daily brief orchestration, publishing, archive
  alerts.py           four-tier breaking-news alerts
  render.py           HTML page / email / plain text
  deliver.py          ntfy, Pushover, Gmail / SMTP
  state.py            seen items, feed health
tests/                pytest suite
ios/                  SwiftUI app (XcodeGen project.yml)
docs/                 published site (written by the daily job)
state/digest.json     already-briefed items + feed health (committed by the job)
```
