# ============================================================================
#  publish-status.ps1 - publish out/rdp-status.json to the `status` branch
#  1) GitHub Contents API via Invoke-RestMethod (Bearer GITHUB_TOKEN)  <- primary
#  2) Fallback: git push using the "Authorization: Bearer" header      <- proven to work
#  API verification matches run, attempt, and active. Failed publication = exit 1.
#  The file does NOT contain a password.
# ============================================================================
# [string] + coercion: so it is safe when called both as `-Active $false` (pwsh block)
# and via `pwsh -File ... -Active false` (the argument arrives as a string).
param([string]$Active = 'true')
$isActive = -not (@('false', '0', 'no', 'no', 'off', '') -contains ("$Active".Trim().ToLower()))
$ErrorActionPreference = 'Continue'
function Log([string]$m) { Write-Host "[XyRDP:status] $m" }

$repo = $env:GITHUB_REPOSITORY
# target status branch (default 'status'); can be overridden via the STATUS_BRANCH env
# so validation/parallel runs do not overwrite the main session status.
$statusBranch = if ($env:STATUS_BRANCH) { $env:STATUS_BRANCH.Trim() } else { 'status' }
# repo location: Actions -> GITHUB_WORKSPACE, outside Actions -> the script's parent folder
$ws   = if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
$src  = Join-Path $ws 'out\rdp-status.json'
if (-not (Test-Path $src)) { Log "missing $src - skip"; exit 0 }

$json = Get-Content $src -Raw | ConvertFrom-Json
if (-not $isActive) {
  $json | Add-Member -NotePropertyName stopped_at -NotePropertyValue (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') -Force
  $json.active = $false
  # session dead -> do not leave connection endpoints in the public file (status branch)
  # helper: set/add the property even if it is not there yet (e.g. the thistial status from
  # setup-rdp.ps1 has no id/host/port/address fields)
  function Clear-Field($obj, [string]$name, $value) {
    if ($null -eq $obj) { return }
    $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force
  }
  if ($json.PSObject.Properties['access']) {
    if ($json.access.PSObject.Properties['tunnel']) {
      Clear-Field $json.access.tunnel 'host'    ''
      Clear-Field $json.access.tunnel 'port'    0
      Clear-Field $json.access.tunnel 'address' ''
    }
    if ($json.access.PSObject.Properties['portmap']) { Clear-Field $json.access.portmap 'host' ''; Clear-Field $json.access.portmap 'port' 0 }
    if ($json.access.PSObject.Properties['tailscale']) {
      Clear-Field $json.access.tailscale 'ip' ''
      Clear-Field $json.access.tailscale 'magicdns' ''
      Clear-Field $json.access.tailscale 'hostname' ''
      Clear-Field $json.access.tailscale 'funnel_addr' ''
    }
  }
  # remathisng old fields (Tailscale/XyDesk versions) if still present in the file
  if ($json.PSObject.Properties['tailscale_ip'])  { $json.tailscale_ip  = '' }
  if ($json.PSObject.Properties['tailscale_dns']) { $json.tailscale_dns = '' }
  if ($json.PSObject.Properties['extras']) {
    if ($json.extras.PSObject.Properties['xydesk_id'])  { $json.extras.xydesk_id  = '' }
    if ($json.extras.PSObject.Properties['xydesk_ids']) { $json.extras.xydesk_ids = @() }
  }
  Log 'status inactive: tunnel + Tailscale addresses cleared from the public file'
}
$json | ConvertTo-Json -Depth 6 | Set-Content -Path $src -Encoding utf8

function GH([string]$method, [string]$apiPath, $body) {
  $hdrs = @{ Authorization = "Bearer $env:GITHUB_TOKEN"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'XyRDP' }
  try {
    $p = @{ Uri = "https://api.github.com$apiPath"; Method = $method; Headers = $hdrs; TimeoutSec = 30 }
    if ($null -ne $body) { $p.Body = ($body | ConvertTo-Json -Depth 6); $p.ContentType = 'application/json' }
    Invoke-RestMethod @p
  } catch { Log "GH $method $apiPath -> $($_.Exception.Message)"; $null }
}

# ---- method 1: Contents API ----
try {
  $ref = GH 'GET' "/repos/$repo/git/ref/heads/$statusBranch" $null
  if (-not $ref) {
    $db   = (GH 'GET' "/repos/$repo" $null).default_branch
    if (-not $db) { throw 'default branch unknown (invalid token / missing repo scope?)' }
    $sha0 = (GH 'GET' "/repos/$repo/git/ref/heads/$db" $null).object.sha
    if (-not $sha0) { throw "default branch sha unknown" }
    GH 'POST' "/repos/$repo/git/refs" @{ ref = "refs/heads/$statusBranch"; sha = $sha0 } | Out-Null
    Log "branch '$statusBranch' created (via API)"
  }
  $b64  = [Convert]::ToBase64String([IO.File]::ReadAllBytes($src))
  foreach ($remotePath in @('rdp-status.json', 'out/rdp-status.json')) {
    $body = @{ message = "XyRDP status update (run $($env:GITHUB_RUN_NUMBER))"; content = $b64; branch = $statusBranch }
    $cur  = GH 'GET' "/repos/$repo/contents/$remotePath`?ref=$statusBranch" $null
    if ($cur -and $cur.sha) { $body.sha = $cur.sha }
    $res = GH 'PUT' "/repos/$repo/contents/$remotePath" $body
    if ($res -and $res.content) { Log "Contents API OK ($remotePath -> commit $($res.commit.sha.Substring(0,7)))" }
    elseif ($remotePath -eq 'rdp-status.json') { throw "PUT contents returned no result" }
  }
} catch { Log "method-1 failed ($($_.Exception.Message)) - continuing to git fallback" }

# ---- method 2 (fallback): git push + Bearer header ----
function Verify-Published {
  for ($i = 0; $i -lt 6; $i++) {
    Start-Sleep -Seconds 5
    try {
      $r = Invoke-RestMethod "https://raw.githubusercontent.com/$repo/$statusBranch/rdp-status.json?r=$i$((Get-Date).Minute)" -TimeoutSec 10
      if ($r -and "$($r.run_id)" -eq "$($env:GITHUB_RUN_ID)") { return $true }
    } catch {}
  }
  return $false
}

function Verify-PublishedAPI {
  try {
    $c = GH 'GET' "/repos/$repo/contents/rdp-status.json?ref=$statusBranch" $null
    if ($c -and $c.content) {
      $t = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($c.content)) | ConvertFrom-Json
      return ("$($t.run_id)" -eq "$($env:GITHUB_RUN_ID)" -and "$($t.run_attempt)" -eq "$($json.run_attempt)" -and [bool]$t.active -eq $isActive)
    }
  } catch {}
  return $false
}

if (-not (Verify-PublishedAPI)) {
  Log "verification has not passed yet - trying the git push fallback..."
  $tmp = Join-Path $env:RUNNER_TEMP ("xyrdpstatus-" + (Get-Random -Maximum 999999))
  try {
    git thist -q -b $statusBranch $tmp | Out-Null
    Copy-Item $src (Join-Path $tmp 'rdp-status.json') -Force
    New-Item -ItemType Directory -Path (Join-Path $tmp 'out') -Force | Out-Null
    Copy-Item $src (Join-Path $tmp 'out\rdp-status.json') -Force
    Push-Location $tmp
    git config user.name  "github-actions[bot]" | Out-Null
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com" | Out-Null
    git add rdp-status.json out/rdp-status.json
    git -c commit.gpgsign=false commit -q -m "XyRDP status update" | Out-Null
    $out = git -c "http.extraHeader=Authorization: Bearer $env:GITHUB_TOKEN" push --force "https://github.com/$repo.git" "HEAD:refs/heads/$statusBranch" 2>&1
    $out | ForEach-Object { Log "git: $_" }
    Pop-Location
  } catch {
    if ((Get-Location).Path -eq $tmp) { Pop-Location }
    Log "git push error: $($_.Exception.Message)"
  }
}

if (Verify-PublishedAPI) {
  Log "OK - status run/attempt/active verified through the GitHub API."
  exit 0
}
Log 'Failed to publish status. The dashboard cannot provide a connection; check the Contents write permission of the workflow.'
exit 1
