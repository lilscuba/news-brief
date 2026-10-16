#!/usr/bin/env bash
# Personal Feed setup for macOS / Linux: publishes this folder to GitHub, stores your keys as
# GitHub secrets, turns on GitHub Pages, runs the first brief, and sends a test push.
#
# Before running, have ready (all free):
#   - a GitHub account                      https://github.com/signup
#   - the ntfy app on your iPhone           (App Store, no account needed)
#   - optional: Gemini API key              https://aistudio.google.com/apikey
#   - optional: Gmail app password          https://myaccount.google.com/apppasswords
#                                           (needs 2-Step Verification turned on first)
#
# Run from this folder:   chmod +x setup.sh && ./setup.sh
# Safe to re-run: existing repo, Pages site and secrets are reused or updated.
set -euo pipefail
cd "$(dirname "$0")"

step() { printf '\n== %s\n' "$1"; }

step "Checking tools"
command -v git >/dev/null || { echo "Install Git first (xcode-select --install)."; exit 1; }
if ! command -v gh >/dev/null; then
  if command -v brew >/dev/null; then
    brew install gh
  else
    echo "Install Homebrew (https://brew.sh) or GitHub CLI (https://cli.github.com), then re-run."
    exit 1
  fi
fi
if ! gh auth status >/dev/null 2>&1; then
  step "Logging in to GitHub (a browser window opens)"
  gh auth login --web --git-protocol https
fi
GH_USER=$(gh api user --jq .login)

step "Repository"
read -rp "Repo name [news-brief]: " REPO
REPO=${REPO:-news-brief}
FULL="$GH_USER/$REPO"
if gh repo view "$FULL" >/dev/null 2>&1; then
  echo "Using existing https://github.com/$FULL"
else
  # Public: GitHub Pages and unlimited Actions minutes are free only for public repos.
  # Nothing secret lives in the files; keys are stored as encrypted secrets.
  gh repo create "$FULL" --public --description "Personal daily gaming, tech and AI news brief"
fi

step "Pushing the code"
[ -d .git ] || git init -b main
if [ -z "$(git config user.email || true)" ]; then
  git config user.name "$GH_USER"
  git config user.email "$GH_USER@users.noreply.github.com"
fi
REMOTE="https://github.com/$FULL.git"
git remote set-url origin "$REMOTE" 2>/dev/null || git remote add origin "$REMOTE"
git add -A
git diff --cached --quiet || git commit -m "Personal Feed: daily brief, breaking alerts, iOS app"
git branch -M main
if git ls-remote --exit-code --heads origin main >/dev/null 2>&1; then
  # The repo already has commits (e.g. a README from an earlier setup); keep our versions.
  git pull origin main --allow-unrelated-histories --no-rebase -X ours --no-edit
fi
git push -u origin main

step "Secrets (input is hidden; press Enter to skip any)"
read -rsp "Gemini API key: " GEMINI_API_KEY; echo
[ -n "$GEMINI_API_KEY" ] && gh secret set GEMINI_API_KEY -R "$FULL" -b "$GEMINI_API_KEY"

read -rp "Gmail address (to email yourself the brief): " GMAIL_ADDRESS
if [ -n "$GMAIL_ADDRESS" ]; then
  read -rsp "Gmail app password (16 chars, spaces OK): " GMAIL_APP_PASSWORD; echo
  GMAIL_APP_PASSWORD=${GMAIL_APP_PASSWORD// /}
  if [ -n "$GMAIL_APP_PASSWORD" ]; then
    gh secret set GMAIL_ADDRESS -R "$FULL" -b "$GMAIL_ADDRESS"
    gh secret set GMAIL_APP_PASSWORD -R "$FULL" -b "$GMAIL_APP_PASSWORD"
  fi
fi

read -rp "Existing ntfy topic (Enter to generate a new private one): " NTFY_TOPIC
NTFY_TOPIC=${NTFY_TOPIC:-news-$(openssl rand -hex 8)}
gh secret set NTFY_TOPIC -R "$FULL" -b "$NTFY_TOPIC"

SUMMARIZE=false
if [ -n "$GEMINI_API_KEY" ]; then
  read -rp "Turn on Gemini AI summaries now? Otherwise you get the plain article list (y/N): " ANSWER
  [[ "$ANSWER" =~ ^[yY] ]] && SUMMARIZE=true
fi
PAGES_URL="https://$(echo "$GH_USER" | tr '[:upper:]' '[:lower:]').github.io/$REPO/"
gh variable set SUMMARIZE -R "$FULL" -b "$SUMMARIZE"
gh variable set PAGES_URL -R "$FULL" -b "$PAGES_URL"
unset GEMINI_API_KEY GMAIL_APP_PASSWORD

step "Turning on GitHub Pages (deployed by the workflow)"
if gh api "repos/$FULL/pages" >/dev/null 2>&1; then
  gh api -X PUT "repos/$FULL/pages" -f build_type=workflow --silent
else
  gh api -X POST "repos/$FULL/pages" -f build_type=workflow --silent
fi

step "Sending a test push to ntfy topic $NTFY_TOPIC"
curl -fsS -H "Title: Personal Feed" -H "Tags: white_check_mark" \
  -d "Setup works. Your first brief is being built now." "https://ntfy.sh/$NTFY_TOPIC" >/dev/null \
  && echo "Sent." || echo "Test push failed (you can retry later)."

step "Running the first daily brief"
sleep 3
gh workflow run daily-brief.yml -R "$FULL" -f force=true || echo "Couldn't start it yet; run it from the Actions tab."

echo
echo "== Done =="
echo "Repo:       https://github.com/$FULL"
echo "Progress:   https://github.com/$FULL/actions  (first run takes ~2 minutes)"
echo "Your brief: $PAGES_URL"
echo
echo "In the ntfy iPhone app, tap + and subscribe to:"
echo "    $NTFY_TOPIC"
echo "Keep it private: anyone who knows the name can read your alerts."
echo "Optional: import feeds.opml into NetNewsWire to browse every source yourself."
