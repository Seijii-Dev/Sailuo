# ============================================================================
#  keepalive.ps1 - Session Keepalive Guard (Anti-Disconnect & Auto-Heal)
# ----------------------------------------------------------------------------
#  1. Keeps TermService, UmRdpService, Audiosrv & listener 3389 alive
#  2. Ensures Desktop shortcuts have unique names & icons (anti-swap)
#  3. Automatically opens the XyDeskRemote Dashboard on the user's first RDP login
#  4. Runs a cross-session Auto-Checkpoint every 4 minutes to GitHub Release
#     so Google logins and files in Downloads and Desktop stay safe
#     even if the runner is forcibly stopped at any time.
# ============================================================================

$XyTag = 'XyRDP:keepalive'
. "$PSScriptRoot/lib-common.ps1"

$s   = Read-Status
$exp = if ($s -and $s.expires_utc) { [DateTime]::Parse($s.expires_utc).ToUniversalTime() } else { [DateTime]::UtcNow.AddMinutes(335) }
$addr = if ($s -and $s.connect) { $s.connect } else { '(see the Summary step)' }
$rdpUser = if ($env:RDP_USER) { $env:RDP_USER.Trim() } else { (Get-Cfg).rdp_user }

Log "ACTIVE SESSION - address: $addr | ends: $($exp.ToString('HH:mm')) UTC"
$tsExe = "$env:ProgramFiles\Tailscale\tailscale.exe"
$icoDir = Ensure-XyDesktopIcons

function Sync-And-Heal-DesktopShortcuts {
  try {
    $u = $rdpUser
    New-Item -ItemType Directory -Path 'C:\Persist' -Force -ErrorAction SilentlyContinue | Out-Null

    $dashExe      = 'C:\XyRDP\tools\XyDeskDashboard.exe'
    $dashIco      = Join-Path $icoDir 'xydesk-dashboard.ico'
    $persistIco   = Join-Path $icoDir 'persist-folder.ico'
    $cloudSaveIco = Join-Path $icoDir 'cloud-save.ico'
    $persistPs1   = Join-Path $PSScriptRoot 'persist-state.ps1'

    $allDesks = @("C:\Users\$u\Desktop", "C:\Users\Public\Desktop") + @(Get-AllUserProfileDirs $u | ForEach-Object { Join-Path $_ 'Desktop' }) | Select-Object -Unique
    foreach ($desk in $allDesks) {
      if (-not (Test-Path $desk)) {
        New-Item -ItemType Directory -Path $desk -Force -ErrorAction SilentlyContinue | Out-Null
      }
      $wsh = New-Object -ComObject WScript.Shell

      # Remove duplicate/old shortcuts or leftovers from the runner image
      foreach ($oldItem in @('R 4.6.1.lnk')) {
        Remove-Item -LiteralPath (Join-Path $desk $oldItem) -Force -ErrorAction SilentlyContinue
      }

      # 1. XyDeskRemote Dashboard shortcut (blue-cyan 'XY DASHBOARD' icon)
      if (Test-Path $dashExe) {
        $lnkDash = Join-Path $desk 'XyDeskRemote Dashboard.lnk'
        if (-not (Test-Path $lnkDash)) {
          $sc = $wsh.CreateShortcut($lnkDash)
          $sc.TargetPath = $dashExe
          $sc.WorkingDirectory = 'C:\XyRDP\tools'
          $sc.Description = 'XyDeskRemote Dashboard - System Management & Cloud Save Hub'
          if (Test-Path $dashIco) { $sc.IconLocation = "$dashIco,0" }
          $sc.Save()
        }
      }

      # 2. Permanent Folder (C:\Persist) shortcut (gold 'DIR PERSIST' icon)
      $lnkPersist = Join-Path $desk 'Permanent Folder (Anti-Reset).lnk'
      if (-not (Test-Path $lnkPersist)) {
        $sc2 = $wsh.CreateShortcut($lnkPersist)
        $sc2.TargetPath = 'C:\Persist'
        $sc2.Description = 'Every file in this folder is saved automatically to the next RDP session'
        if (Test-Path $persistIco) { $sc2.IconLocation = "$persistIco,0" }
        else { $sc2.IconLocation = 'shell32.dll,43' }
        $sc2.Save()
      }

      # 3. Save Session Data Now (Cloud Save) shortcut (sky-blue 'CLD SAVE' icon)
      if (Test-Path $persistPs1) {
        $lnkSave = Join-Path $desk 'Save Session Data Now (Cloud Save).lnk'
        if (-not (Test-Path $lnkSave)) {
          $sc3 = $wsh.CreateShortcut($lnkSave)
          $sc3.TargetPath = 'powershell.exe'
          $sc3.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$persistPs1`" -Checkpoint"
          $sc3.WorkingDirectory = 'C:\XyRDP\scripts'
          $sc3.Description = 'Instant backup of Browser Logins (Chrome/Edge), Downloads & Desktop to the Cloud'
          if (Test-Path $cloudSaveIco) { $sc3.IconLocation = "$cloudSaveIco,0" }
          else { $sc3.IconLocation = 'shell32.dll,167' }
          $sc3.Save()
        }
      }
    }
  } catch {}
}

Sync-And-Heal-DesktopShortcuts

$i = 0
# Set $lastCheckpointUtc back 2 minutes so the first checkpoint runs at minute 2 after the session becomes active!
$lastCheckpointUtc = [DateTime]::UtcNow.AddMinutes(-2)
$checkpointJob = $null
$dashboardAutoOpened = $false

while ([DateTime]::UtcNow -lt $exp) {
  Start-Sleep -Seconds 60
  $i++
  $now = [DateTime]::UtcNow
  $rem = [int][math]::Max(0, ($exp - $now).TotalMinutes)

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

  # 1b. Auto-open XyDeskRemote Dashboard as soon as the user reaches the RDP Desktop for the first time!
  if (-not $dashboardAutoOpened -and (Test-Path 'C:\XyRDP\tools\XyDeskDashboard.exe')) {
    try {
      $dashRunning = Get-Process -Name 'XyDeskDashboard' -ErrorAction SilentlyContinue
      if ($dashRunning) {
        $dashboardAutoOpened = $true
      } else {
        # Check whether explorer.exe is running in the user's interactive RDP session
        $expProcs = @(Get-Process -Name 'explorer' -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -ge 1 })
        if ($expProcs.Count -gt 0) {
          & schtasks.exe /Create /TN "XyAutoOpenDashboard" /TR "`"C:\XyRDP\tools\XyDeskDashboard.exe`"" /SC ONCE /ST 00:00 /RU $rdpUser /IT /RL HIGHEST /F 2>&1 | Out-Null
          & schtasks.exe /Run /TN "XyAutoOpenDashboard" 2>&1 | Out-Null
          $dashboardAutoOpened = $true
          Log "XyDeskRemote Dashboard opened automatically in user '$rdpUser' Desktop session."
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
        $hn = if ($s -and $s.hostname) { [string]$s.hostname } else { "xyrdp-$env:GITHUB_RUN_NUMBER" }
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

  # 4. Every 4 minutes: run the cross-session Auto-Checkpoint in the background (non-blocking) to Release 'xyrdp-state-latest'
  if (($now - $lastCheckpointUtc).TotalMinutes -ge 4 -and $rem -gt 2) {
    $canRun = $true
    if ($checkpointJob) {
      if ($checkpointJob.State -eq 'Running') {
        $canRun = $false
      } else {
        Remove-Job -Job $checkpointJob -Force -ErrorAction SilentlyContinue
        $checkpointJob = $null
      }
    }
    if ($canRun) {
      $lastCheckpointUtc = $now
      try {
        Log 'Running the 4-minute auto-checkpoint in the background (persist-state.ps1 -Checkpoint)...'
        $persistPath = Join-Path $PSScriptRoot 'persist-state.ps1'
        $checkpointJob = Start-Job -ScriptBlock {
          param($p, $tok, $repo, $usr, $pwd)
          try { [System.Threading.Thread]::CurrentThread.Priority = [System.Threading.ThreadPriority]::Lowest } catch {}
          if ($tok)  { $env:GITHUB_TOKEN      = $tok }
          if ($repo) { $env:GITHUB_REPOSITORY = $repo }
          if ($usr)  { $env:RDP_USER          = $usr }
          if ($pwd)  { $env:RDP_PASSWORD      = $pwd }
          & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p -Checkpoint 2>&1 | Out-Null
        } -ArgumentList $persistPath, $env:GITHUB_TOKEN, $env:GITHUB_REPOSITORY, $env:RDP_USER, $env:RDP_PASSWORD
      } catch {
        Log "Auto-checkpoint warning: $($_.Exception.Message)"
      }
    }
  }
}

if ($checkpointJob) {
  try { Wait-Job -Job $checkpointJob -Timeout 25 | Out-Null } catch {}
  Remove-Job -Job $checkpointJob -Force -ErrorAction SilentlyContinue
}

Log 'Session time completed safely - continuing to final storage & next session handoff.'
exit 0
