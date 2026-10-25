# ============================================================================
#  lib-common.ps1 - shared helpers for all Sailuo scripts (v2: Win10-style,
#  private Tailscale access). Dot-source it like this:
#
#      $SailuoTag = 'Sailuo:access'
#      . "$PSScriptRoot/lib-common.ps1"
#
#  Contains: logger, registry helper, configuration reader (assets/sailuo-extras.json),
#  Default-profile hive manager, out/sailuo-status.json reader/writer.
# ============================================================================

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 } catch {}

# ---------- log ----------
function Log([string]$m) {
  $tag = if ($script:SailuoTag) { $script:SailuoTag } else { 'Sailuo' }
  $stamp = [DateTime]::UtcNow
  Write-Host ("[{0:HH:mm:ss} UTC][{1}] {2}" -f $stamp,$tag,$m)
  # Scheduled runs have no console, so keep a rolling log file as well. Without
  # it a failed 4-minute backup leaves no evidence behind.
  if ($script:SailuoLogFile) {
    try {
      Add-Content -LiteralPath $script:SailuoLogFile -Encoding UTF8 -ErrorAction SilentlyContinue `
        -Value ("[{0:yyyy-MM-dd HH:mm:ss} UTC][{1}] {2}" -f $stamp,$tag,$m)
    } catch {}
  }
}

function Log-Tail([string]$text, [int]$lines = 2) {
  (($text -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -Last $lines) -join ' / '
}

# ---------- registry ----------
# Lessons from a real validation run (2026-10-03) on the windows-2022 runner:
#   - 'New-ItemProperty -Force' on a value that ALREADY EXISTS can be rejected
#     "Attempted to perform an unauthorized operation" (needs Create/Delete rights
#     which Admthisstrators do not have on some keys, e.g.
#     Terminal Server\fDenyTSConnections, Winlogon\DisableCAD,
#     CurrentVersion\ProductName).
#   - 'Set-ItemProperty' on a value that already exists only needs "Set Value"
#     -> SUCCEEDED (that is why the old script worked).
# Set-Reg now: exists? -> Set-ItemProperty; if needed -> New-ItemProperty
# -> reg.exe add /f -> take ownership of the key then retry.

function To-RegExePath([string]$Path) {
  $p = ($Path -replace '^Registry::', '') -replace '^HKLM:\\', 'HKEY_LOCAL_MACHINE\' -replace '^HKCU:\\', 'HKEY_CURRENT_USER\' -replace '^HKU:\\', 'HKEY_USERS\' -replace '^HKCR:\\', 'HKEY_CLASSES_ROOT\' -replace '^HKLM\\', 'HKEY_LOCAL_MACHINE\' -replace '^HKCU\\', 'HKEY_CURRENT_USER\' -replace '^HKU\\', 'HKEY_USERS\' -replace '^HKCR\\', 'HKEY_CLASSES_ROOT\'
  $map = @{ 'HKEY_LOCAL_MACHINE' = 'HKLM'; 'HKEY_CURRENT_USER' = 'HKCU'; 'HKEY_USERS' = 'HKU'; 'HKEY_CLASSES_ROOT' = 'HKCR'; 'HKEY_CURRENT_CONFIG' = 'HKCC' }
  foreach ($k in $map.Keys) { if ($p.StartsWith($k + '\')) { return ($map[$k] + $p.Substring($k.Length)) } }
  return $null
}

function Normalize-PsRegPath([string]$Path) {
  if ($Path -match '^HKLM\\') { return ('HKLM:\' + $Path.Substring(5)) }
  if ($Path -match '^HKCU\\') { return ('HKCU:\' + $Path.Substring(5)) }
  if ($Path -match '^HKU\\')  { return ('Registry::HKEY_USERS\' + $Path.Substring(4)) }
  if ($Path -match '^HKCR\\') { return ('Registry::HKEY_CLASSES_ROOT\' + $Path.Substring(5)) }
  if ($Path -match '^Registry::HKEY_LOCAL_MACHINE\\') { return ('HKLM:\' + $Path.Substring('Registry::HKEY_LOCAL_MACHINE\'.Length)) }
  if ($Path -match '^Registry::HKEY_CURRENT_USER\\')  { return ('HKCU:\' + $Path.Substring('Registry::HKEY_CURRENT_USER\'.Length)) }
  return $Path
}

function Grant-KeyAccess([string]$Path) {
  # take ownership + FullControl for the current user (used only when
  # writing is rejected; e.g. CurrentVersion is owned by TrustedInstaller).
  # NEVER change the ACL/owner of WinStations\RDP-Tcp - it would break TermService (NetworkService) access to the 3389 listener!
  try {
    if ($Path -match 'WinStations|RDP-Tcp') {
      return $false
    }
    $ident = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $rk = To-RegExePath $Path
    if (-not $rk) { return $false }
    if ($rk.StartsWith('HKLM\')) {
      $hive = [Microsoft.Win32.Registry]::LocalMachine; $sub = $rk.Substring(5)
    } elseif ($rk.StartsWith('HKCU\')) {
      $hive = [Microsoft.Win32.Registry]::CurrentUser; $sub = $rk.Substring(5)
    } else { return $false }

    $key = $hive.OpenSubKey($sub, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]::TakeOwnership)
    if (-not $key) { return $false }
    $acl = $key.GetAccessControl([System.Security.AccessControl.AccessControlSections]::None)
    $acl.SetOwner($ident.User); $key.SetAccessControl($acl)
    $acl = $key.GetAccessControl()
    $acl.SetAccessRule((New-Object System.Security.AccessControl.RegistryAccessRule($ident.Name, 'FullControl', 'Allow')))
    $key.SetAccessControl($acl); $key.Close()
    Log "  reg: key ownership taken ($sub)"
    return $true
  } catch { Log "  reg: taking ownership failed: $($_.Exception.Message)"; return $false }
}

function Set-Reg([string]$Path, [string]$Name, $Value, [string]$Type = 'String') {
  $psPath = Normalize-PsRegPath $Path
  # 1) value already exists -> Set-ItemProperty (least privilege)
  $exists = $false
  try { $null = Get-ItemProperty -Path $psPath -Name $Name -ErrorAction Stop; $exists = $true } catch {}
  if ($exists) {
    try { Set-ItemProperty -Path $psPath -Name $Name -Value $Value -ErrorAction Stop; return $true }
    catch { Log "  reg: Set-ItemProperty failed ($Name): $($_.Exception.Message)" }
  }
  # 2) reg.exe add directly (does not alter the key ACL, creates key/value through native Win32)
  $rk = To-RegExePath $Path
  if ($rk) {
    $t = switch ("$Type") { 'DWord' { 'REG_DWORD' } 'QWord' { 'REG_QWORD' } 'ExpandString' { 'REG_EXPAND_SZ' } 'MultiString' { 'REG_MULTI_SZ' } default { 'REG_SZ' } }
    $out = & reg add $rk /v $Name /t $t /d $Value /f 2>&1
    if ($LASTEXITCODE -eq 0) { return $true }
    Log "  reg: reg.exe add failed ($Name): $(Log-Tail "$out" 1)"
  }
  # 3) create/set through the PowerShell provider
  try {
    if (-not (Test-Path $psPath)) { New-Item -Path $psPath -Force -ErrorAction Stop | Out-Null }
    New-ItemProperty -Path $psPath -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
    return $true
  } catch { Log "  reg: New-ItemProperty failed ($Name): $($_.Exception.Message)" }
  # 4) take ownership of the key, then retry (except WinStations\RDP-Tcp)
  if (Grant-KeyAccess $Path) {
    try {
      New-ItemProperty -Path $psPath -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
      return $true
    } catch { Log "  reg: still failing after taking ownership ($Name): $($_.Exception.Message)" }
  }
  Log "  reg FAILED entirely ($Path\$Name)"
  return $false
}

function Get-Reg([string]$Path, [string]$Name) {
  $psPath = Normalize-PsRegPath $Path
  try { return (Get-ItemProperty -Path $psPath -Name $Name -ErrorAction Stop).$Name } catch { return $null }
}

# ---------- konfigurasi (assets/sailuo-extras.json) ----------
$script:SailuoCfgDefaults = [ordered]@{
  lightshot        = $false           # do not run the background app unless requested
  wallpaper        = $true
  wallpaper_file   = 'wallpaper.jpg'
  win10_look       = $true            # all Windows 10 visual tweaks
  win10_badge      = $true            # "Windows 10 Pro" label in the registry (cosmetic)
  win10_wallpaper  = $true            # use the Windows 10 style wallpaper
  sailuo_host      = $true            # host setup for the Sailuo Remote client (AVC444/ClearType/audio)
  dark_theme       = $true            # dark application and system theme
  lightweight_mode = $true            # stop only non-essential background services
  vscode           = $false           # optional extra IDE
  notepadpp        = $false           # optional lightweight editor
  rdp_user         = 'xyadmin'        # default RDP username stored per-repo
  storage_boost    = $true            # clear the toolcache to gain 70GB -> 120GB+ of free space
  debloat          = 'light'         # none / light / full (Edge)
}

function Get-CfgBool([object]$o, [string]$n, [bool]$d) {
  if (-not $o) { return $d }
  $p = $o.PSObject.Properties[$n]
  if ($p -and $null -ne $p.Value) { return [bool]$p.Value }
  return $d
}
function Get-CfgStr([object]$o, [string]$n, [string]$d) {
  if (-not $o) { return $d }
  $p = $o.PSObject.Properties[$n]
  if ($p -and $null -ne $p.Value -and "$($p.Value)".Trim()) { return "$($p.Value)".Trim() }
  return $d
}

# Get-Cfg -> pscustomobject contathisng all settings (defaults + repo contents)
function Get-Cfg {
  $j = $null
  $path = Join-Path (Get-Workspace) 'assets\sailuo-extras.json'
  if (-not (Test-Path $path)) {
    # The repository still ships this file as assets/rdp-extras.json.
    $legacyCfg = Join-Path (Get-Workspace) 'assets\rdp-extras.json'
    if (Test-Path $legacyCfg) { $path = $legacyCfg }
  }
  if (Test-Path $path) {
    try { $j = Get-Content $path -Raw | ConvertFrom-Json; Log 'configuration: assets/sailuo-extras.json' }
    catch { Log "sailuo-extras.json could not be read ($($_.Exception.Message)) - use defaults" }
  } else { Log 'assets/sailuo-extras.json is missing - use defaults' }

  $c = [pscustomobject]@{}
  foreach ($k in $script:SailuoCfgDefaults.Keys) {
    $c | Add-Member -NotePropertyName $k -NotePropertyValue $script:SailuoCfgDefaults[$k] -Force
  }
  if ($j) {
    foreach ($k in @('lightshot','wallpaper','win10_look','win10_badge','win10_wallpaper','sailuo_host','dark_theme','lightweight_mode','vscode','notepadpp','storage_boost')) {
      $c.$k = Get-CfgBool $j $k $c.$k
    }
        $c.debloat          = (Get-CfgStr $j 'debloat' $c.debloat).ToLower()
    $c.wallpaper_file   = (Get-CfgStr $j 'wallpaper_file'   $c.wallpaper_file).ToLower()
    $c.rdp_user         = Get-CfgStr $j 'rdp_user' $c.rdp_user
  }
    return $c
}

# ---------- repository location (Actions: GITHUB_WORKSPACE, local: the script folder/..) ----------
function Get-Workspace {
  if ($env:GITHUB_WORKSPACE) { return $env:GITHUB_WORKSPACE }
  return (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

# ---------- status file (out/sailuo-status.json) ----------
function Get-StatusPath {
  return (Join-Path (Get-Workspace) 'out\sailuo-status.json')
}

function Read-Status {
  $p = Get-StatusPath
  if (-not (Test-Path $p)) { Log "status: $p does not exist yet"; return $null }
  try { return (Get-Content $p -Raw | ConvertFrom-Json) } catch { Log "status could not be read: $($_.Exception.Message)"; return $null }
}

# Update-Status @{ key = value } - merge + write back (no password)
function Update-Status([hashtable]$Pairs) {
  $p = Get-StatusPath
  $obj = Read-Status
  if (-not $obj) { $obj = [pscustomobject]@{} }
  foreach ($k in $Pairs.Keys) {
    $obj | Add-Member -NotePropertyName $k -NotePropertyValue $Pairs[$k] -Force
  }
  try {
    New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null
    ($obj | ConvertTo-Json -Depth 8) | Set-Content -Path $p -Encoding utf8
    return $true
  } catch { Log "writing status failed: $($_.Exception.Message)"; return $false }
}

# ---------- hive profil Default (setting ikut user RDP when login pertama) ----------
$script:DefHiveKey = 'Sailuo_Def'
$script:DefHive    = 'HKU\Sailuo_Def'
$script:DefReg     = 'Registry::HKEY_USERS\Sailuo_Def'
$script:HiveLoaded = $false

function Open-DefaultHive {
  if ($script:HiveLoaded) { return $true }
  try {
    & reg load $script:DefHive 'C:\Users\Default\NTUSER.DAT' 2>&1 | Out-Null
    Start-Sleep -Milliseconds 600
    if (Test-Path $script:DefReg) { $script:HiveLoaded = $true; Log 'profil Default di-load (setting ikut user RDP when login pertama)'; return $true }
  } catch { Log "load profil Default failed: $($_.Exception.Message)" }
  $script:HiveLoaded = $false
  return $false
}

function Close-DefaultHive {
  if (-not $script:HiveLoaded) { return }
  try {
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    & reg unload $script:DefHive 2>&1 | Out-Null
    $script:HiveLoaded = $false
    Log 'profil Default di-unload'
  } catch { Log "unload hive (no kritis): $($_.Exception.Message)" }
}

# Set-RegDefault: tulis ke profil Default DAN ke HKCU session sekarang
function Set-RegBoth([string]$SubKey, [string]$Name, $Value, [string]$Type = 'DWord') {
  Open-DefaultHive | Out-Null
  if ($script:HiveLoaded) { Set-Reg ($script:DefReg + '\' + $SubKey) $Name $Value $Type | Out-Null }
  Set-Reg ('Registry::HKEY_CURRENT_USER\' + $SubKey) $Name $Value $Type | Out-Null
}

# ---------- util gambar ----------
function Get-ImageExt([byte[]]$b) {
  if ($b.Length -ge 3 -and $b[0] -eq 0xFF -and $b[1] -eq 0xD8 -and $b[2] -eq 0xFF) { return 'jpg' }
  if ($b.Length -ge 8 -and $b[0] -eq 0x89 -and $b[1] -eq 0x50 -and $b[2] -eq 0x4E -and $b[3] -eq 0x47) { return 'png' }
  if ($b.Length -ge 2 -and $b[0] -eq 0x42 -and $b[1] -eq 0x4D) { return 'bmp' }
  return $null
}

# ---------- jaringan ----------
function Get-PrimaryIPv4 {
  try {
    $ip = Get-NetIPAddress -AddressFamily IPv4 |
          Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
          Sort-Object -Property SkipAsSource | Select-Object -First 1
    if ($ip) { return $ip.IPAddress }
  } catch {}
  return '0.0.0.0'
}

# ---------------------------------------------------------------------------
#  RDP readiness (lesson from the 2026-10-03 validation on a real runner):
#   - "port 3389 LISTENING" is NOT enough: the listener briefly disappeared for ~2 minutes
#     after tweak Sailuo, and koneksi ke 127.0.0.1 can ditolak sementara
#     the VM's main IP receives. So we wait until RDP really answers
#     handshake X.224 senot yet tunnel diarahkan ke sana.
# ---------------------------------------------------------------------------

# semua alamat IPv4 non-loopback (kandidat alamat RDP lokal)
function Get-LocalIPv4List {
  $out = @()
  try {
    $out = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
             Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
             Sort-Object -Property @{ Expression = { [int]$_.SkipAsSource } }, InterfaceIndex |
             Select-Object -ExpandProperty IPAddress -Unique)
  } catch {}
  if (-not $out) { $out = @(Get-PrimaryIPv4) }
  return $out
}

# summarize listener 3389 availability (address + process name) for the log
function Get-RdpListenerState([int]$Port = 3389) {
  try {
    $l = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
    if (-not $l) { return 'NO listener' }
    $items = foreach ($x in $l) {
      $pn = '?'; try { $pn = (Get-Process -Id $x.OwningProcess -ErrorAction Stop).ProcessName } catch {}
      "$($x.LocalAddress):$($x.LocalPort) ($pn)"
    }
    return ($items -join ' | ')
  } catch { return "error: $($_.Exception.Message)" }
}

# handshake RDP X.224 ke alamat:port -> @{ ok = bool; detail = teks }
# (Connection Confirm = RDP benar-benar menerima koneksi, bukan cuma TCP terbuka)
function Test-RdpHandshake([string]$Address, [int]$Port = 3389, [int]$TimeoutMs = 8000) {
  $cr = [byte[]](0x03,0x00,0x00,0x13, 0x0e,0xe0,0x00,0x00,0x00,0x00,0x00,
                 0x01,0x00,0x08,0x00,0x03,0x00,0x00,0x00)
  try {
    $c = New-Object System.Net.Sockets.TcpClient
    if (-not $c.ConnectAsync($Address, $Port).Wait($TimeoutMs)) { $c.Close(); return @{ ok = $false; detail = 'timeout connect' } }
    $ns = $c.GetStream()
    $ns.Write($cr, 0, $cr.Length); $ns.Flush()
    $c.ReceiveTimeout = $TimeoutMs
    $buf = New-Object byte[] 64
    $n = $ns.Read($buf, 0, $buf.Length)
    $c.Close()
    if ($n -ge 6 -and $buf[0] -eq 0x03 -and $buf[1] -eq 0x00 -and $buf[5] -in @(0xd0, 0xcf)) {
      $hex = (($buf[0..([Math]::Min($n, 10) - 1)] | ForEach-Object { $_.ToString('x2') }) -join ' ')
      return @{ ok = $true; detail = "X.224 Connection Confirm [$hex]" }
    }
    if ($n -gt 0) {
      $hex = (($buf[0..($n - 1)] | ForEach-Object { $_.ToString('x2') }) -join ' ')
      return @{ ok = $false; detail = "balasan $n byte non-confirm [$hex]" }
    }
    return @{ ok = $false; detail = 'koneksi dthattup without data' }
  } catch { return @{ ok = $false; detail = $_.Exception.Message } }
}

# wait until a local address answers the RDP handshake; return that address
# that (or $null). Kalau lama does not exist, TermService di-restart once.
function Wait-RdpReady([int]$TimeoutSec = 240, [int]$Port = 3389) {
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  $lastState = ''
  while ((Get-Date) -lt $deadline) {
    $cands = @('127.0.0.1', '::1') + @(Get-LocalIPv4List) | Select-Object -Unique
    foreach ($c in $cands) {
      $r = Test-RdpHandshake $c $Port
      if ($r.ok) { Log "  RDP READY di $c`:$Port - $($r.detail)"; return $c }
    }
    $st = Get-RdpListenerState $Port
    if ($st -ne $lastState) { Log "  listener $Port : $st"; $lastState = $st }
    # CATATAN: restart TermService SENGAJA no dilakukan again - on runner
    # GitHub, a restart does not bring listener 3389 back (proven on
    # validasi 2026-10-03: menunggu 240s + 150s tetap mati). Kita cukup menunggu
    # and reported what is there; the cause is already mentioned in setup-sailuo.
    Start-Sleep -Seconds 8
  }
  Log "  RDP not yet menjawab handshake after ${TimeoutSec}s"
  return $null
}

# one-line probe: used to track which step breaks RDP
function Probe-Rdp([string]$Where, [string]$Address = '127.0.0.1') {
  $state = Get-RdpListenerState 3389
  $r = Test-RdpHandshake $Address 3389 5000
  $txt = if ($r.ok) { 'handshake ok' } else { "handshake FAILED ($($r.detail))" }
  Log "  [probe] $Where -> $txt | listener: $state"
  return $r.ok
}

# ---------------------------------------------------------------------------
#  Spot-check HTTPS from ALAMAT LAIN (bukan from VM)
#  Why it matters: on 3 Oct 2026 the tunnel proved "selftest ok" from inside
#  VM (bore.pub:51782 menjawab X.224 from in), TAPI from internet port that
#  rejected (6/8 outside nodes "connection refused"). So "selftest ok" alone is NOT
#  cukup - alamat that dipamerkan ke user must diuji from luar.
#  Service: check-host.net (no account needed, supports TCP).
# ---------------------------------------------------------------------------
function Get-OutsideReach([string]$HostName, [int]$Port, [int]$TimeoutSec = 90) {
  $res = @{ ok = $false; detail = 'no diuji'; nodesOk = 0; nodesAll = 0 }
  try {
    $u = "https://check-host.net/check-tcp?host=$([uri]::EscapeDataString("$HostName`:$Port"))&max_nodes=6"
    $req = $null
    foreach ($coba in 1..3) {
      try {
        $req = Invoke-RestMethod -Uri $u -Headers @{ 'Accept' = 'application/json'; 'User-Agent' = 'Sailuo' } -TimeoutSec 30
        if ($req.request_id) { break }
      } catch {
        # 403 = check-host membatasi laju (bukan bukti tunnel mati!) -> do not
        # dipakai for memutuskan ganti provider, cukup 'no diuji'.
        $res.ok = $null; $res.detail = "no can diuji from luar: $($_.Exception.Message)"
        Log "  (uji luar: $($res.detail))"
        Start-Sleep -Seconds 8
      }
    }
    if (-not $req -or -not $req.request_id) {
      if (-not $res.detail) { $res.detail = 'check-host menolak permintaan' }
      return $res
    }
    $rid = $req.request_id
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    Start-Sleep -Seconds 6
    while ((Get-Date) -lt $deadline) {
      $r = Invoke-RestMethod -Uri "https://check-host.net/check-result/$rid" -Headers @{ 'Accept' = 'application/json'; 'User-Agent' = 'Sailuo' } -TimeoutSec 30
      $vals = @($r.PSObject.Properties | ForEach-Object { $_.Value })
      if ($vals.Count -gt 0 -and -not ($vals | Where-Object { $null -eq $_ })) {
        $ok = 0; $all = 0
        foreach ($v in $vals) {
          $all++
          if ($v -is [array] -and $v.Count -gt 0 -and $v[0] -and $v[0].time) { $ok++ }
        }
        $res.nodesOk = $ok; $res.nodesAll = $all; $res.ok = ($ok -gt 0)
        $res.detail = "$ok/$all node luar can tersambung"
        return $res
      }
      Start-Sleep -Seconds 6
    }
    $res.detail = 'uji luar no selesai (timeout)'
    return $res
  } catch { $res.detail = $_.Exception.Message; return $res }
}

# ---------- downloaand ----------
function Get-File([string]$Url, [string]$OutFile, [int]$TimeoutSec = 120) {
  # curl.exe (available di runner Windows) -> batas time keras, no can menggantung
  # (kejadian nyata: Invoke-WebRequest ke app.prntscr.com menggantung 20 menit
  #  until the step times out and all subsequent steps are skipped)
  $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
  for ($i = 1; $i -le 3; $i++) {
    try {
      if ($curl) {
        & $curl.Source -sS -L --connect-timeout 15 --max-time $TimeoutSec -o $OutFile $Url 2>&1 | Out-Null
      } else {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec $TimeoutSec
      }
      if ((Test-Path $OutFile) -and ((Get-Item $OutFile).Length -gt 0)) { return $true }
      Log "  download kosong (coba $i/3)"
    } catch { Log "  download failed (coba $i/3): $($_.Exception.Message)" }
    Start-Sleep -Seconds 3
  }
  return $false
}

# Get-GhAssetUrl <owner/repo> <asset name regex> -> latest asset download url
# Use GITHUB_TOKEN to avoid the 403 rate limit (a real case on the runner:
# shared GitHub-hosted IP often already exhausted the anonymous API quota).
function Get-GhAssetUrl([string]$Repo, [string]$NameRegex) {
  $hdrs = @{ 'User-Agent' = 'Sailuo' }
  if ($env:GITHUB_TOKEN) { $hdrs['Authorization'] = "Bearer $($env:GITHUB_TOKEN)" }
  foreach ($h in @($hdrs, @{ 'User-Agent' = 'Sailuo' })) {
    try {
      $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers $h -TimeoutSec 60
      $a = $rel.assets | Where-Object { $_.name -match $NameRegex } | Select-Object -First 1
      if ($a) { return @{ url = $a.browser_download_url; tag = $rel.tag_name; name = $a.name } }
    } catch { Log "  GitHub API ($Repo) failed: $($_.Exception.Message)" }
  }
  return $null
}

# fallback URL keras (kalau API no can dipakai sama once)
$script:XyFallbackUrls = @{
}

# ---------- 10. Profil Windows Resmi & Unlocker Copy (Anti-Hilang Data Session) ----------
function Ensure-UserProfileCreated([string]$UserName) {
  if (-not $UserName) { return $null }
  $targetDir = "C:\Users\$UserName"
  try {
    $acct = New-Object System.Security.Principal.NTAccount($UserName)
    $sid = $acct.Translate([System.Security.Principal.SecurityIdentifier]).Value
    $profKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
    if (-not (Test-Path $profKey)) {
      if (-not ('XyWin32Profile' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class XyWin32Profile {
    [DllImport("userenv.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int CreateProfile(
        [MarshalAs(UnmanagedType.LPWStr)] string pszUserSid,
        [MarshalAs(UnmanagedType.LPWStr)] string pszUserName,
        [Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszProfilePath,
        uint cchProfilePath);
}
"@ -ErrorAction SilentlyContinue
      }
      $sb = New-Object System.Text.StringBuilder 260
      $hr = [XyWin32Profile]::CreateProfile($sid, $UserName, $sb, 260)
      if ($hr -eq 0 -and $sb.Length -gt 0) {
        $targetDir = $sb.ToString()
        Log "  profil resmi Windows dibuat via CreateProfile: $targetDir (SID=$sid)"
      }
    } else {
      $existingPath = (Get-ItemProperty -Path $profKey -Name 'ProfileImagePath' -ErrorAction SilentlyContinue).ProfileImagePath
      if ($existingPath) { $targetDir = $existingPath }
    }
    # Ensure ProfileList menunjuk ke folder profil that konsisten & milik user penuh.
    # CreateProfile can fail on a fresh runner (the account has never signed in).
    # Without a ProfileList entry Windows invents C:\Users\<user>.<host> at the
    # first RDP logon, which leaves the restored files in a folder the desktop
    # never opens. Register the folder we are about to fill so both sides agree.
    if (-not (Test-Path $targetDir)) {
      New-Item -ItemType Directory -Path $targetDir -Force -ErrorAction SilentlyContinue | Out-Null
    }
    if (-not (Test-Path $profKey)) {
      New-Item -Path $profKey -Force -ErrorAction SilentlyContinue | Out-Null
      if (Test-Path $profKey) {
        New-ItemProperty -Path $profKey -Name 'ProfileImagePath' -Value $targetDir -PropertyType String -Force -ErrorAction SilentlyContinue | Out-Null
        New-ItemProperty -Path $profKey -Name 'State' -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
        New-ItemProperty -Path $profKey -Name 'RefCount' -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
        Log "  profil resmi Windows didaftarkan manual di ProfileList: $targetDir (SID=$sid)"
      }
    } else {
      Set-ItemProperty -Path $profKey -Name 'ProfileImagePath' -Value $targetDir -ErrorAction SilentlyContinue
      New-ItemProperty -Path $profKey -Name 'State' -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
    }
    & icacls $targetDir /grant "${UserName}:(OI)(CI)F" /grant "Administrators:(OI)(CI)F" /grant "SYSTEM:(OI)(CI)F" /C /Q 2>&1 | Out-Null
  } catch {
    Log "  Ensure-UserProfileCreated warning: $($_.Exception.Message)"
  }
  return $targetDir
}

function Get-AllUserProfileDirs([string]$UserName) {
  $dirs = New-Object System.Collections.Generic.List[string]
  if ($UserName) {
    $sid = $null
    try {
      $acct = New-Object System.Security.Principal.NTAccount($UserName)
      $sid = $acct.Translate([System.Security.Principal.SecurityIdentifier]).Value
    } catch {}
    if ($sid) {
      $profKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
      if (Test-Path $profKey) {
        $p = (Get-ItemProperty -Path $profKey -Name 'ProfileImagePath' -ErrorAction SilentlyContinue).ProfileImagePath
        # The ProfileList entry is authoritative even when the folder has not
        # been materialised yet (a brand-new runner). It is the folder Windows
        # will use at the first RDP logon, so restore must fill exactly that.
        if ($p -and -not $dirs.Contains($p)) { $dirs.Add($p) }
      }
    }
    if ($dirs.Count -eq 0) {
      # Dynamically named profiles (sailuo.runnervmdaln5) are normal on
      # GitHub runners. Prefer the profile of the process's own account.
      $currentProfile = $env:USERPROFILE
      $currentName = $env:USERNAME
      if ($currentProfile -and (Test-Path $currentProfile) -and $currentName -and
          ($currentName -ieq $UserName -or $currentName -like "$UserName.*")) {
        if (-not $dirs.Contains($currentProfile)) { $dirs.Add($currentProfile) }
      }
      $base = "C:\Users\$UserName"
      if ((Test-Path $base) -and -not $dirs.Contains($base)) { $dirs.Add($base) }
      if ($dirs.Count -eq 0) {
        Get-ChildItem -Path 'C:\Users' -Directory -Filter "$UserName.*" -ErrorAction SilentlyContinue | ForEach-Object {
          if (-not $dirs.Contains($_.FullName)) { $dirs.Add($_.FullName) }
        }
      }
    }
  }
  if ($dirs.Count -eq 0 -and $UserName) { $dirs.Add("C:\Users\$UserName") }
  return $dirs.ToArray()
}

# Files that could not be copied during this run. persist-state.ps1 inspects
# this list before uploading so a backup can never silently lose a large file.
$global:SailuoCopyFailures = New-Object System.Collections.ArrayList

# Folders that are regenerated by build tools and never need to be backed up.
# Skipping them keeps backups small and fast; the source code itself is kept.
$global:SailuoExcludeDirs = @('build','node_modules','.gradle','.dart_tool','dist','target','.next','__pycache__','.pub-cache','.fvm','coverage')

function Copy-FileUnlocked([string]$SourceFile, [string]$DestFile) {
  if (-not (Test-Path -LiteralPath $SourceFile -PathType Leaf)) { return $false }

  # Large installers are often locked for a second or two by antivirus or a
  # running setup. Retry those; a skipped 200 MB file still produces a valid
  # looking archive that is missing most of its content.
  $sizeBytes = 0
  try { $sizeBytes = (Get-Item -LiteralPath $SourceFile -ErrorAction Stop).Length } catch {}
  $attempts = if ($sizeBytes -ge 16MB) { 4 } else { 1 }

  for ($attempt = 1; $attempt -le $attempts; $attempt++) {
    try {
      $parent = Split-Path -Path $DestFile -Parent
      if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force -ErrorAction SilentlyContinue | Out-Null
      }
      Copy-Item -LiteralPath $SourceFile -Destination $DestFile -Force -ErrorAction Stop
      return $true
    } catch {}

    try {
      $inStream = New-Object System.IO.FileStream($SourceFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
      try {
        $outStream = New-Object System.IO.FileStream($DestFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
          $inStream.CopyTo($outStream)
        } finally {
          $outStream.Dispose()
        }
      } finally {
        $inStream.Dispose()
      }
      return $true
    } catch {
      Remove-Item -LiteralPath $DestFile -Force -ErrorAction SilentlyContinue
    }

    if ($attempt -lt $attempts) { Start-Sleep -Milliseconds (200 * $attempt) }
  }

  try {
    if ($null -eq $global:SailuoCopyFailures) { $global:SailuoCopyFailures = New-Object System.Collections.ArrayList }
    [void]$global:SailuoCopyFailures.Add([pscustomobject]@{
      Path = $SourceFile
      MB   = [math]::Round($sizeBytes / 1MB, 2)
    })
  } catch {}
  return $false
}

# Absolute paths that must never be staged (runtime metadata, work folders,
# restore rollback copies). Set by the save scripts before copying.
$global:SailuoExcludePaths = New-Object System.Collections.ArrayList

function Test-SailuoPathExcluded([string]$Path) {
  if (-not $Path) { return $false }
  if (-not $global:SailuoExcludePaths -or $global:SailuoExcludePaths.Count -eq 0) { return $false }
  try { $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $false }
  foreach ($ex in @($global:SailuoExcludePaths)) {
    if (-not $ex) { continue }
    try { $root = [System.IO.Path]::GetFullPath([string]$ex).TrimEnd('\') } catch { continue }
    if ($full -ieq $root) { return $true }
    if ($full.StartsWith($root + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  return $false
}

function Copy-TreeUnlocked([string]$SourceDir, [string]$DestDir) {
  if (-not (Test-Path -LiteralPath $SourceDir)) { return }
  if (Test-SailuoPathExcluded $SourceDir) { return }
  if (Test-Path -LiteralPath $SourceDir -PathType Leaf) {
    Copy-FileUnlocked $SourceDir $DestDir | Out-Null
    return
  }
  New-Item -ItemType Directory -Path $DestDir -Force -ErrorAction SilentlyContinue | Out-Null
  Get-ChildItem -LiteralPath $SourceDir -Force -ErrorAction SilentlyContinue | Where-Object {
    -not ($_.PSIsContainer -and $global:SailuoExcludeDirs -contains $_.Name) -and
    -not (Test-SailuoPathExcluded $_.FullName)
  } | ForEach-Object {
    $target = Join-Path $DestDir $_.Name
    if ($_.PSIsContainer) {
      Copy-TreeUnlocked $_.FullName $target
    } else {
      Copy-FileUnlocked $_.FullName $target | Out-Null
    }
  }
}

# ===========================================================================
#  State metadata, operation results and archive validation
# ===========================================================================
# The dashboard must be able to tell the difference between a snapshot that
# was really uploaded/verified, a checkpoint that intentionally skipped an
# unchanged upload, and an operation that failed. Two small JSON files carry
# that contract:
#   last-cloud-save.json : durable snapshot metadata (last successful save,
#                          last checkpoint verification, last restore, error)
#   last-operation.json  : result of the current run, keyed by operation id
$global:SailuoCloudMetaPath  = 'C:\Persist\System\last-cloud-save.json'
$global:SailuoOperationPath  = 'C:\Persist\System\last-operation.json'
$global:SailuoSyncLockPath   = 'C:\Persist\System\sync.lock'
$global:SailuoSyncLockOwned  = $false

function Get-SailuoUtcNowText {
  return [DateTime]::UtcNow.ToString('o')
}

function Write-SailuoJson([string]$Path, $Object, [int]$Depth = 12) {
  $parent = Split-Path -Path $Path -Parent
  if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force -ErrorAction SilentlyContinue | Out-Null
  }
  $json = $Object | ConvertTo-Json -Depth $Depth
  [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-SailuoJson([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try { return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json) } catch { return $null }
}

function Get-SailuoCloudMeta {
  $obj = Read-SailuoJson $global:SailuoCloudMetaPath
  if (-not $obj) { $obj = New-Object psobject }
  return $obj
}

# Merge fields into the durable snapshot metadata without dropping fields that
# belong to the other operation (save vs restore).
function Set-SailuoCloudMeta([hashtable]$Pairs) {
  $obj = Get-SailuoCloudMeta
  foreach ($k in $Pairs.Keys) {
    $obj | Add-Member -NotePropertyName $k -NotePropertyValue $Pairs[$k] -Force
  }
  Write-SailuoJson $global:SailuoCloudMetaPath $obj 12
  return $obj
}

function Write-SailuoOperationResult {
  param(
    [string]$Operation,
    [string]$OperationId,
    [string]$Status,
    [string]$Message = '',
    [string]$ErrorText = '',
    [int]$ExitCode = 0,
    [object]$FinishedUtc = $null,
    [hashtable]$Extra = @{}
  )
  if (-not $OperationId) { $OperationId = [guid]::NewGuid().ToString('N') }
  $now = Get-SailuoUtcNowText
  $started = if ($script:SailuoOperationStartedUtc) { $script:SailuoOperationStartedUtc } else { $now }
  if ($null -eq $FinishedUtc -and $Status -ne 'running') { $FinishedUtc = $now }
  $obj = [ordered]@{
    schema        = 1
    operation     = $Operation
    operation_id  = $OperationId
    status        = $Status
    message       = $Message
    error         = $ErrorText
    exit_code     = $ExitCode
    pid           = $PID
    started_utc   = $started
    finished_utc  = $FinishedUtc
    writer        = 'sailuo-operation/1'
  }
  foreach ($k in $Extra.Keys) { $obj[$k] = $Extra[$k] }
  Write-SailuoJson $global:SailuoOperationPath $obj 10
}

function Start-SailuoOperation {
  param(
    [string]$Operation,
    [string]$OperationId,
    [string]$Writer = 'sailuo/3',
    [string]$Message = ''
  )
  $script:SailuoOperationStartedUtc = Get-SailuoUtcNowText
  if (-not $OperationId) { $OperationId = [guid]::NewGuid().ToString('N') }
  $script:SailuoOperationId = $OperationId
  Set-SailuoCloudMeta @{
    schema            = 2
    status            = 'running'
    operation         = $Operation
    operation_id      = $OperationId
    writer            = $Writer
    started_utc       = $script:SailuoOperationStartedUtc
    last_attempt_utc  = $script:SailuoOperationStartedUtc
    pid               = $PID
    progress          = $Message
  } | Out-Null
  Write-SailuoOperationResult -Operation $Operation -OperationId $OperationId -Status 'running' `
    -Message $Message -Extra @{ writer = $Writer }
  return $OperationId
}

function Write-SailuoSyncLock([string]$Mode) {
  New-Item -ItemType Directory -Path 'C:\Persist\System' -Force -ErrorAction SilentlyContinue | Out-Null
  $owns = [ordered]@{
    pid         = $PID
    mode        = $Mode
    started_utc = Get-SailuoUtcNowText
  }
  Write-SailuoJson $global:SailuoSyncLockPath $owns 5
  $global:SailuoSyncLockOwned = $true
}

function Remove-SailuoSyncLock {
  if (-not $global:SailuoSyncLockOwned) { return }
  try {
    if (Test-Path -LiteralPath $global:SailuoSyncLockPath) {
      $raw = Get-Content -LiteralPath $global:SailuoSyncLockPath -Raw -ErrorAction SilentlyContinue
      if ($raw -match '"pid"\s*:\s*(\d+)' -and [int]$Matches[1] -eq $PID) {
        Remove-Item -LiteralPath $global:SailuoSyncLockPath -Force -ErrorAction SilentlyContinue
      }
    }
  } catch {}
  $global:SailuoSyncLockOwned = $false
}

# Append/merge the persist block in out/sailuo-status.json without clobbering
# fields written by the other operation.
function Update-PersistStatus([hashtable]$Pairs) {
  $status = Read-Status
  if (-not $status) { $status = New-Object psobject }
  $persist = $null
  try { $persist = $status.persist } catch {}
  if (-not $persist) { $persist = New-Object psobject }
  foreach ($k in $Pairs.Keys) {
    $persist | Add-Member -NotePropertyName $k -NotePropertyValue $Pairs[$k] -Force
  }
  $status | Add-Member -NotePropertyName 'persist' -NotePropertyValue $persist -Force
  $path = Get-StatusPath
  try {
    $parent = Split-Path -Path $path -Parent
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Write-SailuoJson $path $status 10
    return $true
  } catch {
    Log "writing persist status failed: $($_.Exception.Message)"
    return $false
  }
}

function Get-SailuoSevenZipPath {
  foreach ($candidate in @(
      (Join-Path $env:ProgramFiles '7-Zip\7z.exe'),
      (Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe'),
      'C:\Program Files\7-Zip\7z.exe',
      'C:\Program Files (x86)\7-Zip\7z.exe')) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
  }
  return $null
}

function Get-SailuoFileSha256([string]$Path) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
  try {
    return ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToLowerInvariant()
  } finally {
    $stream.Dispose()
    $sha.Dispose()
  }
}

function Get-SailuoFileMagic([string]$Path) {
  $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  try {
    $buf = New-Object byte[] 8
    $n = $fs.Read($buf, 0, 8)
    return (($buf[0..([Math]::Max(0, $n - 1))] | ForEach-Object { $_.ToString('x2') }) -join '')
  } finally { $fs.Dispose() }
}

function Get-SailuoArchiveFormat([string]$Path) {
  try {
    $magic = Get-SailuoFileMagic $Path
    if ($magic.StartsWith('377abcaf271c')) { return '7z' }
    if ($magic.StartsWith('504b0304') -or $magic.StartsWith('504b0506') -or $magic.StartsWith('504b0708')) { return 'zip' }
  } catch {}
  return $null
}

# Verify the archive itself (CRC for 7z, decompression/CRC for zip) before any
# file is extracted over live data.
function Test-SailuoArchive {
  param([string]$Path, [string]$Format)
  if (-not (Test-Path -LiteralPath $Path)) { return @{ ok = $false; error = 'archive is missing' } }
  if ($Format -eq '7z') {
    $sevenZip = Get-SailuoSevenZipPath
    if (-not $sevenZip) { return @{ ok = $false; error = '7-Zip is not installed' } }
    $output = & $sevenZip t $Path -y 2>&1
    if ($LASTEXITCODE -ne 0) {
      return @{ ok = $false; error = "7-Zip test failed (exit $LASTEXITCODE): $(Log-Tail (($output | Out-String)) 2)" }
    }
    return @{ ok = $true; error = '' }
  }
  if ($Format -eq 'zip') {
    try {
      Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
      $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
      try {
        foreach ($entry in $zip.Entries) {
          if ($entry.Length -le 0) { continue }
          $stream = $entry.Open()
          try {
            $buffer = New-Object byte[] 65536
            while ($stream.Read($buffer, 0, $buffer.Length) -gt 0) { }
          } finally { $stream.Dispose() }
        }
      } finally { $zip.Dispose() }
      return @{ ok = $true; error = '' }
    } catch {
      return @{ ok = $false; error = $_.Exception.Message }
    }
  }
  return @{ ok = $false; error = "unsupported archive format '$Format'" }
}

function Get-SailuoArchiveEntries {
  param([string]$Path, [string]$Format)
  $entries = New-Object System.Collections.ArrayList
  if ($Format -eq '7z') {
    $sevenZip = Get-SailuoSevenZipPath
    if (-not $sevenZip) { throw '7-Zip is not installed' }
    $output = @(& $sevenZip l -slt $Path 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "7-Zip list failed (exit $LASTEXITCODE)" }
    $inBody = $false
    $current = $null
    foreach ($line in $output) {
      $text = [string]$line
      if ($text -match '^----------$') { $inBody = $true; continue }
      if (-not $inBody) { continue }
      if ($text -match '^Path = (.*)$') {
        if ($current) { [void]$entries.Add($current) }
        $current = [pscustomobject]@{ path = $Matches[1]; isDirectory = $false; size = 0L }
      } elseif ($current -and $text -match '^Size = (\d+)$') {
        $current.size = [long]$Matches[1]
      } elseif ($current -and $text -match '^Folder = (\+|-)$') {
        $current.isDirectory = ($Matches[1] -eq '+')
      } elseif ($current -and $text -match '^Attributes = (.*)$') {
        if ($Matches[1] -match '(^|\s)D') { $current.isDirectory = $true }
      }
    }
    if ($current) { [void]$entries.Add($current) }
    return $entries.ToArray()
  }
  if ($Format -eq 'zip') {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
      foreach ($entry in $zip.Entries) {
        [void]$entries.Add([pscustomobject]@{
          path        = $entry.FullName
          isDirectory = $entry.FullName.EndsWith('/')
          size        = [long]$entry.Length
        })
      }
    } finally { $zip.Dispose() }
    return $entries.ToArray()
  }
  throw "unsupported archive format '$Format'"
}

# Reject absolute paths, drive letters, alternate data streams and parent
# traversal before anything is written to disk.
function Test-SailuoArchivePaths($Entries) {
  foreach ($entry in @($Entries)) {
    $p = [string]$entry.path
    if (-not $p) { continue }
    $normalized = $p.Replace('/', '\')
    if ($normalized -match '^[\\/]' -or $normalized -match '^[A-Za-z]:' -or
        $normalized -match '(^|\\)\.\.(\\|$)' -or $normalized.Contains(':')) {
      return @{ ok = $false; error = "unsafe archive path: $p" }
    }
  }
  return @{ ok = $true; error = '' }
}

function Get-SailuoFirstValue($Object, [string]$Name, $Default = $null) {
  if (-not $Object) { return $Default }
  try {
    $property = $Object.PSObject.Properties[$Name]
    if ($property -and $null -ne $property.Value) { return $property.Value }
  } catch {}
  return $Default
}

# ---------- 11. Generator Ikon Unik Desktop (.ico 64x64 ARGB Berwarna) ----------
function New-SailuoAppIcon([string]$OutIcoPath, [string]$BadgeText, [int]$R1, [int]$G1, [int]$B1, [int]$R2, [int]$G2, [int]$B2, [string]$SubText = '', [switch]$Force) {
  # Renders a properly sized, multi-resolution .ico:
  #   * 16-48px  : uncompressed 32bpp DIB frames (required by the shell's small
  #                icon paths so the title bar and taskbar stay crisp);
  #   * 64-256px : PNG-compressed frames (canonical for large sizes);
  #   * text and corner radius are re-rendered per size instead of downscaling
  #     one bitmap, which is what made the old 64px-only icon unreadable at 16px.
  try {
    if ((Test-Path -LiteralPath $OutIcoPath) -and -not $Force) { return $OutIcoPath }
    $dir = Split-Path -Path $OutIcoPath -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

    $sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
    $frames = @()
    foreach ($size in $sizes) {
      $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
      $graphics = [System.Drawing.Graphics]::FromImage($bmp)
      $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
      $graphics.Clear([System.Drawing.Color]::Transparent)
      $margin = [float][Math]::Max(1.0, $size * 0.035)
      $arc = [float][Math]::Max(2.0, [Math]::Round($size * 0.30))
      $rect = New-Object System.Drawing.RectangleF($margin, $margin, [float]($size - 2 * $margin), [float]($size - 2 * $margin))
      $path = New-Object System.Drawing.Drawing2D.GraphicsPath
      $path.AddArc($rect.X, $rect.Y, $arc, $arc, 180, 90)
      $path.AddArc($rect.Right - $arc, $rect.Y, $arc, $arc, 270, 90)
      $path.AddArc($rect.Right - $arc, $rect.Bottom - $arc, $arc, $arc, 0, 90)
      $path.AddArc($rect.X, $rect.Bottom - $arc, $arc, $arc, 90, 90)
      $path.CloseFigure()
      $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $rect,
        [System.Drawing.Color]::FromArgb(255, $R1, $G1, $B1),
        [System.Drawing.Color]::FromArgb(255, $R2, $G2, $B2),
        45.0)
      $graphics.FillPath($brush, $path)
      if ($size -ge 32) {
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(70, 255, 255, 255), [float][Math]::Max(0.75, $size * 0.02))
        $graphics.DrawPath($pen, $path)
        $pen.Dispose()
      }

      $format = New-Object System.Drawing.StringFormat
      $format.Alignment = [System.Drawing.StringAlignment]::Center
      $format.LineAlignment = [System.Drawing.StringAlignment]::Center
      $format.FormatFlags = [System.Drawing.StringFormatFlags]::NoClip
      $showSubText = ($SubText -and $size -ge 40)
      $textSize = if ($showSubText) { $size * 0.42 } else { $size * 0.56 }
      if ($BadgeText.Length -ge 3) { $textSize = $textSize * 0.76 }
      $font = New-Object System.Drawing.Font('Segoe UI', [float]$textSize, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
      $centerY = if ($showSubText) { $rect.Y + $rect.Height * 0.40 } else { $rect.Y + $rect.Height * 0.50 }
      $center = New-Object System.Drawing.PointF([float]($rect.X + $rect.Width / 2), [float]$centerY)
      $graphics.DrawString($BadgeText, $font, [System.Drawing.Brushes]::White, $center, $format)
      $font.Dispose()
      if ($showSubText) {
        $subFont = New-Object System.Drawing.Font('Segoe UI', [float]($size * 0.13), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $subBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(225, 255, 255, 255))
        $subCenter = New-Object System.Drawing.PointF([float]($rect.X + $rect.Width / 2), [float]($rect.Y + $rect.Height * 0.70))
        $graphics.DrawString($SubText, $subFont, $subBrush, $subCenter, $format)
        $subBrush.Dispose()
        $subFont.Dispose()
      }
      $format.Dispose()
      $brush.Dispose()
      $path.Dispose()
      $graphics.Dispose()
      $frames += $bmp
    }

    $payloads = @()
    foreach ($frame in $frames) {
      if ($frame.Width -ge 64) {
        $png = New-Object System.IO.MemoryStream
        $frame.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
        $payloads += [pscustomobject]@{ Size = $frame.Width; Bytes = $png.ToArray() }
        $png.Dispose()
      }
      else {
        $payloads += [pscustomobject]@{ Size = $frame.Width; Bytes = (ConvertTo-SailuoDib32 -Bitmap $frame) }
      }
    }

    $ms = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter($ms)
    $writer.Write([uint16]0)                 # reserved
    $writer.Write([uint16]1)                 # type: icon
    $writer.Write([uint16]$frames.Count)     # image count
    $offset = 6 + 16 * $frames.Count
    foreach ($payload in $payloads) {
      $dimension = if ($payload.Size -ge 256) { 0 } else { $payload.Size }
      $writer.Write([byte]$dimension)
      $writer.Write([byte]$dimension)
      $writer.Write([byte]0)                 # palette count
      $writer.Write([byte]0)                 # reserved
      $writer.Write([uint16]1)               # planes
      $writer.Write([uint16]32)              # bits per pixel
      $writer.Write([uint32]$payload.Bytes.Length)
      $writer.Write([uint32]$offset)
      $offset += $payload.Bytes.Length
    }
    foreach ($payload in $payloads) { $writer.Write([byte[]]$payload.Bytes) }
    $writer.Flush()
    [System.IO.File]::WriteAllBytes($OutIcoPath, $ms.ToArray())
    $writer.Dispose()
    $ms.Dispose()
    foreach ($frame in $frames) { $frame.Dispose() }
    return $OutIcoPath
  }
  catch {
    return $null
  }
}

function ConvertTo-SailuoDib32([System.Drawing.Bitmap]$Bitmap) {
  # Builds the ICO "image" payload for a 32bpp frame: BITMAPINFOHEADER with a
  # doubled height, bottom-up BGRA XOR pixels and a fully transparent AND mask.
  $size = $Bitmap.Width
  $rect = New-Object System.Drawing.Rectangle(0, 0, $size, $size)
  $locked = $Bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $stride = $locked.Stride
  $pixels = New-Object byte[] ($stride * $size)
  [System.Runtime.InteropServices.Marshal]::Copy($locked.Scan0, $pixels, 0, $pixels.Length)
  $Bitmap.UnlockBits($locked)

  $maskStride = [int]([Math]::Floor(($size + 31) / 32) * 4)
  $mask = New-Object byte[] ($maskStride * $size)

  $ms = New-Object System.IO.MemoryStream
  $writer = New-Object System.IO.BinaryWriter($ms)
  $writer.Write([uint32]40)                # biSize
  $writer.Write([int32]$size)              # biWidth
  $writer.Write([int32]($size * 2))        # biHeight (XOR + AND)
  $writer.Write([uint16]1)                 # biPlanes
  $writer.Write([uint16]32)                # biBitCount
  $writer.Write([uint32]0)                 # biCompression = BI_RGB
  $writer.Write([uint32]($size * $size * 4))
  $writer.Write([int32]0)                  # biXPelsPerMeter
  $writer.Write([int32]0)                  # biYPelsPerMeter
  $writer.Write([uint32]0)                 # biClrUsed
  $writer.Write([uint32]0)                 # biClrImportant
  for ($row = $size - 1; $row -ge 0; $row--) {
    $writer.Write($pixels, $row * $stride, $size * 4)
  }
  $writer.Write($mask, 0, $mask.Length)
  $writer.Flush()
  $result = $ms.ToArray()
  $writer.Dispose()
  $ms.Dispose()
  return $result
}

function Ensure-SailuoDesktopIcons {
  $icoDir = 'C:\Sailuo\icons'
  New-Item -ItemType Directory -Path $icoDir -Force -ErrorAction SilentlyContinue | Out-Null
  # -Force upgrades icons produced by the old single-frame generator.
  # Dashboard badge matches the in-app brand mark (cyan -> indigo gradient, "S").
  New-SailuoAppIcon "$icoDir\sailuo-dashboard.ico"   'S'   2   132 199 67  56  202 ''          -Force | Out-Null
  New-SailuoAppIcon "$icoDir\cloud-save.ico"         'CLD' 56  189 248 3   105 161 'SAVE'      -Force | Out-Null
  New-SailuoAppIcon "$icoDir\persist-folder.ico"     'DIR' 234 179 8   161 98  7   'PERSIST'   -Force | Out-Null
  New-SailuoAppIcon "$icoDir\bluestacks.ico"         'BS5' 59  130 246 29  78  216 'ANDROID'   -Force | Out-Null
  return $icoDir
}

Log 'lib-common dimuat'
