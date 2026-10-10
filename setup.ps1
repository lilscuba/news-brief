# Personal Feed setup for Windows: publishes this folder to GitHub, stores your keys as GitHub
# secrets, turns on GitHub Pages, runs the first brief, and sends a test push to your phone.
#
# Before running, have ready (all free):
#   - a GitHub account                      https://github.com/signup
#   - the ntfy app on your iPhone           (App Store, no account needed)
#   - optional: Gemini API key              https://aistudio.google.com/apikey
#   - optional: Gmail app password          https://myaccount.google.com/apppasswords
#                                           (needs 2-Step Verification turned on first)
#
# Run from this folder:   powershell -ExecutionPolicy Bypass -File .\setup.ps1
# Safe to re-run: existing repo, Pages site and secrets are reused or updated.

# "Continue", not "Stop": in Windows PowerShell 5.1, "Stop" turns any stderr output from git/gh
# into a fatal error. Failures are caught through $LASTEXITCODE instead.
$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot

function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Fail($text) { Write-Host $text -ForegroundColor Red; exit 1 }
function Check($what) {
    # Call right after a native command (git/gh); stops the script if it failed.
    if ($LASTEXITCODE -ne 0) { Fail "Failed: $what" }
}
function ReadSecret($prompt) {
    $secure = Read-Host $prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

Step "Checking tools"
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Start-Process "https://git-scm.com/download/win"; Fail "Install Git from the page that just opened, then run this again." }
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "Installing GitHub CLI with winget..."
        winget install --id GitHub.cli --silent --accept-source-agreements --accept-package-agreements
    } else {
        Write-Host "Install the GitHub CLI from the page that opens (Download for Windows), then come back." -ForegroundColor Yellow
        Start-Process "https://cli.github.com/"
        Read-Host "Press Enter after it has installed" | Out-Null
    }
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { Fail "GitHub CLI installed; open a new terminal and re-run this script." }
}

gh auth status *> $null
if ($LASTEXITCODE -ne 0) {
    Step "Logging in to GitHub (a browser window opens)"
    gh auth login --web --git-protocol https; Check "gh auth login"
}
$ghUser = (gh api user --jq .login).Trim()

Step "Repository"
$repo = Read-Host "Repo name [news-brief]"
if (-not $repo) { $repo = "news-brief" }
$full = "$ghUser/$repo"

gh repo view $full *> $null
$exists = ($LASTEXITCODE -eq 0)
if (-not $exists) {
    # Public: GitHub Pages and unlimited Actions minutes are free only for public repos.
    # Nothing secret lives in the files; keys are stored as encrypted secrets.
    gh repo create $full --public --description "Personal daily gaming, tech and AI news brief"; Check "gh repo create"
    Write-Host "Created https://github.com/$full"
} else {
    Write-Host "Using existing https://github.com/$full"
}

Step "Pushing the code"
if (-not (Test-Path .git)) { git init -b main; Check "git init" }
if (-not (git config user.email)) {
    git config user.name $ghUser; Check "git config user.name"
    git config user.email "$ghUser@users.noreply.github.com"; Check "git config user.email"
}
$remoteUrl = "https://github.com/$full.git"
git remote get-url origin *> $null
if ($LASTEXITCODE -eq 0) { git remote set-url origin $remoteUrl } else { git remote add origin $remoteUrl }
Check "git remote"
git add -A; Check "git add -A"
git diff --cached --quiet
if ($LASTEXITCODE -ne 0) { git commit -m "Personal Feed: daily brief, breaking alerts, iOS app"; Check "git commit" }
git branch -M main; Check "git branch -M"
git ls-remote --exit-code --heads origin main *> $null
if ($LASTEXITCODE -eq 0) {
    # The repo already has commits (e.g. a README from an earlier setup); keep our versions.
    git pull origin main --allow-unrelated-histories --no-rebase -X ours --no-edit; Check "git pull origin"
}
git push -u origin main; Check "git push -u"

Step "Secrets (input is hidden; press Enter to skip any)"
$gemini = ReadSecret "Gemini API key"
if ($gemini) { gh secret set GEMINI_API_KEY --repo $full --body $gemini; Check "gh secret set GEMINI_API_KEY" }

$gmail = Read-Host "Gmail address (to email yourself the brief)"
if ($gmail) {
    $gmailPw = (ReadSecret "Gmail app password (16 chars, spaces OK)") -replace " ", ""
    if ($gmailPw) {
        gh secret set GMAIL_ADDRESS --repo $full --body $gmail; Check "gh secret set"
        gh secret set GMAIL_APP_PASSWORD --repo $full --body $gmailPw; Check "gh secret set"
    }
}

$topic = Read-Host "Existing ntfy topic (Enter to generate a new private one)"
if (-not $topic) {
    $bytes = New-Object byte[] 8
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $topic = "news-" + (($bytes | ForEach-Object { $_.ToString("x2") }) -join "")
}
gh secret set NTFY_TOPIC --repo $full --body $topic; Check "gh secret set"

$summarize = "false"
if ($gemini) {
    $answer = Read-Host "Turn on Gemini AI summaries now? Otherwise you get the plain article list (y/N)"
    if ($answer -match "^[yY]") { $summarize = "true" }
}
$pagesUrl = "https://$($ghUser.ToLower()).github.io/$repo/"
gh variable set SUMMARIZE --repo $full --body $summarize; Check "gh variable set"
gh variable set PAGES_URL --repo $full --body $pagesUrl; Check "gh variable set"
Remove-Variable gemini, gmailPw -ErrorAction SilentlyContinue

Step "Turning on GitHub Pages (deployed by the workflow)"
gh api "repos/$full/pages" *> $null
if ($LASTEXITCODE -ne 0) {
    gh api -X POST "repos/$full/pages" -f build_type=workflow --silent; Check "gh api -X"
} else {
    gh api -X PUT "repos/$full/pages" -f build_type=workflow --silent; Check "gh api -X"
}

Step "Sending a test push to ntfy topic $topic"
try {
    Invoke-RestMethod -Method Post -Uri "https://ntfy.sh/$topic" -Body "Setup works. Your first brief is being built now." -Headers @{ Title = "Personal Feed"; Tags = "white_check_mark" } | Out-Null
    Write-Host "Sent. (Subscribe in the ntfy app first if you haven't, then re-send from Actions later.)"
} catch { Write-Host "Test push failed: $_" -ForegroundColor Yellow }

Step "Running the first daily brief"
Start-Sleep -Seconds 3
gh workflow run daily-brief.yml --repo $full -f force=true
if ($LASTEXITCODE -ne 0) { Write-Host "Couldn't start it yet; run it from the Actions tab." -ForegroundColor Yellow }

Write-Host ""
Write-Host "== Done ==" -ForegroundColor Green
Write-Host "Repo:      https://github.com/$full"
Write-Host "Progress:  https://github.com/$full/actions  (first run takes ~2 minutes)"
Write-Host "Your brief: $pagesUrl"
Write-Host ""
Write-Host "In the ntfy iPhone app, tap + and subscribe to:"
Write-Host "    $topic" -ForegroundColor Yellow
Write-Host "Keep it private: anyone who knows the name can read your alerts."
Write-Host "Optional: import feeds.opml into NetNewsWire to browse every source yourself."
