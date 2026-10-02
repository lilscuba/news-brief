#!/bin/bash
# Deploys the app backend to Cloudflare and connects it to GitHub (macOS / Linux).
# Same as deploy.ps1. Run from anywhere:  bash server/deploy.sh
# Safe to re-run: existing database/namespace ids in wrangler.toml are kept.
set -uo pipefail
cd "$(dirname "$0")" || exit 1

step() { printf '\n== %s\n' "$1"; }
fail() { printf '\033[31m%s\033[0m\n' "$1"; exit 1; }

command -v npx >/dev/null || fail "Install Node.js first:  brew install node"

step "Installing wrangler (Cloudflare's CLI)"
npm install --silent || fail "npm install failed"

step "Logging in to Cloudflare"
# whoami exits 0 even when logged out, so read what it says.
who="$(npx wrangler whoami 2>&1)"
if printf '%s' "$who" | grep -q "not authenticated" || ! printf '%s' "$who" | grep -Eq "Account ID|associated with the email"; then
  printf "\033[33mA browser page opens. No Cloudflare account? Click 'Sign up' -> 'Continue with GitHub'.\033[0m\n"
  npx wrangler login || fail "wrangler login failed"
fi

if grep -q 'com\.yourname\.newsfeed' wrangler.toml; then
  read -r -p "Your iOS app bundle id (e.g. com.davidr.brief): " bundle
  [ -n "$bundle" ] || fail "A bundle id is required."
  sed -i '' "s/com\.yourname\.newsfeed/$bundle/" wrangler.toml
fi

if grep -q REPLACE_WITH_D1_ID wrangler.toml; then
  step "Creating the database"
  out="$(npx wrangler d1 create newsfeed 2>&1)"
  id="$(printf '%s' "$out" | grep -Eo '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
  [ -n "$id" ] || { printf '%s\n' "$out"; fail "Couldn't read the database id (if it already exists, paste its id into wrangler.toml)."; }
  sed -i '' "s/REPLACE_WITH_D1_ID/$id/" wrangler.toml
fi

if grep -q REPLACE_WITH_KV_ID wrangler.toml; then
  step "Creating the feed store"
  out="$(npx wrangler kv namespace create FEED 2>&1)"
  id="$(printf '%s' "$out" | grep -Eo '"?id"?[ =:]+"[0-9a-f]{32}"' | grep -Eo '[0-9a-f]{32}' | head -1)"
  [ -n "$id" ] || { printf '%s\n' "$out"; fail "Couldn't read the KV namespace id; paste it into wrangler.toml."; }
  sed -i '' "s/REPLACE_WITH_KV_ID/$id/" wrangler.toml
fi

step "Creating tables"
npx wrangler d1 execute newsfeed --remote --file=schema.sql --yes || fail "d1 execute failed"

step "Setting the ingest secret"
secret="$(openssl rand -hex 32)"
printf '%s' "$secret" | npx wrangler secret put INGEST_SECRET || fail "wrangler secret put failed"

step "Deploying"
out="$(npx wrangler deploy 2>&1)"
printf '%s\n' "$out"
url="$(printf '%s' "$out" | grep -Eo 'https://[a-z0-9.-]+\.workers\.dev' | head -1)"
[ -n "$url" ] || fail "Deploy didn't print a workers.dev URL; check the output above."
url="$url/"
printf '{ "url": "%s" }\n' "$url" > .deployed.json   # remembered for launch.sh (ignored by git)

step "Connecting GitHub (the 15-minute ingest job)"
repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)"
if [ -n "$repo" ]; then
  gh variable set WORKER_URL -R "$repo" -b "$url" || fail "gh variable set failed"
  gh secret set INGEST_SECRET -R "$repo" -b "$secret" || fail "gh secret set failed"
  gh workflow run ingest.yml -R "$repo" && echo "Started the first ingest run on $repo."
else
  printf '\033[33mNot in a GitHub repo yet. Add variable WORKER_URL=%s and secret INGEST_SECRET by hand.\033[0m\n' "$url"
  echo "INGEST_SECRET: $secret"
fi

printf '\n\033[32m== Backend is live ==\033[0m\n'
echo "API:            $url"
echo "Health check:   ${url}v1/health"
echo "Privacy policy: ${url}privacy   (use this URL in App Store Connect)"
