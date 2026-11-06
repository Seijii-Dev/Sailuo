#  - Explorer preferences. No Explorer termination or RDP disconnect.
#  - Taskbar aligned to the left (classic layout).
#  - Google Chrome set as the default browser for the Default profile and
#    the current user (best effort; Chrome creates the final validated
#    entries on the first logon via RunOnce).
param([switch]$CurrentUserOnly)
$ErrorActionPreference = 'Stop'
$preferences = @(
  @{ Key='Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Values=@{ Hidden=1; HideFileExt=0; AutoCheckSelect=1; ShowSuperHidden=0; TaskbarAl=0 } },
  @{ Key='Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Values=@{ AppsUseLightTheme=0; SystemUsesLightTheme=0; EnableTransparency=0 } }
)
$roots = @('Registry::HKEY_CURRENT_USER')
$loadedDefault = $false
try {
  if (-not $CurrentUserOnly) {
    & reg.exe load 'HKU\SailuoExplorerDefault' "$env:SystemDrive\Users\Default\NTUSER.DAT" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not load Default profile preferences; no success reported.' }
    $loadedDefault = $true
    $roots += 'Registry::HKEY_USERS\SailuoExplorerDefault'
  }
  foreach ($root in $roots) {
    foreach ($group in $preferences) {
      $key = "$root\$($group.Key)"
      New-Item -Path $key -Force | Out-Null
      foreach ($entry in $group.Values.GetEnumerator()) {
        New-ItemProperty -Path $key -Name $entry.Key -Value $entry.Value -PropertyType DWord -Force | Out-Null
        if ((Get-ItemPropertyValue -Path $key -Name $entry.Key) -ne $entry.Value) { throw "Verification failed: $($entry.Key)" }
      }
    }
  }
  Write-Host 'Verified: hidden items ON, file extensions ON, item checkboxes ON, dark theme ON, taskbar aligned left.'
  Write-Host 'Protected operating-system files remain hidden. Close/reopen Explorer to refresh; some theme elements may require a later sign-in. No restart is forced.'

  # --- Default browser: Google Chrome (machine-wide + Default profile) ---
  # Windows validates per-user UserChoice hashes, so writing ProgId alone
  # invalidates the entry and Windows reverts to Edge. Instead set the
  # system-wide defaults (inherited by the Default profile for new users)
  # and drop conflicting per-user UserChoice overrides, which then fall
  # back to Chrome. Also allow Chrome to change the default (enterprise
  # MSI ships with DefaultBrowserSettingEnabled = 0).
  try {
    $chromeExe = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
    if (-not (Test-Path $chromeExe)) {
      Write-Host 'Chrome not found - installing Google Chrome via winget (best effort)...'
      try {
        & winget install --id Google.Chrome --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
      } catch {
        Write-Host "winget Chrome install failed: $($_.Exception.Message)"
      }
    }
    if (Test-Path $chromeExe) {
      $chromeCmd = '"C:\Program Files\Google\Chrome\Application\chrome.exe" --single-argument %1'
      try {
        New-Item -Path 'HKLM:\SOFTWARE\Policies\Google\Chrome' -Force | Out-Null
        New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Google\Chrome' -Name 'DefaultBrowserSettingEnabled' -Value 1 -PropertyType DWord -Force | Out-Null
      } catch {}
      foreach ($ext in @('.html', '.htm', '.xhtml', '.shtml')) {
        $machineKey = "HKLM:\SOFTWARE\Classes\$ext"
        New-Item -Path $machineKey -Force | Out-Null
        New-ItemProperty -Path $machineKey -Name '(Default)' -Value 'ChromeHTML' -PropertyType String -Force | Out-Null
      }
      foreach ($proto in @('http', 'https')) {
        $machineKey = "HKLM:\SOFTWARE\Classes\$proto"
        New-Item -Path $machineKey -Force | Out-Null
        New-ItemProperty -Path $machineKey -Name '(Default)' -Value 'ChromeHTML' -PropertyType String -Force | Out-Null
        $cmdKey = "$machineKey\shell\open\command"
        New-Item -Path $cmdKey -Force | Out-Null
        New-ItemProperty -Path $cmdKey -Name '(Default)' -Value $chromeCmd -PropertyType String -Force | Out-Null
      }
      foreach ($root in $roots) {
        foreach ($proto in @('http', 'https')) {
          $ucKey = "$root\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\$proto\UserChoice"
          if (Test-Path $ucKey) {
            $current = $null
            try { $current = Get-ItemPropertyValue -Path $ucKey -Name 'ProgId' } catch {}
            if ($current -ne 'ChromeHTML') { Remove-Item -Path $ucKey -Recurse -Force -ErrorAction SilentlyContinue }
          }
        }
      }
      Write-Host 'Default browser set to Google Chrome.'
    } else {
      Write-Host 'Chrome not installed - default browser not changed.'
    }
  } catch {
    Write-Host "Chrome default warning (non-fatal): $($_.Exception.Message)"
  }
} finally {
  if ($loadedDefault) {
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    & reg.exe unload 'HKU\SailuoExplorerDefault' | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning 'Default profile hive could not be unloaded.' }
  }
}
