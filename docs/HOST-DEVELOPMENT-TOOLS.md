# Host development tools — RdpFree / KallAncrit

Every new rdp-6h workflow run installs/verifies the requested tools before the
connection-ready summary. Existing live sessions are not modified remotely.
A failed verification fails the setup step instead of claiming installation.
Installers have timeouts, and no automatic reboot is issued.

## Installed tools and checks

- WinRAR 7.23 x64, official vendor trial (license not included). Pinned SHA256
  comes from microsoft/winget-pkgs RARLab.WinRAR 7.23.0. Verify WinRAR.exe version,
  then actually create and test an archive with Rar.exe.
- Current Microsoft Visual C++ v14 x86 and x64 from signed official Microsoft
  installers. Check both runtime DLL sets and installed version >= downloaded
  version. This does not claim all historical VC++ releases are installed.
- XAMPP 8.2.12 at C:\xampp, vendor distribution via SourceForge. SHA256 pinned
  to microsoft/winget-pkgs ApacheFriends.Xampp.8.2 8.2.12-0. Verify control panel,
  PHP CLI, Apache syntax test, MariaDB version command. This is an older dev
  bundle, not a hardened/current public production hosting stack. Do not expose
  its admin panel/database directly to the internet. On fresh installation,
  Apache 80/443 and MariaDB bind to loopback. Services are not launched by this
  script, and no firewall openings for XAMPP services are added. Existing XAMPP
  configuration is preserved; incomplete/custom existing directories are not
  overwritten. Start needed components manually through C:\xampp\xampp-control.exe.

## Validation

Windows Server 2022 run: https://github.com/xykal/XyRDP/actions/runs/38363805003
Passed parsing, fresh installation, real executable checks, WinRAR archive test,
and repeated setup. VC++ observed: 14.51.36247.0 for both architectures. XAMPP
PHP 8.2.12 and MariaDB 10.4.32 executed successfully; Apache configuration check
exited zero. Installer and runtime reports are written at
C:\ProgramData\RdpFree\host-tools\report.json and included in private dashboard
status data as host_tools. No remote TCP/UDP reachability, Apache HTTP request,
or database login has been tested. No RDP session started or stopped for this
validation.
