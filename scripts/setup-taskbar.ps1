# ============================================================================
#  setup-taskbar.ps1 - OS26 Liquid Glass "Clear Taskbar" theme
# ----------------------------------------------------------------------------
#  Installs Windhawk when missing, installs or repairs the "Windows 11 Taskbar
#  Styler" mod from mods.windhawk.net and selects the clear-taskbar variant of
#  the OS26 Liquid Glass theme:
#
#      OS26_Liquid_Glass_variant_ClearTaskbar
#
#  The script is idempotent and best-effort: when everything is already in
#  place it only re-applies the registry settings, so it is safe to call from
#  setup-win10.ps1, setup-tools-hub.ps1 and the dashboard.
#
#  The Windows 11 taskbar does not exist on Windows Server 2022 / build 20348,
#  so older systems are skipped with a clear status entry.
#
#  Usage:
#      powershell -NoProfile -ExecutionPolicy Bypass -File setup-taskbar.ps1
#      powershell ... -File setup-taskbar.ps1 -Force
# ============================================================================
param(
  [string]$Theme = 'OS26_Liquid_Glass_variant_ClearTaskbar',
  [switch]$Force
)

$SailuoTag = 'Sailuo:taskbar'
. "$PSScriptRoot/lib-common.ps1"

$modId          = 'windows-11-taskbar-styler'
$modsRoot       = 'https://mods.windhawk.net/mods'
$catalogUrl     = 'https://mods.windhawk.net/catalog.json'
$installerUrl   = 'https://github.com/ramensoftware/windhawk/releases/latest/download/windhawk_setup.exe'
$windhawkExe    = 'C:\Program Files\Windhawk\windhawk.exe'
$windhawkData   = 'C:\ProgramData\Windhawk'
$engineMods     = Join-Path $windhawkData 'Engine\Mods'
$sourceDir      = Join-Path $windhawkData 'ModsSource'
$profilePath    = Join-Path $windhawkData 'userprofile.json'
$regBase        = "HKLM\SOFTWARE\Windhawk\Engine\Mods\$modId"
$regSettings    = "$regBase\Settings"

function Write-TaskbarStatus([string]$State, [string]$Note, [string]$Version) {
  Update-Status @{ taskbar = [ordered]@{
      theme       = $Theme
      mod         = $modId
      version     = $Version
      windhawk    = $(try { (Get-Item $windhawkExe).VersionInfo.ProductVersion } catch { '' })
      status      = $State
      note        = $Note
      updated_utc = (Get-SailuoUtcNowText)
  } } | Out-Null
}

# ---------- 0. platform check ----------
$build = 0
try { $build = [int](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).BuildNumber }
catch { try { $build = [Environment]::OSVersion.Version.Build } catch {} }

if ($build -lt 22000) {
  Log "Windows 11 taskbar not detected (build $build) - the taskbar theme is not supported here."
  Write-TaskbarStatus 'skip' "Requires Windows 11 build 22000 or newer; this host is build $build." ''
  exit 0
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Log 'Administrator rights are required to install/configure Windhawk - skipping the taskbar theme.'
  Write-TaskbarStatus 'skip' 'Run the setup as administrator to install Windhawk.' ''
  exit 1
}

Log "configuring the OS26 Liquid Glass taskbar theme (build $build)..."

# ---------- 1. Windhawk ----------
if (-not (Test-Path $windhawkExe)) {
  Log 'Windhawk is not installed - downloading the installer...'
  $installer = Join-Path $env:TEMP ('windhawk_setup_' + [guid]::NewGuid().ToString('N') + '.exe')
  if (-not (Get-File $installerUrl $installer 300)) {
    Log 'Windhawk installer download failed.'
    Write-TaskbarStatus 'failed' 'Could not download the Windhawk installer.' ''
    exit 1
  }
  try {
    $proc = Start-Process -FilePath $installer -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-' -Wait -PassThru
    Log "Windhawk installer finished with exit code $($proc.ExitCode)."
  } catch {
    Log "Windhawk installer failed: $($_.Exception.Message)"
  } finally {
    Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
  }
  for ($i = 0; $i -lt 15 -and -not (Test-Path $windhawkExe); $i++) { Start-Sleep -Seconds 2 }
}

if (-not (Test-Path $windhawkExe)) {
  Log 'Windhawk is still missing after the install attempt.'
  Write-TaskbarStatus 'failed' 'Windhawk could not be installed.' ''
  exit 1
}

$svc = Get-Service -Name 'Windhawk' -ErrorAction SilentlyContinue
if (-not $svc) {
  for ($i = 0; $i -lt 10 -and -not $svc; $i++) { Start-Sleep -Seconds 2; $svc = Get-Service -Name 'Windhawk' -ErrorAction SilentlyContinue }
}
if ($svc) {
  if ($svc.Status -ne 'Running') {
    try { Start-Service -Name 'Windhawk' -ErrorAction Stop; Log 'Windhawk service started.' }
    catch { Log "Could not start the Windhawk service: $($_.Exception.Message)" }
  }
} else {
  Log 'Windhawk service was not found - the mod can still be configured for the next start.'
}

# ---------- 2. mod version ----------
$version = '1.11'
$catalogTmp = Join-Path $env:TEMP ('sailuo-windhawk-catalog-' + [guid]::NewGuid().ToString('N') + '.json')
if (Get-File $catalogUrl $catalogTmp 30) {
  try {
    $catalog = Get-Content -LiteralPath $catalogTmp -Raw | ConvertFrom-Json
    $entry = $catalog.mods.$modId
    if ($entry -and $entry.metadata -and $entry.metadata.version) { $version = [string]$entry.metadata.version }
  } catch {
    Log "  catalog read warning: $($_.Exception.Message)"
  }
}
Remove-Item -LiteralPath $catalogTmp -Force -ErrorAction SilentlyContinue
Log "  latest $modId version: $version"

# ---------- 3. install/repair the compiled mod ----------
$previousTheme = Get-Reg $regSettings 'theme'
$previousDisabled = Get-Reg $regBase 'Disabled'
$previousLibrary = Get-Reg $regBase 'LibraryFileName'
$previousVersion = Get-Reg $regBase 'Version'
$themeChanged = "$previousTheme" -ne $Theme
$wasDisabled = ($null -ne $previousDisabled -and [int]$previousDisabled -ne 0)

$folderCandidates = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { @('arm64', '64') } else { @('64') }
$installedNow = $false
$modFolder = '64'
$libName = $previousLibrary

$needsInstall = $Force -or -not $previousLibrary -or -not $previousVersion -or ("$previousVersion" -ne $version)
if (-not $needsInstall) {
  $existing = $null
  foreach ($folder in $folderCandidates) {
    $candidate = Join-Path (Join-Path $engineMods $folder) $previousLibrary
    if (Test-Path $candidate) { $modFolder = $folder; $existing = $candidate; break }
  }
  if (-not $existing) { $needsInstall = $true }
}

if ($needsInstall) {
  $tempDll = Join-Path $env:TEMP ('sailuo-taskbar-' + [guid]::NewGuid().ToString('N') + '.dll')
  $downloaded = $false
  foreach ($folder in $folderCandidates) {
    $url = "$modsRoot/$modId/${version}_$folder.dll"
    Log "  downloading $url"
    if ((Get-File $url $tempDll 180) -and (Test-Path $tempDll) -and ((Get-Item $tempDll).Length -gt 10000)) {
      $modFolder = $folder
      $downloaded = $true
      break
    }
  }

  if (-not $downloaded) {
    Log 'Could not download the compiled taskbar-styler mod.'
    Write-TaskbarStatus 'failed' 'The Windows 11 Taskbar Styler download failed.' $version
    exit 1
  }

  try {
    $modDir = Join-Path $engineMods $modFolder
    New-Item -ItemType Directory -Path $modDir -Force | Out-Null
    $libName = '{0}_{1}_{2}.dll' -f $modId, $version, (Get-Random -Minimum 100000 -Maximum 999999)
    Copy-Item -LiteralPath $tempDll -Destination (Join-Path $modDir $libName) -Force -ErrorAction Stop
    $installedNow = $true
    Log "  installed $libName"

    # Older versions are removed once they are no longer loaded by Explorer.
    Get-ChildItem -LiteralPath $modDir -Filter "$modId`_*.dll" -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -ne $libName } |
      ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop } catch {} }

    $tempSource = Join-Path $env:TEMP ('sailuo-taskbar-' + [guid]::NewGuid().ToString('N') + '.wh.cpp')
    if (Get-File "$modsRoot/$modId/$version.wh.cpp" $tempSource 180) {
      New-Item -ItemType Directory -Path $sourceDir -Force | Out-Null
      Copy-Item -LiteralPath $tempSource -Destination (Join-Path $sourceDir ($modId + '.wh.cpp')) -Force -ErrorAction SilentlyContinue
    } else {
      Log '  mod source download skipped - the compiled mod still works.'
    }
    Remove-Item -LiteralPath $tempSource -Force -ErrorAction SilentlyContinue
  } catch {
    Log "Could not install the compiled mod: $($_.Exception.Message)"
    Write-TaskbarStatus 'failed' 'The compiled mod could not be copied into the Windhawk engine folder.' $version
    exit 1
  } finally {
    Remove-Item -LiteralPath $tempDll -Force -ErrorAction SilentlyContinue
  }
} else {
  Log "  $modId $previousVersion is already installed."
}

# ---------- 4. registry configuration ----------
# Windhawk stores the mod's declared architecture here even when the compiled
# DLL lives in the arm64 folder on ARM64 Windows.
$archLabel = 'x86-64'
Set-Reg $regBase 'LibraryFileName' $libName 'String' | Out-Null
Set-Reg $regBase 'Disabled' 0 'DWord' | Out-Null
Set-Reg $regBase 'Include' 'explorer.exe' 'String' | Out-Null
Set-Reg $regBase 'Exclude' '' 'String' | Out-Null
Set-Reg $regBase 'Architecture' $archLabel 'String' | Out-Null
Set-Reg $regBase 'Version' $version 'String' | Out-Null
Set-Reg $regSettings 'theme' $Theme 'String' | Out-Null
$stamp = [int]([DateTime]::UtcNow - [datetime]'1970-01-01').TotalSeconds
Set-Reg $regBase 'SettingsChangeTime' $stamp 'DWord' | Out-Null

# Keep the Windhawk UI's installed-version metadata in sync.
try {
  if (-not (Test-Path $profilePath)) {
    @{ app = @{}; mods = @{}; os = "$build" } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $profilePath -Encoding UTF8 -Force
  }
  $profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
  if (-not $profile.PSObject.Properties['mods']) {
    $profile | Add-Member -NotePropertyName mods -NotePropertyValue ([pscustomobject]@{}) -Force
  }
  $modEntry = $profile.mods.$modId
  if (-not $modEntry) {
    $profile.mods | Add-Member -NotePropertyName $modId -NotePropertyValue ([pscustomobject]@{}) -Force
    $modEntry = $profile.mods.$modId
  }
  $modEntry | Add-Member -NotePropertyName version -NotePropertyValue $version -Force
  ($profile | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $profilePath -Encoding UTF8 -Force
} catch {
  Log "  userprofile.json warning: $($_.Exception.Message)"
}

# ---------- 5. reload ----------
function Test-ModLoaded {
  foreach ($proc in @(Get-Process -Name 'explorer' -ErrorAction SilentlyContinue)) {
    try {
      if ($proc.Modules | Where-Object { $_.ModuleName -eq $libName }) { return $true }
    } catch { }
  }
  return $false
}

$modLoaded = Test-ModLoaded
if ($installedNow -or $themeChanged -or $wasDisabled -or $Force -or -not $modLoaded) {
  if ($installedNow -or $themeChanged -or $wasDisabled -or $Force) {
    try {
      Start-Process -FilePath $windhawkExe -ArgumentList '-restart-bg' -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
      Start-Sleep -Seconds 2
    } catch { }
    $modLoaded = Test-ModLoaded
  }

  # Restart Explorer only when the configured DLL is not injected yet. This also
  # covers a version upgrade, where the old DLL name stays loaded until restart.
  if (-not $modLoaded) {
    $explorers = @(Get-Process -Name 'explorer' -ErrorAction SilentlyContinue)
    if ($explorers.Count -gt 0) {
      Log '  restarting Explorer so the taskbar theme can load...'
      foreach ($proc in $explorers) {
        try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch { }
      }
      Start-Sleep -Seconds 4
    }
  }
}

# A version upgrade can leave the previous DLL behind while Explorer still has it
# loaded. Retry the cleanup once the mod has been reloaded.
$modFolderPath = Join-Path $engineMods $modFolder
if (Test-Path $modFolderPath) {
  Get-ChildItem -LiteralPath $modFolderPath -Filter "$modId`_*.dll" -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne $libName } |
    ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop } catch {} }
}

$applied = Get-Reg $regSettings 'theme'
if ("$applied" -ne $Theme) {
  Log "Taskbar theme could not be confirmed (registry reports '$applied')."
  Write-TaskbarStatus 'failed' 'The theme setting could not be written to the Windhawk configuration.' $version
  exit 1
}

Log "SELESAI - OS26 Liquid Glass clear taskbar is configured (mod $version)."
Write-TaskbarStatus 'ok' "Theme '$Theme' is selected in Windhawk." $version
exit 0
