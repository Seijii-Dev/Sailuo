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
#
#  Exit codes: 0 success, 1 failure, 2 skipped/nothing to save,
#              3 uploaded with a documented warning.

param(
  [string]$ProfileDir,
  [Parameter(Mandatory = $true)][string]$Name,
  [string]$Repo,
  [string]$Token,
  [string]$ReleaseTag = 'sailuo-state-latest',
  [switch]$NoUpload
)

$SailuoTag = 'Sailuo:snapshot'
$script:SailuoLogFile = 'C:\Persist\System\save-snapshot.log'
. "$PSScriptRoot/lib-common.ps1"

$ErrorActionPreference = 'Continue'
$scriptDir = $PSScriptRoot
$operationStartedUtc = Get-SailuoUtcNowText

$workDir  = 'C:\Sailuo\state-archive'
$stageDir = Join-Path $workDir 'stage'
$sigFile  = 'C:\Persist\System\last-snapshot.json'

function Write-SnapshotResult {
  param(
    [int]$Code,
    [string]$Status,
    [string]$Message,
    [string]$ErrorText = '',
    [hashtable]$Extra = @{}
  )
  $result = [ordered]@{
    schema        = 'sailuo-snapshot-result/1'
    status        = $Status
    name          = $Name
    message       = $Message
    error         = $ErrorText
    exit_code     = $Code
    started_utc   = $operationStartedUtc
    finished_utc  = Get-SailuoUtcNowText
    pid           = $PID
  }
  foreach ($key in $Extra.Keys) { $result[$key] = $Extra[$key] }
  try { Write-SailuoJson $sigFile $result 10 } catch {}
  Log $Message
  exit $Code
}

function Fail-Snapshot([string]$Message, [string]$Stage, [hashtable]$Extra = @{}) {
  $details = @{ stage = $Stage }
  foreach ($key in $Extra.Keys) { $details[$key] = $Extra[$key] }
  Write-SnapshotResult -Code 1 -Status 'failure' -Message $Message -ErrorText $Message -Extra $details
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
    return @{ ok = $true; status = 200; data = $data; error = '' }
  } catch {
    $status = 0
    try { $status = [int]$_.Exception.Response.StatusCode } catch {}
    return @{ ok = $false; status = $status; data = $null; error = $_.Exception.Message }
  }
}

$safeName = ($Name -replace '\.(7z|zip)\.enc$', '')
if (-not $safeName -or $safeName -notmatch '^[A-Za-z0-9._-]+$') {
  Fail-Snapshot "Snapshot name '$Name' is not a safe asset name (use letters, digits, '.', '_' and '-')." 'name'
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
  } elseif ($sEnv.GITHUB_TOKEN) {
    $Token = $sEnv.GITHUB_TOKEN
  }
}
$secretKey = if ($p.Length -ge 4) { "Sailuo-Persist-$u-$p" } else { "Sailuo-Persist-$Repo" }

# --- work dirs -------------------------------------------------------------
Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
New-Item -ItemType Directory -Path 'C:\Persist\System' -Force -ErrorAction SilentlyContinue | Out-Null

$global:SailuoCopyFailures = New-Object System.Collections.ArrayList
$global:SailuoExcludePaths = New-Object System.Collections.ArrayList
[void]$global:SailuoExcludePaths.Add('C:\Persist\System')
[void]$global:SailuoExcludePaths.Add($workDir)
[void]$global:SailuoExcludePaths.Add('C:\Sailuo\restore-work')
[void]$global:SailuoExcludePaths.Add('C:\Sailuo\state-work')

$profileDirs = if ($ProfileDir) { @($ProfileDir) } else { @(Get-AllUserProfileDirs $u) }
foreach ($dir in $profileDirs) {
  if (-not (Test-Path -LiteralPath $dir)) { Fail-Snapshot "Profile folder '$dir' does not exist." 'profile' }
}
Log "Profiles: $($profileDirs -join ', ')"

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

function Copy-SafeFolder([string]$Src, [string]$Dst, [int]$MaxMB = 900) {
  if (-not (Test-Path -LiteralPath $Src)) { return }
  if (Test-SailuoPathExcluded $Src) { return }
  $sz = Get-DirSizeMB $Src
  if ($sz -le 0) { return }
  if ($sz -gt $MaxMB) {
    Log "  Skip $Src ($sz MB > limit $MaxMB MB)"
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
      if (Test-Path -LiteralPath $fSrc) { Copy-FileUnlocked $fSrc (Join-Path $profDst $rel) | Out-Null }
    }
    foreach ($subDir in @('Local Storage\leveldb', 'Session Storage', 'Extension State', 'Sync Data\LevelDB', 'Local Extension Settings', 'IndexedDB')) {
      $dSrc = Join-Path $profSrc $subDir
      if ((Test-Path -LiteralPath $dSrc) -and ((Get-DirSizeMB $dSrc) -le 120)) {
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
    if (Test-Path $s) { Copy-SafeFolder $s (Join-Path $stageDir "User\$sub") 2500 }
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
if ($fileCount -eq 0) {
  Write-SnapshotResult -Code 2 -Status 'skipped' -Message 'Nothing to save; no new named snapshot was created.' -Extra @{ reason = 'no-data' }
}
$totalBytes = ($allStaged | Measure-Object -Property Length -Sum).Sum
if (-not $totalBytes) { $totalBytes = 0 }
$totalMB = [math]::Round($totalBytes / 1MB, 2)

$copyFailures = @($global:SailuoCopyFailures)
$largeFailures = @($copyFailures | Where-Object { $_.MB -ge 32 })
if ($largeFailures.Count -gt 0) {
  Fail-Snapshot "Refusing to create a named snapshot: $($largeFailures.Count) important file(s) could not be read." 'copy' @{
    files = @($largeFailures | ForEach-Object { $_.Path })
  }
}
$warningText = ''
if ($copyFailures.Count -gt 0) {
  $warningText = "$($copyFailures.Count) small file(s) could not be read and were left out."
  Log "Warning: $warningText"
}

$manifestPath = Join-Path $stageDir '_sailuo-manifest.json'
$manifest = [ordered]@{
  format          = 'sailuo-state-manifest/1'
  created_utc     = Get-SailuoUtcNowText
  user            = $u
  profile         = ($profileDirs -join ';')
  file_count      = $fileCount
  total_bytes     = [long]$totalBytes
  signature       = "$fileCount|$totalBytes|$(Get-SailuoUtcNowText)"
  copy_failures   = @($copyFailures | ForEach-Object { $_.Path })
  skipped_folders = @()
  named_snapshot  = $safeName
}
Write-SailuoJson $manifestPath $manifest 8
$archiveFileCount = $fileCount + 1

Log "Compressing $archiveFileCount snapshot files ($totalMB MB)..."
$sevenZip = Get-SailuoSevenZipPath
$format = 'zip'
$archivePath = Join-Path $workDir 'snapshot.zip'
if ($sevenZip) {
  $format = '7z'
  $archivePath = Join-Path $workDir 'snapshot.7z'
  $archiveOutput = & $sevenZip a -t7z -mx=3 -y $archivePath "$stageDir\*" 2>&1
  if ($LASTEXITCODE -ne 0) {
    Fail-Snapshot "Archive creation failed (7-Zip exit $LASTEXITCODE): $(Log-Tail (($archiveOutput | Out-String)) 2)" 'compress'
  }
} else {
  try {
    Compress-Archive -Path "$stageDir\*" -DestinationPath $archivePath -CompressionLevel Fastest -Force -ErrorAction Stop
  } catch {
    Fail-Snapshot "Archive creation failed: $($_.Exception.Message)" 'compress'
  }
}
if (-not (Test-Path $archivePath) -or (Get-Item $archivePath).Length -lt 1) {
  Fail-Snapshot 'Archive creation produced no usable file.' 'compress'
}
$archiveTest = Test-SailuoArchive -Path $archivePath -Format $format
if (-not $archiveTest.ok) {
  Fail-Snapshot "The new snapshot archive failed integrity verification: $($archiveTest.error)" 'archive-verify'
}
$archiveSha = Get-SailuoFileSha256 $archivePath
$zipMB = [math]::Round((Get-Item $archivePath).Length / 1MB, 2)
if ($zipMB -gt 5400) {
  Fail-Snapshot "The named snapshot is $zipMB MB, above the 5400 MB multi-part limit." 'size-limit'
}
Log "Snapshot archive created and verified ($zipMB MB). Encrypting with AES-256..."

$encPath = Join-Path $workDir "$safeName.$format.enc"
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
  Fail-Snapshot "Encryption failed: $($_.Exception.Message)" 'encrypt'
}
if (-not (Test-Path $encPath) -or (Get-Item $encPath).Length -le 22) {
  Fail-Snapshot 'Encryption produced no usable file.' 'encrypt'
}
$encLen = (Get-Item $encPath).Length
$encMB = [math]::Round($encLen / 1MB, 2)
$encSha = Get-SailuoFileSha256 $encPath
$baseAssetName = "$safeName.$format.enc"
Log "Encrypted snapshot ready: $encPath ($encMB MB, SHA256 $($encSha.Substring(0, 12))...)."

if ($NoUpload) {
  $resultExtra = @{
    asset_name = $baseAssetName
    asset_sha256 = $encSha
    file_count = $fileCount
    size_mb = $zipMB
    encrypted_path = $encPath
    warning = $warningText
  }
  if ($warningText) {
    Write-SnapshotResult -Code 3 -Status 'warning' -Message "Named snapshot created locally with a warning: $warningText" -Extra $resultExtra
  }
  Write-SnapshotResult -Code 0 -Status 'success' -Message "Named snapshot created locally: $encPath" -Extra $resultExtra
}

if (-not $Token) {
  Fail-Snapshot 'Upload cannot run: GITHUB_TOKEN is missing. The encrypted snapshot is still on disk.' 'configuration' @{ encrypted_path = $encPath }
}

# --- upload ----------------------------------------------------------------
$hdrs = @{
  'Authorization' = "Bearer $Token"
  'Accept'        = 'application/vnd.github+json'
  'User-Agent'    = 'Sailuo-Snapshot'
}
$relResult = Invoke-GitHubRequest -Method 'GET' -Uri "https://api.github.com/repos/$Repo/releases/tags/$ReleaseTag" -Headers $hdrs -TimeoutSec 30
if (-not $relResult.ok) {
  Fail-Snapshot "Could not read release '$ReleaseTag' (HTTP $($relResult.status)): $($relResult.error)" 'release'
}
$rel = $relResult.data
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff')
$oldRenames = New-Object System.Collections.ArrayList
$uploadedAssets = New-Object System.Collections.ArrayList
$expectedParts = New-Object System.Collections.ArrayList

$currentAssets = @($rel.assets)
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
  $oldName = "$safeName-old-$stamp.$format.enc$partSuffix"
  $rename = Invoke-GitHubRequest -Method 'PATCH' -Uri "https://api.github.com/repos/$Repo/releases/assets/$($asset.id)" -Headers $hdrs -Body @{ name = $oldName } -TimeoutSec 30
  if (-not $rename.ok) {
    foreach ($done in @($oldRenames)) {
      try {
        Invoke-GitHubRequest -Method 'PATCH' -Uri "https://api.github.com/repos/$Repo/releases/assets/$($done.id)" -Headers $hdrs -Body @{ name = $done.original } -TimeoutSec 30 | Out-Null
      } catch {}
    }
    Fail-Snapshot "Could not preserve the existing named asset '$($asset.name)': $($rename.error). Nothing was uploaded." 'asset-rename'
  }
  [void]$oldRenames.Add(@{ id = $asset.id; original = $asset.name; renamed = $oldName })
  Log "  Existing snapshot kept as $oldName until the new upload is verified."
}

$upHdrs = @{
  'Authorization' = "Bearer $Token"
  'Content-Type'  = 'application/octet-stream'
  'User-Agent'    = 'Sailuo-Snapshot'
  'Accept'        = 'application/vnd.github+json'
}
$uploadBase = ($rel.upload_url -replace '\{\?name,label\}$', '')
$chunkMaxBytes = 1850L * 1024L * 1024L

try {
  if ($encLen -le $chunkMaxBytes) {
    $uploadUrl = $uploadBase + '?name=' + [uri]::EscapeDataString($baseAssetName)
    $uploadResult = Invoke-GitHubRequest -Method 'POST' -Uri $uploadUrl -Headers $upHdrs -InFile $encPath -TimeoutSec 900
    if (-not $uploadResult.ok) { throw "Asset upload failed: $($uploadResult.error)" }
    $asset = $uploadResult.data
    if (-not $asset -or -not $asset.id) { throw 'GitHub did not return the uploaded asset.' }
    [void]$uploadedAssets.Add(@{ id = $asset.id; name = $asset.name })
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
        [void]$uploadedAssets.Add(@{ id = $asset.id; name = $partName })
        [void]$expectedParts.Add(@{ name = $partName; size = $written; sha256 = $partSha })
        Remove-Item $partPath -Force -ErrorAction SilentlyContinue
        Log "  Uploaded chunk $partName ($([math]::Round($written / 1MB, 1)) MB)."
        $partIdx++
      }
    } finally { $fsRead.Dispose() }
  }

  $verified = $false
  $verifiedAssets = @()
  for ($attempt = 1; $attempt -le 10; $attempt++) {
    $freshResult = Invoke-GitHubRequest -Method 'GET' -Uri "https://api.github.com/repos/$Repo/releases/tags/$ReleaseTag" -Headers $hdrs -TimeoutSec 30
    $freshAssets = if ($freshResult.ok) { @($freshResult.data.assets) } else { @() }
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
  if (-not $verified) { throw 'GitHub did not confirm the uploaded snapshot with matching sizes and digests.' }

  $primaryAsset = $verifiedAssets | Where-Object { $_.name -eq $baseAssetName } | Select-Object -First 1
  if (-not $primaryAsset) { $primaryAsset = $verifiedAssets | Select-Object -First 1 }
  $assetIds = @($verifiedAssets | ForEach-Object { $_.id })
  $assetNames = @($verifiedAssets | ForEach-Object { $_.name })

  foreach ($oldId in @($oldRenames | ForEach-Object { $_.id })) {
    try {
      Invoke-GitHubRequest -Method 'DELETE' -Uri "https://api.github.com/repos/$Repo/releases/assets/$oldId" -Headers $hdrs -TimeoutSec 30 | Out-Null
    } catch {}
  }
  $freshResult = Invoke-GitHubRequest -Method 'GET' -Uri "https://api.github.com/repos/$Repo/releases/tags/$ReleaseTag" -Headers $hdrs -TimeoutSec 30
  if ($freshResult.ok) {
    foreach ($stale in @($freshResult.data.assets | Where-Object { $_.name -like "$safeName-old-*" })) {
      try {
        Invoke-GitHubRequest -Method 'DELETE' -Uri "https://api.github.com/repos/$Repo/releases/assets/$($stale.id)" -Headers $hdrs -TimeoutSec 30 | Out-Null
      } catch {}
    }
  }

  $common = @{
    asset_name    = $baseAssetName
    asset_names   = $assetNames
    asset_ids     = $assetIds
    asset_sha256  = $encSha
    asset_size    = $encLen
    file_count    = $fileCount
    size_mb       = $zipMB
    release_tag   = $ReleaseTag
    archive_format = $format
    profile       = ($profileDirs -join ';')
    warning       = $warningText
    multipart     = ($assetIds.Count -gt 1)
  }
  if ($warningText) {
    Write-SnapshotResult -Code 3 -Status 'warning' -Message "Named snapshot '$baseAssetName' uploaded and verified with a warning: $warningText" -Extra $common
  }
  Write-SnapshotResult -Code 0 -Status 'success' -Message "Named snapshot '$baseAssetName' uploaded and verified ($zipMB MB, $fileCount files)." -Extra $common
} catch {
  $reason = $_.Exception.Message
  Log "Named snapshot upload failed: $reason"
  foreach ($uploaded in @($uploadedAssets)) {
    try {
      Invoke-GitHubRequest -Method 'DELETE' -Uri "https://api.github.com/repos/$Repo/releases/assets/$($uploaded.id)" -Headers $hdrs -TimeoutSec 30 | Out-Null
    } catch {}
  }
  foreach ($done in @($oldRenames)) {
    try {
      Invoke-GitHubRequest -Method 'PATCH' -Uri "https://api.github.com/repos/$Repo/releases/assets/$($done.id)" -Headers $hdrs -Body @{ name = $done.original } -TimeoutSec 30 | Out-Null
      Log "  Existing snapshot restored to $($done.original)."
    } catch {
      Log "  WARNING: existing snapshot is safe as $($done.renamed) but could not be renamed back."
    }
  }
  Fail-Snapshot "Named snapshot upload failed; the previous named snapshot was kept. $reason" 'upload' @{
    encrypted_path = $encPath
  }
}
