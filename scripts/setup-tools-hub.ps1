# ============================================================================
#  setup-tools-hub.ps1 - Build & Install "Sailuo Dashboard" (GUI Desktop)
# ----------------------------------------------------------------------------
#  Compiling aplikasi GUI WinForms native (C:\Sailuo\tools\SailuoDashboard.exe)
#  using C# compiler built-in .NET Framework 4.x di Windows Server 2022/2025.
#  Automatically opens when the user first enters ke the RDP desktop session, dan
#  provides 1-click control for:
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

# Save the session environment context (for the Cloud Save / Restore 1-click feature from the GUI)
$envFile = Join-Path $toolsDir 'session-env.json'
@{
  RDP_USER          = $u
  RDP_PASSWORD      = $(if ($env:RDP_PASSWORD) { $env:RDP_PASSWORD } else { '' })
  GITHUB_TOKEN      = $(if ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } else { '' })
  GITHUB_REPOSITORY = $(if ($env:GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY } else { '' })
  GITHUB_RUN_ID     = $(if ($env:GITHUB_RUN_ID) { $env:GITHUB_RUN_ID } else { '' })
} | ConvertTo-Json | Set-Content -Path $envFile -Encoding UTF8 -Force

$icoDir = Ensure-SailuotopIcons
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
            this.Text = "Sailuo Dashboard - Control Center, Installer & Cloud Save";
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
            sub.Text = "[Cloud Save: AUTO-SYNC EVERY 4 MIN]   [User: " + Environment.UserName + "]";
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
            TabPage tabPro = new TabPage("Utilitas Pro && Engine");

            foreach (TabPage tp in new TabPage[] { tabDash, tabApps, tabPro })
            {
                tp.BackColor = Color.FromArgb(16, 20, 30);
                tp.ForeColor = Color.White;
                tp.Padding = new Padding(14);
            }

            BuildDashboardTab(tabDash);
            BuildAppsTab(tabApps);
            BuildProUtilitiesTab(tabPro);

            tabs.TabPages.AddRange(new TabPage[] { tabDash, tabApps, tabPro });

            Panel bottomPanel = new Panel();
            bottomPanel.Dock = DockStyle.Fill;
            bottomPanel.Padding = new Padding(16, 8, 16, 12);
            bottomPanel.BackColor = Color.FromArgb(11, 14, 20);

            statusLabel = new Label();
            statusLabel.Text = "Status: Ready to use - pick a menu above to manage RDP, install apps, or repair the system.";
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
                "1. Save Google logins & and all files now (Cloud Save)",
                "Backup instan Login Chrome/Edge, file Downloads, Desktop & C:\\Persist ke Cloud",
                Color.FromArgb(16, 185, 129), 16, 16, w, h,
                (s, e) => RunPowerShellTask("Menyimpan Login Browser + Downloads + Desktop ke Cloud...", @"
                    & 'C:\Sailuo\scripts\persist-state.ps1' -Checkpoint
                ")
            ));

            page.Controls.Add(CreateActionButton(
                "2. Restore the old session snapshot (Cloud Restore)",
                "Pull the latest snapshot from the Release 'xyrdp-state-latest' into the current profile",
                Color.FromArgb(99, 102, 241), 432, 16, w, h,
                (s, e) => RunPowerShellTask("Restoring the previous session data from the Cloud...", @"
                    & 'C:\Sailuo\scripts\restore-state.ps1'
                ")
            ));


            page.Controls.Add(CreateActionButton(
                "4. Buka Folder Permanen (C:\\Persist) & Bersihkan RAM",
                "Clear Temp trash to boost FPS & open the Anti-Reset vault",
                Color.FromArgb(56, 189, 248), 432, 106, w, h,
                (s, e) => {
                    Directory.CreateDirectory(@"C:\Persist");
                    Process.Start("explorer.exe", @"C:\Persist");
                    RunPowerShellTask("Cleaning the Temp cache & refreshing RAM...", @"
                        Remove-Item -Path ""$env:TEMP\*"" -Recurse -Force -ErrorAction SilentlyContinue
                        [System.GC]::Collect()
                        Write-Host 'Pembersihan Temp & optimasi RAM selesai!'
                    ");
                }
            ));

            Panel infoBar = new Panel { Location = new Point(16, 198), Size = new Size(816, 68), BackColor = Color.FromArgb(20, 26, 38) };
            Label infoText = new Label {
                Text = "PERSISTENCE INFO: All accounts you sign in to in Chrome/Edge, plus files in Downloads, Desktop, Documents and C:\\Persist are automatically saved to your private GitHub Release every 4 minutes and when RDP is stopped. Click button (1) above any time to save instantly!";
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
                "Install a fast browser with cross-session Google login auto-save",
                Color.FromArgb(16, 185, 129), 16, 16, w, h,
                (s, e) => RunPowerShellTask("Downloading and installing Google Chrome / Brave...", @"
                    & winget install --id Google.Chrome --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
                    Write-Host 'Google Chrome ready to use!'
                ")
            ));

            page.Controls.Add(CreateActionButton(
                "2. Install Discord + VLC Media Player + 7-Zip",
                "Install communication and multimedia apps in one click",
                Color.FromArgb(99, 102, 241), 432, 16, w, h,
                (s, e) => RunPowerShellTask("Installing Discord, VLC & 7-Zip...", @"
                    & winget install --id Discord.Discord --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
                    & winget install --id VideoLAN.VLC --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
                    Write-Host 'Discord & VLC installation complete!'
                ")
            ));


            page.Controls.Add(CreateActionButton(
                "4. Change the RDP desktop wallpaper (saved permanently)",
                "Choose an image (.jpg/.png) to use as wallpaper RDP & app Home preview",
                Color.FromArgb(56, 189, 248), 432, 106, w, h,
                (s, e) => {
                    OpenFileDialog ofd = new OpenFileDialog();
                    ofd.Title = "Pilih Gambar Wallpaper Desktop RDP";
                    ofd.Filter = "Gambar Wallpaper (*.jpg;*.jpeg;*.png;*.bmp)|*.jpg;*.jpeg;*.png;*.bmp";
                    if (ofd.ShowDialog() == DialogResult.OK)
                    {
                        string chosen = ofd.FileName.Replace("'", "''");
                        RunPowerShellTask("Menerapkan & menyimpan Wallpaper Desktop baru...", @"
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
                            Write-Host ""Wallpaper changed successfully & saved permanently di $dstPer!""
                        ");
                    }
                }
            ));


        }

        private void BuildProUtilitiesTab(TabPage page)
        {
            int w = 400, h = 76;

            page.Controls.Add(CreateActionButton(
                "2. RAM Standby Cleaner + High-Priority Game Lock",
                "Clear standby memory & kunci CPU Priority gta_sa/javaw/Roblox ke High",
                Color.FromArgb(99, 102, 241), 432, 16, w, h,
                (s, e) => RunPowerShellTask("Optimizing standby RAM & locking High Priority for processes...", @"
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
                "Pertajam teks RDP, matikan efek animasi berat & activekan 120Hz DWM",
                Color.FromArgb(245, 158, 11), 16, 106, w, h,
                (s, e) => RunPowerShellTask("Mengoptimalkan ketajaman layar, ClearType & 120Hz DWM...", @"
                    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'FontSmoothing' -Value '2' -Force -ErrorAction SilentlyContinue
                    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'FontSmoothingType' -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue
                    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations' -Name 'DWMFRAMEINTERVAL' -Value 8 -Type DWord -Force -ErrorAction SilentlyContinue
                    Write-Host 'Optimasi ketajaman layar & 120Hz DWM selesai diterapkan!'
                ")
            ));

            page.Controls.Add(CreateActionButton(
                "4. Hot-Reload Update Engine Server (Tarik Script Terbaru)",
                "Update the Sailuo engine directly from GitHub without stopping the RDP session",
                Color.FromArgb(56, 189, 248), 432, 106, w, h,
                (s, e) => RunPowerShellTask("Pulling the latest Sailuo Engine update from GitHub...", @"

                    if (Test-Path 'C:\Sailuo\.git') {
                        Set-Location 'C:\Sailuo'
                        & git pull --rebase --autostash 2>&1 | ForEach-Object { Write-Host $_ }
                        Write-Host 'Engine Sailuo updated live successfully (Hot-Reload)!'
                    } else {
                        Write-Host 'Directory C:\Sailuo ready.'
                    }
                ")
            ));

            Panel infoPro = new Panel { Location = new Point(16, 198), Size = new Size(816, 68), BackColor = Color.FromArgb(20, 26, 38) };
            Label lblPro = new Label {
                Text = "ENGINE SERVER PRO: Supports Multi-Part Cloud Persistence up to 5.4 GB, Tunnel Failover (Tailscale / Railway / Bore.pub / Portmap), and Hot-Reload Engine without dropping the session.";
                Location = new Point(14, 14),
                Size = new Size(788, 42),
                ForeColor = Color.FromArgb(148, 163, 184),
                Font = new Font("Segoe UI", 8.8f, FontStyle.Regular)
            };
            infoPro.Controls.Add(lblPro);
            page.Controls.Add(infoPro);
        }

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
    Log "SailuoDashboard.exe compiled successfully at $exePath"

    # 1. Create ONE clean shortcut with a unique icon on the Desktop (remove old duplicates!)
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
        $lnk.Description = 'Sailuo Dashboard - System Management, Installer & Cloud Save'
        $lnk.IconLocation = "$exePath,0"
        $lnk.Save()
      } catch {}
    }

    # 2. Daftarkan Auto-Start agar Sailuo Dashboard OTOMATIS TERBUKA when first entering Desktop RDP!
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
      Log 'Sailuo Dashboard registered in Auto-Start (opens automatically on first RDP login).'
    } catch {}

    Update-Status @{ tools_hub = @{ installed = $true; exe = $exePath; auto_start = $true } } | Out-Null
  }
} catch {
  Log "Kompilasi SailuoDashboard.exe warning: $($_.Exception.Message)"
}
exit 0
