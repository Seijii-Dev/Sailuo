# ============================================================================
#  lib-common.ps1 - shared helpers for all XyRDP scripts (v2: Win10-style,
#  private Tailscale access). Dot-source it like this:
#
#      $XyTag = 'XyRDP:access'
#      . "$PSScriptRoot/lib-common.ps1"
#
#  Contains: logger, registry helper, configuration reader (assets/rdp-extras.json),
#  Default-profile hive manager, out/rdp-status.json reader/writer.
# ============================================================================

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 } catch {}

# ---------- log ----------
function Log([string]$m) {
  $tag = if ($script:XyTag) { $script:XyTag } else { 'XyRDP' }
  Write-Host ("[{0:HH:mm:ss} UTC][{1}] {2}" -f [DateTime]::UtcNow,$tag,$m)
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

# ---------- konfigurasi (assets/rdp-extras.json) ----------
$script:XyCfgDefaults = [ordered]@{
  lightshot        = $false           # do not run the background app unless requested
  wallpaper        = $true
  wallpaper_file   = 'wallpaper.jpg'
  win10_look       = $true            # all Windows 10 visual tweaks
  win10_badge      = $true            # "Windows 10 Pro" label in the registry (cosmetic)
  win10_wallpaper  = $true            # use the Windows 10 style wallpaper
  xydesk_host      = $true            # host setup for the XyDesk Remote client (AVC444/ClearType/audio)
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
  $path = Join-Path (Get-Workspace) 'assets\rdp-extras.json'
  if (Test-Path $path) {
    try { $j = Get-Content $path -Raw | ConvertFrom-Json; Log 'configuration: assets/rdp-extras.json' }
    catch { Log "rdp-extras.json could not be read ($($_.Exception.Message)) - use defaults" }
  } else { Log 'assets/rdp-extras.json is missing - use defaults' }

  $c = [pscustomobject]@{}
  foreach ($k in $script:XyCfgDefaults.Keys) {
    $c | Add-Member -NotePropertyName $k -NotePropertyValue $script:XyCfgDefaults[$k] -Force
  }
  if ($j) {
    foreach ($k in @('lightshot','wallpaper','win10_look','win10_badge','win10_wallpaper','xydesk_host','dark_theme','lightweight_mode','vscode','notepadpp','storage_boost')) {
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

# ---------- status file (out/rdp-status.json) ----------
function Get-StatusPath {
  return (Join-Path (Get-Workspace) 'out\rdp-status.json')
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

# ---------- hive profil Default (setting ikut user RDP saat login pertama) ----------
$script:DefHiveKey = 'XyRDP_Def'
$script:DefHive    = 'HKU\XyRDP_Def'
$script:DefReg     = 'Registry::HKEY_USERS\XyRDP_Def'
$script:HiveLoaded = $false

function Open-DefaultHive {
  if ($script:HiveLoaded) { return $true }
  try {
    & reg load $script:DefHive 'C:\Users\Default\NTUSER.DAT' 2>&1 | Out-Null
    Start-Sleep -Milliseconds 600
    if (Test-Path $script:DefReg) { $script:HiveLoaded = $true; Log 'profil Default di-load (setting ikut user RDP saat login pertama)'; return $true }
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
#     setelah tweak XyDesk, and koneksi ke 127.0.0.1 can ditolak sementara
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
# that (or $null). Kalau lama does not exist, TermService di-restart sekali.
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
    # CATATAN: restart TermService SENGAJA no dilakukan lagi - on runner
    # GitHub, a restart does not bring listener 3389 back (proven on
    # validasi 2026-10-03: menunggu 240s + 150s tetap mati). Kita cukup menunggu
    # and reported what is there; the cause is already mentioned in setup-xydesk.
    Start-Sleep -Seconds 8
  }
  Log "  RDP not yet menjawab handshake setelah ${TimeoutSec}s"
  return $null
}

# probe satu baris: dipakai for melacak step mana that merusak RDP
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
        $req = Invoke-RestMethod -Uri $u -Headers @{ 'Accept' = 'application/json'; 'User-Agent' = 'XyRDP' } -TimeoutSec 30
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
      $r = Invoke-RestMethod -Uri "https://check-host.net/check-result/$rid" -Headers @{ 'Accept' = 'application/json'; 'User-Agent' = 'XyRDP' } -TimeoutSec 30
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
  # curl.exe (available di runner Windows) -> batas waktu keras, no can menggantung
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
  $hdrs = @{ 'User-Agent' = 'XyRDP' }
  if ($env:GITHUB_TOKEN) { $hdrs['Authorization'] = "Bearer $($env:GITHUB_TOKEN)" }
  foreach ($h in @($hdrs, @{ 'User-Agent' = 'XyRDP' })) {
    try {
      $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers $h -TimeoutSec 60
      $a = $rel.assets | Where-Object { $_.name -match $NameRegex } | Select-Object -First 1
      if ($a) { return @{ url = $a.browser_download_url; tag = $rel.tag_name; name = $a.name } }
    } catch { Log "  GitHub API ($Repo) failed: $($_.Exception.Message)" }
  }
  return $null
}

# fallback URL keras (kalau API no can dipakai sama sekali)
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
        Add-Type -TypeDefthistion @"
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
    # Ensure ProfileList menunjuk ke folder profil that konsisten & milik user penuh
    if (-not (Test-Path $targetDir)) {
      New-Item -ItemType Directory -Path $targetDir -Force -ErrorAction SilentlyContinue | Out-Null
    }
    if (Test-Path $profKey) {
      Set-ItemProperty -Path $profKey -Name 'ProfileImagePath' -Value $targetDir -ErrorAction SilentlyContinue
      Set-ItemProperty -Path $profKey -Name 'State' -Value 0 -Type DWord -ErrorAction SilentlyContinue
    }
    & icacls $targetDir /grant "${UserName}:(OI)(CI)F" /grant "Admthisstrators:(OI)(CI)F" /grant "SYSTEM:(OI)(CI)F" /C /Q 2>&1 | Out-Null
  } catch {
    Log "  Ensure-UserProfileCreated warning: $($_.Exception.Message)"
  }
  return $targetDir
}

function Get-AllUserProfileDirs([string]$UserName) {
  $dirs = New-Object System.Collections.Generic.List[string]
  if ($UserName) {
    try {
      $acct = New-Object System.Security.Principal.NTAccount($UserName)
      $sid = $acct.Translate([System.Security.Principal.SecurityIdentifier]).Value
      $profKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
      if (Test-Path $profKey) {
        $p = (Get-ItemProperty -Path $profKey -Name 'ProfileImagePath' -ErrorAction SilentlyContinue).ProfileImagePath
        if ($p -and (Test-Path $p) -and -not $dirs.Contains($p)) { $dirs.Add($p) }
      }
    } catch {}
    $base = "C:\Users\$UserName"
    if ((Test-Path $base) -and -not $dirs.Contains($base)) { $dirs.Add($base) }
    Get-ChildItem -Path 'C:\Users' -Directory -Filter "$UserName.*" -ErrorAction SilentlyContinue | ForEach-Object {
      if (-not $dirs.Contains($_.FullName)) { $dirs.Add($_.FullName) }
    }
  }
  if ($dirs.Count -eq 0 -and $UserName) {
    $dirs.Add("C:\Users\$UserName")
  }
  return $dirs.ToArray()
}

function Copy-FileUnlocked([string]$SourceFile, [string]$DestFile) {
  if (-not (Test-Path -LiteralPath $SourceFile -PathType Leaf)) { return $false }
  try {
    $parent = Split-Path -Path $DestFile -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
      New-Item -ItemType Directory -Path $parent -Force -ErrorAction SilentlyContinue | Out-Null
    }
    Copy-Item -LiteralPath $SourceFile -Destination $DestFile -Force -ErrorAction Stop
    return $true
  } catch {
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
      return $false
    }
  }
}

function Copy-TreeUnlocked([string]$SourceDir, [string]$DestDir) {
  if (-not (Test-Path -LiteralPath $SourceDir)) { return }
  if (Test-Path -LiteralPath $SourceDir -PathType Leaf) {
    Copy-FileUnlocked $SourceDir $DestDir | Out-Null
    return
  }
  New-Item -ItemType Directory -Path $DestDir -Force -ErrorAction SilentlyContinue | Out-Null
  Get-ChildItem -LiteralPath $SourceDir -Force -ErrorAction SilentlyContinue | ForEach-Object {
    $target = Join-Path $DestDir $_.Name
    if ($_.PSIsContainer) {
      Copy-TreeUnlocked $_.FullName $target
    } else {
      Copy-FileUnlocked $_.FullName $target | Out-Null
    }
  }
}

# ---------- 11. Generator Ikon Unik Desktop (.ico 64x64 ARGB Berwarna) ----------
function New-XyAppIcon([string]$OutIcoPath, [string]$BadgeText, [int]$R1, [int]$G1, [int]$B1, [int]$R2, [int]$G2, [int]$B2, [string]$SubText = '') {
  try {
    if (Test-Path -LiteralPath $OutIcoPath) { return $OutIcoPath }
    $dir = Split-Path -Path $OutIcoPath -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
    $bmp = New-Object System.Drawing.Bitmap(64, 64, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $g.Clear([System.Drawing.Color]::Transparent)

    $rect = New-Object System.Drawing.Rectangle(2, 2, 60, 60)
    $c1 = [System.Drawing.Color]::FromArgb(255, $R1, $G1, $B1)
    $c2 = [System.Drawing.Color]::FromArgb(255, $R2, $G2, $B2)
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $c1, $c2, 45.0)

    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = 16
    $path.AddArc(2, 2, $d, $d, 180, 90)
    $path.AddArc(62 - $d, 2, $d, $d, 270, 90)
    $path.AddArc(62 - $d, 62 - $d, $d, $d, 0, 90)
    $path.AddArc(2, 62 - $d, $d, $d, 90, 90)
    $path.CloseFigure()

    $g.FillPath($brush, $path)
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(140, 255, 255, 255), 2.0)
    $g.DrawPath($pen, $path)

    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center

    $fontSize = if ($BadgeText.Length -ge 3) { 16.5 } else { 21.0 }
    $font = New-Object System.Drawing.Font('Segoe UI', [float]$fontSize, [System.Drawing.FontStyle]::Bold)
    $textY = if ($SubText) { 26 } else { 32 }
    $g.DrawString($BadgeText, $font, [System.Drawing.Brushes]::White, [System.Drawing.PointF]::new(32.0, [float]$textY), $sf)

    if ($SubText) {
      $subFont = New-Object System.Drawing.Font('Segoe UI', 7.5, [System.Drawing.FontStyle]::Bold)
      $subBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(230, 255, 255, 255))
      $g.DrawString($SubText, $subFont, $subBrush, [System.Drawing.PointF]::new(32.0, 49.0), $sf)
      $subBrush.Dispose()
      $subFont.Dispose()
    }

    $msPng = New-Object System.IO.MemoryStream
    $bmp.Save($msPng, [System.Drawing.Imaging.ImageFormat]::Png)
    $pngBytes = $msPng.ToArray()
    $msPng.Dispose()
    $font.Dispose(); $pen.Dispose(); $path.Dispose(); $brush.Dispose(); $g.Dispose(); $bmp.Dispose()

    $fs = New-Object System.IO.FileStream($OutIcoPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    $bw = New-Object System.IO.BinaryWriter($fs)
    # ICONDIR header (6 bytes) + ICONDIRENTRY (16 bytes) + PNG payload
    $bw.Write([uint16]0)
    $bw.Write([uint16]1)
    $bw.Write([uint16]1)
    $bw.Write([byte]64)
    $bw.Write([byte]64)
    $bw.Write([byte]0)
    $bw.Write([byte]0)
    $bw.Write([uint16]1)
    $bw.Write([uint16]32)
    $bw.Write([uint32]$pngBytes.Length)
    $bw.Write([uint32]22)
    $bw.Write($pngBytes)
    $bw.Flush()
    $bw.Dispose()
    $fs.Dispose()
    return $OutIcoPath
  } catch {
    return $null
  }
}

function Ensure-XyDesktopIcons {
  $icoDir = 'C:\XyRDP\icons'
  New-Item -ItemType Directory -Path $icoDir -Force -ErrorAction SilentlyContinue | Out-Null
  New-XyAppIcon "$icoDir\xydesk-dashboard.ico"   'XY'  2   132 199 15  23  42  'DASHBOARD' | Out-Null
  New-XyAppIcon "$icoDir\cloud-save.ico"         'CLD' 56  189 248 3   105 161 'SAVE'      | Out-Null
  New-XyAppIcon "$icoDir\persist-folder.ico"     'DIR' 234 179 8   161 98  7   'PERSIST'   | Out-Null
  New-XyAppIcon "$icoDir\bluestacks.ico"         'BS5' 59  130 246 29  78  216 'ANDROID'   | Out-Null
  return $icoDir
}

Log 'lib-common dimuat'
