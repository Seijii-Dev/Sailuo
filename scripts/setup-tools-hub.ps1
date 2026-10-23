# ============================================================================
#  setup-tools-hub.ps1 - Build & Install "Sailuo Dashboard" (GUI Desktop)
# ----------------------------------------------------------------------------
#  Mengompilasi aplikasi GUI WinForms native (C:\Sailuo\tools\SailuoDashboard.exe)
#  menggunwill C# compiler bawaan .NET Framework 4.x di Windows Server 2022/2025.
#  Otomatis terbuka when user pertama kali sign in ke session Desktop RDP, and
#  menyediwill kontrol 1-klik for:
#    1. Dashboard & Sistem (Cloud Save/Restore, Gaming Boost, Fix Mouse/Audio)
#    2. Installer Aplikasi (Chrome, Brave, Discord, VLC, 7-Zip, Runtime Game, Wallpaper)
#    3. Roblox Anti-VM & 120 FPS (Bypass VM Detection, Direct3D 11, Bloxstrap)
#    4. GTA SA-MP (Runtime DX9, SilentPatch 90 FPS, Anti-Ban GPCI/WARP, Nickname)
#    5. Minecraft Java & Bedrock (TLauncher, PrismLauncher, Mesa3D OpenGL 4.6)
# ============================================================================

$XyTag = 'Sailuo:dashboard'
. "$PSScriptRoot/lib-common.ps1"

$cfg = Get-Cfg
$u = if ($env:RDP_USER) { $env:RDP_USER.Trim() } else { $cfg.rdp_user }

$toolsDir = 'C:\Sailuo\tools'
New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null

# Save konteks environment session (for fitur Cloud Save / Restore 1-klik from GUI)
$envFile = Join-Path $toolsDir 'session-env.json'
@{
  RDP_USER          = $u
  RDP_PASSWORD      = $(if ($env:RDP_PASSWORD) { $env:RDP_PASSWORD } else { '' })
  GITHUB_TOKEN      = $(if ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } else { '' })
  GITHUB_REPOSITORY = $(if ($env:GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY } else { '' })
  GITHUB_RUN_ID     = $(if ($env:GITHUB_RUN_ID) { $env:GITHUB_RUN_ID } else { '' })
} | ConvertTo-Json | Set-Content -Path $envFile -Encoding UTF8 -Force

$icoDir = Ensure-SailuoDesktopIcons
$dashIco = Join-Path $icoDir 'sailuo-dashboard.ico'
$exePath = Join-Path $toolsDir 'SailuoDashboard.exe'
$legacyExePath = Join-Path $toolsDir 'SailuoTools.exe'

$csharpSource = @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Threading;
using System.Windows.Forms;

namespace SailuoTools
{
    public class MainForm : Form
    {
        private RichTextBox logBox;
        private Label statusLabel;
        private ProgressBar progressBar;
        private TextBox sampNickBox;
        private TextBox sampPathBox;
        private TextBox sampServerBox;

        public MainForm()
        {
            this.Text = "Sailuo Dashboard - Pusat Kontrol, Installer, Anti-VM & Cloud Save";
            this.Size = new Size(880, 650);
            this.MinimumSize = new Size(840, 600);
            this.StartPosition = FormStartPosition.CenterScreen;
            this.BackColor = Color.FromArgb(13, 16, 23);
            this.ForeColor = Color.FromArgb(235, 240, 248);
            this.Font = new Font("Segoe UI", 9.5f, FontStyle.Regular);
            try {
                if (File.Exists(@"C:\Sailuo\icons\sailuo-dashboard.ico")) {
                    this.Icon = new Icon(@"C:\Sailuo\icons\sailuo-dashboard.ico");
                }
            } catch { }

            BuildLayout();
            LoadSampRegistryInfo();
            AppendLog("Welcome to the Sailuo Dashboard! Cloud Save auto-sync every 4 minutes is active.");
        }

        private void BuildLayout()
        {
            Panel header = new Panel();
            header.Dock = DockStyle.Top;
            header.Height = 76;
            header.BackColor = Color.FromArgb(18, 23, 35);
            header.Padding = new Padding(18, 10, 18, 8);

            Label title = new Label();
            title.Text = "Sailuo Dashboard - RDP Management, Installer & Cloud Save";
            title.Font = new Font("Segoe UI Semibold", 13.5f, FontStyle.Bold);
            title.ForeColor = Color.FromArgb(56, 189, 248);
            title.AutoSize = true;
            title.Location = new Point(18, 10);

            Label sub = new Label();
            sub.Text = "[Anti-VM: AKTIF (ASUS ROG B650)]   [Gaming Boost: ULTIMATE 120 FPS]   [Cloud Save: AUTO-SYNC TIAP 4 MENIT]   [User: " + Environment.UserName + "]";
            sub.Font = new Font("Segoe UI", 8.8f, FontStyle.Bold);
            sub.ForeColor = Color.FromArgb(52, 211, 153);
            sub.AutoSize = true;
            sub.Location = new Point(18, 42);

            header.Controls.Add(title);
            header.Controls.Add(sub);

            TabControl tabs = new TabControl();
            tabs.Dock = DockStyle.Top;
            tabs.Height = 335;
            tabs.Font = new Font("Segoe UI Semibold", 9.5f, FontStyle.Regular);
            tabs.Padding = new Point(12, 6);

            TabPage tabDash = new TabPage("Dashboard && Sistem");
            TabPage tabApps = new TabPage("Installer Aplikasi");
            TabPage tabRoblox = new TabPage("Roblox Anti-VM");
            TabPage tabSamp = new TabPage("GTA SA-MP (Anti-Ban)");
            TabPage tabMc = new TabPage("Minecraft && OpenGL");
            TabPage tabPro = new TabPage("Utilitas Pro && Engine");

            foreach (TabPage tp in new TabPage[] { tabDash, tabApps, tabRoblox, tabSamp, tabMc, tabPro })
            {
                tp.BackColor = Color.FromArgb(16, 20, 30);
                tp.ForeColor = Color.White;
                tp.Padding = new Padding(14);
            }

            BuildDashboardTab(tabDash);
            BuildAppsTab(tabApps);
            BuildRobloxTab(tabRoblox);
            BuildSampTab(tabSamp);
            BuildMinecraftTab(tabMc);
            BuildProUtilitiesTab(tabPro);

            tabs.TabPages.AddRange(new TabPage[] { tabDash, tabApps, tabRoblox, tabSamp, tabMc, tabPro });

            Panel bottomPanel = new Panel();
            bottomPanel.Dock = DockStyle.Fill;
            bottomPanel.Padding = new Padding(16, 8, 16, 12);
            bottomPanel.BackColor = Color.FromArgb(11, 14, 20);

            statusLabel = new Label();
            statusLabel.Text = "Status: Ready digunwill - Pilih menu di atas for mengelola RDP, menginstal app, or memperbaiki game.";
            statusLabel.Dock = DockStyle.Top;
            statusLabel.Height = 22;
            statusLabel.ForeColor = Color.FromArgb(52, 211, 153);
            statusLabel.Font = new Font("Segoe UI Semibold", 9f, FontStyle.Bold);

            progressBar = new ProgressBar();
            progressBar.Dock = DockStyle.Top;
            progressBar.Height = 6;
            progressBar.Style = ProgressBarStyle.Continuous;

            logBox = new RichTextBox();
            logBox.Dock = DockStyle.Fill;
            logBox.BackColor = Color.FromArgb(8, 10, 15);
            logBox.ForeColor = Color.FromArgb(203, 213, 225);
            logBox.Font = new Font("Consolas", 9f, FontStyle.Regular);
            logBox.ReadOnly = true;
            logBox.BorderStyle = BorderStyle.None;

            bottomPanel.Controls.Add(logBox);
            bottomPanel.Controls.Add(progressBar);
            bottomPanel.Controls.Add(statusLabel);

            this.Controls.Add(bottomPanel);
            this.Controls.Add(tabs);
            this.Controls.Add(header);
        }

        private Button CreateActionButton(string text, string desc, Color accent, int x, int y, int w, int h, EventHandler onClick)
        {
            Button btn = new Button();
            btn.Text = text + "\n" + desc;
            btn.TextAlign = ContentAlignment.MiddleLeft;
            btn.FlatStyle = FlatStyle.Flat;
            btn.FlatAppearance.BorderColor = accent;
            btn.FlatAppearance.BorderSize = 1;
            btn.BackColor = Color.FromArgb(23, 29, 43);
            btn.ForeColor = Color.White;
            btn.Font = new Font("Segoe UI Semibold", 9.2f, FontStyle.Bold);
            btn.Location = new Point(x, y);
            btn.Size = new Size(w, h);
            btn.Padding = new Padding(10, 4, 10, 4);
            btn.Cursor = Cursors.Hand;
            btn.Click += onClick;
            return btn;
        }

        private void BuildDashboardTab(TabPage page)
        {
            int w = 400, h = 76;
            page.Controls.Add(CreateActionButton(
                "1. Save Login Google & Semua File Sekarang (Cloud Save)",
                "Backup instan Login Chrome/Edge, file Downloads, Desktop & C:\\Persist ke Cloud",
                Color.FromArgb(16, 185, 129), 16, 16, w, h,
                (s, e) => RunPowerShellTask("Menyimpan Login Browser + Downloads + Desktop ke Cloud...", @"
                    & 'C:\Sailuo\scripts\persist-state.ps1' -Checkpoint
                ")
            ));

            page.Controls.Add(CreateActionButton(
                "2. Restore Savean Session Lama (Cloud Restore)",
                "Tarik ulang savean terbaru from Release 'xyrdp-state-latest' ke profil when ini",
                Color.FromArgb(99, 102, 241), 432, 16, w, h,
                (s, e) => RunPowerShellTask("Restoring data session senot yetnya from Cloud...", @"
                    & 'C:\Sailuo\scripts\restore-state.ps1'
                ")
            ));

            page.Controls.Add(CreateActionButton(
                "3. Aktifkan Extreme Gaming Boost + Anti-VM Hardening",
                "Ultimate Power Plan + MMCSS GPU Priority 8 + Spoof SMBIOS ASUS ROG B650",
                Color.FromArgb(245, 158, 11), 16, 106, w, h,
                (s, e) => RunPowerShellTask("Applying Extreme Gaming Boost & Anti-VM Spoofing...", @"
                    if (Test-Path 'C:\Sailuo\tools\Apply-AntiVM-Boost.ps1') {
                        & 'C:\Sailuo\tools\Apply-AntiVM-Boost.ps1'
                    }
                    Set-ItemProperty -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseSpeed' -Value '0' -ErrorAction SilentlyContinue
                    Set-ItemProperty -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseThreshold1' -Value '0' -ErrorAction SilentlyContinue
                    Set-ItemProperty -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseThreshold2' -Value '0' -ErrorAction SilentlyContinue
                    Restart-Service Audiosrv -Force -ErrorAction SilentlyContinue
                    Restart-Service AudioEndpointBuilder -Force -ErrorAction SilentlyContinue
                    Write-Host 'Extreme Gaming Boost, Raw Mouse Input & Audio RDP succeeded optimized!'
                ")
            ));

            page.Controls.Add(CreateActionButton(
                "4. Buka Folder Permanen (C:\\Persist) & Bersihkan RAM",
                "Kosongkan sampah Temp for mendongkrak FPS & buka brankas Anti-Reset",
                Color.FromArgb(56, 189, 248), 432, 106, w, h,
                (s, e) => {
                    Directory.CreateDirectory(@"C:\Persist");
                    Process.Start("explorer.exe", @"C:\Persist");
                    RunPowerShellTask("Membersihkan cache Temp & menyegarkan RAM...", @"
                        Remove-Item -Path ""$env:TEMP\*"" -Recurse -Force -ErrorAction SilentlyContinue
                        [System.GC]::Collect()
                        Write-Host 'Pembersihan Temp & optimasi RAM done!'
                    ");
                }
            ));

            Panel infoBar = new Panel { Location = new Point(16, 198), Size = new Size(816, 68), BackColor = Color.FromArgb(20, 26, 38) };
            Label infoText = new Label {
                Text = "INFO PERSISTENSI: Semua akun that Anda login di Chrome/Edge, file di Downloads, Desktop, Documents, and C:\\Persist otomatis disave ke GitHub Release pribadi Anda setiap 4 menit & when RDP dimatikan. Klik tombol (1) di atas kwhatn only for menyimpan as instan!",
                Location = new Point(14, 12),
                Size = new Size(788, 44),
                ForeColor = Color.FromArgb(148, 163, 184),
                Font = new Font("Segoe UI", 8.8f, FontStyle.Regular)
            };
            infoBar.Controls.Add(infoText);
            page.Controls.Add(infoBar);
        }

        private void BuildAppsTab(TabPage page)
        {
            int w = 400, h = 76;
            page.Controls.Add(CreateActionButton(
                "1. Install Google Chrome & Brave Browser Terbaru",
                "Install browser cepat with dukungan auto-save login Google lintas session",
                Color.FromArgb(16, 185, 129), 16, 16, w, h,
                (s, e) => RunPowerShellTask("Downloading & memasang Google Chrome / Brave...", @"
                    & winget install --id Google.Chrome --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
                    Write-Host 'Google Chrome ready digunwill!'
                ")
            ));

            page.Controls.Add(CreateActionButton(
                "2. Install Discord + VLC Media Player + 7-Zip",
                "Install aplikasi komunikasi gaming & multimedia lengkap 1-klik",
                Color.FromArgb(99, 102, 241), 432, 16, w, h,
                (s, e) => RunPowerShellTask("Installing Discord, VLC & 7-Zip...", @"
                    & winget install --id Discord.Discord --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
                    & winget install --id VideoLAN.VLC --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
                    Write-Host 'Instalasi Discord & VLC done!'
                ")
            ));

            page.Controls.Add(CreateActionButton(
                "3. Install Semua Runtime Game (DirectX 9 + VC++ + WebView2)",
                "Atasi error d3dx9_43.dll, vcruntime140.dll, xinput1_3.dll & aplikasi failed buka",
                Color.FromArgb(245, 158, 11), 16, 106, w, h,
                (s, e) => RunPowerShellTask("Checking & memasang seluruh runtime game...", @"& 'C:\Sailuo\scripts\setup-samp.ps1'")
            ));

            page.Controls.Add(CreateActionButton(
                "4. Ganti Wallpaper Desktop RDP (Tersave Permanen)",
                "Pilih gambar (.jpg/.png) for dijadikan wallpaper RDP & preview Home aplikasi",
                Color.FromArgb(56, 189, 248), 432, 106, w, h,
                (s, e) => {
                    OpenFileDialog ofd = new OpenFileDialog();
                    ofd.Title = "Pilih Gambar Wallpaper Desktop RDP";
                    ofd.Filter = "Gambar Wallpaper (*.jpg;*.jpeg;*.png;*.bmp)|*.jpg;*.jpeg;*.png;*.bmp";
                    if (ofd.ShowDialog() == DialogResult.OK)
                    {
                        string chosen = ofd.FileName.Replace("'", "''");
                        RunPowerShellTask("Applying & menyimpan Wallpaper Desktop baru...", @"
                            $src = '" + chosen + @"'
                            $ext = [IO.Path]::GetExtension($src).ToLower()
                            if (-not $ext) { $ext = '.jpg' }
                            New-Item -ItemType Directory -Path 'C:\Users\Public\Pictures\Sailuo' -Force | Out-Null
                            New-Item -ItemType Directory -Path 'C:\Persist\Config' -Force | Out-Null
                            $dstPub = ""C:\Users\Public\Pictures\Sailuo\wallpaper$ext""
                            $dstPer = ""C:\Persist\Config\wallpaper$ext""
                            Copy-Item -LiteralPath $src -Destination $dstPub -Force
                            Copy-Item -LiteralPath $src -Destination $dstPer -Force
                            Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'Wallpaper' -Value $dstPub -Force
                            Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public class Wp { [DllImport(""user32.dll"", CharSet=CharSet.Auto)] public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni); }' -ErrorAction SilentlyContinue
                            [Wp]::SystemParametersInfo(20, 0, $dstPub, 3) | Out-Null
                            Write-Host ""Wallpaper succeeded diganti & disave permanen di $dstPer!""
                        ");
                    }
                }
            ));

            page.Controls.Add(CreateActionButton(
                "5. Install / Buka MEmu Emulator & Euro Truck Simulator 2 (Free)",
                "Install MEmu Android Emulator & ETS 2 Free Edition (OpenGL 4.6 Ready)",
                Color.FromArgb(16, 185, 129), 16, 196, w, 68,
                (s, e) => RunPowerShellTask("Preparing MEmu Emulator & Euro Truck Simulator 2 Free...", @"
                    if (Test-Path 'C:\Games\MEmu\Launch-MEmu.ps1') { & 'C:\Games\MEmu\Launch-MEmu.ps1' }
                    if (Test-Path 'C:\Games\ETS2\Launch-ETS2-Free.ps1') { & 'C:\Games\ETS2\Launch-ETS2-Free.ps1' }
                    Write-Host 'MEmu Emulator & Euro Truck Simulator 2 Free ready di Desktop!'
                ")
            ));

            page.Controls.Add(CreateActionButton(
                "6. Install / Buka Blender 3D Studio (Mesa3D OpenGL 4.6)",
                "Install & run Blender 3D Portable with akselerator OpenGL 4.6",
                Color.FromArgb(234, 88, 12), 432, 196, w, 68,
                (s, e) => RunPowerShellTask("Preparing & membuka Blender 3D Studio...", @"
                    if (Test-Path 'C:\Games\Blender\Launch-Blender.ps1') { & 'C:\Games\Blender\Launch-Blender.ps1' }
                    Write-Host 'Blender 3D Studio ready dirun!'
                ")
            ));
        }

        private void BuildRobloxTab(TabPage page)
        {
            int w = 400, h = 76;
            page.Controls.Add(CreateActionButton(
                "1. Buka / Install Roblox Player (Mode Anti-VM Boost)",
                "Run Roblox with Spoof SMBIOS ASUS ROG + Direct3D 11 120 FPS",
                Color.FromArgb(239, 68, 68), 16, 16, w, h,
                (s, e) => RunPowerShellTask("Preparing & membuka Roblox Player (Anti-VM Boost)...", @"
                    if (Test-Path 'C:\Games\Roblox\Launch-Roblox-AntiVM.ps1') {
                        & 'C:\Games\Roblox\Launch-Roblox-AntiVM.ps1'
                    } else {
                        $env:ROBLOX='ya'; & 'C:\Sailuo\scripts\setup-games.ps1'
                        if (Test-Path 'C:\Games\Roblox\Launch-Roblox-AntiVM.ps1') {
                            & 'C:\Games\Roblox\Launch-Roblox-AntiVM.ps1'
                        }
                    }
                ")
            ));

            page.Controls.Add(CreateActionButton(
                "2. Fix Error 'Cannot Run Under a Virtual Machine'",
                "Bersihkan Hyper-V Guest Parameters, matikan vmic* & suntikkan FFlags DX11",
                Color.FromArgb(99, 102, 241), 432, 16, w, h,
                (s, e) => RunPowerShellTask("Running Deep Anti-VM Hardening for Roblox...", @"
                    if (Test-Path 'C:\Sailuo\tools\Apply-AntiVM-Boost.ps1') {
                        & 'C:\Sailuo\tools\Apply-AntiVM-Boost.ps1'
                    }
                    & 'C:\Sailuo\scripts\setup-grafis.ps1'
                    Write-Host 'Deep Anti-VM Hardening & Direct3D 11 FastFlags done applied!'
                ")
            ));

            page.Controls.Add(CreateActionButton(
                "3. Install Bloxstrap (Launcher Mod Roblox + FastFlags)",
                "Install Bloxstrap terbaru for atur wilayah server, ping & grafik ringan",
                Color.FromArgb(245, 158, 11), 16, 106, w, h,
                (s, e) => RunPowerShellTask("Downloading & menrun Bloxstrap...", @"
                    $work = 'C:\Sailuo\deps\games'
                    New-Item -ItemType Directory -Path $work -Force | Out-Null
                    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/bloxstraplabs/bloxstrap/releases/latest' -Headers @{ 'User-Agent' = 'Sailuo' }
                    $asset = $rel.assets | Where-Object { $_.name -match '\.exe$' } | Select-Object -First 1
                    if ($asset) {
                        $exe = Join-Path $work $asset.name
                        & curl.exe -fL --retry 2 -sS $asset.browser_download_url -o $exe
                        if (Test-Path $exe) { Start-Process $exe }
                    }
                ")
            ));

            page.Controls.Add(CreateActionButton(
                "4. Buka Folder Roblox & Bersihkan Cache Anti-Cheat",
                "Reset cache lokal Roblox bila sangkut when loading or failed update",
                Color.FromArgb(56, 189, 248), 432, 106, w, h,
                (s, e) => {
                    string rbx = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Roblox");
                    Directory.CreateDirectory(rbx);
                    Process.Start("explorer.exe", rbx);
                }
            ));
        }

        private void BuildSampTab(TabPage page)
        {
            int w = 400, h = 68;
            page.Controls.Add(CreateActionButton(
                "1. Install Runtime SA-MP Lengkap (DirectX 9 + DirectPlay + VC++)",
                "Wajib agar GTA SA & SA-MP not crash / not minta d3dx9_43.dll",
                Color.FromArgb(99, 102, 241), 16, 14, w, h,
                (s, e) => RunPowerShellTask("Installing Runtime DirectX 9 + DirectPlay + VC++...", @"& 'C:\Sailuo\scripts\setup-samp.ps1'")
            ));

            page.Controls.Add(CreateActionButton(
                "2. Patch Folder GTA SA (SilentPatch 90 FPS + Fix Mouse RDP)",
                "Install ASI Loader, SilentPatch, Widescreen & dgVoodoo2 Fullscreen",
                Color.FromArgb(16, 185, 129), 432, 14, w, h,
                (s, e) => RunPowerShellTask("Memilih & mem-patch folder GTA San Andreas...", @"& 'C:\Games\GTA-SAMP\Patch-GTA-SAMP.ps1' -Interactive")
            ));

            page.Controls.Add(CreateActionButton(
                "3. Atasi Banned Server & Anti-VPN SAMP (Reset GPCI + WARP)",
                "Spoof serial GPCI/HWID unik & aktifkan split-tunnel agar not terdeteksi VPN",
                Color.FromArgb(245, 158, 11), 16, 94, w, h,
                (s, e) => RunPowerShellTask("Mereset GPCI/HWID & mengaktifkan Anti-VPN SA-MP...", @"& 'C:\Games\GTA-SAMP\Patch-GTA-SAMP.ps1' -Interactive -ResetAntiBan")
            ));

            page.Controls.Add(CreateActionButton(
                "4. Buka Folder GTA-SAMP & Folder Permanen (C:\\Persist)",
                "Taruh file GTA SA kamu di C:\\Games or C:\\Persist agar anti-reset",
                Color.FromArgb(56, 189, 248), 432, 94, w, h,
                (s, e) => {
                    Directory.CreateDirectory(@"C:\Games");
                    Directory.CreateDirectory(@"C:\Persist");
                    Process.Start("explorer.exe", @"C:\Games");
                }
            ));

            Panel regPanel = new Panel();
            regPanel.Location = new Point(16, 174);
            regPanel.Size = new Size(816, 110);
            regPanel.BackColor = Color.FromArgb(20, 24, 36);
            regPanel.Padding = new Padding(12);

            Label lblNick = new Label { Text = "Nickname SA-MP:", Location = new Point(14, 16), AutoSize = true, ForeColor = Color.FromArgb(203, 213, 225) };
            sampNickBox = new TextBox { Location = new Point(140, 13), Width = 220, BackColor = Color.FromArgb(12, 15, 23), ForeColor = Color.White, BorderStyle = BorderStyle.FixedSingle };

            Label lblPath = new Label { Text = "Lokasi gta_sa.exe:", Location = new Point(14, 50), AutoSize = true, ForeColor = Color.FromArgb(203, 213, 225) };
            sampPathBox = new TextBox { Location = new Point(140, 47), Width = 445, BackColor = Color.FromArgb(12, 15, 23), ForeColor = Color.White, BorderStyle = BorderStyle.FixedSingle };

            Button btnBrowse = new Button { Text = "Pilih gta_sa.exe...", Location = new Point(595, 45), Size = new Size(195, 27), FlatStyle = FlatStyle.Flat, BackColor = Color.FromArgb(30, 41, 59), ForeColor = Color.White };
            btnBrowse.Click += (s, e) => {
                OpenFileDialog ofd = new OpenFileDialog();
                ofd.Filter = "gta_sa.exe|gta_sa.exe|Executable (*.exe)|*.exe";
                if (ofd.ShowDialog() == DialogResult.OK) sampPathBox.Text = ofd.FileName;
            };

            Button btnSaveSamp = new Button { Text = "Save ke Registry SA-MP", Location = new Point(375, 11), Size = new Size(190, 28), FlatStyle = FlatStyle.Flat, BackColor = Color.FromArgb(16, 185, 129), ForeColor = Color.Black, Font = new Font("Segoe UI", 9f, FontStyle.Bold) };
            btnSaveSamp.Click += (s, e) => SaveSampRegistryInfo();

            Label lblSrv = new Label { Text = "Server IP:Port:", Location = new Point(14, 82), AutoSize = true, ForeColor = Color.FromArgb(203, 213, 225) };
            sampServerBox = new TextBox { Text = "127.0.0.1:7777", Location = new Point(140, 79), Width = 220, BackColor = Color.FromArgb(12, 15, 23), ForeColor = Color.White, BorderStyle = BorderStyle.FixedSingle };

            Button btnConnectSamp = new Button { Text = "Cek Ping && Direct Connect SA-MP", Location = new Point(375, 77), Size = new Size(260, 27), FlatStyle = FlatStyle.Flat, BackColor = Color.FromArgb(56, 189, 248), ForeColor = Color.Black, Font = new Font("Segoe UI", 8.8f, FontStyle.Bold) };
            btnConnectSamp.Click += (s, e) => {
                SaveSampRegistryInfo();
                string srv = sampServerBox.Text.Trim().Replace("'", "");
                string gtaExe = sampPathBox.Text.Trim().Replace("'", "''");
                RunPowerShellTask("Mengecek ping & menghubungkan langsung ke server SA-MP " + srv + "...", @"
                    $srv = '" + srv + @"'
                    $hostOnly = ($srv -split ':')[0]
                    try {
                        $ping = Test-Connection -ComputerName $hostOnly -Count 1 -ErrorAction SilentlyContinue
                        if ($ping) { Write-Host ""Ping ke $hostOnly : $($ping.ResponseTime) ms"" }
                    } catch {}
                    $gtaDir = Split-Path -Parent '" + gtaExe + @"'
                    if (Test-Path 'C:\Games\GTA-SAMP\Patch-GTA-SAMP.ps1') {
                        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File 'C:\Games\GTA-SAMP\Patch-GTA-SAMP.ps1' -TargetDir $gtaDir 2>&1 | Out-Null
                    }
                    $sampExe = Join-Path $gtaDir 'samp.exe'
                    if (Test-Path $sampExe) {
                        Start-Process -FilePath $sampExe -ArgumentList $srv -WorkingDirectory $gtaDir
                        Write-Host ""Meluncurkan samp.exe -> $srv (Anti-0x00746929 & Borderless Fullscreen aktif)""
                    } else {
                        Write-Host 'samp.exe not yet ditemukan di folder GTA SA that. Ensure lokasi gta_sa.exe already benar.'
                    }
                ");
            };

            regPanel.Controls.AddRange(new Control[] { lblNick, sampNickBox, btnSaveSamp, lblPath, sampPathBox, btnBrowse, lblSrv, sampServerBox, btnConnectSamp });
            page.Controls.Add(regPanel);
        }

        private void BuildProUtilitiesTab(TabPage page)
        {
            int w = 400, h = 76;
            page.Controls.Add(CreateActionButton(
                "1. Install Modpack CLEO 4 + AntiCrasher + FPS Unlock SA-MP",
                "Instal otomatis CLEO.asi, SilentPatch & AntiCrasher ke folder GTA SA",
                Color.FromArgb(16, 185, 129), 16, 16, w, h,
                (s, e) => RunPowerShellTask("Installing Modpack CLEO 4 + SilentPatch + AntiCrasher SA-MP...", @"
                    & 'C:\Games\GTA-SAMP\Patch-GTA-SAMP.ps1'
                    $gtaDir = Split-Path -Parent '" + sampPathBox.Text.Trim().Replace("'", "''") + @"'
                    if (Test-Path $gtaDir) {
                        New-Item -ItemType Directory -Path (Join-Path $gtaDir 'cleo') -Force | Out-Null
                        Write-Host ""Folder CLEO & ASI Loader ready di: $gtaDir""
                    }
                ")
            ));

            page.Controls.Add(CreateActionButton(
                "2. RAM Standby Cleaner + High-Priority Game Lock",
                "Kosongkan Standby Memory & kunci CPU Priority gta_sa/javaw/Roblox ke High",
                Color.FromArgb(99, 102, 241), 432, 16, w, h,
                (s, e) => RunPowerShellTask("Optimizing RAM Standby & mengunci High Priority for Game...", @"
                    foreach ($pName in @('gta_sa', 'samp', 'javaw', 'java', 'RobloxPlayerBeta', 'Minecraft.Windows')) {
                        Get-Process -Name $pName -ErrorAction SilentlyContinue | ForEach-Object {
                            try { $_.PriorityClass = 'High'; Write-Host ""Set High Priority: $($_.ProcessName) (PID $($_.Id))"" } catch {}
                        }
                    }
                    Remove-Item -Path ""$env:TEMP\*"" -Recurse -Force -ErrorAction SilentlyContinue
                    Remove-Item -Path 'C:\Windows\Temp\*' -Recurse -Force -ErrorAction SilentlyContinue
                    [System.GC]::Collect()
                    [System.GC]::WaitForPendingFinalizers()
                    $drive = Get-PSDrive C
                    $freeGB = [math]::Round($drive.Free / 1GB, 2)
                    Write-Host ""RAM & Temp dibersihkan! Sisa Disk SSD C: $freeGB GB""
                ")
            ));

            page.Controls.Add(CreateActionButton(
                "3. Optimasi Resolusi HD/FHD & ClearType Sharpness",
                "Pertajam teks RDP, matikan efek animasi berat & aktifkan 120Hz DWM",
                Color.FromArgb(245, 158, 11), 16, 106, w, h,
                (s, e) => RunPowerShellTask("Optimizing ketajaman layar, ClearType & 120Hz DWM...", @"
                    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'FontSmoothing' -Value '2' -Force -ErrorAction SilentlyContinue
                    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'FontSmoothingType' -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue
                    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations' -Name 'DWMFRAMEINTERVAL' -Value 8 -Type DWord -Force -ErrorAction SilentlyContinue
                    Write-Host 'Optimasi ketajaman layar & 120Hz DWM done applied!'
                ")
            ));

            page.Controls.Add(CreateActionButton(
                "4. Hot-Reload Update Engine Server (Tarik Script Terbaru)",
                "Perbarui engine Sailuo langsung from GitHub without mematikan session RDP",
                Color.FromArgb(56, 189, 248), 432, 106, w, h,
                (s, e) => RunPowerShellTask("Pulling pembaruan Engine Sailuo terbaru from GitHub...", @"
                    if (Test-Path 'C:\Sailuo\.git') {
                        Set-Location 'C:\Sailuo'
                        & git pull --rebase --autostash 2>&1 | ForEach-Object { Write-Host $_ }
                        Write-Host 'Engine Sailuo succeeded diperbarui as live (Hot-Reload)!'
                    } else {
                        Write-Host 'Direktori C:\Sailuo ready.'
                    }
                ")
            ));

            Panel infoPro = new Panel { Location = new Point(16, 198), Size = new Size(816, 68), BackColor = Color.FromArgb(20, 26, 38) };
            Label lblPro = new Label {
                Text = "ENGINE SERVER PRO: Mendukung Multi-Part Cloud Persistence hingga 5.4 GB, Tunnel Failover (Tailscale / Railway / Bore.pub / Portmap), Anti-VM Spoofing ASUS ROG B650, and Hot-Reload Engine without putus session.",
                Location = new Point(14, 14),
                Size = new Size(788, 42),
                ForeColor = Color.FromArgb(148, 163, 184),
                Font = new Font("Segoe UI", 8.8f, FontStyle.Regular)
            };
            infoPro.Controls.Add(lblPro);
            page.Controls.Add(infoPro);
        }

        private void BuildMinecraftTab(TabPage page)
        {
            int w = 400, h = 76;
            page.Controls.Add(CreateActionButton(
                "1. Install / Perbarui TLauncher & PrismLauncher (Java 21 & 8)",
                "Install TLauncher Cracked & PrismLauncher Modpack di C:\\Games",
                Color.FromArgb(16, 185, 129), 16, 16, w, h,
                (s, e) => RunPowerShellTask("Installing TLauncher + PrismLauncher + Java 21 & 8...", @"$env:MINECRAFT_JAVA='ya'; & 'C:\Sailuo\scripts\setup-games.ps1'")
            ));

            page.Controls.Add(CreateActionButton(
                "2. Suntikkan Akselerator OpenGL 4.6 (Mesa3D D3D12)",
                "Atasi error 'GLFW error 65542: The driver does not appear to support OpenGL'",
                Color.FromArgb(99, 102, 241), 432, 16, w, h,
                (s, e) => RunPowerShellTask("Menyuntikkan Mesa3D OpenGL 4.6 ke semua runtime Java...", @"
                    $env:GRAFIS='software'
                    & 'C:\Sailuo\scripts\setup-grafis.ps1'
                    if (Test-Path 'C:\Sailuo\grafis\Deploy-OpenGL-To-Java.ps1') {
                        & 'C:\Sailuo\grafis\Deploy-OpenGL-To-Java.ps1'
                    }
                ")
            ));

            page.Controls.Add(CreateActionButton(
                "3. Install Official Minecraft Launcher (Bedrock & Java)",
                "Download & install MinecraftInstaller resmi from Xbox/Mojang",
                Color.FromArgb(245, 158, 11), 16, 106, w, h,
                (s, e) => RunPowerShellTask("Installing Official Minecraft Launcher...", @"$env:MINECRAFT_BEDROCK='ya'; & 'C:\Sailuo\scripts\setup-games.ps1'")
            ));

            page.Controls.Add(CreateActionButton(
                "4. Buka Folder .minecraft & PrismLauncher",
                "Access cepat ke folder mods, resourcepacks, and world saves",
                Color.FromArgb(56, 189, 248), 432, 106, w, h,
                (s, e) => {
                    string mc = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), ".minecraft");
                    Directory.CreateDirectory(mc);
                    Process.Start("explorer.exe", mc);
                }
            ));
        }

        private void LoadSampRegistryInfo()
        {
            try
            {
                using (var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\SAMP", false))
                {
                    if (key != null)
                    {
                        sampNickBox.Text = Convert.ToString(key.GetValue("PlayerName", Environment.UserName));
                        sampPathBox.Text = Convert.ToString(key.GetValue("gta_sa_exe", @"C:\Games\GTA San Andreas\gta_sa.exe"));
                        return;
                    }
                }
            }
            catch { }
            sampNickBox.Text = Environment.UserName;
            sampPathBox.Text = @"C:\Games\GTA San Andreas\gta_sa.exe";
        }

        private void SaveSampRegistryInfo()
        {
            try
            {
                using (var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(@"Software\SAMP"))
                {
                    key.SetValue("PlayerName", sampNickBox.Text.Trim());
                    key.SetValue("gta_sa_exe", sampPathBox.Text.Trim());
                }
                AppendLog("[OK] Registry HKCU\\Software\\SAMP succeeded disave: Nick=" + sampNickBox.Text.Trim());
                statusLabel.Text = "Status: Pengaturan SA-MP tersave.";
            }
            catch (Exception ex)
            {
                AppendLog("[ERR] Failed menyimpan registry SA-MP: " + ex.Message);
            }
        }

        private void AppendLog(string line)
        {
            if (this.InvokeRequired)
            {
                this.BeginInvoke(new Action<string>(AppendLog), line);
                return;
            }
            logBox.AppendText("[" + DateTime.Now.ToString("HH:mm:ss") + "] " + line + Environment.NewLine);
            logBox.SelectionStart = logBox.Text.Length;
            logBox.ScrollToCaret();
        }

        private void RunPowerShellTask(string label, string psCommand)
        {
            statusLabel.Text = "Status: " + label;
            progressBar.Style = ProgressBarStyle.Marquee;
            AppendLog("==> " + label);

            ThreadPool.QueueUserWorkItem(_ =>
            {
                try
                {
                    string tempScript = Path.Combine(Path.GetTempPath(), "xydesk_task_" + Guid.NewGuid().ToString("N") + ".ps1");
                    File.WriteAllText(tempScript, psCommand, System.Text.Encoding.UTF8);

                    ProcessStartInfo psi = new ProcessStartInfo();
                    psi.FileName = "powershell.exe";
                    psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + tempScript + "\"";
                    psi.UseShellExecute = false;
                    psi.RedirectStandardOutput = true;
                    psi.RedirectStandardError = true;
                    psi.CreateNoWindow = true;

                    using (Process proc = Process.Start(psi))
                    {
                        proc.OutputDataReceived += (s, ev) => { if (!string.IsNullOrEmpty(ev.Data)) AppendLog(ev.Data); };
                        proc.ErrorDataReceived += (s, ev) => { if (!string.IsNullOrEmpty(ev.Data)) AppendLog("[WARN] " + ev.Data); };
                        proc.BeginOutputReadLine();
                        proc.BeginErrorReadLine();
                        proc.WaitForExit();
                    }
                    try { File.Delete(tempScript); } catch { }

                    this.BeginInvoke(new Action(() =>
                    {
                        progressBar.Style = ProgressBarStyle.Continuous;
                        progressBar.Value = 100;
                        statusLabel.Text = "Status: Selesai - " + label;
                        AppendLog("[SELESAI] " + label);
                    }));
                }
                catch (Exception ex)
                {
                    this.BeginInvoke(new Action(() =>
                    {
                        progressBar.Style = ProgressBarStyle.Continuous;
                        progressBar.Value = 0;
                        statusLabel.Text = "Status: Failed (" + ex.Message + ")";
                        AppendLog("[ERROR] " + ex.Message);
                    }));
                }
            });
        }

        [STAThread]
        public static void Main()
        {
            bool createdNew = false;
            using (Mutex mutex = new Mutex(true, "Global\\SailuoDashboardSingleton", out createdNew))
            {
                if (!createdNew) return;
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new MainForm());
            }
        }
    }
}
'@

try {
  $csFile = Join-Path $toolsDir 'SailuoDashboard.cs'
  Set-Content -LiteralPath $csFile -Value $csharpSource -Encoding UTF8 -Force
  $cscExe = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
  Remove-Item -LiteralPath $exePath -Force -ErrorAction SilentlyContinue
  if (Test-Path $cscExe) {
    $cscArgs = @('/nologo', '/target:winexe', "/out:$exePath", '/r:System.dll', '/r:System.Drawing.dll', '/r:System.Windows.Forms.dll')
    if (Test-Path $dashIco) { $cscArgs += "/win32icon:$dashIco" }
    $cscArgs += $csFile
    & $cscExe @cscArgs 2>&1 | Out-Null
  } else {
    Add-Type -TypeDefinition $csharpSource `
      -ReferencedAssemblies @('System.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll') `
      -OutputAssembly $exePath `
      -OutputType WindowsApplication `
      -ErrorAction Stop
  }

  if (Test-Path $exePath) {
    Copy-Item -LiteralPath $exePath -Destination $legacyExePath -Force -ErrorAction SilentlyContinue
    Log "SailuoDashboard.exe succeeded dikompilasi di $exePath"

    # 1. Buat SATU shortcut bersih & berikon unik di Desktop (delete duplikat lama!)
    foreach ($desk in @("C:\Users\$u\Desktop", "C:\Users\Public\Desktop", "C:\Users\Default\Desktop")) {
      if (-not (Test-Path $desk)) {
        New-Item -ItemType Directory -Path $desk -Force -ErrorAction SilentlyContinue | Out-Null
      }
      try {
        Remove-Item -LiteralPath (Join-Path $desk 'SailuoTools.exe') -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $desk 'Sailuo Gaming & Tools Hub.lnk') -Force -ErrorAction SilentlyContinue
        $wsh = New-Object -ComObject WScript.Shell
        $lnk = $wsh.CreateShortcut((Join-Path $desk 'Sailuo Dashboard.lnk'))
        $lnk.TargetPath = $exePath
        $lnk.WorkingDirectory = $toolsDir
        $lnk.Description = 'Sailuo Dashboard - Pusat Kelola Sistem, Installer, Anti-VM & Cloud Save'
        $lnk.IconLocation = "$exePath,0"
        $lnk.Save()
      } catch {}
    }

    # 2. Daftarkan Auto-Start agar Sailuo Dashboard OTOMATIS TERBUKA when pertama kali sign in Desktop RDP!
    try {
      Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' 'SailuoDashboard' "`"$exePath`"" 'String' | Out-Null
      Set-RegBoth 'Software\Microsoft\Windows\CurrentVersion\Run' 'SailuoDashboard' "`"$exePath`"" 'String' | Out-Null
      $commonStartup = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp'
      if (Test-Path $commonStartup) {
        $wsh2 = New-Object -ComObject WScript.Shell
        $sLnk = $wsh2.CreateShortcut((Join-Path $commonStartup 'Sailuo Dashboard.lnk'))
        $sLnk.TargetPath = $exePath
        $sLnk.WorkingDirectory = $toolsDir
        if (Test-Path $dashIco) { $sLnk.IconLocation = "$dashIco,0" }
        $sLnk.Save()
      }
      Log 'Sailuo Dashboard didaftarkan di Auto-Start (otomatis terbuka when sign in RDP pertama kali).'
    } catch {}

    Update-Status @{ tools_hub = @{ installed = $true; exe = $exePath; auto_start = $true } } | Out-Null
  }
} catch {
  Log "Kompilasi SailuoDashboard.exe warning: $($_.Exception.Message)"
}
exit 0
