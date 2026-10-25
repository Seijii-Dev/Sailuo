# ============================================================================
#  persist-state.ps1 - Save Sailuo Session State (Auto-Save to GitHub Release)
# ----------------------------------------------------------------------------
#  Saves:
#    - C:\Persist (user's permanent folder)
#    - The RDP user's Desktop, Documents, Downloads, Pictures, Videos, Music
#      (read from all candidate profile folders: C:\Users\$u, ProfileList, C:\Users\$u.*)
#    - Browser Login Sessions (Google Chrome, Microsoft Edge, Brave, Firefox)
#      along with the DPAPI keys (AppData\Roaming\Microsoft\Protect & Credentials)
#      and SQLite WAL/SHM/LevelDB files using FileShare.ReadWrite
#      so Google/YouTube/GitHub logins stay saved even while Chrome is open!
#  Then encrypts the archive with AES-256-CBC (PBKDF2 from RDP_PASSWORD /
#  GITHUB_TOKEN) and uploads it to the hidden Release `sailuo-state-latest`
#  in the user's own repository.
# ============================================================================
param(
  [switch]$Checkpoint,
  [switch]$Force
)

$SailuoTag = if ($Checkpoint) { 'Sailuo:checkpoint' } else { 'Sailuo:persist' }
. "$PSScriptRoot/lib-common.ps1"

# Give every run a persistent log: scheduled tasks run headless and otherwise
# leave no trace when a checkpoint fails.
$script:SailuoLogFile = 'C:\Persist\System\persist-state.log'
try {
  New-Item -ItemType Directory -Path 'C:\Persist\System' -Force -ErrorAction SilentlyContinue | Out-Null
  if (Test-Path $script:SailuoLogFile) {
    $existingLines = @(Get-Content -LiteralPath $script:SailuoLogFile -ErrorAction SilentlyContinue)
    if ($existingLines.Count -gt 600) {
      Set-Content -LiteralPath $script:SailuoLogFile -Value ($existingLines | Select-Object -Last 400) -Encoding UTF8 -Force
    }
  }
  Add-Content -LiteralPath $script:SailuoLogFile -Value ("---- run start pid=$PID mode=$(if ($Checkpoint) { 'checkpoint' } else { 'final' }) at $([DateTime]::UtcNow.ToString('o')) ----") -Encoding UTF8 -ErrorAction SilentlyContinue
} catch {}

# Only one save or restore may touch the stage/upload at a time. Without this,
# the 4-minute task and a dashboard-triggered checkpoint can race, upload a
# half-written archive, or restore while a save is in flight.
$syncMutex = New-Object System.Threading.Mutex($false, 'Global\SailuoStateSync')
$syncOwned = $false
try {
  $syncOwned = $syncMutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
  $syncOwned = $true
} catch {
  $syncOwned = $false
}
if (-not $syncOwned) {
  Log 'Another cloud save or restore is already running - skip this run.'
  exit 0
}

# The mutex can be released prematurely (for example if a previous run exited
# while a child process kept running). As a second line of defence, refuse to
# start while a recorded owner is still alive.
$lockFile = 'C:\Persist\System\sync.lock'
$ownerPid = 0
if (Test-Path $lockFile) {
  try {
    $lockRaw = Get-Content $lockFile -Raw -ErrorAction SilentlyContinue
    if ($lockRaw -match '"pid"\s*:\s*(\d+)') { $ownerPid = [int]$Matches[1] }
  } catch {}
}
if ($ownerPid -gt 0 -and $ownerPid -ne $PID) {
  $ownerAlive = $false
  try { $ownerAlive = -not (Get-Process -Id $ownerPid -ErrorAction Stop).HasExited } catch { $ownerAlive = $false }
  if ($ownerAlive) {
    Log "Another cloud save (pid $ownerPid) is still running - skip this run."
    exit 0
  }
}

# Publish an in-progress marker so the dashboard can show "Saving..." while the
# scheduled task runs in the background. The marker is removed when the
# PowerShell process exits (including every early exit path below).
try {
  New-Item -ItemType Directory -Path 'C:\Persist\System' -Force -ErrorAction SilentlyContinue | Out-Null
  @{
    pid         = $PID
    mode        = $(if ($Checkpoint) { 'checkpoint' } else { 'final' })
    started_utc = [DateTime]::UtcNow.ToString('o')
  } | ConvertTo-Json | Set-Content -Path $lockFile -Encoding UTF8 -Force
  Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    Remove-Item 'C:\Persist\System\sync.lock' -Force -ErrorAction SilentlyContinue
  } | Out-Null
} catch {}

$cfg = Get-Cfg
if ($env:PERSIST_DATA -and @('no','0','false','no','off') -contains $env:PERSIST_DATA.Trim().ToLower()) {
  Log 'Data persistence disabled by user input - skip.'
  exit 0
}

# Fallback: read the environment from C:\Sailuo\tools\session-env.json when called from a background job / Dashboard
if ((-not $env:GITHUB_TOKEN -or -not $env:GITHUB_REPOSITORY) -and (Test-Path 'C:\Sailuo\tools\session-env.json')) {
  try {
    $sEnv = Get-Content 'C:\Sailuo\tools\session-env.json' -Raw | ConvertFrom-Json
    if (-not $env:RDP_USER -and $sEnv.RDP_USER) { $env:RDP_USER = $sEnv.RDP_USER }
    if (-not $env:RDP_PASSWORD -and $sEnv.RDP_PASSWORD) { $env:RDP_PASSWORD = $sEnv.RDP_PASSWORD }
    if (-not $env:GITHUB_TOKEN -and $sEnv.GITHUB_TOKEN) { $env:GITHUB_TOKEN = $sEnv.GITHUB_TOKEN }
    if (-not $env:GITHUB_REPOSITORY -and $sEnv.GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY = $sEnv.GITHUB_REPOSITORY }
  } catch {}
}

$ghToken = $env:GITHUB_TOKEN
$ghRepo  = $env:GITHUB_REPOSITORY
if (-not $ghToken -or -not $ghRepo) {
  Log 'GITHUB_TOKEN or GITHUB_REPOSITORY not available - skip persist state.'
  exit 0
}

$u = if ($env:RDP_USER) { $env:RDP_USER.Trim() } else { $cfg.rdp_user }
$p = if ($env:RDP_PASSWORD) { $env:RDP_PASSWORD.Trim() } else { '' }
$secretKey = if ($p.Length -ge 4) { "Sailuo-Persist-$u-$p" } else { "Sailuo-Persist-$ghRepo" }

$metaPath = 'C:\Persist\System\last-cloud-save.json'

# Record that the cloud copy is still current even when nothing changed. The
# dashboard reads last_check_utc together with last_saved_utc; without this a
# skipped checkpoint would look "stale" forever and trigger save attempts every
# minute.
function Write-CloudHeartbeat([int]$count, [double]$mb) {
  try {
    # Read the raw JSON instead of ConvertFrom-Json: PowerShell 7 turns ISO
    # date strings into DateTime objects, which would be re-serialized in a
    # locale-specific format that the dashboard cannot parse reliably.
    $raw = ''
    if (Test-Path $metaPath) {
      try { $raw = Get-Content $metaPath -Raw -ErrorAction SilentlyContinue } catch {}
    }
    $savedUtc = ''
    if ($raw -match '"last_saved_utc"\s*:\s*"([^"]+)"') { $savedUtc = $Matches[1] }
    $prevSize = $mb
    if ($raw -match '"size_mb"\s*:\s*([0-9.]+)') { $prevSize = [double]$Matches[1] }
    $prevCount = $count
    if ($raw -match '"file_count"\s*:\s*(\d+)') { $prevCount = [int]$Matches[1] }
    $prevUser = $u
    if ($raw -match '"user"\s*:\s*"([^"]*)"') { $prevUser = $Matches[1] }

    New-Item -ItemType Directory -Path 'C:\Persist\System' -Force -ErrorAction SilentlyContinue | Out-Null
    @{
      last_saved_utc = $(if ($savedUtc) { $savedUtc } else { [DateTime]::UtcNow.ToString('o') })
      last_check_utc = [DateTime]::UtcNow.ToString('o')
      size_mb        = $prevSize
      file_count     = $prevCount
      user           = $prevUser
      writer         = 'persist-state/v2'
    } | ConvertTo-Json | Set-Content -Path $metaPath -Encoding UTF8 -Force
  } catch {}
}

$workDir  = 'C:\Sailuo\state-work'
$stageDir = Join-Path $workDir 'stage'
$zipPath  = Join-Path $workDir 'sailuo-state.7z'
$encPath  = Join-Path $workDir 'sailuo-state.bin'

# Folders that were skipped only because they were larger than the per-folder
# limit. A backup that silently drops Desktop/Documents/Downloads is worse than
# no backup, so the upload is blocked while this list is not empty.
$global:SailuoSkippedFolders = New-Object System.Collections.ArrayList

Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

Log "Preparing session state storage for user '$u' (mode=$(if ($Checkpoint) { 'Checkpoint Live' } else { 'Final Shutdown' }))..."

# At session end (not a live checkpoint), close browsers gracefully so SQLite flushes the WAL into Cookies & Login Data
if (-not $Checkpoint) {
  foreach ($brProc in @('chrome', 'msedge', 'brave', 'firefox')) {
    try {
      Get-Process -Name $brProc -ErrorAction SilentlyContinue | ForEach-Object {
        $_.CloseMainWindow() | Out-Null
      }
    } catch {}
  }
  Start-Sleep -Milliseconds 1200
}

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
        } else {
          $sum += $_.Length
        }
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
  if ($sz -gt $MaxMB) {
    Log "  Skip $Src ($sz MB > limit $MaxMB MB)"
    [void]$global:SailuoSkippedFolders.Add("$Src ($sz MB)")
    return
  }
  Log "  Copying $Src ($sz MB)..."
  New-Item -ItemType Directory -Path $Dst -Force -ErrorAction SilentlyContinue | Out-Null
  Copy-TreeUnlocked $Src $Dst
}

# 1. C:\Persist (dedicated anti-reset folder)
Copy-SafeFolder 'C:\Persist' (Join-Path $stageDir 'Persist') 1200

# Also save the active Wallpaper to Persist\Config so the next session automatically uses the same wallpaper
try {
  $wpPersistenceDir = Join-Path $stageDir 'Persist\Config'
  New-Item -ItemType Directory -Path $wpPersistenceDir -Force -ErrorAction SilentlyContinue | Out-Null
  $pubWpDir = 'C:\Users\Public\Pictures\Sailuo'
  if (Test-Path $pubWpDir) {
    Get-ChildItem -Path $pubWpDir -Filter 'wallpaper.*' -File -ErrorAction SilentlyContinue | ForEach-Object {
      Copy-FileUnlocked $_.FullName (Join-Path $wpPersistenceDir $_.Name) | Out-Null
    }
  }
} catch {}

# 2. Collect ALL profile folders where the user may store files / browser logins
#    (C:\Users\$u, ProfileImagePath from ProfileList, C:\Users\$u.*)
$profileDirs = @(Get-AllUserProfileDirs $u)
Log "  Candidate profile folders for user '$u': $($profileDirs -join ', ')"

# Standard user folders (Downloads, Desktop, Documents, Pictures, Videos, Music)
foreach ($profDir in $profileDirs) {
  foreach ($sub in @('Desktop', 'Documents', 'Downloads', 'Pictures', 'Videos', 'Music')) {
    $s = Join-Path $profDir $sub
    if (Test-Path $s) {
      Copy-SafeFolder $s (Join-Path $stageDir "User\$sub") 2500
    }
  }
}

# 3. Browser Login Sessions (Chrome, Edge, Brave, Firefox) + DPAPI Master Keys + SQLite WAL/SHM
#     Uses Copy-FileUnlocked (FileShare.ReadWrite) so it stays 100% backed up
#     even while the browser is open during auto-checkpoint!
function Copy-ChromiumSession([string]$BrowserName, [string]$UserDataDir) {
  if (-not (Test-Path $UserDataDir)) { return }
  $dstRoot = Join-Path $stageDir "Browsers\$BrowserName"
  New-Item -ItemType Directory -Path $dstRoot -Force -ErrorAction SilentlyContinue | Out-Null

  $localState = Join-Path $UserDataDir 'Local State'
  if (Test-Path $localState) {
    Copy-FileUnlocked $localState (Join-Path $dstRoot 'Local State') | Out-Null
  }

  $profiles = @('Default', 'Profile 1', 'Profile 2', 'Profile 3', 'Profile 4', 'Profile 5')
  foreach ($prof in $profiles) {
    $profSrc = Join-Path $UserDataDir $prof
    if (-not (Test-Path $profSrc)) { continue }
    $profDst = Join-Path $dstRoot $prof
    New-Item -ItemType Directory -Path $profDst -Force -ErrorAction SilentlyContinue | Out-Null

    # Complete list of main SQLite files + journal/WAL files (-wal, -shm, -journal)
    $essentialFiles = @(
      'Preferences',
      'Secure Preferences',
      'Bookmarks',
      'Bookmarks.bak',
      'Login Data',
      'Login Data-journal',
      'Login Data-wal',
      'Login Data-shm',
      'Login Data For Account',
      'Login Data For Account-journal',
      'Login Data For Account-wal',
      'Login Data For Account-shm',
      'Web Data',
      'Web Data-journal',
      'Web Data-wal',
      'Web Data-shm',
      'History',
      'History-journal',
      'History-wal',
      'Favicons',
      'Shortcuts',
      'Visited Links',
      'TransportSecurity',
      'Network\Cookies',
      'Network\Cookies-journal',
      'Network\Cookies-wal',
      'Network\Cookies-shm',
      'Network\Reporting and NEL',
      'Network\TransportSecurity',
      'Network\Trust Tokens',
      'Cookies',
      'Cookies-journal',
      'Cookies-wal',
      'Cookies-shm'
    )
    foreach ($rel in $essentialFiles) {
      $fSrc = Join-Path $profSrc $rel
      if (Test-Path -LiteralPath $fSrc) {
        $fDst = Join-Path $profDst $rel
        Copy-FileUnlocked $fSrc $fDst | Out-Null
      }
    }
    foreach ($subDir in @('Local Storage\leveldb', 'Session Storage', 'Extension State', 'Sync Data\LevelDB', 'Local Extension Settings', 'IndexedDB')) {
      $dSrc = Join-Path $profSrc $subDir
      if ((Test-Path $dSrc) -and ((Get-DirSizeMB $dSrc) -le 120)) {
        $dDst = Join-Path $profDst $subDir
        Copy-TreeUnlocked $dSrc $dDst
      }
    }
  }
  Log "  Browser login session $BrowserName (Cookies + WAL + Login Data + LevelDB) copied successfully."
}

foreach ($profDir in $profileDirs) {
  Copy-ChromiumSession 'Chrome' (Join-Path $profDir 'AppData\Local\Google\Chrome\User Data')
  Copy-ChromiumSession 'Edge'   (Join-Path $profDir 'AppData\Local\Microsoft\Edge\User Data')
  Copy-ChromiumSession 'Brave'  (Join-Path $profDir 'AppData\Local\BraveSoftware\Brave-Browser\User Data')

  $ffProfiles = Join-Path $profDir 'AppData\Roaming\Mozilla\Firefox'
  if (Test-Path $ffProfiles) {
    Copy-SafeFolder $ffProfiles (Join-Path $stageDir 'Browsers\Firefox') 200
  }

  # User DPAPI Keys so Chrome Cookies & Passwords can still be decrypted in the next session's VM
  foreach ($dpapiRel in @(
    'AppData\Roaming\Microsoft\Protect',
    'AppData\Roaming\Microsoft\Credentials',
    'AppData\Local\Microsoft\Credentials',
    'AppData\Roaming\Microsoft\Crypto'
  )) {
    $dpSrc = Join-Path $profDir $dpapiRel
    if (Test-Path $dpSrc) {
      $dpDst = Join-Path $stageDir "DPAPI\$dpapiRel"
      Copy-TreeUnlocked $dpSrc $dpDst
    }
  }
}

# 4. Check whether anything will be saved & detect changes (API Anti-Spam for New Accounts)
$allStagedFiles = @(Get-ChildItem -Path $stageDir -Recurse -File -Force -ErrorAction SilentlyContinue)
$fileCount = $allStagedFiles.Count
if ($fileCount -eq 0) {
  Log 'No new files in C:\Persist or the user profile to save.'
  Write-CloudHeartbeat 0 0
  Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
  exit 0
}

$totalBytes = ($allStagedFiles | Measure-Object -Property Length -Sum).Sum

# A skipped folder means the user's files were left out. Never let that archive
# replace a healthy snapshot: the old behaviour produced a 4.5 MB "state" that
# looked valid while Desktop/Documents/Downloads were missing.
$skippedFolders = @()
if ($global:SailuoSkippedFolders) { $skippedFolders = @($global:SailuoSkippedFolders) }
if ($skippedFolders.Count -gt 0 -and -not $Force) {
  Log 'These folders are too large to back up and were left out:'
  $skippedFolders | ForEach-Object { Log "  - $_" }
  Log 'Keeping the previous cloud snapshot instead of uploading an incomplete one.'
  Log 'Move big installers out of those folders (C:\Persist is backed up separately) or raise the limit in persist-state.ps1.'
  Write-CloudHeartbeat $fileCount ([math]::Round($totalBytes / 1MB, 2))
  Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
  exit 0
}
$latestTicks = ($allStagedFiles | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).LastWriteTimeUtc.Ticks
$stateSig = "$fileCount|$totalBytes|$latestTicks"
$sigFile = 'C:\Sailuo\tools\last-checkpoint-sig.txt'
if ($Checkpoint -and (Test-Path $sigFile)) {
  $prevSig = (Get-Content $sigFile -Raw -ErrorAction SilentlyContinue).Trim()
  if ($prevSig -eq $stateSig) {
    Log "No data changes since the last checkpoint ($fileCount files) - skip the API upload."
    Write-CloudHeartbeat $fileCount ([math]::Round($totalBytes / 1MB, 2))
    Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 0
  }
}

# Report anything that could not be read, so a thin archive is never a surprise.
$copyFailures = @()
try {
  if ($global:SailuoCopyFailures) { $copyFailures = @($global:SailuoCopyFailures) }
} catch {}
if ($copyFailures.Count -gt 0) {
  $failedMB = [math]::Round((($copyFailures | Measure-Object -Property MB -Sum).Sum), 2)
  Log "Warning: $($copyFailures.Count) file(s) could not be read and were left out ($failedMB MB)."
  $copyFailures | Sort-Object MB -Descending | Select-Object -First 5 | ForEach-Object {
    Log "  - $($_.Path) ($($_.MB) MB)"
  }
}

Log "Compressing $fileCount state files..."
$sevenZip = "${env:ProgramFiles}\7-Zip\7z.exe"
if (Test-Path $sevenZip) {
  & $sevenZip a -t7z -mx=3 $zipPath "$stageDir\*" | Out-Null
} else {
  $zipPath = Join-Path $workDir 'sailuo-state.zip'
  Compress-Archive -Path "$stageDir\*" -DestinationPath $zipPath -CompressionLevel Fastest -Force
}

if (-not (Test-Path $zipPath)) {
  Log 'Failed to create the state archive.'
  exit 0
}

$zipMB = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
Log "State archive created ($zipMB MB). Encrypting with AES-256..."
if ($zipMB -gt 5400) {
  Log "Archive exceeds the maximum multi-part limit (5400 MB) - skip upload."
  Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
  exit 0
}

# Safety: never replace a healthy snapshot with a suspiciously incomplete one.
# A run is "suspicious" when a large file could not be read while staging, or
# when the archive shrank to less than half of the previous one. The first
# suspicious run is blocked once; if the next run is still suspicious (for
# example a file that stays locked) the shrink is accepted so backups can never
# stall forever. -Force bypasses the check.
$guardFile = 'C:\Persist\System\shrink-guard.txt'
$guardState = ''
if (Test-Path $guardFile) {
  $guardState = (Get-Content $guardFile -Raw -ErrorAction SilentlyContinue).Trim()
}
$prevRaw = ''
$prevMb = 0.0
$prevCount = 0
if (Test-Path $metaPath) {
  try {
    $prevRaw = Get-Content $metaPath -Raw -ErrorAction SilentlyContinue
    if ($prevRaw -match '"size_mb"\s*:\s*([0-9.]+)') { $prevMb = [double]$Matches[1] }
    if ($prevRaw -match '"file_count"\s*:\s*(\d+)') { $prevCount = [int]$Matches[1] }
  } catch {}
}
$bigFailures = @($copyFailures | Where-Object { $_.MB -ge 32 })
# A healthy snapshot must never be replaced by one that lost most of its files,
# even when the remaining bytes still look large (one big installer can hide a
# wiped profile). Compare the file count as well as the archive size.
$countCollapsed = ($prevCount -gt 20 -and $fileCount -lt [int]($prevCount * 0.5))
$isSuspicious = ($bigFailures.Count -gt 0) -or ($prevMb -gt 20 -and $zipMB -lt ($prevMb * 0.5)) -or $countCollapsed
if (-not $Force -and $isSuspicious -and (Test-Path $metaPath)) {
  if ($guardState -notmatch '^suspicious') {
    Set-Content -Path $guardFile -Value ("suspicious " + [DateTime]::UtcNow.ToString('o')) -Encoding ASCII -Force
    $reason = if ($bigFailures.Count -gt 0) {
      "$([math]::Round((($bigFailures | Measure-Object -Property MB -Sum).Sum), 2)) MB of files could not be read"
    } else {
      "$zipMB MB / $fileCount files vs previous $prevMb MB / $prevCount files"
    }
    Log "Keeping the previous cloud snapshot ($reason). It will be saved anyway if the next checkpoint looks the same."
    Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 0
  }
  Log "Archive is still suspicious ($zipMB MB / $fileCount files) - treating it as intentional and saving it."
  Remove-Item $guardFile -Force -ErrorAction SilentlyContinue
}

try {
  $salt = New-Object byte[] 16
  [System.Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($salt)
  $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($secretKey, $salt, 20000)
  $aes = [System.Security.Cryptography.Aes]::Create()
  $aes.KeySize = 256
  $aes.Key = $kdf.GetBytes(32)
  $aes.IV  = $kdf.GetBytes(16)
  $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
  $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7

  $fsOut = $null
  for ($encTry = 1; $encTry -le 5; $encTry++) {
    try {
      $fsOut = [System.IO.File]::OpenWrite($encPath)
      break
    } catch {
      Log "Encryption file is busy (attempt $encTry/5): $($_.Exception.Message)"
      Start-Sleep -Seconds 3
    }
  }
  if ($null -eq $fsOut) { throw 'could not open the encrypted output file' }
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
} catch {
  Log "Encryption failed: $($_.Exception.Message)"
  Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
  exit 0
}

$tag = 'sailuo-state-latest'
$hdrs = @{
  'Authorization' = "Bearer $ghToken"
  'Accept'        = 'application/vnd.github+json'
  'User-Agent'    = 'Sailuo-State'
}

try {
  $rel = $null
  try {
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$ghRepo/releases/tags/$tag" -Headers $hdrs -TimeoutSec 30
  } catch {}

  if (-not $rel) {
    $body = @{
      tag_name   = $tag
      name       = 'Sailuo Persistent State (Auto-Save)'
      body       = 'AES-256 encrypted archive for saving files between RDP sessions.'
      draft      = $false
      prerelease = $true
    } | ConvertTo-Json
    $rel = Invoke-RestMethod -Method Post -Uri "https://api.github.com/repos/$ghRepo/releases" -Headers $hdrs -ContentType 'application/json' -Body $body -TimeoutSec 30
  }

  $baseAssetName = if ($zipPath.EndsWith('.7z')) { 'sailuo-state.7z.enc' } else { 'sailuo-state.zip.enc' }
  # Never delete the only good snapshot before the new upload has succeeded.
  # Rename the current asset first (keeping the canonical name free), upload the
  # new archive, then remove the renamed copy. A failed upload leaves the old
  # snapshot in place so the next restore still has something to download.
  $oldAssetIds = @()
  foreach ($a in @($rel.assets)) {
    if ($a.name -like 'sailuo-state.*') {
      $oldAssetIds += $a.id
      if ($a.name -notlike 'sailuo-state-old-*') {
        try {
          $oldName = 'sailuo-state-old-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss') + ($a.name -replace '^sailuo-state', '')
          Invoke-RestMethod -Method Patch -Uri "https://api.github.com/repos/$ghRepo/releases/assets/$($a.id)" -Headers $hdrs -ContentType 'application/json' -Body (@{ name = $oldName } | ConvertTo-Json) -TimeoutSec 30 | Out-Null
          Log "  Previous snapshot kept as $oldName until the new upload succeeds."
        } catch {
          Log "  Could not rename the previous snapshot: $($_.Exception.Message)"
        }
      }
    }
  }

  $upHdrs = @{
    'Authorization' = "Bearer $ghToken"
    'Content-Type'  = 'application/octet-stream'
    'User-Agent'    = 'Sailuo-State'
  }
  $encLen = (Get-Item $encPath).Length
  $chunkMaxBytes = 1850L * 1024L * 1024L
  if ($encLen -le $chunkMaxBytes) {
    $uploadUrl = ($rel.upload_url -replace '\{\?name,label\}$', '') + "?name=$baseAssetName"
    Invoke-RestMethod -Method Post -Uri $uploadUrl -Headers $upHdrs -InFile $encPath -TimeoutSec 300 | Out-Null
    Log "State saved successfully to Release '$tag' ($baseAssetName, $zipMB MB, $fileCount files)."
  } else {
    # Multi-Part Split Archive Upload (>1.85 GB up to 5.4 GB)
    $fsRead = [System.IO.File]::OpenRead($encPath)
    $partIdx = 1
    $buf = New-Object byte[] (16 * 1024 * 1024)
    try {
      while ($fsRead.Position -lt $fsRead.Length) {
        $partName = "{0}.part{1:D2}" -f $baseAssetName, $partIdx
        $partPath = Join-Path $workDir $partName
        $fsPart = [System.IO.File]::Create($partPath)
        $written = 0L
        while ($written -lt $chunkMaxBytes -and $fsRead.Position -lt $fsRead.Length) {
          $toRead = [int][Math]::Min([long]$buf.Length, ($chunkMaxBytes - $written))
          $n = $fsRead.Read($buf, 0, $toRead)
          if ($n -le 0) { break }
          $fsPart.Write($buf, 0, $n)
          $written += $n
        }
        $fsPart.Close()
        $uploadUrl = ($rel.upload_url -replace '\{\?name,label\}$', '') + "?name=$partName"
        Invoke-RestMethod -Method Post -Uri $uploadUrl -Headers $upHdrs -InFile $partPath -TimeoutSec 300 | Out-Null
        Remove-Item $partPath -Force -ErrorAction SilentlyContinue
        Log "  Uploaded multi-part chunk $partName ($([math]::Round($written / 1MB, 1)) MB)"
        $partIdx++
      }
    } finally {
      $fsRead.Close()
    }
  }

  # The new snapshot is uploaded; only now drop the previous copy.
  foreach ($oldId in $oldAssetIds) {
    try {
      Invoke-RestMethod -Method Delete -Uri "https://api.github.com/repos/$ghRepo/releases/assets/$oldId" -Headers $hdrs -TimeoutSec 30 | Out-Null
    } catch {}
  }

  # Save the last state signature so the next checkpoint does not spam the API when nothing has changed
  New-Item -ItemType Directory -Path 'C:\Sailuo\tools' -Force -ErrorAction SilentlyContinue | Out-Null
  Set-Content -Path $sigFile -Value $stateSig -Encoding ASCII -Force

  # Record the last save time to display in the SailuoRemote Dashboard
  New-Item -ItemType Directory -Path 'C:\Persist\System' -Force -ErrorAction SilentlyContinue | Out-Null
  Remove-Item $guardFile -Force -ErrorAction SilentlyContinue
  @{
    last_saved_utc = [DateTime]::UtcNow.ToString('o')
    last_check_utc = [DateTime]::UtcNow.ToString('o')
    size_mb        = $zipMB
    file_count     = $fileCount
    user           = $u
    writer         = 'persist-state/v2'
  } | ConvertTo-Json | Set-Content -Path $metaPath -Encoding UTF8 -Force

  # At the end of a session, keep a copy of the archive on disk so the workflow
  # can attach it to the Actions run as a downloadable artifact. Without this
  # the artifact step found no file and every run ended up with 0 artifacts,
  # which meant an overwritten release asset could never be recovered.
  #
  # The workflow looks for C:\Sailuo\persist\sailuo-state.zip, so write that
  # exact name too. The extension is historical - the payload is the encrypted
  # 7z archive, identical to the .7z.enc copy.
  if (-not $Checkpoint) {
    try {
      New-Item -ItemType Directory -Path 'C:\Sailuo\persist' -Force -ErrorAction SilentlyContinue | Out-Null
      foreach ($artifactName in @('sailuo-state.7z.enc', 'sailuo-state.zip')) {
        Copy-Item -LiteralPath $encPath -Destination (Join-Path 'C:\Sailuo\persist' $artifactName) -Force -ErrorAction Stop
      }
      Log 'Kept a copy for the run artifact: C:\Sailuo\persist\sailuo-state.zip'
    } catch {
      Log "Could not keep the artifact copy: $($_.Exception.Message)"
    }
  }
} catch {
  Log "State upload failed: $($_.Exception.Message)"
}

Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
exit 0
