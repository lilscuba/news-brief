# Deploys the app backend to Cloudflare and connects it to GitHub. Windows PowerShell.
#
# Needs: Node.js, a free Cloudflare account, the GitHub CLI logged in (setup.ps1 does that),
# and your app's bundle id (e.g. com.yourname.newsfeed).
# Run from the server folder:   powershell -ExecutionPolicy Bypass -File .\deploy.ps1
# Safe to re-run: existing database/namespace ids in wrangler.toml are kept.

$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot

function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Fail($text) { Write-Host $text -ForegroundColor Red; exit 1 }
function Check($what) { if ($LASTEXITCODE -ne 0) { Fail "Failed: $what" } }

if (-not (Get-Command npx -ErrorAction SilentlyContinue)) { Start-Process "https://nodejs.org/en/download"; Fail "Install Node.js (LTS) from the page that just opened, then run this again." }

Step "Installing wrangler (Cloudflare's CLI)"
npm install --silent; Check "npm install"

Step "Logging in to Cloudflare (a browser window opens)"
# whoami exits 0 even when logged out, so read what it says.
$who = (npx wrangler whoami 2>&1 | Out-String)
if ($who -match "not authenticated" -or $who -notmatch "Account ID|associated with the email") {
    Write-Host "A browser page opens. No Cloudflare account? Click 'Sign up' -> 'Continue with GitHub'." -ForegroundColor Yellow
    npx wrangler login; Check "wrangler login"
}

$toml = Get-Content wrangler.toml -Raw

if ($toml -match 'com\.yourname\.newsfeed') {
    $bundle = Read-Host "Your iOS app bundle id (e.g. com.davidr.newsfeed)"
    if (-not $bundle) { Fail "A bundle id is required." }
    $toml = $toml.Replace("com.yourname.newsfeed", $bundle)
}

if ($toml -match 'REPLACE_WITH_D1_ID') {
    Step "Creating the database"
    $out = (npx wrangler d1 create newsfeed 2>&1 | Out-String)
    $m = [regex]::Match($out, 'database_id\s*=\s*"([0-9a-f-]{36})"')
    if (-not $m.Success) { $m = [regex]::Match($out, '"database_id"\s*:\s*"([0-9a-f-]{36})"') }
    if (-not $m.Success) { Write-Host $out; Fail "Couldn't read the database id (if it already exists, paste its id into wrangler.toml)." }
    $toml = $toml.Replace("REPLACE_WITH_D1_ID", $m.Groups[1].Value)
}

if ($toml -match 'REPLACE_WITH_KV_ID') {
    Step "Creating the feed store"
    $out = (npx wrangler kv namespace create FEED 2>&1 | Out-String)
    $m = [regex]::Match($out, '\bid\s*[=:]\s*"([0-9a-f]{32})"')
    if (-not $m.Success) { Write-Host $out; Fail "Couldn't read the KV namespace id; paste it into wrangler.toml." }
    $toml = $toml.Replace("REPLACE_WITH_KV_ID", $m.Groups[1].Value)
}
[IO.File]::WriteAllText("$PSScriptRoot\wrangler.toml", $toml)

Step "Creating tables"
npx wrangler d1 execute newsfeed --remote --file=schema.sql --yes; Check "d1 execute"

Step "Setting the ingest secret"
$bytes = New-Object byte[] 32
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$secret = -join ($bytes | ForEach-Object { $_.ToString("x2") })
$secret | npx wrangler secret put INGEST_SECRET; Check "wrangler secret put"

Step "Deploying"
$out = (npx wrangler deploy 2>&1 | Out-String)
Write-Host $out
$m = [regex]::Match($out, 'https://[a-z0-9.-]+\.workers\.dev')
if (-not $m.Success) { Fail "Deploy didn't print a workers.dev URL; check the output above." }
$url = $m.Value + "/"
# Remembered for launch.ps1 (not secret; ignored by git).
[IO.File]::WriteAllText("$PSScriptRoot\.deployed.json", (@{ url = $url } | ConvertTo-Json))

Step "Connecting GitHub (the 15-minute ingest job)"
$repo = (gh repo view --json nameWithOwner --jq .nameWithOwner 2>$null)
if ($repo) {
    gh variable set WORKER_URL --repo $repo --body $url; Check "gh variable set"
    gh secret set INGEST_SECRET --repo $repo --body $secret; Check "gh secret set"
    gh workflow run ingest.yml --repo $repo
    Write-Host "Started the first ingest run on $repo."
} else {
    Write-Host "Not in a GitHub repo yet. Add variable WORKER_URL=$url and secret INGEST_SECRET by hand." -ForegroundColor Yellow
    Write-Host "INGEST_SECRET: $secret"
}

Write-Host ""
Write-Host "== Backend is live ==" -ForegroundColor Green
Write-Host "API:            $url"
Write-Host "Health check:   ${url}v1/health"
Write-Host "Privacy policy: ${url}privacy   (use this URL in App Store Connect)"
Write-Host ""
Write-Host "Next: put $url in ios/project.yml (API_BASE_URL), then add the APNs secrets (server/README.md)."
