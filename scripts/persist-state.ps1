# ============================================================================
#  persist-state.ps1 - Save Sailuo Session State (Auto-Save to GitHub Release)
# ----------------------------------------------------------------------------
#  Saves:
#    - C:\Persist (user's permanent folder; runtime metadata is excluded)
#    - The RDP user's Desktop, Documents, Downloads, Pictures, Videos, Music
#      (read from the authoritative ProfileList profile, including dynamically
#      named profiles such as C:\Users\sailuo.runnervmdaln5)
#    - Browser Login Sessions (Google Chrome, Microsoft Edge, Brave, Firefox)
#      along with the DPAPI keys (AppData\Roaming\Microsoft\Protect &
#      Credentials) and SQLite WAL/SHM/LevelDB files using FileShare.ReadWrite
#      so Google/YouTube/GitHub logins stay saved even while Chrome is open!
#  Then encrypts the archive with AES-256-CBC (PBKDF2 from RDP_PASSWORD /
#  GITHUB_TOKEN) and uploads it to the hidden Release `sailuo-state-latest`
#  in the user's own repository.
#
#  Exit codes (dashboard contract):
#    0 = success, 1 = failure, 2 = skipped (busy/unchanged/disabled),
#    3 = completed with a documented warning.
# ============================================================================
param(
  [switch]$Checkpoint,
  [switch]$Force,
  [string]$OperationId,
  [string]$ReleaseTag = 'sailuo-state-latest',
  [string]$AssetBaseName = 'sailuo-state'
)

$SailuoTag = if ($Checkpoint) { 'Sailuo:checkpoint' } else { 'Sailuo:persist' }
$script:SailuoLogFile = 'C:\Persist\System\persist-state.log'
. "$PSScriptRoot/lib-common.ps1"

$script:SailuoOperationStartedUtc = $null
# Keep the caller-supplied id even for early failures that happen before
# Start-SailuoOperation, so the dashboard can always match the result file.
$script:SailuoOperationId = $OperationId
$script:SailuoSyncMutex = $null
$script:SailuoMutexOwned = $false

# Keep a rolling, non-secret diagnostic log. Scheduled tasks run headless.
try {
  New-Item -ItemType Directory -Path 'C:\Persist\System' -Force -ErrorAction SilentlyContinue | Out-Null
  if (Test-Path $script:SailuoLogFile) {
    $existingLines = @(Get-Content -LiteralPath $script:SailuoLogFile -ErrorAction SilentlyContinue)
    if ($existingLines.Count -gt 700) {
      Set-Content -LiteralPath $script:SailuoLogFile -Value ($existingLines | Select-Object -Last 450) -Encoding UTF8 -Force
    }
  }
  Add-Content -LiteralPath $script:SailuoLogFile -Encoding UTF8 -ErrorAction SilentlyContinue `
    -Value ("---- run start pid=$PID mode=$(if ($Checkpoint) { 'checkpoint' } else { 'final' }) at $([DateTime]::UtcNow.ToString('o')) ----")
} catch {}

$metaPath = $global:SailuoCloudMetaPath
$workDir = 'C:\Sailuo\state-work'
$stageDir = Join-Path $workDir 'stage'

# Only one save or restore may touch the stage/upload/profile at a time.
$syncMutex = New-Object System.Threading.Mutex($false, 'Local\SailuoStateSync')
$script:SailuoSyncMutex = $syncMutex
try {
  $script:SailuoMutexOwned = $syncMutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
  $script:SailuoMutexOwned = $true
} catch {
  $script:SailuoMutexOwned = $false
}
if (-not $script:SailuoMutexOwned) {
  Log 'Another cloud save or restore is already running - this run was skipped safely.'
  exit 2
}

# A killed process can leave the mutex released while a child still writes the
# lock file. Refuse to start until the recorded owner is really gone.
$lockFile = $global:SailuoSyncLockPath
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
    Log "Another cloud operation (pid $ownerPid) is still running - this run was skipped safely."
    try { $syncMutex.ReleaseMutex() } catch {}
    exit 2
  }
  Log "Removing stale synchronization lock left by pid $ownerPid."
}

Write-SailuoSyncLock $(if ($Checkpoint) { 'checkpoint' } else { 'final' })
try {
  Register-EngineEvent -SourceIdentifier "Sailuo.Persist.$PID" -Action {
    try {
      $raw = Get-Content -LiteralPath 'C:\Persist\System\sync.lock' -Raw -ErrorAction SilentlyContinue
      if ($raw -match '"pid"\s*:\s*(\d+)' -and [int]$Matches[1] -eq $PID) {
        Remove-Item -LiteralPath 'C:\Persist\System\sync.lock' -Force -ErrorAction SilentlyContinue
      }
    } catch {}
  } | Out-Null
} catch {}

# ---------------------------------------------------------------------------
#  Result helpers: every exit path writes a result that belongs to this run.
# ---------------------------------------------------------------------------
function Complete-SailuoOperation {
  param(
    [int]$Code,
    [string]$Status,
    [string]$Message,
    [string]$ErrorText = '',
    [hashtable]$Meta = @{},
    [hashtable]$Extra = @{}
  )
  $now = Get-SailuoUtcNowText
  $pairs = @{
    schema            = 2
    status            = $Status
    operation         = 'save'
    operation_id      = $script:SailuoOperationId
    writer            = 'persist-state/3'
    last_attempt_utc  = $now
    pid               = $PID
    progress          = ''
  }
  foreach ($k in $Meta.Keys) { $pairs[$k] = $Meta[$k] }
  if ($ErrorText) {
    $pairs.last_error = $ErrorText
    $pairs.last_error_utc = $now
    $pairs.last_error_operation = 'save'
  } elseif ($Status -in @('success','warning','skipped')) {
    $pairs.last_error = ''
  }
  try { Set-SailuoCloudMeta $pairs | Out-Null } catch { Log "Could not update snapshot metadata: $($_.Exception.Message)" }
  try {
    $statusPairs = @{
      status       = $Status
      operation    = 'save'
      operation_id = $script:SailuoOperationId
      updated_utc  = $now
    }
    if ($Meta.ContainsKey('asset_name'))     { $statusPairs.asset = $Meta['asset_name'] }
    if ($Meta.ContainsKey('file_count'))     { $statusPairs.files = $Meta['file_count'] }
    if ($Meta.ContainsKey('size_mb'))        { $statusPairs.size_mb = $Meta['size_mb'] }
    if ($Meta.ContainsKey('user'))           { $statusPairs.user = $Meta['user'] }
    if ($Meta.ContainsKey('last_saved_utc')) { $statusPairs.last_saved_utc = $Meta['last_saved_utc'] }
    if ($Meta.ContainsKey('last_check_utc')) { $statusPairs.last_check_utc = $Meta['last_check_utc'] }
    if ($ErrorText) { $statusPairs.error = $ErrorText }
    if ($Status -eq 'success' -or $Status -eq 'warning') {
      # The active session now matches a freshly uploaded snapshot, so it no
      # longer originates from a restore.
      $statusPairs.restored = $false
      $statusPairs.verified = $true
    } elseif ($Status -eq 'failure') {
      $statusPairs.verified = $false
    }
    Update-PersistStatus $statusPairs | Out-Null
  } catch {}
  try {
    Write-SailuoOperationResult -Operation 'save' -OperationId $script:SailuoOperationId `
      -Status $Status -Message $Message -ErrorText $ErrorText -ExitCode $Code `
      -Extra $Extra
  } catch { Log "Could not write the operation result: $($_.Exception.Message)" }

  Remove-SailuoSyncLock
  try {
    if ($script:SailuoMutexOwned -and $script:SailuoSyncMutex) {
      $script:SailuoSyncMutex.ReleaseMutex()
      $script:SailuoMutexOwned = $false
    }
  } catch {}
  Log $Message
  exit $Code
}

function Fail-Sailuo([string]$Message, [string]$Stage, [hashtable]$Extra = @{}) {
  $details = @{ stage = $Stage }
  foreach ($k in $Extra.Keys) { $details[$k] = $Extra[$k] }
  Complete-SailuoOperation -Code 1 -Status 'failure' -Message $Message -ErrorText $Message -Extra $details
}

function Skip-Sailuo([string]$Message, [string]$Reason, [hashtable]$Meta = @{}) {
  $all = @{ reason = $Reason }
  foreach ($k in $Meta.Keys) { $all[$k] = $Meta[$k] }
  Complete-SailuoOperation -Code 2 -Status 'skipped' -Message $Message -Meta $Meta -Extra $all
}

function Warn-Sailuo([string]$Message, [string]$Reason, [hashtable]$Meta = @{}) {
  $all = @{ reason = $Reason }
  foreach ($k in $Meta.Keys) { $all[$k] = $Meta[$k] }
  Complete-SailuoOperation -Code 3 -Status 'warning' -Message $Message -Meta $Meta -Extra $all
}

function Invoke-GitHubRequest {
  param(
    [string]$Method,
    [string]$Uri,
    [hashtable]$Headers,
    [object]$Body = $null,
    [string]$InFile = $null,
    [int]$TimeoutSec = 60
  )
  try {
    $params = @{ Method = $Method; Uri = $Uri; Headers = $Headers; TimeoutSec = $TimeoutSec; ErrorAction = 'Stop' }
    if ($null -ne $Body) {
      $params.ContentType = 'application/json'
      $params.Body = ($Body | ConvertTo-Json -Depth 6)
    }
    if ($InFile) { $params.InFile = $InFile }
    $data = Invoke-RestMethod @params
    return @{ ok = $true; status = 200; data = $data; error = ''; body = '' }
  } catch {
    $status = 0
    $bodyText = ''
    try { $status = [int]$_.Exception.Response.StatusCode } catch {}
    try {
      $stream = $_.Exception.Response.GetResponseStream()
      if ($stream) {
        $reader = New-Object System.IO.StreamReader($stream)
        $bodyText = $reader.ReadToEnd()
        $reader.Dispose()
      }
    } catch {}
    return @{ ok = $false; status = $status; data = $null; error = $_.Exception.Message; body = $bodyText }
  }
}

function Get-GitHubRelease {
  param([string]$Repo, [string]$Tag, [hashtable]$Headers)
  return (Invoke-GitHubRequest -Method 'GET' -Uri "https://api.github.com/repos/$Repo/releases/tags/$Tag" -Headers $Headers -TimeoutSec 30)
}

function Get-GitHubAssetList {
  param([string]$Repo, [string]$Tag, [hashtable]$Headers)
  $result = Get-GitHubRelease -Repo $Repo -Tag $Tag -Headers $Headers
  if (-not $result.ok) { return @() }
  return @($result.data.assets)
}

function Get-DirSizeMB([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return 0 }
  try {
    $sum = 0L
    $stack = New-Object System.Collections.Stack
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
      $cur = $stack.Pop()
      Get-ChildItem -LiteralPath $cur -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if (Test-SailuoPathExcluded $_.FullName) { return }
        if ($_.PSIsContainer) {
          if ($global:SailuoExcludeDirs -notcontains $_.Name) { $stack.Push($_.FullName) }
        } else {
          $sum += $_.Length
        }
      }
    }
    if (-not $sum) { return 0 }
    return [math]::Round($sum / 1MB, 6)
  } catch { return 0 }
}

$global:SailuoSkippedFolders = New-Object System.Collections.ArrayList
$global:SailuoCopyFailures = New-Object System.Collections.ArrayList
$global:SailuoExcludePaths = New-Object System.Collections.ArrayList
[void]$global:SailuoExcludePaths.Add('C:\Persist\System')
[void]$global:SailuoExcludePaths.Add($workDir)
[void]$global:SailuoExcludePaths.Add('C:\Sailuo\restore-work')

function Copy-SafeFolder([string]$Src, [string]$Dst, [int]$MaxMB = 900) {
  if (-not (Test-Path -LiteralPath $Src)) { return }
  if (Test-SailuoPathExcluded $Src) { return }
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

function Copy-ChromiumSession([string]$BrowserName, [string]$UserDataDir) {
  if (-not (Test-Path -LiteralPath $UserDataDir)) { return }
  $dstRoot = Join-Path $stageDir "Browsers\$BrowserName"
  New-Item -ItemType Directory -Path $dstRoot -Force -ErrorAction SilentlyContinue | Out-Null

  $localState = Join-Path $UserDataDir 'Local State'
  if (Test-Path -LiteralPath $localState) {
    Copy-FileUnlocked $localState (Join-Path $dstRoot 'Local State') | Out-Null
  }

  foreach ($prof in @('Default', 'Profile 1', 'Profile 2', 'Profile 3', 'Profile 4', 'Profile 5')) {
    $profSrc = Join-Path $UserDataDir $prof
    if (-not (Test-Path -LiteralPath $profSrc)) { continue }
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
      if (Test-Path -LiteralPath $fSrc) {
        Copy-FileUnlocked $fSrc (Join-Path $profDst $rel) | Out-Null
      }
    }
    foreach ($subDir in @('Local Storage\leveldb', 'Session Storage', 'Extension State', 'Sync Data\LevelDB', 'Local Extension Settings', 'IndexedDB')) {
      $dSrc = Join-Path $profSrc $subDir
      if ((Test-Path -LiteralPath $dSrc) -and ((Get-DirSizeMB $dSrc) -le 120)) {
        Copy-TreeUnlocked $dSrc (Join-Path $profDst $subDir)
      }
    }
  }
  $copied = @(Get-ChildItem -LiteralPath $dstRoot -Recurse -File -Force -ErrorAction SilentlyContinue).Count
  if ($copied -gt 0) {
    Log "  Browser login session $BrowserName copied ($copied files)."
  }
}

try {
  $cfg = Get-Cfg
  if ($env:PERSIST_DATA -and @('no', '0', 'false', 'off') -contains $env:PERSIST_DATA.Trim().ToLower()) {
    Skip-Sailuo 'Data persistence is disabled; no snapshot was created.' 'disabled-by-user'
  }

  # Background jobs and the dashboard do not inherit the setup process env.
  if ((-not $env:GITHUB_TOKEN -or -not $env:GITHUB_REPOSITORY) -and (Test-Path 'C:\Sailuo\tools\session-env.json')) {
    try {
      $sEnv = Get-Content 'C:\Sailuo\tools\session-env.json' -Raw | ConvertFrom-Json
      if (-not $env:RDP_USER -and $sEnv.RDP_USER) { $env:RDP_USER = $sEnv.RDP_USER }
      if (-not $env:RDP_PASSWORD -and $sEnv.RDP_PASSWORD) { $env:RDP_PASSWORD = $sEnv.RDP_PASSWORD }
      if (-not $env:GITHUB_TOKEN -and $sEnv.GITHUB_TOKEN) { $env:GITHUB_TOKEN = $sEnv.GITHUB_TOKEN }
      if (-not $env:GITHUB_REPOSITORY -and $sEnv.GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY = $sEnv.GITHUB_REPOSITORY }
    } catch {
      Log "Could not read C:\Sailuo\tools\session-env.json: $($_.Exception.Message)"
    }
  }

  $ghToken = $env:GITHUB_TOKEN
  $ghRepo = $env:GITHUB_REPOSITORY
  if (-not $ghToken -or -not $ghRepo) {
    Fail-Sailuo 'Save State cannot run: GITHUB_TOKEN or GITHUB_REPOSITORY is missing. Sign in again or repair the session configuration.' 'configuration'
  }

  $u = if ($env:RDP_USER) { $env:RDP_USER.Trim() } else { $cfg.rdp_user }
  $p = if ($env:RDP_PASSWORD) { $env:RDP_PASSWORD.Trim() } else { '' }
  $secretKey = if ($p.Length -ge 4) { "Sailuo-Persist-$u-$p" } else { "Sailuo-Persist-$ghRepo" }

  Start-SailuoOperation -Operation 'save' -OperationId $OperationId -Writer 'persist-state/3' `
    -Message ("Preparing a {0} snapshot for user '{1}'." -f $(if ($Checkpoint) { 'checkpoint' } else { 'final' }), $u) | Out-Null

  $profileDirs = @(Get-AllUserProfileDirs $u)
  if ($profileDirs.Count -eq 0) {
    Fail-Sailuo "Save State cannot run: no profile folder was found for user '$u'." 'profile'
  }
  Log "Preparing session state storage for user '$u' (mode=$(if ($Checkpoint) { 'Checkpoint Live' } else { 'Final Shutdown' }))..."
  Log "  Candidate profile folders for user '$u': $($profileDirs -join ', ')"

  Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

  # At session end (not a live checkpoint), close browsers gracefully so SQLite
  # flushes the WAL into Cookies & Login Data.
  if (-not $Checkpoint) {
    foreach ($brProc in @('chrome', 'msedge', 'brave', 'firefox')) {
      try {
        Get-Process -Name $brProc -ErrorAction SilentlyContinue | ForEach-Object { $_.CloseMainWindow() | Out-Null }
      } catch {}
    }
    Start-Sleep -Milliseconds 1200
  }

  # 1. C:\Persist (dedicated anti-reset folder). System metadata is excluded so
  # a restore can never resurrect an old lock/result file.
  Copy-SafeFolder 'C:\Persist' (Join-Path $stageDir 'Persist') 1200

  # Save the active wallpaper to Persist\Config so the next session reuses it.
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

  # 2. Standard user folders from the authoritative profile only.
  foreach ($profDir in $profileDirs) {
    foreach ($sub in @('Desktop', 'Documents', 'Downloads', 'Pictures', 'Videos', 'Music')) {
      $s = Join-Path $profDir $sub
      if (Test-Path -LiteralPath $s) {
        Copy-SafeFolder $s (Join-Path $stageDir "User\$sub") 2500
      }
    }
  }

  # 3. Browser sessions + DPAPI master keys.
  foreach ($profDir in $profileDirs) {
    Copy-ChromiumSession 'Chrome' (Join-Path $profDir 'AppData\Local\Google\Chrome\User Data')
    Copy-ChromiumSession 'Edge'   (Join-Path $profDir 'AppData\Local\Microsoft\Edge\User Data')
    Copy-ChromiumSession 'Brave'  (Join-Path $profDir 'AppData\Local\BraveSoftware\Brave-Browser\User Data')

    $ffProfiles = Join-Path $profDir 'AppData\Roaming\Mozilla\Firefox'
    if (Test-Path -LiteralPath $ffProfiles) {
      Copy-SafeFolder $ffProfiles (Join-Path $stageDir 'Browsers\Firefox') 200
    }

    foreach ($dpapiRel in @(
        'AppData\Roaming\Microsoft\Protect',
        'AppData\Roaming\Microsoft\Credentials',
        'AppData\Local\Microsoft\Credentials',
        'AppData\Roaming\Microsoft\Crypto')) {
      $dpSrc = Join-Path $profDir $dpapiRel
      if (Test-Path -LiteralPath $dpSrc) {
        Copy-TreeUnlocked $dpSrc (Join-Path $stageDir "DPAPI\$dpapiRel")
      }
    }
  }

  # 4. Validate staging before creating an archive that could replace a good one.
  $stagedFiles = @(Get-ChildItem -Path $stageDir -Recurse -File -Force -ErrorAction SilentlyContinue)
  $fileCount = $stagedFiles.Count
  if ($fileCount -eq 0) {
    Skip-Sailuo 'No files were found in C:\Persist or the user profile; the previous snapshot was not changed.' 'no-data'
  }
  $totalBytes = ($stagedFiles | Measure-Object -Property Length -Sum).Sum
  if (-not $totalBytes) { $totalBytes = 0 }
  $latestTicks = ($stagedFiles | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).LastWriteTimeUtc.Ticks
  $stateSig = "$fileCount|$totalBytes|$latestTicks"
  $sigFile = 'C:\Sailuo\tools\last-checkpoint-sig.txt'

  $copyFailures = @($global:SailuoCopyFailures)
  $skippedFolders = @($global:SailuoSkippedFolders)
  $largeFailures = @($copyFailures | Where-Object { $_.MB -ge 32 })
  $copyFailureTotalMb = 0.0
  if ($copyFailures.Count -gt 0) {
    $copyFailureTotalMb = [math]::Round((($copyFailures | Measure-Object -Property MB -Sum).Sum), 2)
    Log "Warning: $($copyFailures.Count) file(s) could not be read and were left out ($copyFailureTotalMb MB)."
    $copyFailures | Sort-Object MB -Descending | Select-Object -First 10 | ForEach-Object {
      Log "  - $($_.Path) ($($_.MB) MB)"
    }
  }

  if ($skippedFolders.Count -gt 0 -and -not $Force) {
    Log 'These folders are too large to back up and were left out:'
    $skippedFolders | ForEach-Object { Log "  - $_" }
    Log 'Keeping the previous cloud snapshot instead of uploading an incomplete one.'
    Warn-Sailuo 'Save State kept the previous snapshot because some folders exceed the configured size limit.' 'folders-over-limit' @{
      user = $u
      skipped_folders = $skippedFolders
      last_warning = 'Some folders exceed the configured size limit, so the previous verified snapshot was kept.'
    }
  }

  if ($largeFailures.Count -gt 0 -and -not $Force) {
    Log 'Important files could not be read; keeping the previous cloud snapshot.'
    Warn-Sailuo 'Save State kept the previous snapshot because important files were locked or unreadable.' 'large-copy-failures' @{
      user = $u
      copy_failures = @($largeFailures | ForEach-Object { $_.Path })
      last_warning = 'Important files were locked or unreadable, so the previous verified snapshot was kept.'
    }
  }

  # Unchanged checkpoints must not claim a new upload, and must not touch
  # last_saved_utc. Only report the previous verified snapshot as current.
  $prevMeta = Get-SailuoCloudMeta
  $prevSaved = Get-SailuoFirstValue $prevMeta 'last_saved_utc' ''
  $prevAsset = Get-SailuoFirstValue $prevMeta 'asset_name' ''
  if ($Checkpoint -and -not $Force -and (Test-Path $sigFile) -and $prevSaved -and $prevAsset) {
    $prevSig = (Get-Content $sigFile -Raw -ErrorAction SilentlyContinue).Trim()
    if ($prevSig -eq $stateSig) {
      $now = Get-SailuoUtcNowText
      Skip-Sailuo 'No data changes since the last verified checkpoint; the previous snapshot remains current.' 'unchanged' @{
        last_check_utc = $now
        checkpoint_file_count = $fileCount
        checkpoint_size_mb = [math]::Round($totalBytes / 1MB, 2)
        user = $u
        asset_name = $prevAsset
      }
    }
  }

  # A manifest inside the encrypted archive lets restore reject a truncated or
  # structurally wrong archive before touching live data.
  $manifestPath = Join-Path $stageDir '_sailuo-manifest.json'
  $manifest = [ordered]@{
    format          = 'sailuo-state-manifest/1'
    created_utc     = Get-SailuoUtcNowText
    user            = $u
    profile         = ($profileDirs -join ';')
    file_count      = $fileCount
    total_bytes     = [long]$totalBytes
    signature       = $stateSig
    copy_failures   = @($copyFailures | ForEach-Object { $_.Path })
    skipped_folders = @($skippedFolders)
  }
  Write-SailuoJson $manifestPath $manifest 8
  $archiveFileCount = $fileCount + 1

  Log "Compressing $archiveFileCount state files..."
  $sevenZip = Get-SailuoSevenZipPath
  $format = 'zip'
  $archivePath = Join-Path $workDir 'sailuo-state.zip'
  if ($sevenZip) {
    $format = '7z'
    $archivePath = Join-Path $workDir 'sailuo-state.7z'
    $archiveOutput = & $sevenZip a -t7z -mx=3 -y $archivePath "$stageDir\*" 2>&1
    if ($LASTEXITCODE -ne 0) {
      Fail-Sailuo "Archive creation failed (7-Zip exit $LASTEXITCODE): $(Log-Tail (($archiveOutput | Out-String)) 2)" 'compress'
    }
  } else {
    try {
      Compress-Archive -Path "$stageDir\*" -DestinationPath $archivePath -CompressionLevel Fastest -Force -ErrorAction Stop
    } catch {
      Fail-Sailuo "Archive creation failed: $($_.Exception.Message)" 'compress'
    }
  }
  if (-not (Test-Path $archivePath) -or (Get-Item $archivePath).Length -lt 1) {
    Fail-Sailuo 'Archive creation produced no usable file.' 'compress'
  }

  $archiveTest = Test-SailuoArchive -Path $archivePath -Format $format
  if (-not $archiveTest.ok) {
    Fail-Sailuo "The new archive failed integrity verification: $($archiveTest.error)" 'archive-verify'
  }
  $archiveSha = Get-SailuoFileSha256 $archivePath
  $zipMB = [math]::Round((Get-Item $archivePath).Length / 1MB, 2)
  Log "State archive created and verified ($zipMB MB, $archiveFileCount files). Encrypting with AES-256..."

  if ($zipMB -gt 5400) {
    Fail-Sailuo "The archive is $zipMB MB, above the 5400 MB multi-part limit. The previous snapshot was kept." 'size-limit'
  }

  # Never replace a healthy snapshot with a suspiciously incomplete one.
  $guardFile = 'C:\Persist\System\shrink-guard.txt'
  $guardState = ''
  if (Test-Path $guardFile) { $guardState = (Get-Content $guardFile -Raw -ErrorAction SilentlyContinue).Trim() }
  $prevMb = 0.0
  $prevCount = 0
  try {
    $p = Get-SailuoFirstValue $prevMeta 'size_mb' 0
    if ($p) { $prevMb = [double]$p }
    $c = Get-SailuoFirstValue $prevMeta 'file_count' 0
    if ($c) { $prevCount = [int]$c }
  } catch {}
  $countCollapsed = ($prevCount -gt 20 -and $fileCount -lt [int]($prevCount * 0.5))
  $isSuspicious = ($largeFailures.Count -gt 0) -or ($prevMb -gt 20 -and $zipMB -lt ($prevMb * 0.5)) -or $countCollapsed
  $suspiciousAccepted = $false
  if (-not $Force -and $isSuspicious -and $prevSaved) {
    if ($guardState -notmatch '^suspicious') {
      Set-Content -Path $guardFile -Value ("suspicious " + [DateTime]::UtcNow.ToString('o')) -Encoding ASCII -Force
      $reason = if ($prevMb -gt 0) { "$zipMB MB / $fileCount files vs previous $prevMb MB / $prevCount files" } else { 'large or unreadable files were omitted' }
      Warn-Sailuo "Save State kept the previous snapshot because the new archive looked incomplete ($reason)." 'suspicious-shrink' @{
        user = $u
        staged_file_count = $fileCount
        staged_size_mb = $zipMB
        last_warning = "The new archive looked incomplete ($reason), so the previous verified snapshot was kept."
      }
    }
    Log "Archive is still suspicious ($zipMB MB / $fileCount files) - treating it as an intentional change after two consistent checkpoints."
    Remove-Item $guardFile -Force -ErrorAction SilentlyContinue
    $suspiciousAccepted = $true
  }

  $encPath = Join-Path $workDir 'sailuo-state.bin'
  try {
    $salt = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($salt)
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($secretKey, $salt, 20000)
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256
    $aes.Key = $kdf.GetBytes(32)
    $aes.IV = $kdf.GetBytes(16)
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7

    $fsOut = [System.IO.File]::Open($encPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
      $header = [System.Text.Encoding]::ASCII.GetBytes('XYST01')
      $fsOut.Write($header, 0, $header.Length)
      $fsOut.Write($salt, 0, $salt.Length)
      $cs = New-Object System.Security.Cryptography.CryptoStream($fsOut, $aes.CreateEncryptor(), [System.Security.Cryptography.CryptoStreamMode]::Write)
      try {
        $fsIn = [System.IO.File]::OpenRead($archivePath)
        try { $fsIn.CopyTo($cs) } finally { $fsIn.Dispose() }
        $cs.FlushFinalBlock()
      } finally { $cs.Dispose() }
    } finally { $fsOut.Dispose() }
    $aes.Dispose()
  } catch {
    Fail-Sailuo "Encryption failed: $($_.Exception.Message)" 'encrypt'
  }
  if (-not (Test-Path $encPath) -or (Get-Item $encPath).Length -le 22) {
    Fail-Sailuo 'Encryption produced no usable file.' 'encrypt'
  }
  $encSha = Get-SailuoFileSha256 $encPath
  $encLen = (Get-Item $encPath).Length
  $encMB = [math]::Round($encLen / 1MB, 2)
  Log "Encrypted archive ready ($encMB MB, SHA256 $($encSha.Substring(0, 12))...)."

  # ------------------------------------------------------------------
  #  GitHub release upload with verification and previous-snapshot safety
  # ------------------------------------------------------------------
  $tag = $ReleaseTag
  $hdrs = @{
    'Authorization' = "Bearer $ghToken"
    'Accept'        = 'application/vnd.github+json'
    'User-Agent'    = 'Sailuo-State'
  }
  $relResult = Get-GitHubRelease -Repo $ghRepo -Tag $tag -Headers $hdrs
  $rel = $null
  if ($relResult.ok) {
    $rel = $relResult.data
  } elseif ($relResult.status -eq 404) {
    $body = @{
      tag_name   = $tag
      name       = 'Sailuo Persistent State (Auto-Save)'
      body       = 'AES-256 encrypted archive for saving files between RDP sessions.'
      draft      = $false
      prerelease = $true
    }
    $createResult = Invoke-GitHubRequest -Method 'POST' -Uri "https://api.github.com/repos/$ghRepo/releases" -Headers $hdrs -Body $body -TimeoutSec 30
    if (-not $createResult.ok) {
      # A concurrent run may have created it between GET and POST.
      $retry = Get-GitHubRelease -Repo $ghRepo -Tag $tag -Headers $hdrs
      if ($retry.ok) { $rel = $retry.data } else {
        Fail-Sailuo "Could not create or read release '$tag': $($createResult.error)" 'release'
      }
    } else {
      $rel = $createResult.data
    }
  } else {
    Fail-Sailuo "Could not read release '$tag' (HTTP $($relResult.status)): $($relResult.error)" 'release'
  }

  $formatSuffix = if ($format -eq '7z') { '.7z.enc' } else { '.zip.enc' }
  $baseAssetName = "$AssetBaseName$formatSuffix"
  $stamp = [DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff')
  $oldRenames = New-Object System.Collections.ArrayList
  $uploadedAssets = New-Object System.Collections.ArrayList

  # GitHub asset names are unique. Rename the current canonical asset/parts so
  # the new set can use the canonical names; if any later step fails they are
  # renamed back. The previous snapshot is never deleted before verification.
  $currentAssets = @()
  try { $currentAssets = @($rel.assets) } catch {}
  $canonicalAssets = @($currentAssets | Where-Object {
      $_.name -eq $baseAssetName -or $_.name -match ('^' + [regex]::Escape($baseAssetName) + '\.part\d+$')
    })
  foreach ($asset in $canonicalAssets) {
    $partSuffix = [string]$asset.name
    if ($partSuffix.StartsWith($baseAssetName, [System.StringComparison]::Ordinal)) {
      $partSuffix = $partSuffix.Substring($baseAssetName.Length)
    } else {
      $partSuffix = ''
    }
    $oldName = "$AssetBaseName-old-$stamp$formatSuffix$partSuffix"
    $rename = Invoke-GitHubRequest -Method 'PATCH' -Uri "https://api.github.com/repos/$ghRepo/releases/assets/$($asset.id)" -Headers $hdrs -Body @{ name = $oldName } -TimeoutSec 30
    if (-not $rename.ok) {
      foreach ($done in @($oldRenames)) {
        try {
          Invoke-GitHubRequest -Method 'PATCH' -Uri "https://api.github.com/repos/$ghRepo/releases/assets/$($done.id)" -Headers $hdrs -Body @{ name = $done.original } -TimeoutSec 30 | Out-Null
        } catch {}
      }
      Fail-Sailuo "Could not preserve the previous snapshot asset '$($asset.name)': $($rename.error). Nothing was uploaded." 'asset-rename'
    }
    [void]$oldRenames.Add(@{ id = $asset.id; original = $asset.name; renamed = $oldName })
    Log "  Previous snapshot asset kept as $oldName until the new upload is verified."
  }

  $upHdrs = @{
    'Authorization' = "Bearer $ghToken"
    'Content-Type'  = 'application/octet-stream'
    'User-Agent'    = 'Sailuo-State'
    'Accept'        = 'application/vnd.github+json'
  }
  $uploadBase = ($rel.upload_url -replace '\{\?name,label\}$', '')
  $chunkMaxBytes = 1850L * 1024L * 1024L
  $expectedParts = New-Object System.Collections.ArrayList

  try {
    if ($encLen -le $chunkMaxBytes) {
      $uploadUrl = $uploadBase + '?name=' + [uri]::EscapeDataString($baseAssetName)
      $uploadResult = Invoke-GitHubRequest -Method 'POST' -Uri $uploadUrl -Headers $upHdrs -InFile $encPath -TimeoutSec 900
      if (-not $uploadResult.ok) { throw "Asset upload failed: $($uploadResult.error)" }
      $asset = $uploadResult.data
      if (-not $asset -or -not $asset.id) { throw 'GitHub did not return the uploaded asset.' }
      [void]$uploadedAssets.Add(@{ id = $asset.id; name = $asset.name; size = $encLen; sha256 = $encSha })
      [void]$expectedParts.Add(@{ name = $baseAssetName; size = $encLen; sha256 = $encSha })
    } else {
      $fsRead = [System.IO.File]::OpenRead($encPath)
      $partIdx = 1
      $buffer = New-Object byte[] (16 * 1024 * 1024)
      try {
        while ($fsRead.Position -lt $fsRead.Length) {
          $partName = '{0}.part{1:D2}' -f $baseAssetName, $partIdx
          $partPath = Join-Path $workDir $partName
          $fsPart = [System.IO.File]::Create($partPath)
          $written = 0L
          try {
            while ($written -lt $chunkMaxBytes -and $fsRead.Position -lt $fsRead.Length) {
              $toRead = [int][Math]::Min([long]$buffer.Length, ($chunkMaxBytes - $written))
              $n = $fsRead.Read($buffer, 0, $toRead)
              if ($n -le 0) { break }
              $fsPart.Write($buffer, 0, $n)
              $written += $n
            }
          } finally { $fsPart.Dispose() }
          $partSha = Get-SailuoFileSha256 $partPath
          $uploadUrl = $uploadBase + '?name=' + [uri]::EscapeDataString($partName)
          $uploadResult = Invoke-GitHubRequest -Method 'POST' -Uri $uploadUrl -Headers $upHdrs -InFile $partPath -TimeoutSec 900
          if (-not $uploadResult.ok) { throw "Multi-part upload failed for $partName`: $($uploadResult.error)" }
          $asset = $uploadResult.data
          if (-not $asset -or -not $asset.id) { throw "GitHub did not return the uploaded asset for $partName." }
          [void]$uploadedAssets.Add(@{ id = $asset.id; name = $partName; size = $written; sha256 = $partSha })
          [void]$expectedParts.Add(@{ name = $partName; size = $written; sha256 = $partSha })
          Remove-Item $partPath -Force -ErrorAction SilentlyContinue
          Log "  Uploaded multi-part chunk $partName ($([math]::Round($written / 1MB, 1)) MB)."
          $partIdx++
        }
      } finally { $fsRead.Dispose() }
    }

    # Verify through a fresh API read: names, sizes and (when GitHub exposes it)
    # the sha256 digest must match the local bytes.
    $verified = $false
    $verifiedAssets = @()
    for ($attempt = 1; $attempt -le 10; $attempt++) {
      $freshAssets = @(Get-GitHubAssetList -Repo $ghRepo -Tag $tag -Headers $hdrs)
      $allMatch = $true
      $matched = @()
      foreach ($expected in @($expectedParts)) {
        $actual = $freshAssets | Where-Object { $_.name -eq $expected.name } | Select-Object -First 1
        if (-not $actual) { $allMatch = $false; break }
        if ([long]$actual.size -ne [long]$expected.size) { $allMatch = $false; break }
        if ($actual.digest -and ([string]$actual.digest).StartsWith('sha256:')) {
          $remoteSha = ([string]$actual.digest).Substring(7).ToLowerInvariant()
          if ($remoteSha -ne [string]$expected.sha256) { $allMatch = $false; break }
        }
        $matched += $actual
      }
      if ($allMatch -and $matched.Count -eq @($expectedParts).Count) {
        $verified = $true
        $verifiedAssets = $matched
        break
      }
      Start-Sleep -Seconds 2
    }
    if (-not $verified) { throw 'GitHub did not confirm the uploaded asset(s) with matching sizes and digests.' }

    $primaryAsset = $verifiedAssets | Where-Object { $_.name -eq $baseAssetName } | Select-Object -First 1
    if (-not $primaryAsset) { $primaryAsset = $verifiedAssets | Select-Object -First 1 }
    $assetIds = @($verifiedAssets | ForEach-Object { $_.id })
    $assetNames = @($verifiedAssets | ForEach-Object { $_.name })
    $now = Get-SailuoUtcNowText
    $finalStatus = if ($copyFailures.Count -gt 0 -or $suspiciousAccepted) { 'warning' } else { 'success' }
    $warningText = ''
    if ($copyFailures.Count -gt 0) {
      $warningText = "$($copyFailures.Count) file(s) could not be read while staging; the snapshot is otherwise verified."
    }
    if ($suspiciousAccepted) {
      $warningText = (($warningText + ' ').Trim() + 'The archive was much smaller than the previous one and was accepted after two consistent checkpoints.')
    }

    $metaPairs = @{
      last_saved_utc       = $now
      last_check_utc       = $now
      last_attempt_utc     = $now
      asset_name           = $baseAssetName
      asset_id             = $primaryAsset.id
      asset_ids            = $assetIds
      asset_names          = $assetNames
      asset_size_bytes     = $encLen
      asset_sha256         = $encSha
      asset_created_utc    = [string]$primaryAsset.created_at
      asset_digest         = [string]$primaryAsset.digest
      archive_format       = $format
      archive_sha256       = $archiveSha
      file_count           = $fileCount
      archive_file_count   = $archiveFileCount
      size_mb              = $zipMB
      source_size_mb       = [math]::Round($totalBytes / 1MB, 2)
      user                 = $u
      profile              = ($profileDirs -join ';')
      release_tag          = $tag
      snapshot_signature   = $stateSig
      copy_failures_count  = $copyFailures.Count
      skipped_folders      = $skippedFolders
      multipart            = ($assetIds.Count -gt 1)
      last_warning         = $warningText
    }
    try {
      Set-SailuoCloudMeta $metaPairs | Out-Null
    } catch {
      # The new snapshot is uploaded and verified, but the dashboard relies on
      # metadata. Report a warning and keep the old assets so nothing is lost.
      Warn-Sailuo "The new snapshot uploaded and verified, but local metadata could not be updated: $($_.Exception.Message)" 'metadata-write' @{
        asset_name = $baseAssetName
        file_count = $fileCount
        size_mb = $zipMB
        user = $u
        last_saved_utc = $now
        last_check_utc = $now
        last_warning = "The snapshot uploaded and verified, but local metadata could not be updated."
      }
    }
    New-Item -ItemType Directory -Path 'C:\Sailuo\tools' -Force -ErrorAction SilentlyContinue | Out-Null
    Set-Content -Path $sigFile -Value $stateSig -Encoding ASCII -Force
    Remove-Item $guardFile -Force -ErrorAction SilentlyContinue

    # Only now is it safe to drop the previous snapshot.
    foreach ($oldId in @($oldRenames | ForEach-Object { $_.id })) {
      try {
        Invoke-GitHubRequest -Method 'DELETE' -Uri "https://api.github.com/repos/$ghRepo/releases/assets/$oldId" -Headers $hdrs -TimeoutSec 30 | Out-Null
      } catch {
        Log "  Warning: could not remove the previous asset id $oldId yet: $($_.Exception.Message)"
      }
    }
    # Prune older '-old-' copies as well; they are superseded by the verified set.
    $freshAssets = @(Get-GitHubAssetList -Repo $ghRepo -Tag $tag -Headers $hdrs)
    foreach ($stale in @($freshAssets | Where-Object { $_.name -like "$AssetBaseName-old-*" })) {
      try {
        Invoke-GitHubRequest -Method 'DELETE' -Uri "https://api.github.com/repos/$ghRepo/releases/assets/$($stale.id)" -Headers $hdrs -TimeoutSec 30 | Out-Null
      } catch {}
    }

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

    Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue

    if ($finalStatus -eq 'warning') {
      Warn-Sailuo "Snapshot uploaded and verified, but with warnings: $warningText" 'completed-with-warning' @{
        file_count = $fileCount
        size_mb = $zipMB
        user = $u
        asset_name = $baseAssetName
        last_saved_utc = $now
        last_check_utc = $now
        asset_id = $primaryAsset.id
        asset_sha256 = $encSha
      }
    }
    Complete-SailuoOperation -Code 0 -Status 'success' `
      -Message "State saved and verified on release '$tag' ($baseAssetName, $zipMB MB, $fileCount files)." `
      -Meta $metaPairs -Extra @{
        asset_name = $baseAssetName
        asset_id = $primaryAsset.id
        asset_size_bytes = $encLen
        asset_sha256 = $encSha
        file_count = $fileCount
        size_mb = $zipMB
        release_tag = $tag
        verified = $true
      }
  } catch {
    $reason = $_.Exception.Message
    Log "State upload failed: $reason"
    # Remove any partially uploaded new assets, then put the old snapshot back
    # under its canonical name. The previous snapshot is never destroyed.
    foreach ($uploaded in @($uploadedAssets)) {
      try {
        Invoke-GitHubRequest -Method 'DELETE' -Uri "https://api.github.com/repos/$ghRepo/releases/assets/$($uploaded.id)" -Headers $hdrs -TimeoutSec 30 | Out-Null
      } catch {}
    }
    foreach ($done in @($oldRenames)) {
      try {
        Invoke-GitHubRequest -Method 'PATCH' -Uri "https://api.github.com/repos/$ghRepo/releases/assets/$($done.id)" -Headers $hdrs -Body @{ name = $done.original } -TimeoutSec 30 | Out-Null
        Log "  Previous snapshot restored to canonical name $($done.original)."
      } catch {
        Log "  CRITICAL: the previous snapshot is still safe under $($done.renamed) but could not be renamed back: $($_.Exception.Message)"
      }
    }
    Log "Diagnostic files kept in $workDir (encrypted archive: $encPath)."
    Fail-Sailuo "Save State failed; the previous verified snapshot was kept. $reason" 'upload' @{
      work_dir = $workDir
      encrypted_archive = $encPath
      previous_snapshot_preserved = $true
    }
  }
} catch {
  $message = "Unexpected Save State failure: $($_.Exception.Message)"
  Log $message
  Fail-Sailuo $message 'unexpected'
}
