#!/bin/bash
# Gets the newest Brief onto this Mac and installs it on the plugged-in iPhone, in one go.
#
#   bash update.sh                 from the project folder: the newest version of main
#   bash update.sh some-branch     a version that isn't in main yet
#
# Without the project folder to hand, Terminal can run it straight from GitHub (the last word is
# the branch to install):
#   bash <(curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/BRANCH/update.sh) BRANCH
#
# What it does, saying each step as it goes:
#   1. finds the project folder (the one Terminal is in, or ~/news-brief)
#   2. downloads the branch's latest code, from the repository this folder is linked to or, when
#      the branch isn't there, from the project's own repository (GITHUB_REPO in
#      server/wrangler.toml): a folder can end up linked to a different one
#   3. sets aside local edits to project files, which would otherwise stop git switching branches
#      (the launcher writes this Mac's team, app id and server address into them). Nothing is
#      lost: git's stash keeps the edits, and the launcher puts those settings back when it builds
#   4. switches to the branch and runs `launch.sh --install`, which builds and installs the app
#
# It stops with a message, rather than carrying on, if any step fails: an update that quietly
# does nothing looks the same as one that worked. Works with the bash 3.2 that ships with macOS.

BRANCH="${1:-main}"

say()  { printf '%s\n' "$*"; }
fail() { printf '\n%s\n' "$*" >&2; exit 1; }

# The folder Terminal is in when it is the project, else the usual places it gets put.
find_project() {
  local top dir
  top="$(git rev-parse --show-toplevel 2>/dev/null)"
  if [ -n "$top" ] && [ -f "$top/launch.sh" ] && [ -d "$top/ios" ]; then
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

DIR="$(find_project)" || fail "Couldn't find the Brief project folder. In Terminal, type cd and a space, drag the folder into the window, press Return, then run this again."
cd "$DIR" || fail "Couldn't open $DIR."
say "1/4  Project folder: $DIR"
say "     It has: $(git branch --show-current 2>/dev/null) $(git log -1 --format=%h 2>/dev/null)"

say "2/4  Downloading the latest $BRANCH..."
if ! git fetch -q origin "$BRANCH" 2>/dev/null; then
  # Not in the repository this folder is linked to. The project's own repository is the one the
  # server is set up to use.
  home="$(sed -nE 's/^GITHUB_REPO *= *"([^"]+)".*/\1/p' "$DIR/server/wrangler.toml" 2>/dev/null | head -1)"
  linked="$(git remote get-url origin 2>/dev/null)"
  [ -n "$home" ] || fail "Couldn't download '$BRANCH' from ${linked:-the repository this folder is linked to}. Check the internet connection, then run this again."
  say "     It isn't in ${linked:-the repository this folder is linked to}."
  say "     Getting it from the project's own repository, $home..."
  git fetch -q "https://github.com/$home.git" "$BRANCH" || fail "Couldn't download '$BRANCH' from $home either. Check the internet connection, then run this again."
fi
want="$(git rev-parse FETCH_HEAD)" || fail "Couldn't read what was downloaded."

say "3/4  Switching this Mac's copy to it..."
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  if git stash push -q -m "set aside by update.sh on $(date '+%Y-%m-%d %H:%M')" >/dev/null 2>&1; then
    say "     Set aside local edits to project files (git stash has them)."
  else
    # A half-finished merge can't be stashed. Keep a copy of the edits, then clear them.
    mkdir -p "$DIR/.launch"
    backup="$DIR/.launch/local-edits-$(date '+%Y%m%d-%H%M%S').patch"
    git diff HEAD > "$backup" 2>/dev/null
    git merge --abort 2>/dev/null
    git reset -q --hard HEAD || fail "Couldn't clear the local edits to project files. Copy this window's text to Claude."
    say "     Cleared local edits to project files (a copy is in $backup)."
  fi
fi
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git checkout -q "$BRANCH" || fail "Couldn't switch to $BRANCH. Copy this window's text to Claude."
  git merge -q --ff-only "$want" || fail "This Mac's copy of $BRANCH has changes of its own, so the update can't simply be added. Copy this window's text to Claude."
else
  git checkout -q -b "$BRANCH" "$want" || fail "Couldn't switch to $BRANCH. Copy this window's text to Claude."
  git branch -q --set-upstream-to="origin/$BRANCH" 2>/dev/null
fi
[ "$(git rev-parse HEAD)" = "$want" ] || fail "The switch didn't land on the downloaded version. Copy this window's text to Claude."
say "     Now has: $BRANCH $(git log -1 --format='%h  %s')"

say "4/4  Building the app and installing it on the iPhone..."
[ -f "$DIR/launch.sh" ] || fail "This version has no launcher (launch.sh)."
exec bash "$DIR/launch.sh" --install
