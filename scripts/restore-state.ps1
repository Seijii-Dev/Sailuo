# ============================================================================
#  restore-state.ps1 - Restore Sailuo Session State from GitHub Release
# ----------------------------------------------------------------------------
#  Downloads the encrypted archive from the `sailuo-state-latest` Release in the
#  user's repo, decrypts it with AES-256-CBC (PBKDF2 from RDP_PASSWORD /
#  GITHUB_TOKEN), validates the archive, extracts it to staging, then restores:
#    - C:\Persist
#    - The authoritative C:\Users\<user> profile (Desktop, Documents, Downloads,
#      Pictures, Videos, Music, including dynamically named profiles)
#    - Browser Login Sessions (Chrome, Edge, Brave, Firefox) + DPAPI Master Keys
#    - Wallpaper from the previous session
#
#  Existing data is backed up before replacement and rolled back if any copy or
#  hash verification fails. Exit codes: 0 success, 1 failure, 2 skipped,
#  3 completed with a documented warning.
# ============================================================================
param(
  # Optional: restore a specific named snapshot instead of the newest auto-save.
  [string]$Asset,
  # Optional: just list the snapshots that are available in the release.
  [switch]$List,
  [string]$OperationId,
  [string]$ReleaseTag = 'sailuo-state-latest',
  # Optional isolated destination root used by end-to-end tests. Production
  # calls leave this empty and restore to the real profile.
  [string]$TestDestinationRoot
)

$SailuoTag = 'Sailuo:restore'
$script:SailuoLogFile = 'C:\Persist\System\restore-state.log'
. "$PSScriptRoot/lib-common.ps1"

$script:SailuoOperationStartedUtc = $null
# The dashboard passes -OperationId so it can match the result file even when
# the script stops before Start-SailuoOperation (missing token, no release...).
$script:SailuoOperationId = $OperationId
$script:SailuoSyncMutex = $null
$script:SailuoMutexOwned = $false

try {
  New-Item -ItemType Directory -Path 'C:\Persist\System' -Force -ErrorAction SilentlyContinue | Out-Null
  if (Test-Path $script:SailuoLogFile) {
    $existingLines = @(Get-Content -LiteralPath $script:SailuoLogFile -ErrorAction SilentlyContinue)
    if ($existingLines.Count -gt 700) {
      Set-Content -LiteralPath $script:SailuoLogFile -Value ($existingLines | Select-Object -Last 450) -Encoding UTF8 -Force
    }
  }
  Add-Content -LiteralPath $script:SailuoLogFile -Encoding UTF8 -ErrorAction SilentlyContinue `
    -Value ("---- restore start pid=$PID at $([DateTime]::UtcNow.ToString('o')) ----")
} catch {}

$workDir = 'C:\Sailuo\restore-work'

# Serialize with persist-state.ps1 so a restore never overwrites the profile
# while a checkpoint is staging or uploading.
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
  Log 'A cloud save or restore is already running - wait for it to finish, then restore again.'
  exit 2
}
Write-SailuoSyncLock 'restore'
try {
  Register-EngineEvent -SourceIdentifier "Sailuo.Restore.$PID" -Action {
    try {
      $raw = Get-Content -LiteralPath 'C:\Persist\System\sync.lock' -Raw -ErrorAction SilentlyContinue
      if ($raw -match '"pid"\s*:\s*(\d+)' -and [int]$Matches[1] -eq $PID) {
        Remove-Item -LiteralPath 'C:\Persist\System\sync.lock' -Force -ErrorAction SilentlyContinue
      }
    } catch {}
  } | Out-Null
} catch {}

$testMode = [bool]$TestDestinationRoot
$backupRoot = $null
$rollback = New-Object System.Collections.ArrayList
# Hard failures abort/rollback; permission glitches are reported as a warning
# after the content itself has been verified.
$restoreErrors = New-Object System.Collections.ArrayList
$restoreWarnings = New-Object System.Collections.ArrayList
$verifiedFiles = 0
$verifiedBytes = 0L
# The wallpaper is stored once under Persist\Config and copied a second time to
# the public Pictures folder. That auxiliary copy is verified too, but it must
# not be counted against the manifest's payload file count.
$wallpaperCopies = 0

function Finish-SailuoRestore {
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
    schema                = 2
    status                = $Status
    operation             = 'restore'
    operation_id          = $script:SailuoOperationId
    writer                = 'restore-state/3'
    last_attempt_utc      = $now
    last_restore_attempt_utc = $now
    pid                   = $PID
    progress              = ''
    last_restore_warning  = ''
  }
  if ($Status -eq 'success' -or $Status -eq 'warning') {
    $pairs.last_restore_utc = $now
    $pairs.last_restore_status = $Status
    if ($Status -eq 'warning') { $pairs.last_restore_warning = $Message }
  } elseif ($Status -eq 'failure') {
    $pairs.last_restore_status = 'failure'
    $pairs.last_restore_error = $ErrorText
  } elseif ($Status -eq 'skipped') {
    $pairs.last_restore_status = 'skipped'
  }
  foreach ($k in $Meta.Keys) { $pairs[$k] = $Meta[$k] }
  if ($ErrorText) {
    $pairs.last_error = $ErrorText
    $pairs.last_error_utc = $now
    $pairs.last_error_operation = 'restore'
  } elseif ($Status -in @('success','warning','skipped')) {
    $pairs.last_error = ''
  }
  try { Set-SailuoCloudMeta $pairs | Out-Null } catch { Log "Could not update restore metadata: $($_.Exception.Message)" }
  try {
    $statusPairs = @{
      status       = $Status
      operation    = 'restore'
      operation_id = $script:SailuoOperationId
      updated_utc  = $now
    }
    if ($Status -eq 'success' -or $Status -eq 'warning') {
      $statusPairs.restored = $true
      if ($Meta.ContainsKey('last_restore_source')) { $statusPairs.source = $Meta['last_restore_source'] }
      if ($Meta.ContainsKey('last_restore_files')) { $statusPairs.files = $Meta['last_restore_files'] }
      if ($Meta.ContainsKey('last_restore_profile')) { $statusPairs.profile = $Meta['last_restore_profile'] }
      $statusPairs.restored_utc = $now
      $statusPairs.verified = $true
      if ($Status -eq 'warning') { $statusPairs.warning = $Message }
    } elseif ($Status -eq 'failure') {
      $statusPairs.restored = $false
      $statusPairs.verified = $false
      if ($ErrorText) { $statusPairs.error = $ErrorText }
    } else {
      # A skipped attempt did not change any files, so the outcome of the last
      # real restore stays visible instead of being reset to false.
      $statusPairs.skipped = $Message
    }
    Update-PersistStatus $statusPairs | Out-Null
  } catch {}
  try {
    Write-SailuoOperationResult -Operation 'restore' -OperationId $script:SailuoOperationId `
      -Status $Status -Message $Message -ErrorText $ErrorText -ExitCode $Code -Extra $Extra
  } catch { Log "Could not write the restore result: $($_.Exception.Message)" }
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

function Fail-SailuoRestore([string]$Message, [string]$Stage, [hashtable]$Extra = @{}) {
  $details = @{ stage = $Stage }
  foreach ($k in $Extra.Keys) { $details[$k] = $Extra[$k] }
  Finish-SailuoRestore -Code 1 -Status 'failure' -Message $Message -ErrorText $Message -Extra $details
}

function Invoke-GitHubGet {
  param([string]$Uri, [hashtable]$Headers, [int]$TimeoutSec = 30)
  try {
    $data = Invoke-RestMethod -Method 'GET' -Uri $Uri -Headers $Headers -TimeoutSec $TimeoutSec -ErrorAction Stop
    return @{ ok = $true; status = 200; data = $data; error = '' }
  } catch {
    $status = 0
    try { $status = [int]$_.Exception.Response.StatusCode } catch {}
    return @{ ok = $false; status = $status; data = $null; error = $_.Exception.Message }
  }
}

function Get-SnapshotSetKey([string]$Name) {
  $m = [regex]::Match($Name, '^(.*\.(?:7z|zip)\.enc)(?:\.part\d+)?$')
  if ($m.Success) { return $m.Groups[1].Value }
  return $null
}

function Get-SnapshotSets($Assets) {
  $map = @{}
  foreach ($a in @($Assets)) {
    $key = Get-SnapshotSetKey ([string]$a.name)
    if (-not $key) { continue }
    if (-not $map.ContainsKey($key)) { $map[$key] = New-Object System.Collections.ArrayList }
    [void]$map[$key].Add($a)
  }
  $sets = New-Object System.Collections.ArrayList
  foreach ($key in $map.Keys) {
    $items = @($map[$key])
    $single = @($items | Where-Object { $_.name -eq $key } | Select-Object -First 1)
    $parts = @($items | Where-Object { $_.name -match ('^' + [regex]::Escape($key) + '\.part(\d+)$') } |
      Sort-Object { [int]([regex]::Match($_.name, '\.part(\d+)$').Groups[1].Value) })
    $complete = $false
    $ordered = @()
    if ($single.Count -eq 1 -and $parts.Count -eq 0) {
      $complete = $true
      $ordered = @($single[0])
    } elseif ($parts.Count -gt 0) {
      $complete = $true
      $expected = 1
      foreach ($part in $parts) {
        $m = [regex]::Match($part.name, '\.part(\d+)$')
        if (-not $m.Success -or [int]$m.Groups[1].Value -ne $expected) { $complete = $false; break }
        $expected++
      }
      if ($complete) { $ordered = $parts }
    }
    if (-not $complete) { continue }
    $newest = ''
    foreach ($item in $ordered) {
      if ([string]$item.created_at -gt $newest) { $newest = [string]$item.created_at }
    }
    $size = 0L
    foreach ($item in $ordered) { $size += [long]$item.size }
    [void]$sets.Add([pscustomobject]@{
      Key         = $key
      Assets      = $ordered
      Newest      = $newest
      Size        = $size
      IsCanonical = ($key -match '^sailuo-state\.(7z|zip)\.enc$')
      IsOld       = ($key -match '^sailuo-state-old-')
      IsNamed     = ($key -match '^sailuo-snapshot-')
    })
  }
  return $sets.ToArray()
}

function Invoke-DownloadSet($Set) {
  Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Path $workDir -Force | Out-Null
  $encPath = Join-Path $workDir 'merged-state.bin'
  $downloads = New-Object System.Collections.ArrayList
  $fsJoin = [System.IO.File]::Open($encPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
  try {
    foreach ($asset in @($Set.Assets)) {
      $target = Join-Path $workDir ([string]$asset.name)
      $lastError = ''
      $downloaded = $false
      for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
          Invoke-WebRequest -Uri "https://api.github.com/repos/$ghRepo/releases/assets/$($asset.id)" `
            -Headers $dlHdrs -OutFile $target -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop
          $downloaded = $true
          break
        } catch {
          $lastError = $_.Exception.Message
          Start-Sleep -Seconds (2 * $attempt)
        }
      }
      if (-not $downloaded) { throw "Download failed for $($asset.name): $lastError" }
      if (-not (Test-Path $target)) { throw "Download produced no file for $($asset.name)." }
      $actualLength = (Get-Item $target).Length
      if ($actualLength -ne [long]$asset.size) {
        throw "Downloaded size for $($asset.name) is $actualLength bytes, expected $($asset.size)."
      }
      $sha = Get-SailuoFileSha256 $target
      if ($asset.digest -and ([string]$asset.digest).StartsWith('sha256:')) {
        $expectedDigest = ([string]$asset.digest).Substring(7).ToLowerInvariant()
        if ($expectedDigest -ne $sha) {
          throw "SHA256 mismatch for $($asset.name) (GitHub digest does not match the downloaded bytes)."
        }
      }
      [void]$downloads.Add([ordered]@{
        name   = [string]$asset.name
        id     = $asset.id
        size   = $actualLength
        sha256 = $sha
        digest = [string]$asset.digest
      })
      $fsPart = [System.IO.File]::OpenRead($target)
      try { $fsPart.CopyTo($fsJoin) } finally { $fsPart.Dispose() }
      Remove-Item $target -Force -ErrorAction SilentlyContinue
      Log "  Downloaded and hashed $($asset.name) ($([math]::Round($actualLength / 1MB, 1)) MB)."
    }
  } finally {
    $fsJoin.Dispose()
  }

  $mergedLength = (Get-Item $encPath).Length
  $expectedLength = 0L
  foreach ($asset in @($Set.Assets)) { $expectedLength += [long]$asset.size }
  if ($mergedLength -ne $expectedLength) {
    throw "Merged archive is $mergedLength bytes, expected $expectedLength (incomplete multi-part download)."
  }
  $mergedSha = Get-SailuoFileSha256 $encPath

  # Cross-check against local metadata when this is the snapshot it recorded.
  $meta = Get-SailuoCloudMeta
  $metaSha = [string](Get-SailuoFirstValue $meta 'asset_sha256' '')
  $metaIds = @()
  $rawIds = Get-SailuoFirstValue $meta 'asset_ids' $null
  if ($rawIds) { $metaIds = @($rawIds | ForEach-Object { [string]$_ }) }
  $setIds = @($Set.Assets | ForEach-Object { [string]$_.id })
  $idsMatch = $false
  if ($metaIds.Count -eq $setIds.Count) {
    $idsMatch = $true
    foreach ($id in $setIds) { if ($metaIds -notcontains $id) { $idsMatch = $false; break } }
  }
  if ($metaSha -and $idsMatch -and $metaSha -ne $mergedSha) {
    throw 'The downloaded snapshot does not match the SHA256 recorded by the last successful save.'
  }

  Write-SailuoJson (Join-Path $workDir 'download-manifest.json') ([ordered]@{
    schema        = 'sailuo-download-manifest/1'
    downloaded_utc = Get-SailuoUtcNowText
    source_set    = $Set.Key
    release_tag   = $ReleaseTag
    merged_bytes  = $mergedLength
    merged_sha256 = $mergedSha
    parts         = @($downloads)
  }) 8
  return @{ encPath = $encPath; sha256 = $mergedSha; length = $mergedLength; downloads = @($downloads) }
}

function Invoke-DecryptAndValidate($EncPath, $Set) {
  $keysToTry = New-Object System.Collections.ArrayList
  if ($p.Length -ge 4) { [void]$keysToTry.Add("Sailuo-Persist-$u-$p") }
  [void]$keysToTry.Add("Sailuo-Persist-$ghRepo")
  $uniqueKeys = @($keysToTry | Select-Object -Unique)

  $lastError = ''
  $tryIndex = 0
  foreach ($key in $uniqueKeys) {
    $tryIndex++
    $outPath = Join-Path $workDir ("decrypted-try$tryIndex.bin")
    try {
      $fsIn = [System.IO.File]::Open($EncPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
      try {
        $header = New-Object byte[] 6
        if ($fsIn.Read($header, 0, 6) -ne 6) { throw 'Encrypted file is too short.' }
        if ([System.Text.Encoding]::ASCII.GetString($header) -ne 'XYST01') { throw 'Encryption header is not XYST01.' }
        $salt = New-Object byte[] 16
        if ($fsIn.Read($salt, 0, 16) -ne 16) { throw 'Encrypted file has no complete salt.' }

        $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($key, $salt, 20000)
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.KeySize = 256
        $aes.Key = $kdf.GetBytes(32)
        $aes.IV = $kdf.GetBytes(16)
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $fsOut = [System.IO.File]::Open($outPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
          $cs = New-Object System.Security.Cryptography.CryptoStream($fsIn, $aes.CreateDecryptor(), [System.Security.Cryptography.CryptoStreamMode]::Read)
          try { $cs.CopyTo($fsOut) } finally { $cs.Dispose() }
        } finally { $fsOut.Dispose() }
        $aes.Dispose()
      } finally { $fsIn.Dispose() }

      $format = Get-SailuoArchiveFormat $outPath
      if (-not $format) { throw 'Decrypted payload is not a 7z or zip archive.' }
      $test = Test-SailuoArchive -Path $outPath -Format $format
      if (-not $test.ok) { throw "Archive integrity check failed: $($test.error)" }

      $entries = @(Get-SailuoArchiveEntries -Path $outPath -Format $format)
      if ($entries.Count -eq 0) { throw 'Archive contains no entries.' }
      $safe = Test-SailuoArchivePaths $entries
      if (-not $safe.ok) { throw $safe.error }
      $topLevel = @($entries | ForEach-Object { (([string]$_.path).Replace('/', '\') -split '\\')[0] } | Select-Object -Unique)
      $allowed = @('Persist', 'User', 'Browsers', 'DPAPI', '_sailuo-manifest.json')
      $recognised = @($topLevel | Where-Object { $allowed -contains $_ })
      if ($recognised.Count -eq 0) { throw "Archive has no recognised Sailuo data folders (found: $($topLevel -join ', '))." }
      if (($topLevel | Where-Object { $allowed -notcontains $_ }).Count -gt 0) {
        throw "Archive contains unexpected top-level entries: $(($topLevel | Where-Object { $allowed -notcontains $_ }) -join ', ')."
      }

      $extDir = Join-Path $workDir 'extracted'
      Remove-Item $extDir -Recurse -Force -ErrorAction SilentlyContinue
      New-Item -ItemType Directory -Path $extDir -Force | Out-Null
      if ($format -eq '7z') {
        $sevenZip = Get-SailuoSevenZipPath
        if (-not $sevenZip) { throw '7-Zip is required to extract this snapshot but is not installed.' }
        $extractOutput = & $sevenZip x $outPath "-o$extDir" -y 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Archive extraction failed (7-Zip exit $LASTEXITCODE): $(Log-Tail (($extractOutput | Out-String)) 2)" }
      } else {
        Expand-Archive -Path $outPath -DestinationPath $extDir -Force -ErrorAction Stop
      }

      $extractedFiles = @(Get-ChildItem -Path $extDir -Recurse -File -Force -ErrorAction SilentlyContinue)
      $expectedFiles = @($entries | Where-Object { -not $_.isDirectory })
      if ($extractedFiles.Count -ne $expectedFiles.Count) {
        throw "Extraction produced $($extractedFiles.Count) files, expected $($expectedFiles.Count)."
      }
      $extractedBytes = ($extractedFiles | Measure-Object -Property Length -Sum).Sum
      $expectedBytes = ($expectedFiles | Measure-Object -Property size -Sum).Sum
      if (-not $extractedBytes) { $extractedBytes = 0 }
      if (-not $expectedBytes) { $expectedBytes = 0 }
      if ([long]$extractedBytes -ne [long]$expectedBytes) {
        throw "Extraction size mismatch ($extractedBytes bytes extracted, expected $expectedBytes)."
      }
      $reparse = @(Get-ChildItem -Path $extDir -Recurse -Force -ErrorAction SilentlyContinue | Where-Object {
          ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
        })
      if ($reparse.Count -gt 0) { throw 'Archive contains reparse points/symlinks, which Sailuo does not restore.' }

      $manifest = $null
      $manifestPath = Join-Path $extDir '_sailuo-manifest.json'
      if (Test-Path $manifestPath) {
        $manifest = Read-SailuoJson $manifestPath
        if (-not $manifest) { throw 'Archive manifest is not valid JSON.' }
        $manifestFormat = [string](Get-SailuoFirstValue $manifest 'format' '')
        if ($manifestFormat -and -not $manifestFormat.StartsWith('sailuo-state-manifest/')) {
          throw "Unsupported snapshot manifest format '$manifestFormat'."
        }
        $manifestCount = Get-SailuoFirstValue $manifest 'file_count' $null
        $manifestBytes = Get-SailuoFirstValue $manifest 'total_bytes' $null
        if ($null -ne $manifestCount -and [int]$manifestCount -ne ($extractedFiles.Count - 1)) {
          throw "Snapshot manifest says $manifestCount files, archive contains $($extractedFiles.Count - 1)."
        }
        if ($null -ne $manifestBytes -and [long]$manifestBytes -ne ([long]$extractedBytes - (Get-Item $manifestPath).Length)) {
          throw 'Snapshot manifest byte count does not match the extracted files.'
        }
      } else {
        Log 'This is an older snapshot without a manifest; archive CRC validation passed.'
      }

      $hasPayload = (Test-Path (Join-Path $extDir 'Persist')) -or (Test-Path (Join-Path $extDir 'User')) -or
                    (Test-Path (Join-Path $extDir 'Browsers')) -or (Test-Path (Join-Path $extDir 'DPAPI'))
      if (-not $hasPayload) { throw 'Archive contains no restorable Sailuo payload.' }

      return @{
        ok       = $true
        extDir   = $extDir
        format   = $format
        manifest = $manifest
        encPath  = $EncPath
        decryptedPath = $outPath
      }
    } catch {
      $lastError = $_.Exception.Message
      Remove-Item $outPath -Force -ErrorAction SilentlyContinue
    }
  }
  throw "The snapshot could not be decrypted or validated. $lastError"
}

function Test-RestoredFile([string]$Source, [string]$Destination) {
  if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) { return $false }
  $src = Get-Item -LiteralPath $Source -ErrorAction SilentlyContinue
  $dst = Get-Item -LiteralPath $Destination -ErrorAction SilentlyContinue
  if (-not $src -or -not $dst) { return $false }
  if ([long]$src.Length -ne [long]$dst.Length) { return $false }
  try { return ((Get-SailuoFileSha256 $Source) -eq (Get-SailuoFileSha256 $Destination)) } catch { return $false }
}

function Copy-OneVerified([string]$Source, [string]$Destination) {
  $parent = Split-Path -Path $Destination -Parent
  if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
  }
  if (-not (Copy-FileUnlocked $Source $Destination)) {
    throw "Could not copy $Source to $Destination."
  }
  if (-not (Test-RestoredFile $Source $Destination)) {
    throw "Restored file failed SHA256 verification: $Destination"
  }
  try { [System.IO.File]::SetLastWriteTimeUtc($Destination, [System.IO.File]::GetLastWriteTimeUtc($Source)) } catch {}
  $script:verifiedFiles++
  try { $script:verifiedBytes += (Get-Item -LiteralPath $Destination).Length } catch {}
}

function Copy-TreeVerified([string]$Source, [string]$Destination) {
  if (-not (Test-Path -LiteralPath $Source)) { return }
  foreach ($dir in @(Get-ChildItem -LiteralPath $Source -Recurse -Directory -Force -ErrorAction SilentlyContinue)) {
    $rel = $dir.FullName.Substring($Source.Length).TrimStart('\')
    New-Item -ItemType Directory -Path (Join-Path $Destination $rel) -Force -ErrorAction SilentlyContinue | Out-Null
  }
  foreach ($file in @(Get-ChildItem -LiteralPath $Source -Recurse -File -Force -ErrorAction SilentlyContinue)) {
    $rel = $file.FullName.Substring($Source.Length).TrimStart('\')
    Copy-OneVerified $file.FullName (Join-Path $Destination $rel)
  }
}

function Get-SafeLabel([string]$Text) {
  return ($Text -replace '[^A-Za-z0-9._-]', '_')
}

function Restore-ReplaceDirectory([string]$Source, [string]$Destination, [string]$Label) {
  $backup = $null
  if (Test-Path -LiteralPath $Destination) {
    $backup = Join-Path $backupRoot ('replace\' + (Get-SafeLabel $Label) + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Split-Path $backup -Parent) -Force -ErrorAction Stop | Out-Null
    Move-Item -LiteralPath $Destination -Destination $backup -Force -ErrorAction Stop
  }
  try {
    New-Item -ItemType Directory -Path $Destination -Force -ErrorAction Stop | Out-Null
    Copy-TreeVerified $Source $Destination
    [void]$rollback.Add(@{ type = 'replace'; destination = $Destination; backup = $backup })
  } catch {
    try {
      if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue }
      if ($backup -and (Test-Path -LiteralPath $backup)) { Move-Item -LiteralPath $backup -Destination $Destination -Force -ErrorAction SilentlyContinue }
    } catch {}
    throw
  }
}

function Restore-ReplaceFile([string]$Source, [string]$Destination, [string]$Label) {
  $backup = $null
  if (Test-Path -LiteralPath $Destination) {
    $backup = Join-Path $backupRoot ('replace\' + (Get-SafeLabel $Label) + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Split-Path $backup -Parent) -Force -ErrorAction Stop | Out-Null
    Copy-Item -LiteralPath $Destination -Destination $backup -Force -ErrorAction Stop
  }
  try {
    Copy-OneVerified $Source $Destination
    [void]$rollback.Add(@{ type = 'replacefile'; destination = $Destination; backup = $backup })
  } catch {
    try {
      if ($backup -and (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $backup -Destination $Destination -Force -ErrorAction SilentlyContinue }
      elseif (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue }
    } catch {}
    throw
  }
}

function Restore-MergeDirectory([string]$Source, [string]$Destination, [string]$Label) {
  if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Path $Destination -Force -ErrorAction Stop | Out-Null }
  $operations = New-Object System.Collections.ArrayList
  try {
    foreach ($file in @(Get-ChildItem -LiteralPath $Source -Recurse -File -Force -ErrorAction SilentlyContinue)) {
      $rel = $file.FullName.Substring($Source.Length).TrimStart('\')
      $target = Join-Path $Destination $rel
      $backup = $null
      $existed = Test-Path -LiteralPath $target
      if ($existed) {
        $backup = Join-Path $backupRoot ('merge\' + (Get-SafeLabel $Label) + '\' + $rel)
        $parent = Split-Path $backup -Parent
        if ($parent) { New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null }
        Copy-Item -LiteralPath $target -Destination $backup -Force -ErrorAction Stop
      }
      try {
        Copy-OneVerified $file.FullName $target
      } catch {
        if ($existed -and $backup -and (Test-Path -LiteralPath $backup)) {
          try { Copy-Item -LiteralPath $backup -Destination $target -Force -ErrorAction SilentlyContinue } catch {}
        }
        throw
      }
      [void]$operations.Add(@{ target = $target; backup = $backup; existed = $existed })
    }
    [void]$rollback.Add(@{ type = 'merge'; operations = $operations })
  } catch {
    for ($i = $operations.Count - 1; $i -ge 0; $i--) {
      $op = $operations[$i]
      try {
        if ($op.backup -and (Test-Path -LiteralPath $op.backup)) {
          Copy-Item -LiteralPath $op.backup -Destination $op.target -Force -ErrorAction SilentlyContinue
        } elseif (-not $op.existed -and (Test-Path -LiteralPath $op.target)) {
          Remove-Item -LiteralPath $op.target -Force -ErrorAction SilentlyContinue
        }
      } catch {}
    }
    throw
  }
}

function Invoke-Rollback {
  for ($i = $rollback.Count - 1; $i -ge 0; $i--) {
    $action = $rollback[$i]
    if ($action.type -eq 'replace') {
      try {
        if (Test-Path -LiteralPath $action.destination) {
          Remove-Item -LiteralPath $action.destination -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($action.backup -and (Test-Path -LiteralPath $action.backup)) {
          Move-Item -LiteralPath $action.backup -Destination $action.destination -Force -ErrorAction SilentlyContinue
        }
      } catch { [void]$restoreErrors.Add("rollback replace $($action.destination): $($_.Exception.Message)") }
    } elseif ($action.type -eq 'replacefile') {
      try {
        if ($action.backup -and (Test-Path -LiteralPath $action.backup)) {
          Copy-Item -LiteralPath $action.backup -Destination $action.destination -Force -ErrorAction SilentlyContinue
        } elseif (Test-Path -LiteralPath $action.destination) {
          Remove-Item -LiteralPath $action.destination -Force -ErrorAction SilentlyContinue
        }
      } catch { [void]$restoreErrors.Add("rollback file $($action.destination): $($_.Exception.Message)") }
    } elseif ($action.type -eq 'merge') {
      for ($j = $action.operations.Count - 1; $j -ge 0; $j--) {
        $op = $action.operations[$j]
        try {
          if ($op.backup -and (Test-Path -LiteralPath $op.backup)) {
            Copy-Item -LiteralPath $op.backup -Destination $op.target -Force -ErrorAction SilentlyContinue
          } elseif (-not $op.existed -and (Test-Path -LiteralPath $op.target)) {
            Remove-Item -LiteralPath $op.target -Force -ErrorAction SilentlyContinue
          }
        } catch { [void]$restoreErrors.Add("rollback merge $($op.target): $($_.Exception.Message)") }
      }
    }
  }
}

function Set-RestoredPermissions([string]$Path) {
  if ($testMode) { return }
  try {
    $output = & icacls $Path /grant "${u}:(OI)(CI)F" /grant "Administrators:(OI)(CI)F" /grant "SYSTEM:(OI)(CI)F" /T /C /Q 2>&1
    if ($LASTEXITCODE -ne 0) {
      $message = "icacls could not apply permissions to $Path (exit $LASTEXITCODE): $(Log-Tail (($output | Out-String)) 1)"
      Log "Warning: $message"
      [void]$restoreWarnings.Add($message)
    }
  } catch {
    [void]$restoreWarnings.Add("icacls failed for ${Path}: $($_.Exception.Message)")
  }
}

function Stop-RestoreBrowsers {
  if ($testMode) { return }
  foreach ($name in @('chrome', 'msedge', 'brave', 'firefox')) {
    try {
      Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object { $_.CloseMainWindow() | Out-Null }
    } catch {}
  }
  Start-Sleep -Milliseconds 1500
}

try {
  $cfg = Get-Cfg
  if ($env:PERSIST_DATA -and @('no', '0', 'false', 'off') -contains $env:PERSIST_DATA.Trim().ToLower()) {
    Finish-SailuoRestore -Code 2 -Status 'skipped' -Message 'State restore is disabled; no files were changed.' -Extra @{ reason = 'disabled-by-user' }
  }

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
  $ghRepo = $env:GITHUB_REPOSITORY
  if (-not $ghToken -or -not $ghRepo) {
    Fail-SailuoRestore 'Restore State cannot run: GITHUB_TOKEN or GITHUB_REPOSITORY is missing.' 'configuration'
  }
  $u = if ($env:RDP_USER) { $env:RDP_USER.Trim() } else { $cfg.rdp_user }
  $p = if ($env:RDP_PASSWORD) { $env:RDP_PASSWORD.Trim() } else { '' }

  $hdrs = @{
    'Authorization' = "Bearer $ghToken"
    'Accept'        = 'application/vnd.github+json'
    'User-Agent'    = 'Sailuo-State'
  }
  $dlHdrs = @{
    'Authorization' = "Bearer $ghToken"
    'Accept'        = 'application/octet-stream'
    'User-Agent'    = 'Sailuo-State'
  }

  $relResult = Invoke-GitHubGet -Uri "https://api.github.com/repos/$ghRepo/releases/tags/$ReleaseTag" -Headers $hdrs
  if (-not $relResult.ok) {
    if ($relResult.status -eq 404) {
      Fail-SailuoRestore "No snapshot release '$ReleaseTag' exists in $ghRepo. Save State has not uploaded a snapshot yet." 'release'
    }
    Fail-SailuoRestore "Could not read snapshot release '$ReleaseTag' (HTTP $($relResult.status)): $($relResult.error)" 'release'
  }
  $rel = $relResult.data
  $allAssets = @($rel.assets)
  $sets = @(Get-SnapshotSets $allAssets)

  if ($List) {
    if ($sets.Count -eq 0) {
      Log "No state snapshots found in release '$ReleaseTag'."
    } else {
      Log "Snapshots in release '$ReleaseTag':"
      foreach ($set in ($sets | Sort-Object Newest -Descending)) {
        $kind = if ($set.IsCanonical) { 'current' } elseif ($set.IsOld) { 'previous' } elseif ($set.IsNamed) { 'named' } else { 'other' }
        Log ("  {0,-58} {1,4} part(s) {2,9:N1} MB  {3}  {4}" -f $set.Key, @($set.Assets).Count, ($set.Size / 1MB), $kind, $set.Newest)
      }
    }
    Remove-SailuoSyncLock
    try { if ($script:SailuoMutexOwned) { $script:SailuoSyncMutex.ReleaseMutex(); $script:SailuoMutexOwned = $false } } catch {}
    exit 0
  }

  Start-SailuoOperation -Operation 'restore' -OperationId $OperationId -Writer 'restore-state/3' `
    -Message "Preparing to restore user '$u' from release '$ReleaseTag'." | Out-Null

  $candidates = @()
  if ($Asset) {
    $requested = $Asset
    $setKey = Get-SnapshotSetKey $requested
    if (-not $setKey) { Fail-SailuoRestore "Asset '$requested' is not a Sailuo snapshot name." 'asset' }
    $candidates = @($sets | Where-Object { $_.Key -eq $setKey })
    if ($candidates.Count -eq 0) {
      $available = @($sets | ForEach-Object { $_.Key }) -join ', '
      Fail-SailuoRestore "Snapshot '$requested' was not found or is incomplete. Available: $available" 'asset'
    }
  } else {
    $canonical = @($sets | Where-Object { $_.IsCanonical } | Sort-Object Newest -Descending)
    $previous = @($sets | Where-Object { $_.IsOld } | Sort-Object Newest -Descending)
    $candidates = @($canonical) + @($previous)
    if ($candidates.Count -eq 0) {
      Fail-SailuoRestore "Release '$ReleaseTag' has no complete Sailuo snapshot asset. The previous snapshot was not changed." 'asset'
    }
  }

  # Resolve the destination profile before downloading. The ProfileList entry is
  # authoritative and handles dynamically named folders.
  if ($testMode) {
    $persistRoot = Join-Path $TestDestinationRoot 'Persist'
    $profileRoot = Join-Path $TestDestinationRoot 'UserProfile'
    $publicPictures = Join-Path $TestDestinationRoot 'PublicPictures\Sailuo'
    $backupRoot = Join-Path $TestDestinationRoot ('_restore-backup\' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))
    Log "TEST MODE: restoring into isolated root $TestDestinationRoot"
  } else {
    $profileRoot = Ensure-UserProfileCreated $u
    if (-not $profileRoot) { Fail-SailuoRestore "Could not determine the Windows profile folder for '$u'." 'profile' }
    $persistRoot = 'C:\Persist'
    $publicPictures = 'C:\Users\Public\Pictures\Sailuo'
    $backupRoot = Join-Path 'C:\Persist\System' ('restore-backup\' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))
  }
  foreach ($required in @($persistRoot, $profileRoot)) {
    try {
      New-Item -ItemType Directory -Path $required -Force -ErrorAction Stop | Out-Null
      $probe = Join-Path $required ('.sailuo-write-test-' + [guid]::NewGuid().ToString('N'))
      Set-Content -LiteralPath $probe -Value 'ok' -Encoding ASCII -ErrorAction Stop
      Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    } catch {
      Fail-SailuoRestore "Restore State cannot write to $required : $($_.Exception.Message)" 'destination'
    }
  }
  if (-not $testMode) {
    Log "Destination profile: $profileRoot (user '$u')"
    $authoritative = @(Get-AllUserProfileDirs $u)
    if ($authoritative.Count -gt 0 -and ($authoritative -notcontains $profileRoot)) {
      Fail-SailuoRestore "Refusing to restore: '$profileRoot' is not the registered profile for '$u' ($($authoritative -join ', '))." 'profile'
    }
  }

  # Ensure C:\Persist and its readme exist before the first restore.
  if (-not $testMode) {
    New-Item -ItemType Directory -Path 'C:\Persist' -Force -ErrorAction SilentlyContinue | Out-Null
    $readmePersist = 'C:\Persist\BACA-SAYA-ANTI-RESET.txt'
    if (-not (Test-Path $readmePersist)) {
      @(
        '===================================================================='
        '  Sailuo PERMANENT FOLDER (C:\Persist) - ANTI RESET'
        '===================================================================='
        'Any file, installer, browser account, or document you save in:'
        '  1. C:\Persist'
        '  2. Desktop, Documents, Downloads, Pictures, Videos, Music'
        '  3. Google Chrome, Microsoft Edge, Brave, Firefox (Login & Cookie)'
        ''
        'Is AUTOMATICALLY BACKED UP every 4 minutes & when the RDP session ends to'
        'your private GitHub Release (AES-256 encrypted) and RESTORED'
        'back when you start the next RDP session!'
        '===================================================================='
      ) | Set-Content -Path $readmePersist -Encoding UTF8 -Force
    }
  }

  $selectedSet = $null
  $selectedEncSha = ''
  $prepared = $null
  $lastCandidateError = ''
  foreach ($candidate in $candidates) {
    try {
      Log "Selected snapshot $($candidate.Key) ($(@($candidate.Assets).Count) part(s), $([math]::Round($candidate.Size / 1MB, 2)) MB)."
      $downloaded = Invoke-DownloadSet $candidate
      $prepared = Invoke-DecryptAndValidate $downloaded.encPath $candidate
      $selectedSet = $candidate
      $selectedEncSha = [string]$downloaded.sha256
      break
    } catch {
      $lastCandidateError = $_.Exception.Message
      Log "Snapshot $($candidate.Key) could not be used: $lastCandidateError"
      Remove-Item (Join-Path $workDir 'extracted') -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
  if (-not $prepared -or -not $selectedSet) {
    Fail-SailuoRestore "No usable snapshot could be restored. $lastCandidateError" 'download-decrypt' @{
      work_dir = $workDir
    }
  }

  $extDir = $prepared.extDir
  $manifest = $prepared.manifest
  $sourceSet = $selectedSet.Key
  $sourceIds = @($selectedSet.Assets | ForEach-Object { $_.id })
  $sourceNames = @($selectedSet.Assets | ForEach-Object { $_.name })
  Log "Snapshot validated and extracted ($($prepared.format), $sourceSet). Applying to $profileRoot..."

  # Stop browsers before merging their databases; files locked by a running
  # browser would otherwise make the restore fail (and roll back).
  Stop-RestoreBrowsers

  try {
    # ------------------------------------------------------------------
    #  C:\Persist (preserve the local System folder with logs/metadata)
    # ------------------------------------------------------------------
    $stagedPersist = Join-Path $extDir 'Persist'
    if (Test-Path $stagedPersist) {
      foreach ($item in @(Get-ChildItem -LiteralPath $stagedPersist -Force -ErrorAction SilentlyContinue)) {
        if ($item.Name -ieq 'System') { continue }
        $target = Join-Path $persistRoot $item.Name
        if ($item.PSIsContainer) {
          Restore-ReplaceDirectory $item.FullName $target ("Persist\" + $item.Name)
        } else {
          Restore-ReplaceFile $item.FullName $target ("Persist\" + $item.Name)
        }
      }
      Set-RestoredPermissions $persistRoot
    }

    # ------------------------------------------------------------------
    #  Standard profile folders
    # ------------------------------------------------------------------
    $stagedUser = Join-Path $extDir 'User'
    if (Test-Path $stagedUser) {
      foreach ($sub in @('Desktop', 'Documents', 'Downloads', 'Pictures', 'Videos', 'Music')) {
        $src = Join-Path $stagedUser $sub
        if (Test-Path -LiteralPath $src) {
          Restore-ReplaceDirectory $src (Join-Path $profileRoot $sub) ("User\" + $sub)
          Set-RestoredPermissions (Join-Path $profileRoot $sub)
        }
      }
    }

    # ------------------------------------------------------------------
    #  Browsers and DPAPI keys (merge so unrelated extensions/caches survive)
    # ------------------------------------------------------------------
    $browserMap = @(
      @{ Stage = 'Browsers\Chrome';  Dest = 'AppData\Local\Google\Chrome\User Data' },
      @{ Stage = 'Browsers\Edge';    Dest = 'AppData\Local\Microsoft\Edge\User Data' },
      @{ Stage = 'Browsers\Brave';   Dest = 'AppData\Local\BraveSoftware\Brave-Browser\User Data' },
      @{ Stage = 'Browsers\Firefox'; Dest = 'AppData\Roaming\Mozilla\Firefox' }
    )
    foreach ($browser in $browserMap) {
      $src = Join-Path $extDir $browser.Stage
      if (Test-Path -LiteralPath $src) {
        $target = Join-Path $profileRoot $browser.Dest
        Restore-MergeDirectory $src $target $browser.Stage
        Set-RestoredPermissions $target
        Log "  Restored $($browser.Stage)."
      }
    }
    $stagedDpapi = Join-Path $extDir 'DPAPI'
    if (Test-Path -LiteralPath $stagedDpapi) {
      Restore-MergeDirectory $stagedDpapi $profileRoot 'DPAPI'
      # Only touch the DPAPI subtrees; applying icacls /T to the whole profile
      # would crawl every unrelated file and can fail on locked system data.
      foreach ($dpapiRel in @(
          'AppData\Roaming\Microsoft\Protect',
          'AppData\Roaming\Microsoft\Credentials',
          'AppData\Local\Microsoft\Credentials',
          'AppData\Roaming\Microsoft\Crypto')) {
        $dpapiTarget = Join-Path $profileRoot $dpapiRel
        if (Test-Path -LiteralPath $dpapiTarget) { Set-RestoredPermissions $dpapiTarget }
      }
      Log '  Restored DPAPI master keys and credentials.'
    }

    # ------------------------------------------------------------------
    #  Saved wallpaper
    # ------------------------------------------------------------------
    $savedWallpaperDir = Join-Path $persistRoot 'Config'
    if (Test-Path -LiteralPath $savedWallpaperDir) {
      New-Item -ItemType Directory -Path $publicPictures -Force -ErrorAction SilentlyContinue | Out-Null
      foreach ($wp in @(Get-ChildItem -Path $savedWallpaperDir -Filter 'wallpaper.*' -File -ErrorAction SilentlyContinue)) {
        Restore-ReplaceFile $wp.FullName (Join-Path $publicPictures $wp.Name) ('Wallpaper\' + $wp.Name)
        # The same bytes already verified with Persist\Config; count this copy
        # separately so the manifest payload comparison stays exact.
        $wallpaperCopies++
      }
    }

    if ($verifiedFiles -eq 0) {
      throw 'The restore processed no files; refusing to report success.'
    }
    if ($restoreErrors.Count -gt 0) {
      throw "Restore verification reported $($restoreErrors.Count) problem(s): $(($restoreErrors | Select-Object -First 3) -join ' | ')"
    }

    $payloadVerified = $verifiedFiles - $wallpaperCopies
    $manifestCount = $null
    if ($manifest) { $manifestCount = Get-SailuoFirstValue $manifest 'file_count' $null }
    if ($null -ne $manifestCount -and [int]$manifestCount -ne $payloadVerified) {
      throw "Restored $payloadVerified payload files but the snapshot manifest lists $manifestCount."
    }

    # Keep the rollback copy as a documented recovery point, but prune older ones.
    try {
      $backupParent = Split-Path -Path $backupRoot -Parent
      $oldBackups = @(Get-ChildItem -Path $backupParent -Directory -ErrorAction SilentlyContinue |
        Sort-Object CreationTimeUtc -Descending | Select-Object -Skip 2)
      foreach ($old in $oldBackups) { Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    } catch {}

    $warningText = ''
    if ($restoreWarnings.Count -gt 0) {
      $warningText = "$($restoreWarnings.Count) permission warning(s): $(($restoreWarnings | Select-Object -First 3) -join ' | ')"
      Log "Restore completed with warnings: $warningText"
    }
    $extra = @{
      last_restore_source      = $sourceSet
      last_restore_asset_names = $sourceNames
      last_restore_asset_ids   = $sourceIds
      last_restore_files       = $payloadVerified
      last_restore_copies      = $verifiedFiles
      last_restore_bytes       = $verifiedBytes
      last_restore_profile     = $profileRoot
      last_restore_verified    = $true
      last_restore_format      = $prepared.format
      last_restore_backup      = $backupRoot
      last_restore_sha256      = $selectedEncSha
      restore_test_mode        = $testMode
      warning                  = $warningText
    }
    $meta = @{
      last_restore_source      = $sourceSet
      last_restore_asset_names = $sourceNames
      last_restore_asset_ids   = $sourceIds
      last_restore_files       = $payloadVerified
      last_restore_copies      = $verifiedFiles
      last_restore_bytes       = $verifiedBytes
      last_restore_profile     = $profileRoot
      last_restore_verified    = $true
      last_restore_format      = $prepared.format
      last_restore_backup      = $backupRoot
      last_restore_sha256      = $selectedEncSha
      release_tag              = $ReleaseTag
      last_restore_error       = ''
      last_restore_warning     = $warningText
    }
    Set-SailuoCloudMeta $meta | Out-Null

    # Success cleanup: the encrypted/decrypted working copy is no longer needed.
    Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue

    $finishCode = if ($restoreWarnings.Count -gt 0) { 3 } else { 0 }
    $finishStatus = if ($restoreWarnings.Count -gt 0) { 'warning' } else { 'success' }
    $finishMessage = "Session state restored and SHA256-verified ($payloadVerified payload files, $verifiedFiles copies) from $sourceSet to $profileRoot."
    if ($warningText) { $finishMessage = "$finishMessage $warningText" }
    Finish-SailuoRestore -Code $finishCode -Status $finishStatus `
      -Message $finishMessage -Meta $meta -Extra $extra
  } catch {
    $reason = $_.Exception.Message
    Log "Restore failed while applying data: $reason"
    Log 'Rolling the live profile back to the pre-restore state...'
    Invoke-Rollback
    $rollbackFailed = $restoreErrors.Count -gt 0
    if ($rollbackFailed) {
      Log "CRITICAL: rollback also reported problems: $(($restoreErrors | Select-Object -First 5) -join ' | ')"
      Log "Pre-restore backup remains at: $backupRoot"
    } else {
      Log "Rollback completed. Pre-restore data is also kept at: $backupRoot"
    }
    Log "Downloaded snapshot and diagnostics kept in: $workDir"
    Fail-SailuoRestore "Restore failed and the previous data was rolled back where possible. $reason" 'apply' @{
      rolled_back = (-not $rollbackFailed)
      backup_path = $backupRoot
      work_dir = $workDir
      source = $sourceSet
    }
  }
} catch {
  $message = "Unexpected Restore State failure: $($_.Exception.Message)"
  Log $message
  try { Invoke-Rollback } catch {}
  Fail-SailuoRestore $message 'unexpected' @{ backup_path = $backupRoot; work_dir = $workDir }
}
