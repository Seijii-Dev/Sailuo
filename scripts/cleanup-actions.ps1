# ============================================================================
#  cleanup-actions.ps1 - Gradual Cleanup of Old Runs (Safe for New Accounts)
# ----------------------------------------------------------------------------
#  Keeps the newest KEEP_RUNS runs (default 5) and deletes at most 3
#  oldest completed runs per session with a polite delay (1.2 seconds) so it
#  does not trigger rate limits or anti-abuse detection on new GitHub accounts.
# ============================================================================
$ErrorActionPreference = 'Continue'
function Log([string]$m) { Write-Host "[XyRDP:cleanup] $m" }

$repo = $env:GITHUB_REPOSITORY
$wf   = $env:GH_WORKFLOW; if (-not $wf) { $wf = 'rdp-6h.yml' }
$keep = [int]($env:KEEP_RUNS -replace '\D',''); if ($keep -lt 1) { $keep = 5 }
$tok  = if ($env:CLEANUP_TOKEN) { $env:CLEANUP_TOKEN } else { $env:GITHUB_TOKEN }

if (-not $repo -or -not $tok) { Log 'repo/token unknown - skip'; exit 0 }

$hdrs = @{
  Authorization          = "Bearer $tok"
  Accept                 = 'application/vnd.github+json'
  'User-Agent'           = 'XyRDP-Workspace'
  'X-GitHub-Api-Version' = '2022-11-28'
}

try {
  $runs = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/actions/workflows/$wf/runs?per_page=25" -Method Get -Headers $hdrs -TimeoutSec 25
  $list = @($runs.workflow_runs)
  if ($list.Count -le $keep) {
    Log "Total runs ($($list.Count)) still within the safe limit ($keep) - nothing deleted."
    exit 0
  }
  $old = @($list | Select-Object -Skip $keep | Where-Object { $_.status -notin @('in_progress', 'queued') } | Select-Object -Last 3)
  $n = 0
  foreach ($r in $old) {
    try {
      Start-Sleep -Milliseconds 1200
      Invoke-RestMethod -Method Delete -Uri "https://api.github.com/repos/$repo/actions/runs/$($r.id)" -Headers $hdrs -TimeoutSec 25 | Out-Null
      $n++
    } catch {}
  }
  Log "Gradual cleanup complete: $n old runs removed."
} catch {
  Log "Cleanup skipped: $($_.Exception.Message)"
}
exit 0
