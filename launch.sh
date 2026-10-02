#!/bin/bash
# Brief launcher for macOS: one guided checklist, from nothing to the app on your iPhone.
# Remembers where you stopped. Detects what you're already signed in to and skips it.
#
#   Double-click "Launch Brief.command"      (first time: right-click it -> Open)
#   or in Terminal:   bash launch.sh          (add --status to see the checklist, --reset to start over)
#
# Accounts chain off ones you already have, so there are no new passwords:
#   Apple ID (Xcode) -> GitHub ("Continue with Apple") -> Cloudflare ("Continue with GitHub")
# Works with the bash 3.2 that ships with macOS.

cd "$(dirname "$0")" || exit 1
ROOT="$(pwd)"
STATE_DIR="$ROOT/.launch"
STATE="$STATE_DIR/progress.txt"
mkdir -p "$STATE_DIR"
touch "$STATE"

# ------------------------------------------------------------------ helpers

c_cyan=$'\033[36m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_red=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
say()   { printf '%s\n' "$*"; }
ok()    { printf '%s%s%s\n' "$c_green" "$*" "$c_off"; }
warn()  { printf '%s%s%s\n' "$c_yellow" "$*" "$c_off"; }
title() { printf '\n%s=== %s ===%s\n' "$c_cyan" "$*" "$c_off"; }
has()   { command -v "$1" >/dev/null 2>&1; }
open_page() { say "   Opening $1"; open "$1"; }
wait_user() {  # returns 1 if the user typed "skip"
  local prompt="$1" a
  [ -n "$prompt" ] || prompt="   Press Enter when you are done (or type skip): "
  read -r -p "$prompt" a
  [ "$a" != "skip" ]
}

get() { grep -E "^$1=" "$STATE" 2>/dev/null | tail -1 | cut -d= -f2-; }
put() {
  grep -vE "^$1=" "$STATE" > "$STATE.tmp" 2>/dev/null
  printf '%s=%s\n' "$1" "$2" >> "$STATE.tmp"
  mv "$STATE.tmp" "$STATE"
}
done_step() { put "done_$1" "$(date '+%Y-%m-%d %H:%M')"; }
is_done()   { [ -n "$(get "done_$1")" ]; }

# Replace a regex in a file (macOS sed needs -i '').
replace_in() { sed -i '' -E "s#$2#$3#" "$1"; }

load_brew() {
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$b" ] && eval "$("$b" shellenv)" && return 0
  done
  return 1
}
load_brew

# ------------------------------------------------------------------ the checklist

STEP_IDS=(tools github repo team bundle cloudflare applekey iphone)
step_name() {
  case "$1" in
    tools)      echo "Install the tools (Homebrew, GitHub CLI, Node, XcodeGen) + check Xcode";;
    github)     echo "GitHub account (Continue with Apple)";;
    repo)       echo "Put the project on GitHub + phone alerts";;
    team)       echo "Your Apple developer team (from Xcode)";;
    bundle)     echo "Choose the app's ID";;
    cloudflare) echo "Cloudflare account (Continue with GitHub) + deploy the server";;
    applekey)   echo "Push notification key (Apple Developer website)";;
    iphone)     echo "Build the app and install it on your iPhone";;
  esac
}
step_what() {
  case "$1" in
    tools)      echo "Installs free command-line tools. Already-installed ones are skipped. Needs Xcode from the App Store.";;
    github)     echo "Connects this Mac to GitHub, which stores the project and runs it every 15 minutes for free.";;
    repo)       echo "Creates your repo, uploads the project, turns on the web page and sets up ntfy alerts.";;
    team)       echo "Reads your Apple developer Team ID from Xcode, so you don't have to look it up.";;
    bundle)     echo "Picks the app's unique id (like com.you.brief) and fills it in everywhere.";;
    cloudflare) echo "Creates the free server for sign-in, settings and push, and deploys it.";;
    applekey)   echo "Creates the key that lets the server send notifications and stores it as a GitHub secret.";;
    iphone)     echo "Builds the app with Xcode and installs it on your plugged-in iPhone.";;
  esac
}
step_need() {
  case "$1" in
    tools)      echo "Your Mac password (for Homebrew) and Xcode installed.";;
    github)     echo "Nothing if you're signed in; otherwise your Apple ID.";;
    repo)       echo "The ntfy app on your iPhone. Optional: Gemini key, Gmail app password.";;
    team)       echo "Xcode signed in to your Apple ID (Xcode > Settings > Accounts).";;
    bundle)     echo "Nothing; a suggestion is offered.";;
    cloudflare) echo "Nothing new: sign up with 'Continue with GitHub'.";;
    applekey)   echo "Your Apple ID (developer membership).";;
    iphone)     echo "Your iPhone and its USB cable.";;
  esac
}
step_minutes() {
  case "$1" in tools) echo 10;; github) echo 2;; repo) echo 3;; team) echo 1;; bundle) echo 1;;
               cloudflare) echo 4;; applekey) echo 2;; iphone) echo 8;; esac
}

show_checklist() {
  title "Brief launch checklist"
  local n=1 id
  for id in "${STEP_IDS[@]}"; do
    if is_done "$id"; then printf '  %s[x] %d. %s%s\n' "$c_green" "$n" "$(step_name "$id")" "$c_off"
    else printf '  [ ] %d. %s\n' "$n" "$(step_name "$id")"; fi
    n=$((n + 1))
  done
  local k v printed=""
  for k in github_user repo team_id bundle_id worker_url; do
    v="$(get "$k")"
    if [ -n "$v" ]; then
      [ -z "$printed" ] && { say ""; say "  Remembered for you:"; printed=1; }
      printf '    %-12s %s\n' "$k" "$v"
    fi
  done
}

# ------------------------------------------------------------------ steps

step_tools() {
  title "Tools"
  if ! has brew; then
    say "   Installing Homebrew (the standard Mac tool installer). It will ask for your Mac password;"
    say "   typing it shows nothing, which is normal."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || return 1
    load_brew || { warn "   Homebrew didn't finish installing; run the launcher again."; return 1; }
  fi
  local missing=""
  has gh || missing="$missing gh"
  has node || missing="$missing node"
  has xcodegen || missing="$missing xcodegen"
  if [ -n "$missing" ]; then
    say "   Installing:$missing"
    # shellcheck disable=SC2086
    brew install $missing || return 1
  fi
  if [ ! -d /Applications/Xcode.app ]; then
    warn "   Xcode isn't installed. The App Store page opens: click Get / Install (it's large; give it a while)."
    open "macappstore://apps.apple.com/app/id497799835"
    wait_user "   Press Enter once Xcode has finished installing: " || return 1
    [ -d /Applications/Xcode.app ] || { warn "   Still not found in Applications."; return 1; }
  fi
  if ! xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
    say "   Pointing the command-line tools at Xcode (asks for your Mac password)."
    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer || return 1
  fi
  if ! xcodebuild -version >/dev/null 2>&1; then
    say "   Finishing Xcode's first-time setup (asks for your Mac password)."
    sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch || return 1
  fi
  ok "   Tools ready."
  done_step tools
}

step_github() {
  title "GitHub"
  local user
  user="$(gh api user --jq .login 2>/dev/null)"
  if [ -z "$user" ]; then
    say "   A browser page opens. Have an account? Sign in."
    warn "   No account yet? Choose 'Create an account' -> 'Continue with Apple' (no new password)."
    say "   Copy the one-time code shown here into the browser when it asks."
    gh auth login --web --git-protocol https || return 1
    user="$(gh api user --jq .login 2>/dev/null)"
    [ -n "$user" ] || { warn "   Not signed in yet."; return 1; }
  fi
  ok "   Signed in to GitHub as $user."
  put github_user "$user"
  git config --global user.email >/dev/null || {
    git config --global user.name "$user"
    git config --global user.email "$user@users.noreply.github.com"
  }
  done_step github
}

step_repo() {
  title "Project on GitHub"
  say "   Runs setup.sh: creates your repo, uploads the project, turns on the web page and ntfy alerts."
  say "   Press Enter to skip any optional key it asks for."
  bash "$ROOT/setup.sh" || { warn "   setup.sh stopped; fix the error above and run the launcher again."; return 1; }
  local repo
  repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)"
  [ -n "$repo" ] || { warn "   The repo isn't set up yet."; return 1; }
  put repo "$repo"
  done_step repo
}

step_team() {
  title "Apple developer team"
  # Xcode stores the teams of signed-in accounts in its preferences.
  local teams
  teams="$(defaults read com.apple.dt.Xcode 2>/dev/null | grep -Eo 'teamID = "?[A-Z0-9]{10}"?' | grep -Eo '[A-Z0-9]{10}' | sort -u)"
  if [ -z "$teams" ]; then
    warn "   Xcode isn't signed in to an Apple ID yet. Opening Xcode:"
    say "     Xcode menu > Settings > Accounts > + > Apple ID > sign in with your developer Apple ID."
    open -a Xcode
    wait_user "   Press Enter after you've signed in (then close Settings): " || return 1
    teams="$(defaults read com.apple.dt.Xcode 2>/dev/null | grep -Eo 'teamID = "?[A-Z0-9]{10}"?' | grep -Eo '[A-Z0-9]{10}' | sort -u)"
  fi
  local team count
  count="$(printf '%s\n' "$teams" | grep -c .)"
  if [ "$count" = "1" ]; then
    team="$teams"
  else
    [ -n "$teams" ] && { say "   Teams found in Xcode:"; printf '     %s\n' $teams; }
    say "   (Your Team ID is also on https://developer.apple.com/account under Membership details.)"
    read -r -p "   Team ID to use: " team
  fi
  team="$(printf '%s' "$team" | tr '[:lower:]' '[:upper:]' | tr -d ' ')"
  printf '%s' "$team" | grep -Eq '^[A-Z0-9]{10}$' || { warn "   That isn't a 10-character Team ID."; return 1; }
  put team_id "$team"
  replace_in "$ROOT/ios/project.yml" 'DEVELOPMENT_TEAM: "[^"]*"' "DEVELOPMENT_TEAM: \"$team\""
  ok "   Using team $team (saved to ios/project.yml)."
  done_step team
}

step_bundle() {
  title "App ID"
  local user clean suggest id
  user="$(get github_user)"
  clean="$(printf '%s' "${user:-me}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
  suggest="com.$clean.brief"
  say "   Every iOS app has a unique id in reverse-domain form. This fills it in everywhere for you."
  read -r -p "   App id [$suggest]: " id
  id="${id:-$suggest}"
  printf '%s' "$id" | grep -Eq '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+){2,}$' || { warn "   Use the form com.something.app"; return 1; }
  put bundle_id "$id"
  replace_in "$ROOT/server/wrangler.toml" 'APPLE_BUNDLE_IDS = "[^"]*"' "APPLE_BUNDLE_IDS = \"$id\""
  replace_in "$ROOT/ios/project.yml" 'PRODUCT_BUNDLE_IDENTIFIER: [^ ]+$' "PRODUCT_BUNDLE_IDENTIFIER: $id"
  ok "   Saved $id. (Xcode registers it with Apple automatically when it builds the app.)"
  done_step bundle
}

step_cloudflare() {
  title "Cloudflare"
  say "   If a Cloudflare page opens:"
  warn "   No account? Click 'Sign up' -> 'Continue with GitHub', then 'Allow'."
  bash "$ROOT/server/deploy.sh" || { warn "   Deploy stopped; fix the error above and run the launcher again."; return 1; }
  local url
  url="$(sed -nE 's/.*"url" *: *"([^"]+)".*/\1/p' "$ROOT/server/.deployed.json" 2>/dev/null)"
  [ -n "$url" ] || { warn "   Couldn't find the server address."; return 1; }
  put worker_url "$url"
  replace_in "$ROOT/ios/project.yml" 'API_BASE_URL: "[^"]*"' "API_BASE_URL: \"$url\""
  ok "   Server live at $url (saved to ios/project.yml)."
  done_step cloudflare
}

step_applekey() {
  title "Push notification key"
  say "   On the page that opens (sign in with your developer Apple ID if asked):"
  say "     1. Key Name: Brief push"
  say "     2. Tick 'Apple Push Notifications service (APNs)' -> Continue -> Register"
  warn "     3. Click Download. Apple allows ONE download; the launcher stores it as an encrypted GitHub secret."
  open_page "https://developer.apple.com/account/resources/authkeys/add"
  wait_user "   Press Enter after AuthKey_....p8 has downloaded: " || return 1
  local p8 keyid repo
  p8="$(ls -t "$HOME"/Downloads/AuthKey_*.p8 2>/dev/null | head -1)"
  if [ -z "$p8" ]; then
    read -r -p "   Couldn't find it in Downloads. Drag the .p8 file into this window and press Enter: " p8
    p8="$(printf '%s' "$p8" | sed -e "s/^['\"]//" -e "s/['\"]$//" -e 's/\\ / /g' -e 's/ *$//')"
    [ -f "$p8" ] || { warn "   File not found."; return 1; }
  fi
  keyid="$(basename "$p8" | sed -nE 's/^AuthKey_([A-Z0-9]{10})\.p8$/\1/p')"
  [ -n "$keyid" ] || read -r -p "   Key ID (10 characters, shown on the key's page): " keyid
  say "   Found $(basename "$p8") (Key ID $keyid)."
  repo="$(get repo)"
  gh secret set APNS_KEY -R "$repo" < "$p8" &&
    gh secret set APNS_KEY_ID -R "$repo" -b "$keyid" &&
    gh secret set APNS_TEAM_ID -R "$repo" -b "$(get team_id)" &&
    gh secret set APNS_TOPIC -R "$repo" -b "$(get bundle_id)" || { warn "   Couldn't save the secrets."; return 1; }
  ok "   Saved as GitHub secrets. You can delete $(basename "$p8") from Downloads now."
  done_step applekey
}

# Finds a connected iPhone via Xcode's devicectl. Prints "coredevice_id|udid|name".
find_iphone() {
  local json="$STATE_DIR/devices.json"
  xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 || return 1
  /usr/bin/python3 - "$json" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1])).get("result", {}).get("devices", [])
for d in devices:
    hw = d.get("hardwareProperties", {})
    conn = d.get("connectionProperties", {})
    if hw.get("platform") == "iOS" and conn.get("pairingState") == "paired" and conn.get("tunnelState") != "unavailable":
        print(f'{d["identifier"]}|{hw.get("udid","")}|{d.get("deviceProperties",{}).get("name","iPhone")}')
        break
PY
}

step_iphone() {
  title "Build and install on your iPhone"
  local bundle device cid udid name
  bundle="$(get bundle_id)"
  (cd "$ROOT/ios" && xcodegen -q) || { warn "   XcodeGen failed."; return 1; }
  say "   Plug your iPhone into this Mac with its cable and unlock it."
  say "   If the phone asks 'Trust This Computer?', tap Trust."
  say "   First time only: on the iPhone, Settings > Privacy & Security > Developer Mode > On (it restarts)."
  wait_user "   Press Enter when the iPhone is plugged in and unlocked: " || return 1

  device="$(find_iphone)"
  if [ -z "$device" ]; then
    warn "   No iPhone found. Opening the project in Xcode instead:"
    say "     pick your iPhone at the top of the window, then press the Run button (triangle)."
    open "$ROOT/ios/PersonalFeed.xcodeproj"
    wait_user "   Press Enter once the app is on your phone: " && done_step iphone
    return 0
  fi
  cid="${device%%|*}"; udid="$(printf '%s' "$device" | cut -d'|' -f2)"; name="${device##*|}"
  say "   Found $name. Building (the first build takes a few minutes)..."
  local log="$STATE_DIR/build.log"
  if ! xcodebuild -project "$ROOT/ios/PersonalFeed.xcodeproj" -scheme PersonalFeed -configuration Debug \
       -destination "id=$udid" -derivedDataPath "$ROOT/ios/build" -allowProvisioningUpdates build >"$log" 2>&1; then
    warn "   The build failed. The errors:"
    grep -E "error:" "$log" | sort -u | head -20
    say ""
    say "   Full log: $log"
    say "   Opening the project in Xcode so you can see the errors in context."
    open "$ROOT/ios/PersonalFeed.xcodeproj"
    return 1
  fi
  local app="$ROOT/ios/build/Build/Products/Debug-iphoneos/PersonalFeed.app"
  say "   Installing on $name..."
  xcrun devicectl device install app --device "$cid" "$app" >/dev/null || { warn "   Install failed (is the phone unlocked?)."; return 1; }
  xcrun devicectl device process launch --device "$cid" "$bundle" >/dev/null 2>&1 || true
  ok "   Brief is on your iPhone and should be opening now. Tap 'Continue with Apple' to sign in."
  done_step iphone
}

# ------------------------------------------------------------------ main

case "$1" in
  --status) show_checklist; exit 0;;
  --reset)  rm -f "$STATE"; touch "$STATE"; say "Progress cleared.";;
esac

total=${#STEP_IDS[@]}
i=0
for id in "${STEP_IDS[@]}"; do
  i=$((i + 1))
  is_done "$id" && continue
  clear
  show_checklist
  say ""
  printf '  %sSTEP %d of %d:  %s%s\n' "$c_cyan" "$i" "$total" "$(step_name "$id")" "$c_off"
  printf '  %s------------------------------------------------------------%s\n' "$c_dim" "$c_off"
  say "  What happens:  $(step_what "$id")"
  say "  You'll need:   $(step_need "$id")"
  say "  Takes about:   $(step_minutes "$id") min"
  say ""
  read -r -p "  Press Enter to start this step, or 'q' to stop here: " a
  [ "$a" = "q" ] && break
  if "step_$id"; then
    say ""; ok "  Step $i done."
    read -r -p "  Press Enter for the next step " _
  else
    say ""; warn "  Paused at step $i. Run the launcher again any time to pick up right here."
    read -r -p "  Press Enter to close " _
    exit 0
  fi
done

clear
show_checklist
say ""
left=0
for id in "${STEP_IDS[@]}"; do is_done "$id" || left=$((left + 1)); done
if [ "$left" = "0" ]; then
  ok "  All done. Brief is live and on your iPhone."
else
  warn "  $left step(s) left. Run the launcher again whenever you're ready; it starts where you stopped."
fi
