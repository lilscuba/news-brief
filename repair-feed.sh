#!/bin/bash
# Puts the news feed back in working order when the "Shared feed" job on GitHub fails with
# "401 Unauthorized". That error means the server and the repository that builds its feed no
# longer hold the same secret. It happens when the server is deployed from a copy of the project
# that is linked to a different GitHub repository: the new secret goes to that repository, and
# the one the server actually starts every 10 minutes is locked out.
#
#   bash repair-feed.sh
#
# What it does, saying each step as it goes:
#   1. finds the project folder and the repository the server uses (GITHUB_REPO in
#      server/wrangler.toml)
#   2. links the folder to that repository again, if it was linked to another one
#   3. makes a new secret and gives it to that repository (GitHub), then to the server
#      (Cloudflare). If the second half fails it says so, and running it again finishes the job
#   4. starts the feed job, so the result shows within a couple of minutes
#   5. offers to switch off the scheduled jobs in the other repository, which otherwise keeps
#      building its own copy of everything. It asks first, and they can be switched back on
#
# Needs the GitHub CLI and Cloudflare's wrangler signed in on this Mac (the launcher does both).
# Works with the bash 3.2 that ships with macOS.

say()  { printf '%s\n' "$*"; }
fail() { printf '\n%s\n' "$*" >&2; exit 1; }

# The folder Terminal is in when it is the project, else the usual places it gets put.
find_project() {
  local top dir
  top="$(git rev-parse --show-toplevel 2>/dev/null)"
  if [ -n "$top" ] && [ -f "$top/launch.sh" ] && [ -d "$top/server" ]; then
    printf '%s' "$top"
    return 0
  fi
  for dir in "$HOME/news-brief" "$HOME/Desktop/news-brief" "$HOME/Documents/news-brief" "$HOME/Downloads/news-brief"; do
    if [ -d "$dir/.git" ] && [ -f "$dir/launch.sh" ]; then
      printf '%s' "$dir"
      return 0
    fi
  done
  return 1
}

# "owner/name" from a GitHub address, https or ssh.
repo_of() { printf '%s' "$1" | sed -E 's#^https://github\.com/##; s#^git@github\.com:##; s#\.git$##; s#/$##'; }

DIR="$(find_project)" || fail "Couldn't find the Brief project folder. In Terminal, type cd and a space, drag the folder into the window, press Return, then run this again."
cd "$DIR" || fail "Couldn't open $DIR."
command -v gh >/dev/null || fail "The GitHub CLI (gh) isn't installed. Run the launcher's first step, then this again."
command -v npx >/dev/null || fail "Node.js isn't installed. Run the launcher's first step, then this again."
gh auth status >/dev/null 2>&1 || fail "The GitHub CLI isn't signed in. Run:  gh auth login   then this again."

home="$(sed -nE 's/^GITHUB_REPO *= *"([^"]+)".*/\1/p' server/wrangler.toml 2>/dev/null | head -1)"
[ -n "$home" ] || fail "server/wrangler.toml doesn't say which repository the server uses (GITHUB_REPO)."
linked="$(repo_of "$(git remote get-url origin 2>/dev/null)")"

say "1/5  Project folder: $DIR"
say "     The server starts the feed job in:  $home"
say "     This folder is linked to:           ${linked:-nothing}"
gh repo view "$home" >/dev/null 2>&1 || fail "Couldn't open $home on GitHub with this account. Copy this window's text to Claude."

if [ "$linked" = "$home" ]; then
  say "2/5  The folder is already linked to $home."
  other=""
else
  git remote set-url origin "https://github.com/$home.git" 2>/dev/null || git remote add origin "https://github.com/$home.git" \
    || fail "Couldn't link the folder to $home."
  say "2/5  Linked the folder to $home again."
  other="$linked"
  # The launcher remembers the repository too, and saves the push key to it.
  if [ -f .launch/progress.txt ]; then
    grep -v '^repo=' .launch/progress.txt > .launch/progress.tmp 2>/dev/null
    printf 'repo=%s\n' "$home" >> .launch/progress.tmp
    mv .launch/progress.tmp .launch/progress.txt
  fi
fi

say "3/5  Giving $home and the server the same new secret..."
secret="$(openssl rand -hex 32)" || fail "Couldn't make a secret (openssl)."
[ -n "$secret" ] || fail "Couldn't make a secret (openssl)."
gh secret set INGEST_SECRET -R "$home" -b "$secret" >/dev/null \
  || fail "GitHub didn't take the secret. Nothing has changed. Copy this window's text to Claude."
say "     GitHub has it."
if ! (cd server && printf '%s' "$secret" | npx wrangler secret put INGEST_SECRET); then
  unset secret
  fail "The server (Cloudflare) didn't take the secret. GitHub now holds one the server doesn't know, so the feed job can't deliver until this has run through. If it said you aren't logged in, run:  cd \"$DIR/server\" && npx wrangler login   then this again."
fi
unset secret
say "     The server has it."

say "4/5  Starting the feed job..."
if gh workflow run ingest.yml -R "$home" >/dev/null 2>&1; then
  say "     Started. In about two minutes the newest run on this page should have a green tick:"
  say "     https://github.com/$home/actions/workflows/ingest.yml"
else
  say "     Couldn't start it by hand; the server starts it itself within 10 minutes."
fi

if [ -n "$other" ]; then
  say "5/5  $other has its own copy of the scheduled jobs (daily brief, alerts, feed)."
  say "     Its feed job no longer has the server's secret, so it will fail from now on; the daily"
  say "     brief and alerts there keep running unless they are switched off."
  printf '     Switch off the scheduled jobs in %s? [y/N] ' "$other"
  read -r answer
  case "$answer" in
    y|Y|yes|Yes|YES)
      ids="$(gh workflow list -R "$other" --json id,state --jq '.[] | select(.state == "active") | .id' 2>/dev/null)"
      if [ -z "$ids" ]; then
        say "     Found none switched on (or couldn't list them)."
      else
        for id in $ids; do
          gh workflow disable "$id" -R "$other" >/dev/null 2>&1 && say "     Switched off job $id."
        done
        say "     To undo: https://github.com/$other/actions (each job has an Enable button)."
      fi
      ;;
    *) say "     Left as they are." ;;
  esac
else
  say "5/5  No other repository to tidy up."
fi

say ""
say "Done. The app shows new stories again once the feed job has run."
