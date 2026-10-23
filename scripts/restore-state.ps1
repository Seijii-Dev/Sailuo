# ============================================================================
#  restore-state.ps1 - Restore XyRDP Session State from GitHub Release
# ----------------------------------------------------------------------------
#  Downloads the encrypted archive from the `xyrdp-state-latest` Release in the
#  user's repo, decrypts it with AES-256-CBC (PBKDF2 from RDP_PASSWORD /
#  GITHUB_TOKEN), then extracts it back to:
#    - C:\Persist
#    - The official C:\Users\$u profile (Desktop, Documents, Downloads, Pictures, Videos, Music)
#    - Browser Login Sessions (Chrome, Edge, Brave, Firefox) + DPAPI Master Keys
#    - Wallpaper from the previous session
# ============================================================================

$XyTag = 'XyRDP:restore'
. "$PSScriptRoot/lib-common.ps1"

$cfg = Get-Cfg
if ($env:PERSIST_DATA -and @('no','0','false','no','off') -contains $env:PERSIST_DATA.Trim().ToLower()) {
  Log 'State restore disabled by user input - skip.'
  exit 0
}

# Fallback: read the environment from C:\XyRDP\tools\session-env.json when called from the Dashboard
if ((-not $env:GITHUB_TOKEN -or -not $env:GITHUB_REPOSITORY) -and (Test-Path 'C:\XyRDP\tools\session-env.json')) {
  try {
    $sEnv = Get-Content 'C:\XyRDP\tools\session-env.json' -Raw | ConvertFrom-Json
    if (-not $env:RDP_USER -and $sEnv.RDP_USER) { $env:RDP_USER = $sEnv.RDP_USER }
    if (-not $env:RDP_PASSWORD -and $sEnv.RDP_PASSWORD) { $env:RDP_PASSWORD = $sEnv.RDP_PASSWORD }
    if (-not $env:GITHUB_TOKEN -and $sEnv.GITHUB_TOKEN) { $env:GITHUB_TOKEN = $sEnv.GITHUB_TOKEN }
    if (-not $env:GITHUB_REPOSITORY -and $sEnv.GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY = $sEnv.GITHUB_REPOSITORY }
  } catch {}
}

$ghToken = $env:GITHUB_TOKEN
$ghRepo  = $env:GITHUB_REPOSITORY
$u = if ($env:RDP_USER) { $env:RDP_USER.Trim() } else { $cfg.rdp_user }
$p = if ($env:RDP_PASSWORD) { $env:RDP_PASSWORD.Trim() } else { '' }

# CRITICAL: Ensure the Windows profile C:\Users\$u is officially registered in ProfileList
# before creating any subfolder inside it!
$primaryProfDir = Ensure-UserProfileCreated $u

# Always prepare C:\Persist so the user immediately sees the permanent folder
New-Item -ItemType Directory -Path 'C:\Persist' -Force | Out-Null

$readmePersist = 'C:\Persist\BACA-SAYA-ANTI-RESET.txt'
if (-not (Test-Path $readmePersist)) {
  @(
    '===================================================================='
    '  XyRDP PERMANENT FOLDER (C:\Persist) - ANTI RESET'
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

if (-not $ghToken -or -not $ghRepo) {
  Log 'GITHUB_TOKEN or GITHUB_REPOSITORY not available - skip restore state.'
  exit 0
}

$tag = 'xyrdp-state-latest'
$hdrs = @{
  'Authorization' = "Bearer $ghToken"
  'Accept'        = 'application/vnd.github+json'
  'User-Agent'    = 'XyRDP-State'
}

$rel = $null
try {
  $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$ghRepo/releases/tags/$tag" -Headers $hdrs -TimeoutSec 25
} catch {
  Log "No previous state save exists in Release '$tag' (first session)."
  exit 0
}

$asset = $rel.assets | Where-Object { $_.name -like 'xyrdp-state.*.enc' } | Select-Object -First 1
$partAssets = @($rel.assets | Where-Object { $_.name -like 'xyrdp-state.*.enc.part*' } | Sort-Object -Property name)
if (-not $asset -and $partAssets.Count -eq 0) {
  Log 'State asset not found in the release.'
  exit 0
}

$workDir = 'C:\XyRDP\restore-work'
Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

$dlHdrs = @{
  'Authorization' = "Bearer $ghToken"
  'Accept'        = 'application/octet-stream'
  'User-Agent'    = 'XyRDP-State'
}

if ($partAssets.Count -gt 0) {
  $baseEncName = $partAssets[0].name -replace '\.part\d+$', ''
  $encPath = Join-Path $workDir $baseEncName
  $zipPath = Join-Path $workDir ($baseEncName -replace '\.enc$', '')
  $extDir  = Join-Path $workDir 'extracted'
  Log "Downloading & merging $($partAssets.Count) state archive parts ($baseEncName)..."
  try {
    $fsJoin = [System.IO.File]::Create($encPath)
    try {
      foreach ($pa in $partAssets) {
        $tmpPart = Join-Path $workDir $pa.name
        Invoke-WebRequest -Uri "https://api.github.com/repos/$ghRepo/releases/assets/$($pa.id)" -Headers $dlHdrs -OutFile $tmpPart -UseBasicParsing -TimeoutSec 240
        $fsPart = [System.IO.File]::OpenRead($tmpPart)
        $fsPart.CopyTo($fsJoin)
        $fsPart.Close()
        Remove-Item $tmpPart -Force -ErrorAction SilentlyContinue
      }
    } finally {
      $fsJoin.Close()
    }
  } catch {
    Log "Failed to download multi-part state: $($_.Exception.Message)"
    Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 0
  }
} else {
  $encPath = Join-Path $workDir $asset.name
  $zipPath = Join-Path $workDir ($asset.name -replace '\.enc$', '')
  $extDir  = Join-Path $workDir 'extracted'
  Log "Downloading previous session state ($($asset.name), $([math]::Round($asset.size / 1MB, 2)) MB)..."
  try {
    Invoke-WebRequest -Uri "https://api.github.com/repos/$ghRepo/releases/assets/$($asset.id)" -Headers $dlHdrs -OutFile $encPath -UseBasicParsing -TimeoutSec 240
  } catch {
    Log "Failed to download state: $($_.Exception.Message)"
    Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 0
  }
}

if (-not (Test-Path $encPath) -or (Get-Item $encPath).Length -lt 32) {
  Log 'The downloaded state file is empty/corrupted.'
  Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
  exit 0
}

# Try to decrypt with the current password-based key, then fall back to the repo-based key
$keysToTry = @()
if ($p.Length -ge 4) { $keysToTry += "XyRDP-Persist-$u-$p" }
$keysToTry += "XyRDP-Persist-$ghRepo"

$decrypted = $false
foreach ($k in $keysToTry) {
  try {
    $fsIn = [System.IO.File]::OpenRead($encPath)
    $hdr = New-Object byte[] 6
    [void]$fsIn.Read($hdr, 0, 6)
    $magic = [System.Text.Encoding]::ASCII.GetString($hdr)
    if ($magic -ne 'XYST01') {
      $fsIn.Close()
      throw 'Header magic is not XYST01'
    }
    $salt = New-Object byte[] 16
    [void]$fsIn.Read($salt, 0, 16)

    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($k, $salt, 20000)
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256
    $aes.Key = $kdf.GetBytes(32)
    $aes.IV  = $kdf.GetBytes(16)
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7

    $fsOut = [System.IO.File]::OpenWrite($zipPath)
    $cs = New-Object System.Security.Cryptography.CryptoStream($fsIn, $aes.CreateDecryptor(), [System.Security.Cryptography.CryptoStreamMode]::Read)
    $cs.CopyTo($fsOut)
    $fsOut.Close()
    $cs.Close()
    $fsIn.Close()
    $decrypted = $true
    break
  } catch {
    try { $fsOut.Close() } catch {}
    try { $fsIn.Close() } catch {}
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
  }
}

if (-not $decrypted -or -not (Test-Path $zipPath)) {
  Log 'Failed to decrypt the state archive (the RDP password changed since the previous session).'
  Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
  exit 0
}

New-Item -ItemType Directory -Path $extDir -Force | Out-Null
$sevenZip = "${env:ProgramFiles}\7-Zip\7z.exe"
if ((Test-Path $sevenZip) -and $zipPath.EndsWith('.7z')) {
  & $sevenZip x $zipPath "-o$extDir" -y | Out-Null
} else {
  Expand-Archive -Path $zipPath -DestinationPath $extDir -Force
}

# Restore to the original location (and to all candidate user profile directories)
$targetProfileDirs = @(Get-AllUserProfileDirs $u)
if ($primaryProfDir -and ($targetProfileDirs -notcontains $primaryProfDir)) {
  $targetProfileDirs = @($primaryProfDir) + $targetProfileDirs
}

if (Test-Path (Join-Path $extDir 'Persist')) {
  Copy-TreeUnlocked (Join-Path $extDir 'Persist') 'C:\Persist'
}

# Restore the wallpaper saved from the previous session
$savedWpDir = 'C:\Persist\Config'
if (Test-Path $savedWpDir) {
  $pubWpDir = 'C:\Users\Public\Pictures\XyRDP'
  New-Item -ItemType Directory -Path $pubWpDir -Force -ErrorAction SilentlyContinue | Out-Null
  Get-ChildItem -Path $savedWpDir -Filter 'wallpaper.*' -File -ErrorAction SilentlyContinue | ForEach-Object {
    Copy-FileUnlocked $_.FullName (Join-Path $pubWpDir $_.Name) | Out-Null
  }
}

foreach ($userDir in $targetProfileDirs) {
  if (Test-Path (Join-Path $extDir 'User')) {
    foreach ($sub in @('Desktop', 'Documents', 'Downloads', 'Pictures', 'Videos', 'Music')) {
      $s = Join-Path $extDir "User\$sub"
      if (Test-Path $s) {
        $d = Join-Path $userDir $sub
        New-Item -ItemType Directory -Path $d -Force -ErrorAction SilentlyContinue | Out-Null
        Copy-TreeUnlocked $s $d
      }
    }
  }
  if (Test-Path (Join-Path $extDir 'Browsers\Chrome')) {
    $chDst = Join-Path $userDir 'AppData\Local\Google\Chrome\User Data'
    New-Item -ItemType Directory -Path $chDst -Force -ErrorAction SilentlyContinue | Out-Null
    Copy-TreeUnlocked (Join-Path $extDir 'Browsers\Chrome') $chDst
    Log "  Google Chrome login session restored successfully to $chDst."
  }
  if (Test-Path (Join-Path $extDir 'Browsers\Edge')) {
    $edDst = Join-Path $userDir 'AppData\Local\Microsoft\Edge\User Data'
    New-Item -ItemType Directory -Path $edDst -Force -ErrorAction SilentlyContinue | Out-Null
    Copy-TreeUnlocked (Join-Path $extDir 'Browsers\Edge') $edDst
    Log "  Microsoft Edge login session restored successfully to $edDst."
  }
  if (Test-Path (Join-Path $extDir 'Browsers\Brave')) {
    $brDst = Join-Path $userDir 'AppData\Local\BraveSoftware\Brave-Browser\User Data'
    New-Item -ItemType Directory -Path $brDst -Force -ErrorAction SilentlyContinue | Out-Null
    Copy-TreeUnlocked (Join-Path $extDir 'Browsers\Brave') $brDst
    Log "  Brave Browser login session restored successfully to $brDst."
  }
  if (Test-Path (Join-Path $extDir 'Browsers\Firefox')) {
    $ffDst = Join-Path $userDir 'AppData\Roaming\Mozilla\Firefox'
    New-Item -ItemType Directory -Path $ffDst -Force -ErrorAction SilentlyContinue | Out-Null
    Copy-TreeUnlocked (Join-Path $extDir 'Browsers\Firefox') $ffDst
    Log "  Mozilla Firefox login session restored successfully to $ffDst."
  }
  if (Test-Path (Join-Path $extDir 'DPAPI')) {
    Copy-TreeUnlocked (Join-Path $extDir 'DPAPI') $userDir
    Log "  User DPAPI encryption keys restored successfully to $userDir."
  }

  # CRITICAL: Give full ownership & FullControl to user '$u' over all restored files
  # so Chrome, Explorer & other apps can read/write Cookies, Downloads, and Desktop without Access Denied!
  try {
    & icacls $userDir /grant "${u}:(OI)(CI)F" /grant "Admthisstrators:(OI)(CI)F" /grant "SYSTEM:(OI)(CI)F" /T /C /Q 2>&1 | Out-Null
  } catch {}
}

$restoredCount = (Get-ChildItem -Path $extDir -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object).Count
Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
Log "Previous session state restored successfully! ($restoredCount files returned to profile $primaryProfDir)"
Update-Status @{ persist = @{ restored = $true; files = $restoredCount; source = $asset.name; profile = $primaryProfDir } } | Out-Null
exit 0
