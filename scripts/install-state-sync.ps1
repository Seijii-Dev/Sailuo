# ============================================================================
#  install-state-sync.ps1 - Register / repair the 4-minute cloud auto-save
# ----------------------------------------------------------------------------
#  Creates the scheduled task "Sailuo Cloud Save" which runs
#      persist-state.ps1 -Checkpoint
#  every 4 minutes in the signed-in desktop session.
#
#  Re-running this script repairs a missing, disabled or broken task, so it is
#  safe to call from setup-tools-hub.ps1 and from the dashboard.
#
#  Usage:
#      powershell -NoProfile -ExecutionPolicy Bypass -File install-state-sync.ps1 [-Quiet]
# ============================================================================
param(
  [switch]$Quiet
)

$SailuoTag = 'Sailuo:state-sync'
. "$PSScriptRoot/lib-common.ps1"

$taskName = 'Sailuo Cloud Save'
$persist  = Join-Path $PSScriptRoot 'persist-state.ps1'
$libFile  = Join-Path $PSScriptRoot 'lib-common.ps1'
$psExe    = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Say([string]$m) {
  if (-not $Quiet) { Log $m }
}

if (-not (Test-Path $persist) -or -not (Test-Path $libFile)) {
  Log "Auto-save task not installed: persist-state.ps1 or lib-common.ps1 is missing in $PSScriptRoot"
  exit 1
}

# The task must run as the desktop user whose profile is being saved, not as
# SYSTEM (setup scripts sometimes run elevated). Prefer RDP_USER, then the
# session context written by setup-tools-hub.ps1, then the current user.
$targetUser = ''
if ($env:RDP_USER) {
  $targetUser = $env:RDP_USER.Trim()
} elseif (Test-Path 'C:\Sailuo\tools\session-env.json') {
  try {
    $sessionEnv = Get-Content 'C:\Sailuo\tools\session-env.json' -Raw | ConvertFrom-Json
    if ($sessionEnv.RDP_USER) { $targetUser = ([string]$sessionEnv.RDP_USER).Trim() }
  } catch {}
}
if (-not $targetUser) { $targetUser = $env:USERNAME }

if ($targetUser -eq $env:USERNAME -and $env:USERDOMAIN) {
  $account = "$env:USERDOMAIN\$targetUser"
} else {
  $account = "$env:COMPUTERNAME\$targetUser"
}

# Paths contain no spaces, so the action can stay quote-free and survive
# schtasks parsing. -NonInteractive prevents a hidden prompt from hanging.
$action = "$psExe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File $persist -Checkpoint"

$createArgs = @(
  '/Create',
  '/TN', $taskName,
  '/TR', $action,
  '/SC', 'MINUTE',
  '/MO', '4',
  '/RU', $account,
  '/IT',
  '/RL', 'LIMITED',
  '/F'
)

$createOutput = & schtasks.exe @createArgs 2>&1
if ($LASTEXITCODE -ne 0) {
  # A task that is currently running can block /F; clear it and retry once.
  & schtasks.exe /Delete /TN $taskName /F *> $null
  Start-Sleep -Milliseconds 900
  $createOutput = & schtasks.exe @createArgs 2>&1
}

if ($LASTEXITCODE -ne 0) {
  Log "Failed to register '$taskName': $(Log-Tail ($createOutput -join ' '))"
  exit 1
}

$query = & schtasks.exe /Query /TN $taskName /FO LIST 2>&1
if ($LASTEXITCODE -ne 0) {
  Log "Task '$taskName' was created but cannot be queried: $(Log-Tail ($query -join ' '))"
  exit 1
}

Say "Auto-save task '$taskName' is active: every 4 minutes as $account (interactive session)."
exit 0
