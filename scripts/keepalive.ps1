# ============================================================================
#  keepalive.ps1 - Session Keepalive Guard (Anti-Disconnect & Auto-Heal)
# ----------------------------------------------------------------------------
#  1. Keeps TermService, UmRdpService, Audiosrv & listener 3389 alive
#  2. Ensures Desktop shortcuts have unique names & icons (anti-swap)
#  3. Automatically opens the SailuoRemote Dashboard on the user's first RDP login
# ============================================================================

$SailuoTag = 'Sailuo:keepalive'
. "$PSScriptRoot/lib-common.ps1"

$s   = Read-Status
$exp = if ($s -and $s.expires_utc) { [DateTime]::Parse($s.expires_utc).ToUniversalTime() } else { [DateTime]::UtcNow.AddMinutes(335) }
$addr = if ($s -and $s.connect) { $s.connect } else { '(see the Summary step)' }
$rdpUser = if ($env:RDP_USER) { $env:RDP_USER.Trim() } else { (Get-Cfg).rdp_user }

Log "ACTIVE SESSION - address: $addr | ends: $($exp.ToString('HH:mm')) UTC"
$tsExe = "$env:ProgramFiles\Tailscale\tailscale.exe"
$icoDir = Ensure-SailuoDesktopIcons

function Sync-And-Heal-DesktopShortcuts {
  try {
    $u = $rdpUser
    New-Item -ItemType Directory -Path 'C:\Persist' -Force -ErrorAction SilentlyContinue | Out-Null

    $dashExe      = 'C:\Sailuo\tools\SailuoDashboard.exe'
    $dashIco      = Join-Path $icoDir 'sailuo-dashboard.ico'
    $publicDesk   = 'C:\Users\Public\Desktop'

    $allDesks = @("C:\Users\$u\Desktop", $publicDesk) + @(Get-AllUserProfileDirs $u | ForEach-Object { Join-Path $_ 'Desktop' }) | Select-Object -Unique
    foreach ($desk in $allDesks) {
      if (-not (Test-Path $desk)) {
        New-Item -ItemType Directory -Path $desk -Force -ErrorAction SilentlyContinue | Out-Null
      }
      $wsh = New-Object -ComObject WScript.Shell

      # Remove duplicate/old shortcuts or leftovers from the runner image
      foreach ($oldItem in @('R 4.6.1.lnk')) {
        Remove-Item -LiteralPath (Join-Path $desk $oldItem) -Force -ErrorAction SilentlyContinue
      }

      # Exactly one dashboard shortcut: the shared Public desktop. Older copies
      # on user desktops made the merged desktop show the icon twice.
      Remove-Item -LiteralPath (Join-Path $desk 'SailuoRemote Dashboard.lnk') -Force -ErrorAction SilentlyContinue
      if ($desk -ne $publicDesk) {
        Remove-Item -LiteralPath (Join-Path $desk 'Sailuo Dashboard.lnk') -Force -ErrorAction SilentlyContinue
      } elseif (Test-Path $dashExe) {
        $lnkDash = Join-Path $desk 'Sailuo Dashboard.lnk'
        if (-not (Test-Path $lnkDash)) {
          $sc = $wsh.CreateShortcut($lnkDash)
          $sc.TargetPath = $dashExe
          $sc.WorkingDirectory = 'C:\Sailuo\tools'
          $sc.Description = 'Sailuo Dashboard - System Management & Tools'
          if (Test-Path $dashIco) { $sc.IconLocation = "$dashIco,0" }
          $sc.Save()
        }
      }

      # Remove the retired save/restore session shortcuts from older sessions.
      foreach ($retiredShortcut in @(
        'Permanent Folder (Anti-Reset).lnk',
        'Save Session Data Now (Cloud Save).lnk',
        'Save Session.lnk',
        'Restore Session.lnk',
        'Restore Session Data.lnk'
      )) {
        Remove-Item -LiteralPath (Join-Path $desk $retiredShortcut) -Force -ErrorAction SilentlyContinue
      }
    }
  } catch {}
}

Sync-And-Heal-DesktopShortcuts

# Drop the retired save/restore session helpers if an older setup copied them
# back. They are no longer part of Sailuo.
foreach ($retiredScript in @('persist-state.ps1', 'restore-state.ps1', 'save-snapshot.ps1', 'install-state-sync.ps1')) {
  Remove-Item -LiteralPath (Join-Path 'C:\Sailuo\scripts' $retiredScript) -Force -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath 'C:\Sailuo\tools\last-checkpoint-sig.txt' -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath 'C:\Sailuo\restore-work' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath 'C:\Sailuo\state-work' -Recurse -Force -ErrorAction SilentlyContinue

$i = 0
$dashboardAutoOpened = $false

while ([DateTime]::UtcNow -lt $exp) {
  Start-Sleep -Seconds 60
  $i++
  $rem = [int][math]::Max(0, ($exp - [DateTime]::UtcNow).TotalMinutes)

  # 1. Ensure TermService, UmRdpService, & listener :3389 are always healthy
  try {
    foreach ($svcName in @('TermService', 'UmRdpService')) {
      $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
      if ($svc -and $svc.Status -ne 'Running') {
        Start-Service -Name $svcName -ErrorAction SilentlyContinue
        Log "$svcName restarted automatically."
      }
    }
    $tsReg = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
    if ((Get-ItemPropertyValue $tsReg 'fDenyTSConnections' -ErrorAction SilentlyContinue) -ne 0) {
      Set-ItemProperty $tsReg 'fDenyTSConnections' 0 -Type DWord -Force -ErrorAction SilentlyContinue
    }
  } catch {}

  # 1b. Auto-open SailuoRemote Dashboard as soon as the user reaches the RDP Desktop for the first time!
  if (-not $dashboardAutoOpened -and (Test-Path 'C:\Sailuo\tools\SailuoDashboard.exe')) {
    try {
      $dashRunning = Get-Process -Name 'SailuoDashboard' -ErrorAction SilentlyContinue
      if ($dashRunning) {
        $dashboardAutoOpened = $true
      } else {
        # Check whether explorer.exe is running in the user's interactive RDP session
        $expProcs = @(Get-Process -Name 'explorer' -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -ge 1 })
        if ($expProcs.Count -gt 0) {
          & schtasks.exe /Create /TN "XyAutoOpenDashboard" /TR "`"C:\Sailuo\tools\SailuoDashboard.exe`"" /SC ONCE /ST 00:00 /RU $rdpUser /IT /RL HIGHEST /F 2>&1 | Out-Null
          & schtasks.exe /Run /TN "XyAutoOpenDashboard" 2>&1 | Out-Null
          $dashboardAutoOpened = $true
          Log "SailuoRemote Dashboard opened automatically in user '$rdpUser' Desktop session."
        }
      }
    } catch {}
  }

  # 1c. Auto-heal the Tailscale Tunnel every minute so the phone session does not suddenly drop when the DERP relay changes
  if (Test-Path $tsExe) {
    try {
      $tsSvc = Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
      if ($tsSvc -and $tsSvc.Status -ne 'Running') {
        Start-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
      }
      $tsRaw = & $tsExe status --json 2>$null | Out-String
      $tsObj = if ($tsRaw) { $tsRaw | ConvertFrom-Json -ErrorAction SilentlyContinue } else { $null }
      $tsState = if ($tsObj) { [string]$tsObj.BackendState } else { '' }
      if ($tsState -and $tsState -ne 'Running' -and $env:TAILSCALE_AUTH_KEY) {
        Log "Tailscale state '$tsState' detected - restoring the tunnel connection automatically..."
        $hn = if ($s -and $s.hostname) { [string]$s.hostname } else { "sailuo-$env:GITHUB_RUN_NUMBER" }
        & $tsExe up --authkey="$($env:TAILSCALE_AUTH_KEY.Trim())" --hostname=$hn --unattended --accept-routes --accept-dns=false --reset 2>&1 | Out-Null
      }
    } catch {}
  }

  # 2. Every 2 minutes: keep Desktop shortcuts intact
  if (($i % 2) -eq 0) {
    Sync-And-Heal-DesktopShortcuts
    foreach ($lu in @('xyadmin', 'runneradmin')) {
      $lSet = "C:\Users\$lu\AppData\Local\Lively Wallpaper\Settings.json"
      if (Test-Path $lSet) {
        $rawL = Get-Content -LiteralPath $lSet -Raw -ErrorAction SilentlyContinue
        if ($rawL -and $rawL -match '"RemoteDesktopPause"\s*:\s*0') {
          $rawL = $rawL -replace '"RemoteDesktopPause"\s*:\s*0', '"RemoteDesktopPause": 1'
          $rawL = $rawL -replace '"AppFocusPause"\s*:\s*0', '"AppFocusPause": 1'
          $rawL = $rawL -replace '"AppFullscreenPause"\s*:\s*0', '"AppFullscreenPause": 1'
          Set-Content -LiteralPath $lSet -Value $rawL -Encoding UTF8 -Force -ErrorAction SilentlyContinue
        }
      }
    }
  }

  # 3. Every 5 minutes: heartbeat log + Tailscale check
  if (($i % 5) -eq 0) {
    $tsIp = ''
    if (Test-Path $tsExe) {
      try { $tsIp = ((& $tsExe ip -4 2>$null) | Select-Object -First 1).Trim() } catch {}
    }
    $listen = Get-RdpListenerState 3389
    Log "heartbeat #$i | $rem minutes left | RDP=$listen | tailscale=$tsIp"
  }
}

Log 'Session time completed safely - continuing to final storage & next session handoff.'
exit 0
