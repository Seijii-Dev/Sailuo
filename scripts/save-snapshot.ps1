#  save-snapshot.ps1 - Save one named snapshot of a specific profile
#
#  The normal 4-minute auto-save always overwrites the single asset
#  `sailuo-state.7z.enc`, so older states disappear. This script keeps a
#  permanent, clearly named copy instead:
#
#      .\save-snapshot.ps1 -ProfileDir 'C:\Users\sailuo' -Name 'sailuo-snapshot-run40141009370'
#
#  Result: release asset `sailuo-snapshot-run40141009370.7z.enc`
#  Restore it later with:
#      .\restore-state.ps1 -Asset 'sailuo-snapshot-run40141009370.7z.enc'
#
#  Encrypted with the same AES-256 format as persist-state.ps1, so
#  restore-state.ps1 can read it without any extra setup.

param(
  [string]$ProfileDir,
  [Parameter(Mandatory = $true)][string]$Name,
  [string]$Repo,
  [string]$Token,
  [switch]$NoUpload
)

$ErrorActionPreference = 'Continue'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'lib-common.ps1')

function Log([string]$m) {
  $line = "[$(Get-Date -Format 'HH:mm:ss') UTC][Sailuo:snapshot] $m"
  Write-Host $line
}

# --- credentials -----------------------------------------------------------
$sEnv = $null
$envFile = 'C:\Sailuo\tools\session-env.json'
if (Test-Path $envFile) {
  try { $sEnv = Get-Content $envFile -Raw | ConvertFrom-Json } catch {}
}
$u = if ($env:RDP_USER) { $env:RDP_USER } elseif ($sEnv.RDP_USER) { $sEnv.RDP_USER } else { 'sailuo' }
$p = if ($env:RDP_PASSWORD) { $env:RDP_PASSWORD } elseif ($sEnv.RDP_PASSWORD) { $sEnv.RDP_PASSWORD } else { '' }
if (-not $Repo) { $Repo = if ($env:GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY } elseif ($sEnv.GITHUB_REPOSITORY) { $sEnv.GITHUB_REPOSITORY } else { 'Seijii-Dev/Sailuo' } }
if (-not $Token) {
  if ($env:GITHUB_TOKEN) {
    $Token = $env:GITHUB_TOKEN
  } elseif (Test-Path 'D:\a\Sailuo\Sailuo\.git\config') {
    $cfg = Get-Content 'D:\a\Sailuo\Sailuo\.git\config' -Raw
    $mm = [regex]::Match($cfg, 'AUTHORIZATION: basic (\S+)')
    if ($mm.Success) {
      $dec = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($mm.Groups[1].Value))
      $Token = ($dec -replace '^[^:]*:', '')
    }
  }
}
if (-not $Token) { $Token = $sEnv.GITHUB_TOKEN }

$secretKey = if ($p.Length -ge 4) { "Sailuo-Persist-$u-$p" } else { "Sailuo-Persist-$Repo" }

# --- work dirs -------------------------------------------------------------
$workDir  = 'C:\Sailuo\state-archive'
$stageDir = Join-Path $workDir 'stage'
$zipPath  = Join-Path $workDir 'snapshot.7z'
$encPath  = Join-Path $workDir "$Name.7z.enc"

Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

$profileDirs = if ($ProfileDir) { @($ProfileDir) } else { @(Get-AllUserProfileDirs $u) }
Log "Profiles: $($profileDirs -join ', ')"

function Get-DirSizeMB([string]$Path) {
  if (-not (Test-Path $Path)) { return 0 }
  try {
    $sum = 0
    $stack = New-Object System.Collections.Stack
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
      $cur = $stack.Pop()
      Get-ChildItem -LiteralPath $cur -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.PSIsContainer) {
          if ($global:SailuoExcludeDirs -notcontains $_.Name) { $stack.Push($_.FullName) }
        } else { $sum += $_.Length }
      }
    }
    if (-not $sum) { return 0 }
    return [math]::Round($sum / 1MB, 1)
  } catch { return 0 }
}

function Copy-SafeFolder([string]$Src, [string]$Dst, [int]$MaxMB = 900) {
  if (-not (Test-Path $Src)) { return }
  $sz = Get-DirSizeMB $Src
  if ($sz -le 0) { return }
  if ($sz -gt $MaxMB) { Log "  Skip $Src ($sz MB > limit $MaxMB MB)"; return }
  Log "  Copying $Src ($sz MB)..."
  New-Item -ItemType Directory -Path $Dst -Force -ErrorAction SilentlyContinue | Out-Null
  Copy-TreeUnlocked $Src $Dst
}

function Copy-ChromiumSession([string]$BrowserName, [string]$UserDataDir) {
  if (-not (Test-Path $UserDataDir)) { return }
  $dstRoot = Join-Path $stageDir "Browsers\$BrowserName"
  New-Item -ItemType Directory -Path $dstRoot -Force -ErrorAction SilentlyContinue | Out-Null
  $localState = Join-Path $UserDataDir 'Local State'
  if (Test-Path $localState) { Copy-FileUnlocked $localState (Join-Path $dstRoot 'Local State') | Out-Null }

  foreach ($prof in @('Default', 'Profile 1', 'Profile 2', 'Profile 3', 'Profile 4', 'Profile 5')) {
    $profSrc = Join-Path $UserDataDir $prof
    if (-not (Test-Path $profSrc)) { continue }
    $profDst = Join-Path $dstRoot $prof
    New-Item -ItemType Directory -Path $profDst -Force -ErrorAction SilentlyContinue | Out-Null
    foreach ($rel in @(
        'Preferences', 'Secure Preferences', 'Bookmarks', 'Bookmarks.bak',
        'Login Data', 'Login Data-journal', 'Login Data-wal', 'Login Data-shm',
        'Login Data For Account', 'Login Data For Account-journal', 'Login Data For Account-wal', 'Login Data For Account-shm',
        'Web Data', 'Web Data-journal', 'Web Data-wal', 'Web Data-shm',
        'History', 'History-journal', 'History-wal', 'Favicons', 'Shortcuts', 'Visited Links', 'TransportSecurity',
        'Network\Cookies', 'Network\Cookies-journal', 'Network\Cookies-wal', 'Network\Cookies-shm',
        'Network\Reporting and NEL', 'Network\TransportSecurity', 'Network\Trust Tokens',
        'Cookies', 'Cookies-journal', 'Cookies-wal', 'Cookies-shm')) {
      $fSrc = Join-Path $profSrc $rel
      if (Test-Path -LiteralPath $fSrc) { Copy-FileUnlocked $fSrc (Join-Path $profDst $rel) | Out-Null }
    }
    foreach ($subDir in @('Local Storage\leveldb', 'Session Storage', 'Extension State', 'Sync Data\LevelDB', 'Local Extension Settings', 'IndexedDB')) {
      $dSrc = Join-Path $profSrc $subDir
      if ((Test-Path $dSrc) -and ((Get-DirSizeMB $dSrc) -le 120)) {
        Copy-TreeUnlocked $dSrc (Join-Path $profDst $subDir)
      }
    }
  }
  Log "  Browser login session $BrowserName copied."
}

# --- stage -----------------------------------------------------------------
Copy-SafeFolder 'C:\Persist' (Join-Path $stageDir 'Persist') 1200

foreach ($profDir in $profileDirs) {
  foreach ($sub in @('Desktop', 'Documents', 'Downloads', 'Pictures', 'Videos', 'Music')) {
    $s = Join-Path $profDir $sub
    if (Test-Path $s) { Copy-SafeFolder $s (Join-Path $stageDir "User\$sub") 600 }
  }
}

foreach ($profDir in $profileDirs) {
  Copy-ChromiumSession 'Chrome' (Join-Path $profDir 'AppData\Local\Google\Chrome\User Data')
  Copy-ChromiumSession 'Edge'   (Join-Path $profDir 'AppData\Local\Microsoft\Edge\User Data')
  Copy-ChromiumSession 'Brave'  (Join-Path $profDir 'AppData\Local\BraveSoftware\Brave-Browser\User Data')
  $ffProfiles = Join-Path $profDir 'AppData\Roaming\Mozilla\Firefox'
  if (Test-Path $ffProfiles) { Copy-SafeFolder $ffProfiles (Join-Path $stageDir 'Browsers\Firefox') 200 }

  foreach ($dpapiRel in @(
      'AppData\Roaming\Microsoft\Protect',
      'AppData\Roaming\Microsoft\Credentials',
      'AppData\Local\Microsoft\Credentials',
      'AppData\Roaming\Microsoft\Crypto')) {
    $dpSrc = Join-Path $profDir $dpapiRel
    if (Test-Path $dpSrc) {
      Copy-TreeUnlocked $dpSrc (Join-Path $stageDir "DPAPI\$dpapiRel")
    }
  }
}

$allStaged = @(Get-ChildItem -Path $stageDir -Recurse -File -Force -ErrorAction SilentlyContinue)
$fileCount = $allStaged.Count
if ($fileCount -eq 0) { Log 'Nothing to save.'; exit 1 }
$totalMB = [math]::Round((($allStaged | Measure-Object -Property Length -Sum).Sum) / 1MB, 2)
Log "Compressing $fileCount files ($totalMB MB)..."

$sevenZip = "${env:ProgramFiles}\7-Zip\7z.exe"
if (Test-Path $sevenZip) {
  & $sevenZip a -t7z -mx=3 $zipPath "$stageDir\*" | Out-Null
} else {
  $zipPath = Join-Path $workDir 'snapshot.zip'
  Compress-Archive -Path "$stageDir\*" -DestinationPath $zipPath -CompressionLevel Fastest -Force
}
if (-not (Test-Path $zipPath)) { Log 'Failed to create the archive.'; exit 1 }
$zipMB = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
Log "Archive created ($zipMB MB). Encrypting with AES-256..."

# --- encrypt (XYST01 + salt + AES-256-CBC/PBKDF2, same as persist-state) ----
$salt = New-Object byte[] 16
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)
$kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($secretKey, $salt, 20000)
$aes = [System.Security.Cryptography.Aes]::Create()
$aes.KeySize = 256
$aes.Key = $kdf.GetBytes(32)
$aes.IV = $kdf.GetBytes(16)
$aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
$aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7

$fsOut = [System.IO.File]::OpenWrite($encPath)
$header = [System.Text.Encoding]::ASCII.GetBytes('XYST01')
$fsOut.Write($header, 0, $header.Length)
$fsOut.Write($salt, 0, $salt.Length)
$cs = New-Object System.Security.Cryptography.CryptoStream($fsOut, $aes.CreateEncryptor(), [System.Security.Cryptography.CryptoStreamMode]::Write)
$fsIn = [System.IO.File]::OpenRead($zipPath)
$fsIn.CopyTo($cs)
$fsIn.Close()
$cs.FlushFinalBlock()
$cs.Close()
$fsOut.Close()
Log "Encrypted: $encPath"

if ($NoUpload) {
  Log 'NoUpload set - stopping here.'
  exit 0
}

# --- upload ----------------------------------------------------------------
$tag = 'sailuo-state-latest'
$hdrs = @{
  'Authorization' = "Bearer $Token"
  'Accept'        = 'application/vnd.github+json'
  'User-Agent'    = 'Sailuo-Snapshot'
}
try {
  $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/tags/$tag" -Headers $hdrs -TimeoutSec 30
  $assetName = "$Name.7z.enc"
  $existing = @($rel.assets | Where-Object { $_.name -eq $assetName })
  foreach ($a in $existing) {
    Invoke-RestMethod -Method Delete -Uri "https://api.github.com/repos/$Repo/releases/assets/$($a.id)" -Headers $hdrs -TimeoutSec 30 | Out-Null
    Log "  Replaced existing asset $assetName."
  }
  $uploadUrl = ($rel.upload_url -replace '\{\?name,label\}$', '') + "?name=$assetName"
  $upHdrs = @{
    'Authorization'        = "Bearer $Token"
    'Accept'               = 'application/vnd.github+json'
    'User-Agent'           = 'Sailuo-Snapshot'
    'Content-Type'         = 'application/octet-stream'
    'X-GitHub-Api-Version' = '2022-11-28'
  }
  Invoke-RestMethod -Method Post -Uri $uploadUrl -Headers $upHdrs -InFile $encPath -TimeoutSec 900 | Out-Null
  Log "Snapshot uploaded as '$assetName' ($zipMB MB, $fileCount files)."
  Log "Download: https://github.com/$Repo/releases/download/$tag/$assetName"
} catch {
  Log "Upload failed: $($_.Exception.Message)"
  Log "The encrypted file is still on disk: $encPath"
  exit 1
}

Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
Log 'Done.'
