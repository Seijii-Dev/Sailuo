# ============================================================================
#  optimize-storage.ps1 - XyRDP STORAGE BOOST
# ----------------------------------------------------------------------------
#  Problem: the windows-2022 runner shows "Disk C: 225 GB" but only ~70GB free
#  because the GitHub image is already full of toolcache (Android, Haskell, CodeQL,
#  Node, old Python versions, Docker, dotnet SDK, etc.) + Windows Update cache.
#
#  Solution: this script runs FIRST in the workflow (before RDP setup)
#  to free an additional 45-75 GB. Everything is BEST-EFFORT; it does not stop
#  the session on failure. Results are logged + written to out/rdp-status.json.
#
#  Cleanup targets (ordered by largest weight):
#    1) C:\hostedtoolcache  (Node/Python/Go/Ruby version cache - 8-12 GB)
#    2) C:\tools            (large binaries - 2-4 GB)
#    3) C:\Android          (Android SDK/NDK - 10-15 GB)
#    4) C:\Program Files\dotnet\sdk  (old SDKs - 3-6 GB, runtimes kept)
#    5) C:\Program Files (x86)\Microsoft SDKs + Android - 1-2 GB
#    6) C:\ProgramData\Chocolatey\lib + cache - 1-2 GB
#    7) C:\hostedtoolcache\windows\stack - Haskell Stack - 1-2 GB
#    8) Docker images/cache (if present) - 2-5 GB
#    9) Windows Update cache (SoftwareDistribution\Download) - 1-3 GB
#   10) Temp + Logs + Recycle Bin + Delivery Optimization
#
#  Note: do NOT delete C:\Windows\WinSxS with aggressive DISM on the 6-hour
#  ephemeral runner - it can break RDP/Win32. We only delete caches & SDKs
#  that are safe.
#
#  Env:
#    STORAGE_BOOST = yes/no (default yes). If "no" -> skip.
# ============================================================================

$XyTag = 'XyRDP:storage'
. "$PSScriptRoot/lib-common.ps1"

$boost = $true
if ($env:STORAGE_BOOST) {
  $e = $env:STORAGE_BOOST.Trim().ToLower()
  if (@('no','0','false','no','off','skip','none') -contains $e) { $boost = $false }
}
$cfg = Get-Cfg
if (-not $cfg.storage_boost) { $boost = $false }
# the workflow input can also disable it
if ($env:STORAGE_BOOST -eq 'no') { $boost = $false }

if (-not $boost) {
  Log 'storage boost skipped (STORAGE_BOOST=no or storage_boost=false)'
  Update-Status @{ storage = @{ boost='skip'; note='skipped per config' } } | Out-Null
  exit 0
}

Log '=== OPTIMIZE STORAGE - starting to free space ==='

function Get-FreeGB {
  try {
    $d = Get-PSDrive -Name C -ErrorAction Stop
    return [math]::Round(($d.Free / 1GB),2)
  } catch {
    try { $v = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"; return [math]::Round($v.FreeSpace/1GB,2) } catch { return -1 }
  }
}
function Get-SizeGB([string]$path) {
  # FAST: do not compute recursively (it would hang 10 minutes on C:\Android) - return 0 so Remove-Tree deletes directly
  return 0
}
function Remove-Tree([string]$path, [string]$label) {
  $normalized=[IO.Path]::GetFullPath($path).TrimEnd('\')
  $protected=@("$env:SystemRoot", "$env:SystemRoot\WinSxS", "$env:SystemRoot\Installer", "$env:SystemRoot\System32", "$env:SystemRoot\SysWOW64", "$env:SystemRoot\Microsoft.NET", "$env:SystemRoot\Temp", "$env:ProgramFiles\dotnet\shared", "$env:ProgramFiles\Tailscale", 'C:\ProgramData\RdpFree')
  foreach($safe in $protected) {
    if($normalized -ieq $safe -or ($safe -ine $env:SystemRoot -and $normalized.StartsWith($safe+'\',[StringComparison]::OrdinalIgnoreCase))) { Log "PROTECTED: $label"; return 0 }
  }

  if (-not (Test-Path $path)) { Log "  $label : does not exist -> skip"; return 0 }
  # FAST: delete directly without computing size, 90s timeout per path so it does not hang
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    # try a fast delete without takeown first (fastest)
    Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $path)) { Log "  $label : DELETED (fast)"; return 1 }
    # takeown/icacls fallback only if it still exists & time <60s
    if ($sw.Elapsed.TotalSeconds -lt 60) {
      & takeown.exe /f $path /r /d y 2>&1 | Out-Null
      & icacls.exe $path /grant '*S-1-5-32-544:F' /t /q 2>&1 | Out-Null
      Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
      if (-not (Test-Path $path)) { Log "  $label : DELETED (takeown)"; return 1 }
    }
    if ($sw.Elapsed.TotalSeconds -gt 90) { Log "  $label : SKIP 90s timeout (continuing)"; return 0 }
    # robocopy empty trick last
    if (Test-Path $path) {
      $empty = Join-Path $env:RUNNER_TEMP '_empty'
      New-Item -ItemType Directory -Path $empty -Force | Out-Null
      & robocopy $empty $path /purge /q /r:1 /w:1 2>&1 | Out-Null
      Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
    }
    $still = Test-Path $path
    if ($still) { Log "  $label : FAILED to delete (still present)" }
    else { Log "  $label : DELETED" }
    if ($still) { return 0 }; return 1
  } catch { Log "  $label : error $($_.Exception.Message)"; return 0 }
  finally { $sw.Stop() }
}

$freeBefore = Get-FreeGB
Log "  C: free before : ${freeBefore} GB"
$script:BoostStart = Get-Date
function Test-BoostTimeout { return ((Get-Date) - $script:BoostStart).TotalMinutes -gt 8 }

try {
  $vd = Get-CimInstance Win32_LogicalDisk | ForEach-Object { "$($_.DeviceID) $([math]::Round($_.Size/1GB))GB total / $([math]::Round($_.FreeSpace/1GB))GB free" }
  Log "  Disk layout : $($vd -join ' | ')"
} catch {}

$totalFreed = 0

# ---------- 1. Disable hibernation + delete hiberfil.sys (2-4 GB) ----------
try {
  & powercfg.exe /hibernate off 2>&1 | Out-Null
  if (Test-Path 'C:\hiberfil.sys') { Remove-Item 'C:\hiberfil.sys' -Force -ErrorAction SilentlyContinue }
  Log '  hibernation disabled'
} catch { Log "  hibernate off failed: $($_.Exception.Message)" }

# ---------- 2. Large toolcache ----------
$totalFreed += Remove-Tree 'C:\hostedtoolcache\windows\stack' 'Haskell Stack'
# REMOVE UNITY HUB & R (request: free up storage)
$totalFreed += Remove-Tree 'C:\Program Files\Unity Hub' 'Unity Hub'
$totalFreed += Remove-Tree 'C:\Program Files\Unity' 'Unity Editor'
$totalFreed += Remove-Tree 'C:\hostedtoolcache\windows\R' 'R language'
$totalFreed += Remove-Tree 'C:\Program Files\R' 'R Program Files'
$totalFreed += Remove-Tree 'C:\R' 'R root'
try { & winget uninstall --id Unity.UnityHub --exact --silent --accept-source-agreements 2>&1 | Out-Null } catch {}
try { & winget uninstall --id RProject.R --exact --silent 2>&1 | Out-Null } catch {}
try { & choco uninstall unityhub -y --no-progress 2>&1 | Out-Null } catch {}
try { & choco uninstall r.project -y --no-progress 2>&1 | Out-Null } catch {}
# Delete old Node/Python/Go versions except the one the runner is currently using
# We KEEP the active folder (check PATH), deleting the rest is safer
# Strategy: delete all of hostedtoolcache except the folder just used? Simpler: delete only Android & Haskell, the biggest and not needed here.
if (Test-BoostTimeout) { Log '  boost timeout 8 minutes -> skip the rest'; } else { $totalFreed += Remove-Tree 'C:\Android' 'Android SDK/NDK' }
$totalFreed += Remove-Tree 'C:\hostedtoolcache\CodeQL' 'CodeQL'
$totalFreed += Remove-Tree 'C:\hostedtoolcache\go' 'Go cache'
$totalFreed += Remove-Tree 'C:\agents' 'agents'
$totalFreed += Remove-Tree 'C:\Modules' 'Modules (az)'

# Delete old dotnet SDKs but keep the newest runtime
if (Test-BoostTimeout) { Log '  boost timeout -> skip dotnet' } else { try {
  $dotnetRoot = 'C:\Program Files\dotnet\sdk'
  if (Test-Path $dotnetRoot) {
    $sdks = Get-ChildItem $dotnetRoot -Directory | Sort-Object Name -Descending
    if ($sdks.Count -gt 1) {
      $keep = $sdks[0]
      Log "  dotnet SDK keep: $($keep.Name) - removing $($sdks.Count-1) old versions"
      foreach ($s in $sdks | Select-Object -Skip 1) {
        $totalFreed += Remove-Tree $s.FullName "dotnet SDK $($s.Name)"
      }
    } else { Log '  only 1 dotnet SDK version -> kept' }
  }
} catch { Log "  dotnet SDK cleanup failed: $($_.Exception.Message)" } }

# Docker
try {
  $docker = Get-Command docker -ErrorAction SilentlyContinue
  if ($docker) {
    Log '  Docker: prune images...'
    & docker system prune -a -f 2>&1 | Out-Null
    & docker builder prune -a -f 2>&1 | Out-Null
  }
} catch {}

# ---------- 3. Chocolatey cache ----------
$totalFreed += Remove-Tree 'C:\ProgramData\chocolatey\lib' 'Choco lib cache'
$totalFreed += Remove-Tree "$env:LOCALAPPDATA\..\chocolatey" 'Choco user cache'

# ---------- 4. NPM / pip / NuGet cache ----------
try {
  if (Get-Command npm -ErrorAction SilentlyContinue) { & npm cache clean --force 2>&1 | Out-Null; Log '  npm cache cleaned' }
  if (Get-Command pip -ErrorAction SilentlyContinue) { & pip cache purge 2>&1 | Out-Null; Log '  pip cache purged' }
  if (Get-Command dotnet -ErrorAction SilentlyContinue) { & dotnet nuget locals all --clear 2>&1 | Out-Null; Log '  nuget locals cleared' }
} catch {}

# ---------- 5. Windows Update + Temp ----------
$totalFreed += Remove-Tree 'C:\Windows\SoftwareDistribution\Download' 'Windows Update Download'
# Preserve the SYSTEM temp directory and its ACL; MSI installers need it later.
try { Get-ChildItem "$env:SystemRoot\Temp" -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue; Log '  Windows Temp cleaned without deleting the folder/ACL' } catch {}
try { if (Test-Path $env:TEMP) { Get-ChildItem $env:TEMP -Force -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue; Log '  %TEMP% cleaned' } } catch {}
try { if (Test-Path 'C:\Temp') { Remove-Tree 'C:\Temp' 'C:\Temp' | Out-Null } } catch {}
# SKIP heavy DISM/cleanmgr (it hangs 5-10 minutes on the runner) - just log
try { Log '  DISM/cleanmgr skipped (fast mode) - to avoid hanging' } catch {}
try { Clear-RecycleBin -Force -ErrorAction SilentlyContinue; Log '  RecycleBin emptied' } catch {}

# ---------- 5b. DEBLOAT - remove large built-in apps (Edge + OneDrive + Xbox etc) ----------
# Env DEBLOAT: no / light / full (default FULL when STORAGE_BOOST=yes, the user wants to remove everything)
$debloat = if ($env:DEBLOAT) { $env:DEBLOAT.Trim().ToLower() } else { 'full' }
if ($env:DEBLOAT -eq 'no' -or $env:DEBLOAT -eq '0' -or $env:DEBLOAT -eq 'false') { $debloat = 'no' }
$cfgDeb = $null
try { $cfgDeb = (Get-Cfg).PSObject.Properties['debloat'] } catch {}
if ($cfgDeb -and $null -ne $cfgDeb.Value) {
  # if rdp-extras.json has a debloat setting, use it when the input is not set explicitly
  if (-not $env:DEBLOAT) { $debloat = "$($cfgDeb.Value)".ToLower() }
}
Log "  Debloat mode: $debloat (no=skip, light=OneDrive/Xbox/Appx, full=+Edge+Unity+R+shortcuts ALL)"

if ($debloat -ne 'no') {
  # check Chrome exists before removing Edge
  $chromeExists = $false
  foreach ($cp in @('C:\Program Files\Google\Chrome\Application\chrome.exe','C:\Program Files (x86)\Google\Chrome\Application\chrome.exe')) {
    if (Test-Path $cp) { $chromeExists = $true; break }
  }
  if (-not $chromeExists) { $cc = Get-Command chrome -ErrorAction SilentlyContinue; if ($cc) { $chromeExists = $true } }

  # light: Appx bloat (IMPORTANT: do NOT remove Microsoft.XboxIdentityProvider / Microsoft.XboxTcui / GamingServices because other apps need them!)
  $bloatAppx = @(
    'Microsoft.OneDriveSync','Microsoft.XboxGamingOverlay','Microsoft.XboxSpeechToTextOverlay',
    'Microsoft.ZuneMusic','Microsoft.ZuneVideo','Microsoft.BingNews','Microsoft.BingWeather',
    'Microsoft.GetHelp','Microsoft.Getstarted','Microsoft.WindowsFeedbackHub','Microsoft.MicrosoftOfficeHub',
    'Microsoft.Office.OneNote','Microsoft.SkypeApp','Microsoft.MixedReality.Portal','Microsoft.People',
    'Microsoft.WindowsMaps','Microsoft.Microsoft3DViewer','Microsoft.Print3D','Microsoft.Wallet',
    'Microsoft.MicrosoftSolitaireCollection','Clipchamp.Clipchamp'
  )
  # full adds Edge + Office hub - REMOVE EVERYTHING (Edge is really force-deleted)
  $tryEdge = ($debloat -eq 'full')
  if ($debloat -eq 'light' -and $chromeExists) { $tryEdge = $true }
  if ($tryEdge) {
    Log "  Debloat EDGE: REMOVE $(if ($debloat -eq 'full') {'FULL force'} else {'light'}) - WebView2 kept"
    try {
      $edgePaths = @(
        'C:\Program Files (x86)\Microsoft\Edge\Application',
        'C:\Program Files\Microsoft\Edge\Application'
      )
      $edgeVer = $null
      foreach ($ep in $edgePaths) {
        if (Test-Path $ep) {
          $vers = Get-ChildItem $ep -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
          if ($vers) { $edgeVer = $vers.FullName; break }
        }
      }
      $edgeSize = 0
      if ($edgeVer) { $edgeSize = Get-SizeGB $edgeVer }
      Log "  Edge detected: $edgeVer (~${edgeSize}GB)"
      if (-not $chromeExists -and $debloat -ne 'full') {
        Log '  Chrome does NOT exist - Edge NOT deleted (so a browser remains)'
      } else {
        if (-not $chromeExists) { Log '  Chrome does not exist but FULL force - Edge will still be deleted' }
        # try winget first (cleanest)
        $wg = Get-Command winget -ErrorAction SilentlyContinue
        if ($wg) {
          Log '  Winget uninstall Edge...'
          & winget uninstall --id Microsoft.Edge --exact --silent --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
          Start-Sleep -Seconds 5
        }
        # fallback setup.exe --uninstall (Edge)
        if (Test-Path 'C:\Program Files (x86)\Microsoft\Edge\Application') {
          try {
            $setups = Get-ChildItem 'C:\Program Files (x86)\Microsoft\Edge\Application' -Recurse -Filter 'setup.exe' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -like '*Installer*setup.exe' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($setups) {
              Log "  Edge setup.exe uninstall: $($setups.FullName)"
              Start-Process -FilePath $setups.FullName -ArgumentList '--uninstall','--system-level','--verbose-logging','--force-uninstall' -Wait -ErrorAction SilentlyContinue | Out-Null
              Start-Sleep -Seconds 8
            }
          } catch { Log "  Edge setup uninstall failed: $($_.Exception.Message)" }
        }
        # check the result
        $edgeGone = -not (Test-Path 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe')
        $freedEdge = if ($edgeGone) { $edgeSize } else { 0 }
        $totalFreed += $freedEdge
        # force-delete the remathisng Edge folder COMPLETELY
        foreach ($ep2 in @('C:\Program Files (x86)\Microsoft\Edge','C:\Program Files\Microsoft\Edge','C:\Program Files (x86)\Microsoft\EdgeCore','C:\Program Files\Microsoft\EdgeCore')) { $totalFreed += Remove-Tree $ep2 "Edge folder $ep2" }
        # delete Edge shortcuts on all Desktops & StartMenu
        foreach ($sd in @('C:\Users\Public\Desktop','C:\Users\Default\Desktop',"$env:USERPROFILE\Desktop",'C:\ProgramData\Microsoft\Windows\Start Menu\Programs')) { try { Get-ChildItem $sd -Recurse -Filter '*Edge*.lnk' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue } catch {} }
        try { Get-ChildItem 'C:\Users' -Recurse -Filter '*Edge*.lnk' -ErrorAction SilentlyContinue -Depth 3 | Where-Object { $_.Name -like '*Edge*' } | Remove-Item -Force -ErrorAction SilentlyContinue } catch {}
        $edgeGone = -not (Test-Path 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe')
        $freedEdge = if ($edgeGone) { 1 } else { 0 }
        $totalFreed += $freedEdge
        Log "  Edge: $(if ($edgeGone) { 'successfully deleted COMPLETELY' } else { 'FAILED - remathisng folder force-deleted' })"
        if (-not (Test-Path 'C:\Program Files (x86)\Microsoft\EdgeWebView\Application\msedgewebview2.exe')) {
          Log '  WebView2 is missing - install WebView2 Runtime'
          try { & winget install --id Microsoft.EdgeWebView2Runtime --exact --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null } catch {}
        }
      }
    } catch { Log "  Debloat Edge error: $($_.Exception.Message)" }
  } else {
    Log '  LIGHT debloat: Edge kept (Chrome is missing). Use full to remove Edge completely.'
  }

  # remove Appx for light & full
  $removedAppx = 0
  foreach ($pat in $bloatAppx) {
    try {
      $pkgs = Get-AppxPackage -Name $pat -ErrorAction SilentlyContinue
      foreach ($pkg in $pkgs) {
        try {
          Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction SilentlyContinue | Out-Null
          Log "  Appx removed: $($pkg.Name) ($($pkg.PackageFullName))"
          $removedAppx++
        } catch {}
      }
      $prov = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $pat }
      foreach ($pr in $prov) {
        try { Remove-AppxProvisionedPackage -Online -PackageName $pr.PackageName -ErrorAction SilentlyContinue | Out-Null; Log "  Provisioned removed: $($pr.DisplayName)" } catch {}
      }
    } catch {}
  }
  # OneDrive standalone (not Appx)
  try {
    if (Get-Process OneDrive -ErrorAction SilentlyContinue) { Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2 }
    $odSetup = @('C:\Windows\System32\OneDriveSetup.exe','C:\Windows\SysWOW64\OneDriveSetup.exe')
    foreach ($od in $odSetup) {
      if (Test-Path $od) { Start-Process $od -ArgumentList '/uninstall' -Wait -ErrorAction SilentlyContinue | Out-Null; Log "  OneDrive uninstall: $od"; break }
    }
    $totalFreed += Remove-Tree "$env:USERPROFILE\OneDrive" 'OneDrive user folder'
    $totalFreed += Remove-Tree 'C:\OneDriveTemp' 'OneDriveTemp'
  } catch { Log "  OneDrive uninstall error: $($_.Exception.Message)" }
  Log "  Debloat Appx complete: $removedAppx packages removed"
  # ---------- 5c. REMOVE shortcuts & leftovers of Unity, RGui, Edge, OneDrive, Xbox (WITHOUT touching user app shortcuts!) ----------
  if ($debloat -eq 'full') {
    Log '  FULL debloat: removing Unity/RGui/Edge/OneDrive shortcuts & leftovers...'
    $shortcuts = @(
      'C:\Users\Public\Desktop\Unity*.lnk','C:\Users\Public\Desktop\R x64*.lnk','C:\Users\Public\Desktop\R i386*.lnk','C:\Users\Public\Desktop\RGui*.lnk','C:\Users\Public\Desktop\*Edge*.lnk','C:\Users\Public\Desktop\*OneDrive*.lnk','C:\Users\Public\Desktop\*Xbox*.lnk',
      'C:\Users\Default\Desktop\Unity*.lnk','C:\Users\Default\Desktop\R x64*.lnk','C:\Users\Default\Desktop\*Edge*.lnk',
      'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Unity*','C:\ProgramData\Microsoft\Windows\Start Menu\Programs\R','C:\ProgramData\Microsoft\Windows\Start Menu\Programs\*Edge*','C:\ProgramData\Microsoft\Windows\Start Menu\Programs\*OneDrive*','C:\ProgramData\Microsoft\Windows\Start Menu\Programs\*Xbox*'
    )
    foreach ($sc in $shortcuts) { try { Remove-Item $sc -Recurse -Force -ErrorAction SilentlyContinue } catch {} }
    # Unity & R leftover registry & folders (already Remove-Tree above, add AppData again)
    foreach ($ud in @("$env:APPDATA\Unity", "$env:LOCALAPPDATA\Unity", "$env:USERPROFILE\.R", "C:\Users\Default\.R")) { try { if (Test-Path $ud) { Remove-Item $ud -Recurse -Force -ErrorAction SilentlyContinue; Log "  leftover $ud removed" } } catch {} }
    # OneDrive & Xbox leftovers
    foreach ($od2 in @('C:\Program Files\Microsoft OneDrive','C:\Windows\System32\OneDriveSetup.exe')) { try { if (Test-Path $od2) { Remove-Item $od2 -Recurse -Force -ErrorAction SilentlyContinue } } catch {} }
    # Clean the Delivery Optimization cache (1-2GB)
    try { & net stop DoSvc /y 2>&1 | Out-Null; Remove-Item 'C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache\*' -Recurse -Force -ErrorAction SilentlyContinue; & net start DoSvc 2>&1 | Out-Null; Log '  DeliveryOptimization cache cleaned' } catch {}
    # Extra disk relief: remove Help, F# tools, gh cache
    foreach ($extra in @('C:\Program Files\dotnet\sdk-manifests','C:\hostedtoolcache\windows\stack','C:\tools','C:\vcpkg','C:\gh','C:\Program Files\Git\mingw64\share\doc')) {
      if (Test-Path $extra) { try { $totalFreed += Remove-Tree $extra "extra $extra" } catch {} }
    }
    Log '  Full debloat attempt complete. Locked files may remain; see the verification result for each target.'
  }
} else {
  Log '  Debloat skipped (DEBLOAT=no)'
}

# ---------- 6. Temporarily disable the pagefile? NO - RDP needs the pagefile.
# But we can move the pagefile to D: if D: exists & has more free space
try {
  $dFree = Get-FreeGB
  # check D:
  $dDrive = Get-PSDrive -Name D -ErrorAction SilentlyContinue
  if ($dDrive) {
    $dF = [math]::Round($dDrive.Free/1GB,2)
    Log "  Drive D: ${dF}GB free"
    New-Item -ItemType Directory -Path 'D:\Games' -Force | Out-Null
  }
} catch {}

# ---------- 7. Compact OS (saves ~2-3 GB, without deleting files) ----------
try {
  $compactStat = & compact.exe /CompactOS:query 2>&1 | Out-String
  Log "  CompactOS status: $(Log-Tail $compactStat 1)"
  # Do not force compact if already compacted - a query is enough
} catch {}

$freeAfter = Get-FreeGB
$freedNow = [math]::Round($freeAfter - $freeBefore,2)
Log "  C: free after : ${freeAfter} GB (real +${freedNow} GB gain)"
Log "  Target folders successfully removed: $totalFreed (not a GB size). Actual space change: ${freedNow} GB."

# Save storage info to status so the dashboard / guide can display it
try {
  $drives = @()
  foreach ($letter in @('C','D')) {
    try {
      $ld = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$letter`:'"
      if ($ld) { $drives += @{ letter=$letter; size_gb=[math]::Round($ld.Size/1GB,2); free_gb=[math]::Round($ld.FreeSpace/1GB,2); used_gb=[math]::Round(($ld.Size-$ld.FreeSpace)/1GB,2) } }
    } catch {}
  }
  Update-Status @{ storage = [ordered]@{
    boost='ok'; before_gb=$freeBefore; after_gb=$freeAfter; gained_gb=$freedNow; removed_targets=$totalFreed
    drives=$drives
    note='Cleanup complete. gained_gb is the actual space change, not a promised capacity. Locked targets may remain.'
  } } | Out-Null
} catch { Log "  failed to write storage status: $($_.Exception.Message)" }

Log "DONE - Storage boost: ${freeBefore}GB -> ${freeAfter}GB (+${freedNow}GB)"
exit 0
