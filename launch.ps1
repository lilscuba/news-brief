# Brief launcher: one guided checklist that gets everything live, and remembers where you are.
#
#   powershell -ExecutionPolicy Bypass -File .\launch.ps1           run / resume
#   powershell -ExecutionPolicy Bypass -File .\launch.ps1 -Status   just show the checklist
#   powershell -ExecutionPolicy Bypass -File .\launch.ps1 -Reset    forget progress, start over
#
# It checks what you're ALREADY signed in to and skips those. For anything missing it opens the
# right page and says exactly what to click. Accounts chain off ones you already have, so there
# are no new passwords to remember:
#     Apple ID (you have) -> GitHub ("Continue with Apple") -> Cloudflare ("Continue with GitHub")
# Progress (no passwords or keys) is saved in .launch\progress.json, so you can stop any time.

param([switch]$Status, [switch]$Reset)

$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot
$stateDir = Join-Path $PSScriptRoot ".launch"
$stateFile = Join-Path $stateDir "progress.json"

# ---------------------------------------------------------------- helpers

function Say($text, $color = "Gray") { Write-Host $text -ForegroundColor $color }
function Title($text) { Write-Host ""; Write-Host "=== $text ===" -ForegroundColor Cyan }
function Pause-ForUser($text = "Press Enter when you're done (or type 'skip')") {
    $answer = Read-Host $text
    return ($answer -ne "skip")
}
function Open-Page($url) {
    Say "   Opening $url"
    Start-Process $url
}
function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
}
function Has($cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

function Load-State {
    if (Test-Path $stateFile) {
        try { return (Get-Content $stateFile -Raw | ConvertFrom-Json) } catch { }
    }
    return [pscustomobject]@{}
}
function Save-State {
    if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory $stateDir | Out-Null }
    $script:state | ConvertTo-Json | Out-File $stateFile -Encoding utf8
}
function Get-Val($name) { $p = $script:state.PSObject.Properties[$name]; if ($p) { $p.Value } else { $null } }
function Set-Val($name, $value) {
    $script:state | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force
    Save-State
}
function Done($step) { Set-Val "done_$step" (Get-Date -Format "yyyy-MM-dd HH:mm") }
function IsDone($step) { [bool](Get-Val "done_$step") }

function Replace-InFile($path, $pattern, $replacement) {
    $text = [IO.File]::ReadAllText($path)
    $new = [regex]::Replace($text, $pattern, $replacement)
    if ($new -ne $text) { [IO.File]::WriteAllText($path, $new) }
}

# ---------------------------------------------------------------- live checks

function GitHub-User {
    if (-not (Has gh)) { return $null }
    $u = (gh api user --jq .login 2>$null)
    if ($LASTEXITCODE -eq 0 -and $u) { return $u.Trim() }
    return $null
}
function Cloudflare-LoggedIn {
    if (-not (Test-Path (Join-Path $PSScriptRoot "server\node_modules\.bin\wrangler.cmd"))) { return $false }
    Push-Location (Join-Path $PSScriptRoot "server")
    $out = (npx wrangler whoami 2>&1 | Out-String)
    Pop-Location
    return ($out -match "associated with the email|Account Name|Account ID") -and ($out -notmatch "not authenticated")
}

# ---------------------------------------------------------------- the checklist

$steps = @(
    @{ id = "tools"; modes = "personal,app"; minutes = "5"
       name = "Install Git, GitHub CLI and Node.js"
       what = "Installs the three free tools the rest of the steps use. Already-installed tools are skipped."
       need = "Nothing." },
    @{ id = "github"; modes = "personal,app"; minutes = "2"
       name = "GitHub account (Continue with Apple)"
       what = "Connects this PC to GitHub, which hosts the project and runs it around the clock for free."
       need = "Your Apple ID (if you don't have GitHub yet) or your GitHub login." },
    @{ id = "repo"; modes = "personal,app"; minutes = "3"
       name = "Put the project on GitHub + phone alerts"
       what = "Creates your repo, uploads the project, turns on the web page, and sets up ntfy phone alerts."
       need = "The ntfy app on your iPhone (App Store, no account). Optional: Gemini key, Gmail app password." },
    @{ id = "bundle"; modes = "app"; minutes = "1"
       name = "Choose the app's ID"
       what = "Picks the app's unique id (like com.you.brief) and fills it into every config file."
       need = "Nothing; a suggestion is offered." },
    @{ id = "cloudflare"; modes = "app"; minutes = "4"
       name = "Cloudflare account (Continue with GitHub) + deploy backend"
       what = "Creates the free server that handles sign-in, settings and push, and deploys it."
       need = "Nothing new: sign up with 'Continue with GitHub'." },
    @{ id = "appleid"; modes = "app"; minutes = "3"
       name = "Apple Developer: register the app"
       what = "Registers the app id with Apple and records your Team ID."
       need = "Your Apple ID with the developer membership." },
    @{ id = "applekey"; modes = "app"; minutes = "2"
       name = "Apple Developer: push notification key"
       what = "Creates the key that lets the server send notifications, and stores it as a GitHub secret."
       need = "Same Apple ID." },
    @{ id = "mac"; modes = "app"; minutes = "10"
       name = "Build on a Mac and install on your iPhone"
       what = "Shows the few Mac steps left. Everything is pre-configured."
       need = "A Mac with Xcode, and your iPhone." }
)

# One screen per step: what's about to happen, then Enter / skip / quit.
function Step-Intro($s, $number, $total) {
    Clear-Host
    Show-Checklist
    Write-Host ""
    Write-Host ("  STEP {0} of {1}:  {2}" -f $number, $total, $s.name) -ForegroundColor Cyan
    Write-Host ("  " + ("-" * 60)) -ForegroundColor DarkGray
    Say "  What happens:  $($s.what)"
    Say "  You'll need:   $($s.need)"
    Say "  Takes about:   $($s.minutes) min"
    Write-Host ""
    $answer = (Read-Host "  Press Enter to start this step, 's' to skip it for now, 'q' to stop here").Trim().ToLower()
    if ($answer -eq "q") { return "quit" }
    if ($answer -eq "s") { return "skip" }
    return "go"
}

function Show-Checklist {
    $mode = Get-Val "mode"
    Title "Brief launch checklist$(if ($mode) { " ($mode)" })"
    $n = 1
    foreach ($s in $steps) {
        if ($mode -and ($s.modes -notmatch $mode)) { continue }
        $mark = if (IsDone $s.id) { "[x]" } else { "[ ]" }
        $color = if (IsDone $s.id) { "Green" } else { "White" }
        Say ("  {0} {1}. {2}" -f $mark, $n, $s.name) $color
        $n++
    }
    $vals = @("github_user", "repo", "bundle_id", "team_id", "worker_url") | Where-Object { Get-Val $_ }
    if ($vals) {
        Say ""
        Say "  Remembered for you:"
        foreach ($v in $vals) { Say ("    {0,-12} {1}" -f $v, (Get-Val $v)) }
    }
}

# ---------------------------------------------------------------- steps

function Step-Tools {
    Title "Tools"
    $need = @()
    if (-not (Has git)) { $need += @{ name = "Git"; winget = "Git.Git"; page = "https://git-scm.com/download/win" } }
    if (-not (Has gh)) { $need += @{ name = "GitHub CLI"; winget = "GitHub.cli"; page = "https://cli.github.com/" } }
    if (-not (Has node)) { $need += @{ name = "Node.js (LTS)"; winget = "OpenJS.NodeJS.LTS"; page = "https://nodejs.org/en/download" } }
    if (-not $need) { Say "   Everything's installed." "Green"; Done "tools"; return $true }

    foreach ($t in $need) {
        if (Has winget) {
            Say "   Installing $($t.name)..."
            winget install --id $t.winget --silent --accept-source-agreements --accept-package-agreements | Out-Null
        } else {
            Say "   Install $($t.name): download the Windows installer from the page that opens and run it" "Yellow"
            Say "   with the default options."
            Open-Page $t.page
            if (-not (Pause-ForUser "Press Enter after $($t.name) finishes installing")) { return $false }
        }
    }
    Refresh-Path
    $missing = @("git", "gh", "node") | Where-Object { -not (Has $_) }
    if ($missing) {
        Say "   Still not found: $($missing -join ', '). Close this window, open a new PowerShell, and run launch.ps1 again." "Yellow"
        return $false
    }
    Done "tools"; return $true
}

function Step-GitHub {
    Title "GitHub account"
    $user = GitHub-User
    if ($user) { Say "   Already signed in as $user." "Green"; Set-Val "github_user" $user; Done "github"; return $true }
    Say "   A browser page opens to connect this PC to GitHub."
    Say "   - Have an account? Just sign in."
    Say "   - No account yet? Choose 'Create an account', then 'Continue with Apple'" "Yellow"
    Say "     (uses your Apple ID, so there's no new password to remember)."
    Say "   When it asks, copy the one-time code shown here into the browser."
    gh auth login --web --git-protocol https
    $user = GitHub-User
    if (-not $user) { Say "   Not signed in yet; run launch.ps1 again to retry." "Yellow"; return $false }
    Set-Val "github_user" $user; Done "github"
    if (-not (git config --global user.email)) {
        git config --global user.name $user
        git config --global user.email "$user@users.noreply.github.com"
    }
    return $true
}

function Step-Repo {
    Title "Project on GitHub"
    Say "   This runs setup.ps1: creates your repo, uploads the project, and sets up phone alerts."
    Say "   It will ask for a repo name and some optional keys. Press Enter to skip any key you don't have."
    Say "   (Optional, free: Gemini key https://aistudio.google.com/apikey,"
    Say "    Gmail app password https://myaccount.google.com/apppasswords. Both use your Google account.)"
    & (Join-Path $PSScriptRoot "setup.ps1")
    $repo = (gh repo view --json nameWithOwner --jq .nameWithOwner 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $repo) { Say "   The repo isn't set up yet; fix the error above and run launch.ps1 again." "Yellow"; return $false }
    Set-Val "repo" $repo.Trim(); Done "repo"; return $true
}

function Step-Bundle {
    Title "App ID"
    $user = (Get-Val "github_user")
    $clean = if ($user) { ($user.ToLower() -replace "[^a-z0-9]", "") } else { "me" }
    $suggest = "com.$clean.brief"
    Say "   Every iOS app has a unique id in reverse-domain form. You'll paste it in a couple of places;"
    Say "   this launcher fills it in everywhere else for you."
    $id = Read-Host "   App id [$suggest]"
    if (-not $id) { $id = $suggest }
    if ($id -notmatch '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+){2,}$') { Say "   That doesn't look like com.something.app; try again." "Yellow"; return $false }
    Set-Val "bundle_id" $id
    Replace-InFile "server\wrangler.toml" 'APPLE_BUNDLE_IDS = "[^"]*"' "APPLE_BUNDLE_IDS = `"$id`""
    Replace-InFile "ios\project.yml" 'PRODUCT_BUNDLE_IDENTIFIER: \S+' "PRODUCT_BUNDLE_IDENTIFIER: $id"
    Say "   Saved $id to server\wrangler.toml and ios\project.yml." "Green"
    Done "bundle"; return $true
}

function Step-Cloudflare {
    Title "Cloudflare (runs the app's sign-in and push server)"
    Say "   If a Cloudflare login page opens:"
    Say "   - No account yet? Click 'Sign up', then 'Continue with GitHub'" "Yellow"
    Say "     (you're already signed in to GitHub, so it's two clicks)."
    Say "   - Then click 'Allow' to let this PC deploy."
    & (Join-Path $PSScriptRoot "server\deploy.ps1")
    $deployed = Join-Path $PSScriptRoot "server\.deployed.json"
    if (-not (Test-Path $deployed)) { Say "   Deploy didn't finish; fix the error above and run launch.ps1 again." "Yellow"; return $false }
    $url = (Get-Content $deployed -Raw | ConvertFrom-Json).url
    Set-Val "worker_url" $url
    Replace-InFile "ios\project.yml" 'API_BASE_URL: "[^"]*"' "API_BASE_URL: `"$url`""
    Say "   Saved $url to ios\project.yml." "Green"
    Done "cloudflare"; return $true
}

function Step-AppleID {
    Title "Register the app with Apple"
    $id = Get-Val "bundle_id"
    Set-Clipboard -Value $id
    Say "   Sign in with your Apple ID (the one with your developer membership). On the page that opens:"
    Say "     1. Choose 'App IDs' -> Continue -> 'App' -> Continue"
    Say "     2. Description: Brief"
    Say "     3. Bundle ID: 'Explicit', then paste  $id  (it's already on your clipboard)" "Yellow"
    Say "     4. Under Capabilities tick 'Push Notifications' and 'Sign In with Apple'"
    Say "     5. Continue -> Register"
    Open-Page "https://developer.apple.com/account/resources/identifiers/add/bundleId"
    if (-not (Pause-ForUser)) { return $false }

    Say ""
    Say "   Now your Team ID: on the page that opens, find 'Team ID' under Membership details."
    Open-Page "https://developer.apple.com/account#MembershipDetailsCard"
    do {
        $team = (Read-Host "   Paste your Team ID (10 letters/numbers)").Trim().ToUpper()
    } until ($team -match '^[A-Z0-9]{10}$')
    Set-Val "team_id" $team
    Replace-InFile "ios\project.yml" 'DEVELOPMENT_TEAM: "[^"]*"' "DEVELOPMENT_TEAM: `"$team`""
    Say "   Saved to ios\project.yml." "Green"
    Done "appleid"; return $true
}

function Step-AppleKey {
    Title "Push notification key"
    Say "   On the page that opens:"
    Say "     1. Key Name: Brief push"
    Say "     2. Tick 'Apple Push Notifications service (APNs)' -> Continue -> Register"
    Say "     3. Click Download. Apple only lets you download it ONCE; this launcher stores it safely" "Yellow"
    Say "        as an encrypted GitHub secret so you never need the file again."
    Open-Page "https://developer.apple.com/account/resources/authkeys/add"
    if (-not (Pause-ForUser "Press Enter after the AuthKey_....p8 file has downloaded")) { return $false }

    $downloads = Join-Path $env:USERPROFILE "Downloads"
    $p8 = Get-ChildItem $downloads -Filter "AuthKey_*.p8" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $p8) {
        $path = Read-Host "   Couldn't find AuthKey_*.p8 in Downloads. Drag the file here (or paste its path)"
        $p8 = Get-Item ($path.Trim('"', ' ')) -ErrorAction SilentlyContinue
        if (-not $p8) { Say "   File not found." "Yellow"; return $false }
    }
    $keyId = [regex]::Match($p8.Name, 'AuthKey_([A-Z0-9]{10})\.p8').Groups[1].Value
    if (-not $keyId) { $keyId = (Read-Host "   Key ID (10 characters, shown on the key's page)").Trim().ToUpper() }
    Say "   Found $($p8.Name) (Key ID $keyId)."

    $repo = Get-Val "repo"
    $keyText = [IO.File]::ReadAllText($p8.FullName)
    gh secret set APNS_KEY --repo $repo --body $keyText
    $ok = ($LASTEXITCODE -eq 0)
    gh secret set APNS_KEY_ID --repo $repo --body $keyId; $ok = $ok -and ($LASTEXITCODE -eq 0)
    gh secret set APNS_TEAM_ID --repo $repo --body (Get-Val "team_id"); $ok = $ok -and ($LASTEXITCODE -eq 0)
    gh secret set APNS_TOPIC --repo $repo --body (Get-Val "bundle_id"); $ok = $ok -and ($LASTEXITCODE -eq 0)
    Remove-Variable keyText
    if (-not $ok) { Say "   Couldn't save the secrets; run launch.ps1 again." "Yellow"; return $false }
    Say "   Push key saved as GitHub secrets (APNS_KEY, APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC)." "Green"
    Say "   You can delete $($p8.Name) from Downloads now, or keep it somewhere private as a backup."
    Done "applekey"; return $true
}

function Step-Mac {
    Title "Build the app (needs a Mac)"
    Say "   Everything Windows can do is done. The project is already configured with your app id,"
    Say "   team and server, so on a Mac it's just:"
    Say "     1. Install Xcode from the Mac App Store, sign in with your Apple ID (Xcode > Settings > Accounts)"
    Say "     2. In Terminal:  git clone https://github.com/$(Get-Val 'repo').git && cd $((Get-Val 'repo') -replace '.*/','')/ios"
    Say "     3. brew install xcodegen && xcodegen && open PersonalFeed.xcodeproj"
    Say "     4. Plug in your iPhone, pick it at the top, press Run"
    Say "   No Mac? GitHub already compiles and tests the app on its Macs every time you push;"
    Say "   see the 'iOS build & tests' run at https://github.com/$(Get-Val 'repo')/actions"
    if (Pause-ForUser "Press Enter once the app is on your phone (or 'skip' to come back later)") { Done "mac" }
    return $true
}

# ---------------------------------------------------------------- main

if ($Reset) { Remove-Item $stateFile -ErrorAction SilentlyContinue; Say "Progress cleared." }
$script:state = Load-State

if ($Status) { Show-Checklist; exit 0 }

if (-not (Get-Val "mode")) {
    Title "Welcome"
    Say "  1) Just me: daily brief web page + email + phone alerts (no app, no Apple steps)"
    Say "  2) The app for anyone: sign in with Apple, your own feed, push (also does 1)"
    $choice = Read-Host "Which one? [2]"
    Set-Val "mode" $(if ($choice -eq "1") { "personal" } else { "app" })
}
$mode = Get-Val "mode"

$handlers = @{
    tools = { Step-Tools }; github = { Step-GitHub }; repo = { Step-Repo }; bundle = { Step-Bundle };
    cloudflare = { Step-Cloudflare }; appleid = { Step-AppleID }; applekey = { Step-AppleKey }; mac = { Step-Mac }
}
$mine = @($steps | Where-Object { $_.modes -match $mode })
$skipped = @()
for ($i = 0; $i -lt $mine.Count; $i++) {
    $s = $mine[$i]
    if (IsDone $s.id) { continue }
    # Later steps depend on earlier ones, so a skipped step stops the run after this point.
    if ($skipped) { break }
    $choice = Step-Intro $s ($i + 1) $mine.Count
    if ($choice -eq "quit") { break }
    if ($choice -eq "skip") { $skipped += $s.name; continue }
    $ok = & $handlers[$s.id]
    if ($ok -and (IsDone $s.id)) {
        Write-Host ""
        Say "  Step $($i + 1) done." "Green"
        Read-Host "  Press Enter for the next step" | Out-Null
    } else {
        Write-Host ""
        Say "  Paused at step $($i + 1). Run launch.ps1 again any time to pick up right here." "Yellow"
        Read-Host "  Press Enter to close" | Out-Null
        exit 0
    }
}

Clear-Host
Show-Checklist
Write-Host ""
$left = @($mine | Where-Object { -not (IsDone $_.id) })
if (-not $left) {
    Say "  All done. Your news feed is live." "Green"
} else {
    Say "  $($left.Count) step(s) left. Run launch.ps1 again whenever you're ready; it starts where you stopped." "Yellow"
}
