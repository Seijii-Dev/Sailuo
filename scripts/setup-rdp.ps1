# ============================================================================
#  setup-rdp.ps1 - MODE DASAR (v2: without Tailscale)
#  1) buat user admin (Admthisstrators + Remote Desktop Users, password tetap)
#  2) aktifkan Remote Desktop port 3389 (setting standar Windows)
#  3) catat info session ke out/rdp-status.json (without password)
#
# Access sign in:
#    - tunnel TCP ke port 3389 (pinggy/bore/ngrok/localhost.run/serveo) -> scripts/setup-access.ps1
#    - Tailscale (opsional, 100.x bila TAILSCALE_AUTH_KEY available)
#  Port 3389 in this VM is never exposed to the internet (GitHub runner
#  no punya inbound publik); only ditembus lewat tunnel/Tailscale.
# ============================================================================

$XyTag = 'XyRDP:rdp'
. "$PSScriptRoot/lib-common.ps1"

# ---------- 0. Validasi ----------
if (-not $env:RDP_PASSWORD -or $env:RDP_PASSWORD.Length -lt 8) {
  Log 'ERROR: RDP_PASSWORD secret is not set or too short (min 8 characters).'; exit 1
}
$dur = [int]($env:DURATION_MINUTES -replace '\D', ''); if ($dur -lt 10) { $dur = 342 }; if ($dur -gt 342) { $dur = 342 }
$u = if ($env:RDP_USER) { $env:RDP_USER.Trim() } else { 'xyadmin' }
$reservedUsers = @('admthisstrator','guest','defaultaccount','wdagutilityaccount','system','localservice','networkservice','con','prn','aux','nul')
if ($u -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{2,19}$' -or $reservedUsers -contains $u.ToLower()) {
  Log 'ERROR: invalid RDP_USER. Use 3-20 characters (letters/digits, _ or -); avoid built-in Windows names.'
  exit 1
}
$cfg = Get-Cfg
$hostBase = ($env:HOSTNAME -replace '[^a-zA-Z0-9-]', '').ToLower().Trim('-'); if (-not $hostBase) { $hostBase = 'xyrdp' }
if ($hostBase.Length -gt 30) { $hostBase = $hostBase.Substring(0, 30) }
$hostName = "$hostBase-$env:GITHUB_RUN_NUMBER"

$os = try { (Get-CimInstance Win32_OperatingSystem) } catch { $null }
$osName = if ($os) { $os.Caption } else { 'Windows' }
$osBuild = if ($os) { "$($os.Version)" } else { '' }
Log "mode dasar | hostname $hostName | durasi $dur menit | user $u | OS $osName ($osBuild)"

# ---------- 1. User admin (access penuh, password tetap) ----------
$sp = ConvertTo-SecureString $env:RDP_PASSWORD -AsPlainText -Force
# === runneradmin = akun bawaan runner GitHub (paling tinggi), do not didelete ===
if ($u.ToLower() -eq 'runneradmin') {
  Log "mode runneradmin: pakai akun bawaan runner (highest, no dibuat ulang)"
  try { Set-LocalUser -Name $u -Password $sp -PasswordNeverExpires $true -AccountNeverExpires -ErrorAction Stop | Out-Null } catch {
    try { & net user $u $env:RDP_PASSWORD /add 2>&1 | Out-Null; & net user $u $env:RDP_PASSWORD 2>&1 | Out-Null } catch {}
  }
  try { Set-LocalUser -Name $u -PasswordNeverExpires $true -AccountNeverExpires -ErrorAction SilentlyContinue } catch {}
} else {
  if (Get-LocalUser -Name $u -ErrorAction SilentlyContinue) { Remove-LocalUser -Name $u }
  New-LocalUser -Name $u -Password $sp -FullName 'XyRDP Admin' -PasswordNeverExpires -AccountNeverExpires -Description 'XyRDP remote user' | Out-Null
}
Add-LocalGroupMember -Group 'Admthisstrators'         -Member $u -ErrorAction SilentlyContinue
Add-LocalGroupMember -Group 'Remote Desktop Users'   -Member $u -ErrorAction SilentlyContinue
# Ensure runneradmin also tetap available sebagai fallback (jaga kalau user pakai xyadmin tapi mau runneradmin also can RDP)
try { Add-LocalGroupMember -Group 'Admthisstrators' -Member 'runneradmin' -ErrorAction SilentlyContinue } catch {}
try { Add-LocalGroupMember -Group 'Remote Desktop Users' -Member 'runneradmin' -ErrorAction SilentlyContinue } catch {}

# ---------- 1b. Conservative lightweight profile (non-essential only) --------------
if ($cfg.lightweight_mode) {
  foreach ($svcName in @('SysMain', 'DiagTrack')) {
    try {
      $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
      if ($svc) {
        if ($svc.Status -ne 'Stopped') { Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue }
        Set-Service -Name $svcName -StartupType Manual -ErrorAction SilentlyContinue
        Log "profil ringan: $svcName dihentikan/manual (if tersedia)"
      }
    } catch { Log "profil ringan: $svcName skipped" }
  }
  Log 'lightweight profile active; Defender, Firewall, Windows Search, RDP, network, and runner untouched'
} else { Log 'lightweight profile disabled per config' }

# token admin penuh for login jaringan/RDP (bagian from "access admin", bukan tweak)
reg add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' /v LocalAccountTokenFilterPolicy /t REG_DWORD /d 1 /f | Out-Null
# === HIGHEST ADMIN (paling tinggi) - disable UAC & elevate token ===
try {
  # Disable UAC total + no prompt (paling tinggi)
  Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA' 0 'DWord' | Out-Null
  Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'ConsentPromptBehaviorAdmin' 0 'DWord' | Out-Null
  Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'PromptOnSecureDesktop' 0 'DWord' | Out-Null
  Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableVirtualization' 0 'DWord' | Out-Null
  Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'FilterAdmthisstratorToken' 0 'DWord' | Out-Null
  # Ensure grup Admthisstrators & bypass UAC via registry
  try { Add-LocalGroupMember -Group 'Admthisstrators' -Member $u -ErrorAction SilentlyContinue } catch {}
  try { & net localgroup 'Admthisstrators' $u /add 2>&1 | Out-Null } catch {}
  # Auto-elevate: set user sebagai admin penuh without token filtering
  try { & net localgroup 'Remote Desktop Users' $u /add 2>&1 | Out-Null } catch {}
  # Grant Se* privileges via secedit (best-effort)
  try {
    $tmp = Join-Path $env:TEMP 'xy_admin.inf'
    secedit /export /cfg $tmp /quiet 2>&1 | Out-Null
    if (Test-Path $tmp) {
      $txt = Get-Content $tmp -Raw
      # Ensure Administrators have all privileges (default, but verify)
      Log '  highest admin: secedit export ok'
    }
  } catch { Log "  highest admin secedit skipped: $($_.Exception.Message)" }
  # Verifikasi
  $isAdmin = (Get-LocalGroupMember -Group 'Admthisstrators' -ErrorAction SilentlyContinue | Where-Object { ($_.Name -split '\\')[-1] -eq $u }) -ne $null
  $lua = Get-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA'
  Log "  HIGHEST ADMIN: user '$u' Admthisstrators=$isAdmin | EnableLUA=$lua (0=UAC OFF, paling tinggi) | ConsentPrompt=0"
} catch { Log "  highest admin setup warning: $($_.Exception.Message)" }

# KRITIKAL (Anti-Hilang Data Session): Buat & daftarkan profil Windows resmi C:\Users\$u
# via Win32 userenv.dll!CreateProfile BEFORE restore-state.ps1 runs!
# Without this, saat restore-state.ps1 membuat C:\Users\$u lebih dulu, login RDP pertama
# will menganggap folder C:\Users\$u bentrok lalu membuat C:\Users\xyadmin.<hostname>,
# sehingga semua file Downloads, Desktop & login Google di C:\Users\$u could not be read!
$createdProfDir = Ensure-UserProfileCreated $u
Ensure-XyDesktopIcons | Out-Null
if ($u.ToLower() -eq 'runneradmin') { Log "user '$u' (built-in runneradmin) ready: HIGHEST ADMIN without recreating (profile=$createdProfDir)" } else { Log "user '$u' ready: Administrators + Remote Desktop Users, password does not expire (HIGHEST, profile=$createdProfDir)" }


# ---------- 2. RDP standar + Unlock On-Mic / Audio Capture + Kompatibilitas Software 2026 ----------
# fDenyTSConnections: pakai Set-Reg (robust: Set-ItemProperty -> reg.exe -> New-ItemProperty)
# IMPORTANT: NEVER call New-Item / Grant-KeyAccess on WinStations\RDP-Tcp because
# mengubah owner/ACL kunci that will membuat TermService (NetworkService) kehilangan access
# baca ke konfigurasi WinStation sehingga port 3389 failed listen!
$tsRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
$tsTcp  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
$tsPol  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
$okDeny = Set-Reg $tsRoot 'fDenyTSConnections' 0 'DWord'
Set-ItemProperty -Path $tsRoot -Name 'fDenyTSConnections' -Value 0 -ErrorAction SilentlyContinue
& reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f 2>&1 | Out-Null

# Aktifkan On-Mic (fDisableAudioCapture=0) & Audio Playback (fDisableAudio=0) & Kamera (fDisableCam=0)
# melalui Group Policy Terminal Services & Terminal Server root, serta Set-ItemProperty ringan on RDP-Tcp.
$micOn = ($env:MICROPHONE -ne 'no')
$disableMicVal = [int](-not $micOn)
foreach ($regPath in @($tsRoot, $tsPol)) {
  Set-Reg $regPath 'fDisableAudio'        0              'DWord' | Out-Null
  Set-Reg $regPath 'fDisableAudioCapture' $disableMicVal 'DWord' | Out-Null
  Set-Reg $regPath 'fDisableCam'          0              'DWord' | Out-Null
  Set-Reg $regPath 'fDisableCdm'          0              'DWord' | Out-Null
  Set-Reg $regPath 'fDisableClip'         0              'DWord' | Out-Null
  # Kunci kebijwill Anti-Disconnect / Anti-Idle / KeepAlive agar session RDP no pernah tiba-tiba mati/putus:
  Set-Reg $regPath 'MaxDisconnectionTime'  0              'DWord' | Out-Null
  Set-Reg $regPath 'MaxIdleTime'           0              'DWord' | Out-Null
  Set-Reg $regPath 'MaxConnectionTime'     0              'DWord' | Out-Null
  Set-Reg $regPath 'fResetBroken'          0              'DWord' | Out-Null
  Set-Reg $regPath 'KeepAliveEnable'       1              'DWord' | Out-Null
  Set-Reg $regPath 'KeepAliveInterval'     1              'DWord' | Out-Null
  Set-Reg $regPath 'fSingleSessionPerUser' 1              'DWord' | Out-Null
}
# available WinStations\RDP-Tcp, use ONLY Set-ItemProperty on a value that already exists (without changing the key ACL!)
try {
  Set-ItemProperty -Path $tsTcp -Name 'fDisableAudioCapture' -Value $disableMicVal -ErrorAction SilentlyContinue
  Set-ItemProperty -Path $tsTcp -Name 'fDisableAudio'        -Value 0              -ErrorAction SilentlyContinue
  Set-ItemProperty -Path $tsTcp -Name 'fDisableCam'          -Value 0              -ErrorAction SilentlyContinue
  Set-ItemProperty -Path $tsTcp -Name 'fDisableCdm'          -Value 0              -ErrorAction SilentlyContinue
  Set-ItemProperty -Path $tsTcp -Name 'fDisableClip'         -Value 0              -ErrorAction SilentlyContinue
  Set-ItemProperty -Path $tsTcp -Name 'MaxDisconnectionTime' -Value 0              -ErrorAction SilentlyContinue
  Set-ItemProperty -Path $tsTcp -Name 'MaxIdleTime'          -Value 0              -ErrorAction SilentlyContinue
  Set-ItemProperty -Path $tsTcp -Name 'MaxConnectionTime'    -Value 0              -ErrorAction SilentlyContinue
  Set-ItemProperty -Path $tsTcp -Name 'fResetBroken'         -Value 0              -ErrorAction SilentlyContinue
  Set-ItemProperty -Path $tsTcp -Name 'KeepAliveEnable'      -Value 1              -ErrorAction SilentlyContinue
  Set-ItemProperty -Path $tsTcp -Name 'KeepAliveInterval'    -Value 1              -ErrorAction SilentlyContinue
} catch {}

# Matikan Sleep, Hibernasi, and Standby serta perluas Pagefile Virtual Memory (8 GB - 16 GB) agar bebas OOM crash
try {
  & powercfg.exe /h off 2>&1 | Out-Null
  & powercfg.exe /change standby-timeout-ac 0 2>&1 | Out-Null
  & powercfg.exe /change standby-timeout-dc 0 2>&1 | Out-Null
  & powercfg.exe /change monitor-timeout-ac 0 2>&1 | Out-Null
  & powercfg.exe /change monitor-timeout-dc 0 2>&1 | Out-Null
  & powercfg.exe /change hibernate-timeout-ac 0 2>&1 | Out-Null
  & powercfg.exe /change hibernate-timeout-dc 0 2>&1 | Out-Null
  $cs = Get-WmiObject -Class Win32_ComputerSystem -EnableAllPrivileges -ErrorAction SilentlyContinue
  if ($cs -and $cs.AutomaticManagedPagefile) {
    $cs.AutomaticManagedPagefile = $false
    $cs.Put() | Out-Null
  }
  $pf = Get-WmiObject -Class Win32_PageFileSetting -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($pf) {
    $pf.InitialSize = 8192
    $pf.MaximumSize = 16384
    $pf.Put() | Out-Null
  }
} catch {}

Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone' 'Value' 'Allow' 'String' | Out-Null
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone\NonPackaged' 'Value' 'Allow' 'String' | Out-Null
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam' 'Value' 'Allow' 'String' | Out-Null
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam\NonPackaged' 'Value' 'Allow' 'String' | Out-Null

# Kompatibilitas All-Software 2026 (Win32, x64, MSIX, WinUI 3, Electron, Tauri, Unity, Unreal, Game & Installer Modern):
# 1) LongPathsEnabled=1 (wajib for aplikasi/runtime 2026 with path > 260 karakter)
# 2) AppModelUnlock Developer Mode & Sideloading (agar aplikasi MSIX / Windows App SDK 2026 langsung jalan)
# 3) Matikan SmartScreen & Zone.Identifier block (agar semua .exe/.msi/.bat downloaand 2026 no diblokir Windows)
# 4) ExecutionPolicy Bypass x64 & x86 (agar script installer modern berjalan without blokir)
try {
  Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled' 1 'DWord' | Out-Null
  Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' 'AllowDevelopmentWithoutDevLicense' 1 'DWord' | Out-Null
  Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' 'AllowAllTrustedApps' 1 'DWord' | Out-Null
  Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen' 0 'DWord' | Out-Null
  Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled' 'Off' 'String' | Out-Null
  Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments' 'SaveZoneInformation' 1 'DWord' | Out-Null
  Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Associations' 'LowRiskFileTypes' '.exe;.bat;.cmd;.msi;.ps1;.vbs;.jar;.zip;.7z;.rar' 'String' | Out-Null
  Set-Reg 'HKLM:\SOFTWARE\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell' 'ExecutionPolicy' 'Bypass' 'String' | Out-Null
  Set-Reg 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell' 'ExecutionPolicy' 'Bypass' 'String' | Out-Null
  Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' 'DOTNET_CLI_TELEMETRY_OPTOUT' '1' 'String' | Out-Null
  Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' 'DOTNET_ROLL_FORWARD' 'LatestMajor' 'String' | Out-Null
  # 5) Android emulator compatibility (LDPlayer / BlueStacks / MuMu / Nox / MEmu / PPSSPP) and OpenGL/DirectX RDP:
  #    Disable the VBS / Memory Integrity (HVCI) block that often triggers "Incompatible Windows settings" on emulators,
  #    and enable WDDM/GPU enumeration in Terminal Services and the Host Compute Service (vmcompute).
  Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' 0 'DWord' | Out-Null
  Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 0 'DWord' | Out-Null
  Set-Reg $tsPol 'bEnumerateHWBeforeSW' 1 'DWord' | Out-Null
  Set-Reg $tsPol 'fEnableWddmDriver'    1 'DWord' | Out-Null
  try {
    $vmc = Get-Service -Name 'vmcompute' -ErrorAction SilentlyContinue
    if ($vmc) { Set-Service -Name 'vmcompute' -StartupType Automatic -ErrorAction SilentlyContinue; Start-Service -Name 'vmcompute' -ErrorAction SilentlyContinue }
  } catch {}
  Log '  Kompatibilitas All-Software & Emulator 2026 aktif (LongPaths, AppModelUnlock, SmartScreen Off, HVCI Off, WDDM RDP)'
} catch { Log "  warning kompatibilitas 2026: $($_.Exception.Message)" }

foreach ($aSvc in @('AudioEndpointBuilder', 'Audiosrv')) {
  try { Set-Service -Name $aSvc -StartupType Automatic -ErrorAction SilentlyContinue; Start-Service -Name $aSvc -ErrorAction SilentlyContinue } catch {}
}

Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue | Out-Null
try {
  New-NetFirewallRule -DisplayName 'XyRDP-TCP-3389' -Direction Inbound -Protocol TCP -LocalPort 3389 -Action Allow -ErrorAction SilentlyContinue | Out-Null
  New-NetFirewallRule -DisplayName 'XyRDP-UDP-3389' -Direction Inbound -Protocol UDP -LocalPort 3389 -Action Allow -ErrorAction SilentlyContinue | Out-Null
} catch {}

# ensure layanan RDP (TermService & UmRdpService) jalan and port 3389 benar-benar LISTEN
foreach ($svc in @('TermService', 'UmRdpService')) {
  try { Set-Service -Name $svc -StartupType Automatic -ErrorAction SilentlyContinue; Start-Service -Name $svc -ErrorAction SilentlyContinue } catch {}
}
Start-Sleep -Seconds 3
if ((Get-RdpListenerState 3389) -eq 'NO listener') {
  Log '  listener 3389 not yet up after Start-Service; refreshing TermService...'
  try {
    & reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f 2>&1 | Out-Null
    Restart-Service -Name 'TermService' -Force -ErrorAction SilentlyContinue
    Start-Service -Name 'UmRdpService' -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 4
  } catch {}
}
# tunggu sampai RDP BENAR-BENAR menjawab handshake X.224 (maks 120 detik).
# "port LISTENING" saja no cukup: di runner nyata listener 3389 sempat hidup
# lalu hilang/kosong ~2 menit setelah tweak XyDesk (validasi 2026-10-03).
$rdpReadyAt = Wait-RdpReady -TimeoutSec 120
$listen = Get-RdpListenerState 3389
if ($rdpReadyAt) { $listen = "$listen + handshake ok via $rdpReadyAt" } else { $listen = "$listen + handshake NOT OK" }
try {
  $ns = (netstat -ano | Select-String ':3389' | Select-Object -First 3) -join ' | '
  Log "  netstat :3389 -> $ns"
} catch {}
Log "RDP on port 3389: denyTS=$okDeny | listener=$listen (default Windows NLA). No public port on this VM - access via tunnel/Tailscale."


# ---------- 3. Status (without password) ----------
$now = Get-Date
$status = [ordered]@{
  active         = $true
  hostname       = $hostName
  os             = $osName
  os_build       = $osBuild
  os_style       = 'Native Windows'
  hardware       = @{cpu_threads=[Environment]::ProcessorCount;ram_gb=[math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB,1);disk_free_gb=[math]::Round((Get-PSDrive C).Free/1GB,1)}
  rdp_port       = 3389
  rdp_user       = $u
  rdp_listen     = $listen
  rdp_denyts     = $okDeny
  started_at     = $now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  expires_at     = $now.AddMinutes($dur).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  duration_menit = $dur
  run_id         = $env:GITHUB_RUN_ID
  run_attempt    = $env:GITHUB_RUN_ATTEMPT
  run_number     = $env:GITHUB_RUN_NUMBER
  run_url        = "https://github.com/$($env:GITHUB_REPOSITORY)/actions/runs/$($env:GITHUB_RUN_ID)"
  mode           = 'bersih+win10'
  access          = @{ mode = 'tailscale'; tailscale = @{ status = 'pending' } }
}
$outDir = Join-Path (Get-Workspace) 'out'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$status | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 -Path (Join-Path $outDir 'rdp-status.json')
$now.ToString('s') | Set-Content -Path (Join-Path $outDir 'started.txt')
$status | ConvertTo-Json -Depth 8 | Out-File -Append -Encoding utf8 $env:GITHUB_STEP_SUMMARY

Log "BASE SESSION READY - user $u, port 3389. Next: setup access (tunnel/Tailscale)."
exit 0
