# ============================================================================
#  setup-tools-hub.ps1 - Build & Install "Sailuo Dashboard" (GUI Desktop)
# ----------------------------------------------------------------------------
#  Compiles the native WinForms dashboard (C:\Sailuo\tools\SailuoDashboard.exe)
#  with the .NET Framework 4.x C# compiler bundled with Windows Server 2022/2025.
#  The dashboard opens automatically the first time the user signs in to the
#  RDP desktop and provides one-click control for:
#    1. Overview  - workspace shortcuts, session status and maintenance
#    2. Apps      - Chrome, Discord, Facebook, Instagram, Apple Music, Spotify,
#                   VS Code, Antigravity IDE, OpenCode Desktop, Telegram Web,
#                   TikTok Web, wallpaper, engine updates
#    3. System    - display tuning, taskbar theme, diagnostics
#
#  It also registers the dashboard auto-start entry.
# ============================================================================

$XyTag = 'Sailuo:dashboard'
. "$PSScriptRoot/lib-common.ps1"

$cfg = Get-Cfg
$u = if ($env:RDP_USER) { $env:RDP_USER.Trim() } else { $cfg.rdp_user }

$toolsDir = 'C:\Sailuo\tools'
New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null

# The dashboard starts helper scripts from C:\Sailuo\scripts. The Actions
# checkout (D:\a\...) disappears when the session ends, so keep a durable copy
# next to the dashboard and refresh it on every setup run.
$scriptsDir = 'C:\Sailuo\scripts'
New-Item -ItemType Directory -Path $scriptsDir -Force -ErrorAction SilentlyContinue | Out-Null
if (Test-Path $PSScriptRoot) {
  Copy-Item -Path (Join-Path $PSScriptRoot '*.ps1') -Destination $scriptsDir -Force -ErrorAction SilentlyContinue
}
$assetsDir = 'C:\Sailuo\assets'
New-Item -ItemType Directory -Path $assetsDir -Force -ErrorAction SilentlyContinue | Out-Null
$repoAssets = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets'
if (Test-Path $repoAssets) {
  Copy-Item -Path (Join-Path $repoAssets '*') -Destination $assetsDir -Force -ErrorAction SilentlyContinue
}

# Persist the session context so the dashboard can read GitHub Actions logs
# without inheriting the setup process environment.
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
// ============================================================================
//  Sailuo Dashboard - native WinForms control center
//  ---------------------------------------------------------------------------
//  UI/UX architecture notes
//  ---------------------------------------------------------------------------
//  * Every layout value is expressed in DIPs (device independent pixels) and
//    converted with Ui.S(), so the whole surface is crisp and correctly
//    proportional from 100% through 200% display scaling. The process opts in
//    to Per-Monitor-V2 DPI awareness before the first window is created and
//    rebuilds its layout when it is moved to a monitor with another DPI.
//  * Layout is computed (Measure/Arrange), never hand-positioned: PageView
//    arranges vertical sections, CardGrid flows action cards into 1-4 columns,
//    the sidebar collapses to an icon rail and the activity panel adapts its
//    height to the window. Resizing therefore never produces overlaps, clipped
//    content or a horizontal scrollbar.
//  * All colours come from Theme; all spacing from the 4/8/12/16/24/32 scale;
//    all text from the UiFonts type scale. Contrast pairs in use are documented
//    next to the tokens.
//  * Interaction states (hover, pressed, focus, disabled) are shared through a
//    single animation ticker and honour the Windows "show animations" setting.
//  * Source is intentionally ASCII-only (Unicode symbols are emitted with \u
//    escapes) so the legacy .NET Framework csc.exe always decodes it correctly.
// ============================================================================

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

[assembly: System.Reflection.AssemblyTitle("Sailuo Dashboard")]
[assembly: System.Reflection.AssemblyProduct("Sailuo")]
[assembly: System.Reflection.AssemblyDescription("Sailuo control center for applications and system tools.")]

namespace SailuoTools
{
    // ========================================================================
    //  Theme - single source of truth for colour
    // ========================================================================
    internal static class Theme
    {
        // Restrained light workspace: cool neutral canvas, white surfaces and a
        // single Sailuo blue accent. Semantic colours are reserved for status.
        public static readonly Color Bg        = Color.FromArgb(246, 247, 249); // window / page canvas
        public static readonly Color BgDeep    = Color.FromArgb(255, 255, 255); // white chrome / panels
        public static readonly Color SurfaceLo = Color.FromArgb(248, 250, 252); // inset wells, subtle fills
        public static readonly Color Surface   = Color.FromArgb(255, 255, 255); // cards, panels
        public static readonly Color SurfaceHi = Color.FromArgb(241, 245, 249); // hover / raised

        // Lines
        public static readonly Color Border       = Color.FromArgb(227, 231, 237);
        public static readonly Color BorderStrong = Color.FromArgb(203, 210, 220);
        public static readonly Color ChromeLine   = Color.FromArgb(234, 237, 242);
        public static readonly Color BorderControl = Color.FromArgb(203, 210, 220);

        // Text (AA contrast on white and the #F6F7F9 canvas).
        public static readonly Color Text      = Color.FromArgb(17, 24, 39);
        public static readonly Color TextSoft  = Color.FromArgb(55, 65, 81);
        public static readonly Color TextMuted = Color.FromArgb(91, 101, 115);

        // Sailuo accents. Blue is the product colour; green / amber / red carry
        // meaning only and are darkened enough for AA text contrast.
        public static readonly Color Blue   = Color.FromArgb(37, 99, 235);
        public static readonly Color Green  = Color.FromArgb(21, 128, 61);
        public static readonly Color Violet = Color.FromArgb(109, 40, 217);
        public static readonly Color Amber  = Color.FromArgb(180, 83, 9);
        public static readonly Color Cyan   = Color.FromArgb(8, 145, 178);
        public static readonly Color Red    = Color.FromArgb(220, 38, 38);
        public static readonly Color Slate  = Color.FromArgb(100, 116, 139);

        // Soft tints used behind small icons and status chips.
        public static readonly Color BlueSoft  = Color.FromArgb(239, 244, 255);
        public static readonly Color GreenSoft = Color.FromArgb(240, 253, 244);
        public static readonly Color AmberSoft = Color.FromArgb(255, 251, 235);
        public static readonly Color RedSoft   = Color.FromArgb(254, 242, 242);

        // Text placed on top of a filled accent control.
        public static readonly Color OnAccent = Color.White;

        // Brand colour (flat; the installed Sailuo mark is used when present).
        public static readonly Color BrandFrom = Color.FromArgb(37, 99, 235);
        public static readonly Color BrandTo   = Color.FromArgb(37, 99, 235);

        // Dark navigation rail (the only dark surface in the light theme).
        public static readonly Color Sidebar       = Color.FromArgb(15, 23, 42);
        public static readonly Color SidebarCard   = Color.FromArgb(20, 31, 51);
        public static readonly Color SidebarHover  = Color.FromArgb(24, 36, 56);
        public static readonly Color SidebarActive = Color.FromArgb(30, 45, 70);
        public static readonly Color SidebarBorder = Color.FromArgb(31, 43, 64);
        public static readonly Color SidebarText   = Color.FromArgb(203, 213, 225);
        public static readonly Color SidebarMuted  = Color.FromArgb(124, 140, 165);
        public static readonly Color SidebarStrong = Color.FromArgb(241, 245, 249);

        // Keyboard focus ring. Light theme uses a strong blue; the dark rail
        // uses a lighter blue so the ring stays visible on navy.
        public static readonly Color Focus = Color.FromArgb(37, 99, 235);
        public static readonly Color FocusOnDark = Color.FromArgb(96, 165, 250);

        public static Color SurfaceFor(bool raised) { return raised ? SurfaceHi : Surface; }
    }

    // ========================================================================
    //  Ui - DPI, spacing scale, system preferences
    // ========================================================================
    internal static class Ui
    {
        public const int BaseDpi = 96;

        // Spacing scale (DIP). Use Ui.S(Ui.Space3) etc.
        public const int Space1 = 4;
        public const int Space2 = 8;
        public const int Space3 = 12;
        public const int Space4 = 16;
        public const int Space5 = 24;
        public const int Space6 = 32;
        public const int Space7 = 40;

        // Corner radii (DIP) - consistent 8/12/16 scale.
        public const int RadiusSm = 8;
        public const int RadiusMd = 12;
        public const int RadiusLg = 16;

        // Control heights (DIP)
        public const int HeaderHeight   = 56;
        public const int PageHeader     = 96;
        public const int NavHeight      = 40;
        public const int CardHeight     = 80;
        public const int ButtonHeight   = 36;
        public const int ButtonHeightSm = 30;

        public static int Dpi = BaseDpi;
        public static int ForcedDpi = 0;   // test/diagnostic override, see Main()

        public static float Scale
        {
            get
            {
                int dpi = ForcedDpi > 0 ? ForcedDpi : Dpi;
                return (float)dpi / BaseDpi;
            }
        }

        /// <summary>Scale a DIP value to physical pixels.</summary>
        public static int S(int dip) { return (int)Math.Round(dip * Scale); }

        /// <summary>Scale a DIP value to physical pixels (float).</summary>
        public static float SF(float dip) { return dip * Scale; }

        /// <summary>
        /// Font point sizes already scale with the monitor DPI, so fonts are only
        /// multiplied when the diagnostic DPI override is active.
        /// </summary>
        public static float FontScale
        {
            get { return ForcedDpi > 0 ? (float)ForcedDpi / BaseDpi : 1f; }
        }

        private static bool _animations;
        private static bool _animationsKnown;

        /// <summary>Respects Settings &gt; Accessibility &gt; Visual effects &gt; Animation effects.</summary>
        public static bool AnimationsEnabled
        {
            get
            {
                if (_animationsKnown) { return _animations; }
                _animationsKnown = true;
                _animations = true;
                try
                {
                    int value = 1;
                    if (SystemParametersInfo(SPI_GETCLIENTAREAANIMATION, 0, ref value, 0)) { _animations = value != 0; }
                }
                catch { }
                return _animations;
            }
        }

        // --- DPI awareness / queries -------------------------------------
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool SetProcessDpiAwarenessContext(IntPtr value);

        [DllImport("shcore.dll")]
        private static extern int SetProcessDpiAwareness(int value);

        [DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();

        [DllImport("user32.dll")]
        public static extern uint GetDpiForWindow(IntPtr hwnd);

        [DllImport("user32.dll")]
        public static extern uint GetDpiForSystem();

        [DllImport("user32.dll")]
        private static extern bool SystemParametersInfo(int action, int param, ref int value, int winIni);

        private const int SPI_GETCLIENTAREAANIMATION = 0x1042;

        /// <summary>
        /// Opts in to Per-Monitor-V2 awareness; degrades to per-monitor, then
        /// system awareness on older Windows builds. Must run before any window
        /// (or device context) is created.
        /// </summary>
        public static void EnableDpiAwareness()
        {
            try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) { return; } }
            catch { }
            try { if (SetProcessDpiAwareness(2) == 0) { return; } }
            catch { }
            try { SetProcessDPIAware(); }
            catch { }
        }

        public static int ScreenDpi()
        {
            uint dpi = 0;
            try { dpi = GetDpiForSystem(); } catch { }
            if (dpi == 0) { dpi = (uint)BaseDpi; }
            return (int)dpi;
        }
    }

    // ========================================================================
    //  UiFonts - type scale.  Families are resolved once with a safe fallback.
    // ========================================================================
    internal static class UiFonts
    {
        private static readonly Dictionary<string, Font> Cache = new Dictionary<string, Font>(StringComparer.Ordinal);
        private static string _textFamily;
        private static string _semiFamily;
        private static string _monoFamily;

        private static string Pick(string[] candidates)
        {
            foreach (string candidate in candidates)
            {
                try
                {
                    using (Font probe = new Font(candidate, 9f))
                    {
                        if (string.Equals(probe.Name, candidate, StringComparison.OrdinalIgnoreCase)) { return candidate; }
                    }
                }
                catch { }
            }
            return "Segoe UI";
        }

        private static string TextFamily
        {
            get
            {
                if (_textFamily == null) { _textFamily = Pick(new string[] { "Segoe UI Variable Text", "Segoe UI", "Tahoma" }); }
                return _textFamily;
            }
        }

        private static string SemiFamily
        {
            get
            {
                if (_semiFamily == null) { _semiFamily = Pick(new string[] { "Segoe UI Semibold", "Segoe UI Variable Text", "Segoe UI", "Tahoma" }); }
                return _semiFamily;
            }
        }

        private static string MonoFamily
        {
            get
            {
                if (_monoFamily == null) { _monoFamily = Pick(new string[] { "Cascadia Mono", "Consolas", "Courier New" }); }
                return _monoFamily;
            }
        }

        private static Font Get(string key, string family, float points, FontStyle style)
        {
            Font font;
            if (Cache.TryGetValue(key, out font)) { return font; }
            font = new Font(family, points * Ui.FontScale, style, GraphicsUnit.Point);
            Cache[key] = font;
            return font;
        }

        // "Semibold" families carry the weight in the family name; plain
        // families need the Bold style to reach the same visual weight.
        private static Font Semi(string key, float points, bool display)
        {
            string family = display ? Pick(new string[] { "Segoe UI Semibold", "Segoe UI Variable Display", "Segoe UI" }) : SemiFamily;
            bool needsBold = !family.StartsWith("Segoe UI Semibold", StringComparison.OrdinalIgnoreCase);
            return Get(key, family, points, needsBold ? FontStyle.Bold : FontStyle.Regular);
        }

        public static Font Hero      { get { return Semi("hero", 24f, true); } }
        public static Font PageTitle { get { return Semi("pageTitle", 21.5f, true); } }
        public static Font Section   { get { return Semi("section", 11.5f, false); } }
        public static Font H1        { get { return Semi("h1", 12.5f, false); } }
        public static Font H2        { get { return Semi("h2", 10.75f, false); } }
        public static Font Brand     { get { return Semi("brand", 15f, true); } }
        public static Font BrandSub  { get { return Get("brandSub", TextFamily, 8.75f, FontStyle.Regular); } }
        public static Font Value     { get { return Semi("value", 17f, true); } }
        public static Font Body      { get { return Get("body", TextFamily, 9.5f, FontStyle.Regular); } }
        public static Font Small     { get { return Get("small", TextFamily, 8.75f, FontStyle.Regular); } }
        public static Font Micro     { get { return Semi("micro", 8.25f, false); } }
        public static Font Button    { get { return Semi("button", 9.5f, false); } }
        public static Font ButtonSm  { get { return Semi("buttonSm", 8.75f, false); } }
        public static Font Mono      { get { return Get("mono", MonoFamily, 9f, FontStyle.Regular); } }
        public static Font Glyph     { get { return Get("glyph", GlyphFamily(), 12f, FontStyle.Regular); } }
        public static Font GlyphSm   { get { return Get("glyphSm", GlyphFamily(), 10f, FontStyle.Regular); } }
        public static Font GlyphLg   { get { return Get("glyphLg", GlyphFamily(), 17f, FontStyle.Regular); } }

        private static string _glyphFamily;
        private static string GlyphFamily()
        {
            if (_glyphFamily == null) { _glyphFamily = Pick(new string[] { "Segoe Fluent Icons", "Segoe MDL2 Assets" }); }
            return _glyphFamily;
        }
    }

    // ========================================================================
    //  Ticker - one shared 60fps timer for every short hover/press animation
    // ========================================================================
    internal interface IAnimatable
    {
        /// <summary>Advance one frame; return false when settled.</summary>
        bool AdvanceFrame();
    }

    internal static class Ticker
    {
        private static readonly System.Windows.Forms.Timer Shared = new System.Windows.Forms.Timer();
        private static readonly List<WeakReference> Items = new List<WeakReference>();
        private static bool _started;

        static Ticker()
        {
            Shared.Interval = 16;
            Shared.Tick += delegate { Pump(); };
        }

        public static void Add(IAnimatable item)
        {
            foreach (WeakReference reference in Items)
            {
                if (reference.Target == item) { return; }
            }
            Items.Add(new WeakReference(item));
        }

        public static void Wake()
        {
            if (!Ui.AnimationsEnabled) { return; }
            if (_started) { return; }
            _started = true;
            Shared.Start();
        }

        private static void Pump()
        {
            bool any = false;
            for (int i = Items.Count - 1; i >= 0; i--)
            {
                IAnimatable item = Items[i].Target as IAnimatable;
                if (item == null) { Items.RemoveAt(i); continue; }
                if (item.AdvanceFrame()) { any = true; }
            }
            if (!any)
            {
                _started = false;
                Shared.Stop();
            }
        }
    }

    // ========================================================================
    //  Gfx - shared drawing helpers
    // ========================================================================
    internal static class Gfx
    {
        [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
        private static extern int SetWindowTheme(IntPtr hWnd, string subApp, string subId);

        public const TextFormatFlags Left = TextFormatFlags.Left | TextFormatFlags.NoPrefix;
        public const TextFormatFlags LeftCenter = TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix;
        public const TextFormatFlags LeftTop = TextFormatFlags.Left | TextFormatFlags.Top | TextFormatFlags.NoPrefix;
        public const TextFormatFlags Center = TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix;

        public static void DarkScroll(Control control)
        {
            // Classic light theme: keep the normal system scrollbar.
            return;
        }

        private static void ApplyDarkScroll(IntPtr handle)
        {
            try { SetWindowTheme(handle, "DarkMode_Explorer", null); }
            catch { }
        }

        public static GraphicsPath Round(Rectangle rect, int radius)
        {
            GraphicsPath path = new GraphicsPath();
            if (radius <= 0 || rect.Width <= 0 || rect.Height <= 0)
            {
                path.AddRectangle(rect);
                return path;
            }
            int diameter = Math.Min(Math.Min(radius * 2, rect.Width), rect.Height);
            path.AddArc(rect.X, rect.Y, diameter, diameter, 180, 90);
            path.AddArc(rect.Right - diameter, rect.Y, diameter, diameter, 270, 90);
            path.AddArc(rect.Right - diameter, rect.Bottom - diameter, diameter, diameter, 0, 90);
            path.AddArc(rect.X, rect.Bottom - diameter, diameter, diameter, 90, 90);
            path.CloseFigure();
            return path;
        }

        public static Color Mix(Color from, Color to, float amount)
        {
            if (amount < 0f) { amount = 0f; }
            if (amount > 1f) { amount = 1f; }
            return Color.FromArgb(
                (int)(from.A + (to.A - from.A) * amount),
                (int)(from.R + (to.R - from.R) * amount),
                (int)(from.G + (to.G - from.G) * amount),
                (int)(from.B + (to.B - from.B) * amount));
        }

        public static Color Alpha(Color color, int alpha)
        {
            return Color.FromArgb(alpha, color.R, color.G, color.B);
        }

        public static void FillRound(Graphics graphics, Rectangle rect, int radius, Color color)
        {
            using (GraphicsPath path = Round(rect, radius))
            using (SolidBrush brush = new SolidBrush(color))
            {
                graphics.FillPath(brush, path);
            }
        }

        public static void StrokeRound(Graphics graphics, Rectangle rect, int radius, Color color, float width)
        {
            using (GraphicsPath path = Round(rect, radius))
            using (Pen pen = new Pen(color, width))
            {
                graphics.DrawPath(pen, path);
            }
        }

        /// <summary>2px accent focus ring with a dark separation line - always visible on any surface.</summary>
        public static void FocusRing(Graphics graphics, Rectangle bounds, int radius, Color color)
        {
            if (bounds.Width < Ui.S(8) || bounds.Height < Ui.S(8)) { return; }
            int inset = Ui.S(2);
            Rectangle outer = new Rectangle(bounds.X + inset, bounds.Y + inset, bounds.Width - inset * 2 - 1, bounds.Height - inset * 2 - 1);
            StrokeRound(graphics, outer, Math.Max(2, radius - inset), color, 2f);
        }

        public static void DrawGlyph(Graphics graphics, string glyph, Font font, Rectangle bounds, Color color, TextFormatFlags flags)
        {
            TextRenderer.DrawText(graphics, glyph, font, bounds, color, flags | TextFormatFlags.NoPrefix);
        }

        /// <summary>Text height for a width-constrained run of text.</summary>
        public static int TextHeight(string text, Font font, int width, TextFormatFlags flags)
        {
            if (width <= 0) { return font.Height; }
            Size size = TextRenderer.MeasureText(text ?? string.Empty, font, new Size(width, int.MaxValue),
                flags | TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix);
            return Math.Max(font.Height, size.Height);
        }

        /// <summary>Clipped single-line text (ellipsis) - used for compact chrome.</summary>
        public static void Ellipsis(Graphics graphics, string text, Font font, Rectangle bounds, Color color)
        {
            TextRenderer.DrawText(graphics, text ?? string.Empty, font, bounds, color,
                TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix |
                TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding);
        }
    }

    // ========================================================================
    //  Controls
    // ========================================================================

    internal sealed class LogoMark : Control
    {
        private static Image _logoImage;
        private static bool _logoTried;

        public LogoMark()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            Size = new Size(Ui.S(34), Ui.S(34));
            BackColor = Theme.Sidebar;
            TabStop = false;
            AccessibleRole = AccessibleRole.Graphic;
            AccessibleName = "Sailuo logo";
            LoadLogoImage();
        }

        private static void LoadLogoImage()
        {
            if (_logoTried) { return; }
            _logoTried = true;
            string[] candidates = new string[]
            {
                @"C:\Sailuo\assets\sailuo-logo.png",
                @"C:\Sailuo\icons\sailuo-logo.png"
            };
            foreach (string candidate in candidates)
            {
                try
                {
                    if (File.Exists(candidate))
                    {
                        using (FileStream stream = File.OpenRead(candidate))
                        using (Image loaded = Image.FromStream(stream))
                        {
                            _logoImage = new Bitmap(loaded);
                        }
                        return;
                    }
                }
                catch { }
            }
            // The dashboard icon already carries the Sailuo mark. Reusing it
            // keeps the brand consistent even when no dedicated PNG is present.
            try
            {
                string iconPath = @"C:\Sailuo\icons\sailuo-dashboard.ico";
                if (File.Exists(iconPath))
                {
                    using (Icon loaded = new Icon(iconPath, 64, 64))
                    {
                        _logoImage = loaded.ToBitmap();
                    }
                }
            }
            catch { }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics graphics = e.Graphics;
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
            graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
            Rectangle rect = new Rectangle(0, 0, Width - 1, Height - 1);
            if (_logoImage != null)
            {
                Rectangle dest = new Rectangle(0, 0, Width, Height);
                try { graphics.DrawImage(_logoImage, dest); } catch { }
                return;
            }
            // Fallback when no mark is installed: rounded Sailuo tile.
            Gfx.FillRound(graphics, rect, Ui.S(9), Theme.BrandFrom);
            using (Font font = new Font(UiFonts.Brand.FontFamily, 15f * Ui.FontScale, FontStyle.Bold))
            {
                TextRenderer.DrawText(graphics, "S", font, rect, Color.White, Gfx.Center);
            }
        }
    }

    internal sealed class Dot : Control
    {
        private Color _color = Theme.Green;

        public Dot()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            Size = new Size(Ui.S(8), Ui.S(8));
            BackColor = Theme.BgDeep;
            TabStop = false;
            AccessibleRole = AccessibleRole.Indicator;
        }

        public void SetColor(Color color)
        {
            _color = color;
            Invalidate();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (SolidBrush brush = new SolidBrush(_color))
            {
                e.Graphics.FillEllipse(brush, 0, 0, Width - 1, Height - 1);
            }
        }
    }

    internal sealed class Chip : Control
    {
        private string _label = string.Empty;
        public Color DotColor = Theme.Green;
        public string Glyph = string.Empty;

        public Chip(string label, Color dotColor)
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.Surface;
            TabStop = false;
            DotColor = dotColor;
            Height = Ui.S(28);
            AccessibleRole = AccessibleRole.StaticText;
            SetLabel(label);
        }

        public void SetLabel(string label)
        {
            _label = label ?? string.Empty;
            Width = MeasuredWidth();
            AccessibleName = _label;
            Invalidate();
        }

        public int MeasuredWidth()
        {
            Size text = TextRenderer.MeasureText(_label, UiFonts.Small);
            int lead = string.IsNullOrEmpty(Glyph) ? Ui.S(7) + Ui.S(7) : Ui.S(14) + Ui.S(6);
            return Ui.S(12) + lead + text.Width + Ui.S(14);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics graphics = e.Graphics;
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle rect = new Rectangle(0, 0, Width - 1, Height - 1);
            Gfx.FillRound(graphics, rect, Height / 2, Theme.Surface);
            Gfx.StrokeRound(graphics, rect, Height / 2, Theme.Border, 1f);
            if (string.IsNullOrEmpty(Glyph))
            {
                int size = Ui.S(6);
                using (SolidBrush dot = new SolidBrush(DotColor))
                {
                    graphics.FillEllipse(dot, Ui.S(12), (Height - size) / 2, size, size);
                }
                Gfx.Ellipsis(graphics, _label, UiFonts.Small,
                    new Rectangle(Ui.S(12) + Ui.S(13), 0, Width - Ui.S(12) - Ui.S(13) - Ui.S(10), Height), Theme.TextSoft);
            }
            else
            {
                Rectangle glyphRect = new Rectangle(Ui.S(11), (Height - Ui.S(14)) / 2, Ui.S(14), Ui.S(14));
                Gfx.DrawGlyph(graphics, Glyph, UiFonts.GlyphSm, glyphRect, Theme.TextMuted, Gfx.Center);
                Gfx.Ellipsis(graphics, _label, UiFonts.Small,
                    new Rectangle(Ui.S(11) + Ui.S(18), 0, Width - Ui.S(11) - Ui.S(18) - Ui.S(10), Height), Theme.TextSoft);
            }
        }
    }

    internal sealed class SlimProgress : Control
    {
        private readonly System.Windows.Forms.Timer _timer;
        private int _offset;
        private bool _active;

        public SlimProgress()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            Height = Ui.S(3);
            BackColor = Theme.BgDeep;
            TabStop = false;
            AccessibleRole = AccessibleRole.ProgressBar;
            _timer = new System.Windows.Forms.Timer();
            _timer.Interval = 16;
            _timer.Tick += delegate
            {
                _offset += Ui.S(9);
                if (_offset > Width) { _offset = -Ui.S(140); }
                Invalidate();
            };
        }

        public bool Active
        {
            get { return _active; }
            set
            {
                if (_active == value) { return; }
                _active = value;
                if (value && Ui.AnimationsEnabled) { _offset = -Ui.S(140); _timer.Start(); }
                else { _timer.Stop(); }
                Invalidate();
            }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                try { _timer.Stop(); _timer.Dispose(); } catch { }
            }
            base.Dispose(disposing);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics graphics = e.Graphics;
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Gfx.FillRound(graphics, new Rectangle(0, 0, Width, Height), Math.Max(1, Height / 2), Theme.SurfaceHi);
            if (!_active) { return; }

            int segment = Ui.S(180);
            int x = Ui.AnimationsEnabled ? _offset : Math.Max(0, (Width - segment) / 4);
            x = Math.Max(0, x);
            int width = Math.Min(segment, Width - x);
            if (width <= 0) { return; }
            Gfx.FillRound(graphics, new Rectangle(x, 0, width, Height), Math.Max(1, Height / 2), Theme.Blue);
        }
    }

    internal enum ButtonVariant
    {
        Primary,
        Secondary,
        Ghost,
        Destructive
    }

    /// <summary>Flat rounded button with shared hover / press / focus / disabled states.</summary>
    internal sealed class PillButton : Control, IAnimatable, IButtonControl
    {
        private float _hover;
        private float _target;
        private bool _pressed;
        private ButtonVariant _variant = ButtonVariant.Secondary;
        private bool _small;
        private string _glyph = string.Empty;
        private bool _autoFit = true;
        private DialogResult _dialogResult = DialogResult.None;

        public Color Accent = Theme.Blue;

        public DialogResult DialogResult
        {
            get { return _dialogResult; }
            set { _dialogResult = value; }
        }

        public void NotifyDefault(bool value)
        {
            // The accent focus ring already communicates the default action.
        }

        public void PerformClick()
        {
            if (Enabled) { OnClick(EventArgs.Empty); }
        }

        public PillButton()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            TabStop = true;
            Cursor = Cursors.Hand;
            BackColor = Theme.Surface;
            Font = UiFonts.Button;
            Height = Ui.S(Ui.ButtonHeight);
            AccessibleRole = AccessibleRole.PushButton;
            Ticker.Add(this);
        }

        public ButtonVariant Variant
        {
            get { return _variant; }
            set { _variant = value; Invalidate(); }
        }

        public bool Small
        {
            get { return _small; }
            set
            {
                _small = value;
                Font = value ? UiFonts.ButtonSm : UiFonts.Button;
                Height = Ui.S(value ? Ui.ButtonHeightSm : Ui.ButtonHeight);
                FitWidth();
                Invalidate();
            }
        }

        public string Glyph
        {
            get { return _glyph; }
            set { _glyph = value ?? string.Empty; FitWidth(); Invalidate(); }
        }

        public bool AutoFit
        {
            get { return _autoFit; }
            set { _autoFit = value; }
        }

        public void FitWidth()
        {
            if (!_autoFit) { return; }
            int padding = Ui.S(_small ? 12 : 14);
            int glyphWidth = string.IsNullOrEmpty(_glyph) ? 0 : Ui.S(_small ? 16 : 18);
            Size text = TextRenderer.MeasureText(Text ?? string.Empty, Font);
            Width = Math.Max(Ui.S(_small ? 30 : 76), text.Width + padding * 2 + glyphWidth);
        }

        protected override void OnTextChanged(EventArgs e)
        {
            base.OnTextChanged(e);
            FitWidth();
            Invalidate();
        }

        protected override void OnEnabledChanged(EventArgs e)
        {
            base.OnEnabledChanged(e);
            if (!Enabled) { _pressed = false; _target = 0f; _hover = 0f; }
            Invalidate();
        }

        protected override void OnMouseEnter(EventArgs e) { AnimateTo(1f); Cursor = Cursors.Hand; base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { _pressed = false; AnimateTo(0f); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left) { Focus(); _pressed = true; Invalidate(); }
            base.OnMouseDown(e);
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            _pressed = false;
            Invalidate();
            base.OnMouseUp(e);
        }

        protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
        protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }

        protected override bool IsInputKey(Keys keyData)
        {
            if (keyData == Keys.Enter || keyData == Keys.Space) { return true; }
            return base.IsInputKey(keyData);
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Enter || e.KeyCode == Keys.Space)
            {
                OnClick(EventArgs.Empty);
                e.Handled = true;
                e.SuppressKeyPress = true;
                return;
            }
            base.OnKeyDown(e);
        }

        private void AnimateTo(float target)
        {
            _target = target;
            if (!Ui.AnimationsEnabled) { _hover = target; Invalidate(); return; }
            Ticker.Wake();
        }

        public bool AdvanceFrame()
        {
            float diff = _target - _hover;
            if (Math.Abs(diff) < 0.02f) { _hover = _target; Invalidate(); return false; }
            _hover += diff * 0.3f;
            Invalidate();
            return true;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics graphics = e.Graphics;
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle rect = new Rectangle(0, 0, Width - 1, Height - 1);
            int radius = Ui.S(Ui.RadiusSm);

            Color face;
            Color border;
            Color foreground;

            if (_variant == ButtonVariant.Primary || _variant == ButtonVariant.Destructive)
            {
                face = _variant == ButtonVariant.Destructive ? Theme.Red : Accent;
                if (Enabled && _hover > 0.01f) { face = Gfx.Mix(face, Color.Black, 0.09f * _hover); }
                if (_pressed) { face = Gfx.Mix(face, Color.Black, 0.16f); }
                if (!Enabled) { face = Theme.SurfaceHi; }
                border = face;
                foreground = Enabled ? Theme.OnAccent : Theme.TextMuted;
            }
            else if (_variant == ButtonVariant.Secondary)
            {
                face = Theme.Surface;
                if (Enabled && _hover > 0.01f) { face = Gfx.Mix(face, Theme.SurfaceHi, _hover); }
                if (_pressed) { face = Gfx.Mix(face, Theme.SurfaceHi, 0.8f); }
                if (!Enabled) { face = Theme.SurfaceLo; }
                border = Enabled ? Gfx.Mix(Theme.BorderStrong, Theme.TextMuted, 0.25f * _hover) : Theme.Border;
                foreground = Enabled ? Theme.Text : Theme.TextMuted;
            }
            else
            {
                face = Gfx.Mix(Theme.Surface, Theme.SurfaceHi, _hover);
                if (_pressed) { face = Gfx.Mix(face, Color.Black, 0.03f); }
                border = Color.Transparent;
                foreground = Enabled ? Gfx.Mix(Theme.TextSoft, Theme.Text, _hover) : Theme.TextMuted;
            }

            if (_variant == ButtonVariant.Ghost)
            {
                if (_hover > 0.01f || _pressed)
                {
                    using (GraphicsPath path = Gfx.Round(rect, radius))
                    using (SolidBrush brush = new SolidBrush(face))
                    {
                        graphics.FillPath(brush, path);
                    }
                }
            }
            else
            {
                Gfx.FillRound(graphics, rect, radius, face);
                if (_variant == ButtonVariant.Secondary)
                {
                    Gfx.StrokeRound(graphics, rect, radius, border, 1f);
                }
            }

            Rectangle textRect = rect;
            if (!string.IsNullOrEmpty(_glyph) && string.IsNullOrEmpty(Text))
            {
                // Icon-only button: keep the glyph perfectly centred.
                int size = Ui.S(_small ? 15 : 17);
                Rectangle glyphOnly = new Rectangle((Width - size) / 2, (Height - size) / 2, size, size);
                Gfx.DrawGlyph(graphics, _glyph, UiFonts.Glyph, glyphOnly, foreground, Gfx.Center);
            }
            else
            {
                if (!string.IsNullOrEmpty(_glyph))
                {
                    int glyphWidth = Ui.S(_small ? 16 : 18);
                    int left = Ui.S(_small ? 11 : 14);
                    Rectangle glyphRect = new Rectangle(rect.X + left, rect.Y, glyphWidth, rect.Height);
                    Gfx.DrawGlyph(graphics, _glyph, UiFonts.GlyphSm, glyphRect, foreground, Gfx.Center);
                    textRect = new Rectangle(rect.X + left + glyphWidth + Ui.S(2), rect.Y,
                        Math.Max(0, rect.Width - left - glyphWidth - Ui.S(2) - Ui.S(8)), rect.Height);
                }
                TextRenderer.DrawText(graphics, Text ?? string.Empty, Font, textRect, foreground, Gfx.Center);
            }
            if (Focused && Enabled)
            {
                bool filled = _variant == ButtonVariant.Primary || _variant == ButtonVariant.Destructive;
                Gfx.FocusRing(graphics, rect, radius, filled ? Color.White : Theme.Focus);
            }
        }
    }

    /// <summary>Sidebar navigation item. In rail mode it renders as an icon-only tile.</summary>
    internal sealed class NavItem : Control, IAnimatable
    {
        private float _hover;
        private float _target;
        private bool _selected;
        private bool _rail;

        public string Glyph = "\uE80F";
        public string Caption = string.Empty;
        public int PageIndex;
        public string Shortcut = string.Empty;

        public NavItem()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            TabStop = true;
            Cursor = Cursors.Hand;
            Height = Ui.S(Ui.NavHeight);
            BackColor = Theme.Sidebar;
            AccessibleRole = AccessibleRole.PageTab;
            Ticker.Add(this);
        }

        public bool Selected
        {
            get { return _selected; }
            set
            {
                if (_selected == value) { return; }
                _selected = value;
                AccessibleDescription = value ? "Selected" : Shortcut;
                Invalidate();
            }
        }

        public bool Rail
        {
            get { return _rail; }
            set { _rail = value; Invalidate(); }
        }

        protected override void OnMouseEnter(EventArgs e) { AnimateTo(1f); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { AnimateTo(0f); base.OnMouseLeave(e); }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left && TabStop) { Focus(); }
            base.OnMouseDown(e);
        }

        protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
        protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }

        protected override bool IsInputKey(Keys keyData)
        {
            if (keyData == Keys.Enter || keyData == Keys.Space) { return true; }
            return base.IsInputKey(keyData);
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Enter || e.KeyCode == Keys.Space)
            {
                OnClick(EventArgs.Empty);
                e.Handled = true;
                e.SuppressKeyPress = true;
                return;
            }
            // Arrow keys move between navigation items, like a tab strip.
            if (e.KeyCode == Keys.Down || e.KeyCode == Keys.Right || e.KeyCode == Keys.Up || e.KeyCode == Keys.Left)
            {
                Control parent = Parent;
                if (parent != null)
                {
                    int direction = (e.KeyCode == Keys.Down || e.KeyCode == Keys.Right) ? 1 : -1;
                    ControlCollection siblings = parent.Controls;
                    int index = siblings.GetChildIndex(this);
                    for (int step = 1; step <= siblings.Count; step++)
                    {
                        int candidate = (index + direction * step + siblings.Count * 2) % siblings.Count;
                        NavItem item = siblings[candidate] as NavItem;
                        if (item != null && item.Visible && item.Enabled) { item.Focus(); break; }
                    }
                }
                e.Handled = true;
                e.SuppressKeyPress = true;
                return;
            }
            base.OnKeyDown(e);
        }

        private void AnimateTo(float target)
        {
            _target = target;
            if (!Ui.AnimationsEnabled) { _hover = target; Invalidate(); return; }
            Ticker.Wake();
        }

        public bool AdvanceFrame()
        {
            float diff = _target - _hover;
            if (Math.Abs(diff) < 0.02f) { _hover = _target; Invalidate(); return false; }
            _hover += diff * 0.3f;
            Invalidate();
            return true;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics graphics = e.Graphics;
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle rect = new Rectangle(0, 0, Width - 1, Height - 1);
            int radius = Ui.S(Ui.RadiusSm);

            if (_selected)
            {
                Gfx.FillRound(graphics, rect, radius, Theme.SidebarActive);
                int barWidth = Ui.S(3);
                int barInset = Ui.S(9);
                Rectangle bar = new Rectangle(Ui.S(1), barInset, barWidth, Height - barInset * 2);
                Gfx.FillRound(graphics, bar, barWidth, Theme.FocusOnDark);
            }
            else if (_hover > 0.01f)
            {
                Gfx.FillRound(graphics, rect, radius, Gfx.Mix(Theme.Sidebar, Theme.SidebarHover, _hover));
            }

            Color foreground = _selected
                ? Theme.SidebarStrong
                : Gfx.Mix(Theme.SidebarText, Theme.SidebarStrong, _hover);
            Color glyphColor = _selected ? Color.FromArgb(147, 197, 253) : Theme.SidebarMuted;
            int glyphSize = Ui.S(18);
            Rectangle glyphRect = _rail
                ? new Rectangle((Width - glyphSize) / 2, (Height - glyphSize) / 2, glyphSize, glyphSize)
                : new Rectangle(Ui.S(14), (Height - glyphSize) / 2, glyphSize, glyphSize);
            Gfx.DrawGlyph(graphics, Glyph, UiFonts.Glyph, glyphRect, glyphColor, Gfx.Center);

            if (!_rail)
            {
                Rectangle textRect = new Rectangle(Ui.S(42), 0, Math.Max(0, Width - Ui.S(52)), Height);
                TextRenderer.DrawText(graphics, Caption, _selected ? UiFonts.H2 : UiFonts.Body, textRect, foreground,
                    TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix |
                    TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding);
            }

            if (Focused && Enabled) { Gfx.FocusRing(graphics, rect, radius, Theme.FocusOnDark); }
        }

        protected override AccessibleObject CreateAccessibilityInstance()
        {
            return new NavItemAccessibleObject(this);
        }

        /// <summary>Exposes the selected state so screen readers announce the active page.</summary>
        private sealed class NavItemAccessibleObject : ControlAccessibleObject
        {
            private readonly NavItem _owner;

            public NavItemAccessibleObject(NavItem owner) : base(owner) { _owner = owner; }

            public override AccessibleStates State
            {
                get
                {
                    AccessibleStates state = base.State;
                    if (_owner.Selected) { state |= AccessibleStates.Selected; }
                    return state;
                }
            }
        }
    }

    /// <summary>Authentic brand marks used by the Applications catalogue.</summary>
    internal enum BrandIcon
    {
        None = -1,
        Chrome = 0,
        Discord = 1,
        Facebook = 2,
        Instagram = 3,
        AppleMusic = 4,
        Spotify = 5,
        VisualStudioCode = 6,
        Antigravity = 7,
        OpenCode = 8,
        Telegram = 9,
        TikTok = 10
    }

    /// <summary>
    /// Draws the embedded brand-icon sprite sheet. Keeping the sheet in the
    /// assembly means the dashboard still ships as one self-contained exe and
    /// never depends on an external asset folder at runtime.
    /// </summary>
    internal static class BrandIcons
    {
        private const int Cell = 96;
        private const int Columns = 6;

private static readonly string SheetBase64 =
            "iVBORw0KGgoAAAANSUhEUgAAAkAAAADACAYAAADstdzHAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAAGYktHRAAAAAAAAPlDu38AAIAASURBVHja7J13nFxl9f" +
            "/f57kzs33Tk03bFCDJht6rNEGaiAVNsLEoUfkqdg2ifsVOUH8WvoISlWAjVEEREAVFIRQhdDahJLBpm03fbLbMzH3O74/nTtud3WyZ2dkk88nr5t69c8tzn7nz3M8953POgSKKKKKIIooooogiiiii" +
            "iCKKKKKIIvZuSKEbkA1rTjykHJgM7A8cANQB04FxwVQFlAQTQGcw7QQ2BdMbwMvAa26S9VMffW5Xoa+tiCJ2h5qFLRXAFNz9PweYDUwDJgCjgBG4ez8S7BLF3f87gG1AE/Am8AqwguD+b1pUtbPQ11" +
            "ZEEUUMb9Q2XFwB0tfxR4EY0AG0kDn+rMSNP68D6xrrlrQW+tq6YlgQoDUnHuqB1gCHAccH89m4Di8HvAEe2gfagGYcEVoOLAN91ggbJj/ygl/oay+iiElfbvGsMAU4BDgBd//PAsbj7n8zwENbYBew" +
            "GTcIPQs8KvCMhXUbF1XHC33tRRRRRGExdUW9JypTQPM5/rxGMP4E83WNdUsKPv4UlACtOeGQCQgnAecBx+GsPGV5Pm0Hzjr0GHAf8MjUR5/fUMh+KGLfRM3ClknAycDbgJOAWlJWzXyhE2jE3f/3A/" +
            "9pWlS9ttB9UUQRRQwtahvqCz3+3Ac80li3pGDjz5AToLUnHeKpcjDwXuBcnHsr353eE6I4E91fgTtQfW7qshcKzkqL2HsxcWFLSOFw4ELgHJyJOVyg5sRwbrJ7gdvV8szGH1THCt1H/cU33/mPMU1l" +
            "4WM3loRrIz7HhFWP8KEmKt4IBU8ULOKJgiigYkAQBROsS86tGxTT/04sZ90+8Vmwj1FNrSd9P03+bdS9UhtVNYovoKKKATWqvih+8HnUoDsN2iwqKxWeiaCvlGjsxQ89dfobhe73BOIf+pKnqlOBQ3" +
            "H3dh3OZTIWJ1cow93jXjAN1KKQb1ic18DH/TbacbKKzTiXzgqcF+F5oDH8+x/ucR6E2hX1IXTYjT9/BW4Hfbax7qYhHX+GjACtPf7gsBo5HvgQjvhMGsoL7QOacIz0JlGWTVn2/B73IChi+KJmYUsE" +
            "Z16+BDgL594dTtiEswgtAR5tWlTdWegG9YanTvuz98upI2a0i/fe7WHvraIcEhMz1iKSJBkKYhOkQ7oRmlyRH0d2tPt6QAJClPo7RY7SSVFAgDL3S/6tiXapQbca9BVP9VFP7B1hE3/uA0+e0V6I7y" +
            "D2wS+OAE4FLsBJF6YCFYW+N/KMNmANzoJxN/Cv8O9/uL3Qjdodpq6oj4gO6/GnGfgbsESNPrJm9k3RoThp3gnQ+pMOEV85AvgYjnWOHooLGwS2An8CfimWp6c89rwtdIOK2HNR8/ntQtgcC1wGnI8T" +
            "EQ5nbAfuAa7DyBNN368advf/5R/418yNpeEP7/LMhzuMqVXFE8QRFpud/CT+zkpe0vfpMu+ZAAWEB8FY7UJsEsRHkmQmg/yoprYj/Vhp23b5XAiIUDp5Epo97F/Cqr/6wPJTHx+q/o994POlIG8H/g" +
            "eR44HSQt8TBUInqo8D14P+OfyH/1cQItobpr50sYiRPW38+QtwPeo90Tj313kdf/JKgNaceMhkXMdfwvCz+OwOG4AbgV9MffT5NYVuTBF7HmoWtkzD3f8fBiYWuj39xEacNej6pkXVbxa6MQC/Ovsv" +
            "4YcnjHj7tpLQlW2eOdIikiIvjuQkrTY2uyXHqPRKeHqy/HQlN0mLknYlMOkWoK7WH81CeiTTPZYkOWnbBusSxEjStwGM6ush7M89id84b/mZ2/P5HcTe/4VZCF/DvczmW6+5p6ADuAPl2+E//mhloR" +
            "uTQO2K+mnonj/+NNYtydv4kxcCtPakg8Kq5nzgy8Cx+Wr8EOEpYJGo3j1l2QtFt1gRu8WEhTvCglwAXAEcWej2DBLLgUWo3tV0zYghMUtnw9cu/EfZ6qrIZ5tLwp+PGTOWNKJiLM7aklwmkwx13SZj" +
            "Xd+tP1ktQBmurXQLTeZn6VagDHdZ13V0tQRphhss6RojzYXmiFDUYH8XRr954TNvzcsLW+z9nz8D+BEuWrGI7ngB+EL4j//v74VsRO2KS8Ko7lXjj4retWZO7t1iOSdAa048pAb4IrAAqM5//wwJdg" +
            "K/Avnh1EefW1/oxhQxfFGzsGUy8CXgIzgB6N6AVpw1dFHToup1Q33yr7/7b+WvV5dfuak0/PmYSFkmwZEUkelChDLIjO2Z4PROhNLcWwmXlk1ZarJae7K4thI6oZ5IT/rnXd1dGWSITOKTJEzuWL4n" +
            "ereH/cK7nznjjVx+B7GLPncB8H+ITEF1qG+BPQMioLoWuDx884/vKkQTahvq9+rxp7FuSU7Hn5wSoDUnHnIs8H3gtKHrmyHFw8AVUx99fsj87UXsOahZ2HI8sAh4S6Hbkif8G/hK06LqZUN1whvP/k" +
            "v4oQkjvrixNPK1mEh5psYnzaKTRoZ6c2kZK45EWE0jM73pgBKkQ7ISn3Ty0zPx6ereoge3VxdS1GV9hiUITSNE6WRIMaJLQxL/7AXLz96Yi+8gdtHnzsA9gKYM1fe+h2Mt8JHwzT8eUktQbUP9PjH+" +
            "NNYtydn4kxMCtObEww347wauBvYrUOcMFVYBX4lbbp+xhwqkL1rQUq0wEzgYOCaYzwS+snRx9R/yee75C1o+jLtPXgeeAZ7EmY7fWLq4ekeh+2YgGH9FqzFq5wHfBWYUuj15xpvAlagsbbom/wLpiz" +
            "/073c2l0YWR0XGJghK0tLTk8WnB4tONitQwiKT+VmaaNl2terQ3QpEmpurN4tPVxKUsZzu3srUCqW5uTKJD5CuB0qzCsUM+iPPxq46//lzBxXNF5v/2dnArRTdXv3FC8B7w0t/kndN0NSXP2REvH1q" +
            "/LGWpWsPXDLo8WfQBGjNCYeEET4J/C/DX2GeK2wDvo3w86mPPF8wXURfcdGClpC60iKH4xJOHoXL/zCWzBxMDwDzli6u3p6Pdsxf0DISuB14a9rqTlwI9ms4MvQY8KyBtX9cPPwzFdcsbCkBPgl8HR" +
            "hZ6PYMEbYD30H4v6ar8xcu/5l5D+2/prx0aasXOrIbuelqsclGerpYd3rT+3QjOdnIT+IzmxnFlUF2soa4dyFLu7X4dA2BT9P9JLaR7sQn3U0m6FYjtv7tz5z9l4H2f2zeZ8qAG4AP5v2O2jvxe1Q/" +
            "Fr71Z3mLDpvWUF+i++b48y1Er2ucc9Ogxp9BEaA1Jx1SivIF4Epcyux9CW04S8YPpj76fEehG9MV8z+6M4To9CDT9ttwpGd3mT47gfqli6uX5qVNC1ouwpnSd9eGNTgy9CDwH7Gy+uZfVw07MlSzsK" +
            "UMWBhM+1oocAdwDcrVTddU53yAv+2kW0N3T5t81bZI6EpFxPQS1WVU++TK6pX4ZCFAGVadZEh718SGkqb/SRc6Z7MCaRZrTzoJyubmyq4DEtFuri9BEQmOLYqBB4zGPnT2s+c3D+Q7iM37zPuAm9j3" +
            "7u1coQO4OHzLT2/Nx8GnvlxfJrLPjj/twA+Aqxvrlgx4/BkwAVpz4iGlwNdwgudCZXIuNKLAD4FvDxcSNH9BSw1wIi452Vtwycn6U0vtPkXfe8viET0Wjn3f/2yScDSSeAagqOJ59uYbqnpUR85f0F" +
            "IB3IbLPtpX+Dgy9AjwZ+A/SxdXNxWoazMQkJ+vA18gVZR0X0MU+H/At5oW5ZYEfep9D8/eGIn8rcN407pZdbJaczRJiBKkJauQOcj1K6p4InjGERIPR3ASU3okV4aWh1RSxcR6uoigM8TMmsgJpEEW" +
            "ahDr/sZ3k9PtgBEySFFXq5ARQLW7tUey6ILc3+0G/fjbnjn3d/3t/9j7Pj0Slw/t1KG9pfY6/At4V/jWn23P5UFrG+qL408w/ih8a80ASdCACNDaEw8Jq2OdX2PfJT8JRIHvoLpo6rIXCuIOm/+xlh" +
            "DKQcA7ccRnMOVFdgIfBZ7D5W4aF0zjcVWAq3DWvhApYuUDcVzhu504E+WmtGkDTkPwGwYemRAFXsJlX70b9MWli0cUxCo0YeGOEkG+AnyFfXfwSSAKXI3I95qursqZO2zBex/5362RyDcUTIr0aBrB" +
            "kTQSpN0sOd0tOM5KVF7uMXJMhJFjI4yeUMKo8SVUVIUoq/SIlBhCEUMobAiFBc9LDY+eJ5iQ+zv9fxcRJcmBVK3ix6wjOsHHNmrxE1OnJdbqE90Ro21TlNZ17bQ3d9K+sZPOrVHEOqIj0sUiJOlWo7" +
            "S5uM8hMU8jRwKCvUdUP3jGM+f3S18Xe+/lFwC3UBzfB4tOYF74tmvvztUBA7dXcfxxcOMP+r3Guv67w/pNgNYcN9fghT6NE1zta26vntAOfBWxP536yItDJoyet2BnSNCTcImuziZ3ya424W6sEeSm" +
            "GnAL7oc6Lkft24Ar2/A7Vfn3Lb+qGrKaPBO+2mokbj8DfI99z+zcEzqAr1rMT5oXVQ76/v/+OQ+Ne7mq/OZOY97a1X3VnehoFjdWygKEr4Q8YezEUuYcOZKZB1dRM62c0TUlhCKFL0mlvtKxNcqOVW" +
            "1sebGFpke3sr1hJ35bHGPSXGRu6xTpUU2RJLqSoozlLap63hnL3/FEX9sUe8+nPIz8CqgvdP/kvsM1mIK/PQMlEbeuM+qYZ+6xBOXS8O3XDnqcqn3pwwZjiuNPJjqAr+KbnzQe9Jt+jT+hfp/KC70b" +
            "Z3orkp8UnDlSzTpcxMSQQNDzcSLFsTk+dK6IisFZfHKdj2IiLrv420X0Upx7bEggcTsPd/8P+8EnfZzPuIbEPHdjfSnwNYPdANw82INtC5ujQlYP8RW8JMHRZMSXdNPzKBmZloPJA2qml3HE6eM4+K" +
            "QxjJpQghca8vrPvUI8oWxcCWXjSqg5dhT7vXMim5dv540/rWfL8m3YDj9wjXVxd2Vxe3Vb5/4eKaKnAX0mQAi1qB5f6L4ZNJQU4RHA86CiDBk1AmrGIlMmwqTxyISxEPexf/4H+mxDPkhQok7aG4M+" +
            "kjF7zPgzhHByHK//40+/vukgz88f2PtD3QeKVcAHhiJP0PyPtUxGuRMXxr4v43HgPUsXV+c9QWXNwpYTcPf/9EJfdDbYxFgvaGmIeEWJ+KVhPM+IZwSxilqrfszHdsbRjrh60Tghm3oploQWZYB4A3" +
            "h/06LqxwZzHZe9a9llHWJ+riqSIjbdNT4ZJSbSorCwSkmJ4ZCTx3LKeyczYfqe967WuS3K2r82ser3b9LR1I6YbOLoLtYeEiQocxn0tlhEPvDWZe/sUyb72Hs++U7cfb5ndVyC7IAjO2WlyKhqmDAW" +
            "mToRmTYJJk1Axo6CynIIZb7/64uv4F/9S+jIeWDjLuAD4Tt+Pig3WG1D/bAef4YBVgMfaKxb0ufxp88WoDUnHjKRfSPPz2AwE/j+mhMPef/UR5/fkK+TzL9sqyHO/1AkP+DC+j/53gXbvn7b4lF5cz" +
            "8GGZ6vZpgNPgpYC5EQ/vRRJnrEVM8/otb4+4014UkjTayyhLAnIggeirVKPOprrLUT3dyqka27rN3eTlvjVmvWbLclz621smarLRngS/B04OqahTvf37SoasAZW0vj/lExYyRVMiJlBUoRHe3m8hKc" +
            "wLiiOsQp86ZyzNtrKCnvj/5/+KBkVIT9PlBL9X4VrPzZK+xcsSNweWUjPmnusOxWoCmRuE7C5VDpCw5nOJOfpBurF7JTO8lZd8aNhsoKCPfhUTdqBJSVQHtHrq1AFbg+HTABCjI8D7vxZ5hhBnB1bU" +
            "P9+/uaMbpPBGjNCYeGQb9AMSKgLzgV+OKaEw6+Ymq+aofFQycClxb6QocRPurh3Qs8mo+DT7yiJaLKlxlmGVatQkmI+PEHeJ3vOyLsn7hfKDKhSspEkoFMXRFyk6QVsfQgJaS0372/U3/yUJRBeIpO" +
            "Bv1yzcKWLzYtqh7Q/R/27cHhLladzBpaKZdXQiScsPxUjghz2odrOeq8ibt1d8UDUbKNW+JRS7zdT4mVoxYbS+PTmuY6TDoWhYSTURLLmpJEi4CJGLywcfOIwSsxeKUe4on7u9Tr2Q4vMO74MYTL62" +
            "hY9BI7V+zIcIchmhJIk7T2pITRkiRH4xSdSF8JkOqcAX/7uUa6GwucZqesFBlRFZCdGqidhEypcWSnqrJvZKeH/g6uPx9XUjfQHWtXXBJBddiNP8MUJwNfrm2o/2Jj3ZLdjj99u1NEzwc+Vugr24Ow" +
            "AJFlwB25PvC8j7VWoPazuKisIhwmAJ+bv6Dl2aWLq3cN+mhdoMo7cbV1hg2sonU1pv3Tp0XiZ88NlZZHpGIQh0sM/V4oN7rgj+BSF9w2kJ2NZWIEzbD8pCcXTBUdzbQQlZQYTp43haPfPhHjZWcVsX" +
            "afza/tpHlFC5tf28mONW20b+kk1hYH6yLF3Dx1DgJXW3KeiLRSR3oE6ZLXJyBsgRXBiCAijpgYIVTqERkZoWJSGdX7VzGirpoRdVWUjMkecDXy0JHM+fwcVnz3BdrfbEVMNwtP2nKKECFJsjYCGN3n" +
            "L0B1Wk7ugoHCBsTTGCgtQUZWpzQ7tZOQKRNSZCcSzt15lRThyj0G3qeusOmwGn+GOfo8/uyWAK094ZDJQcj78CmslrxB09/E0ucFRxXw5cYjD32i9unn1ubywKL2fPqXS2dfwbm4FAB/zOVBaxa2TM" +
            "Pd/5WFvkBwd7wBe8EhoV1fO6fEqx1tqhhGN36ASmBhzcKWJ5sWVffV7ZKEUSrDvs1MHphBeroQoICQHHzqeI48Pzv58WOWtcu30nDPOja+uJ1dzR0p0pKeoLCHjM0WR2o0GHMSf2ecSTO+o6T21gKo" +
            "swu5fBFC51rY+SJsfEAIV4Wpnl3FxDMnMvFtNYRHdo9sHnXUGKZfsh+v/fAFtC2eJD5JK1CC8CR1P92+j/4Ups51UEXfoAolEWS/WmTGVKid6Cw748dCdY7JTm9tyA8G1Ke1DfXTcFXdh8X4s4egEl" +
            "hY21D/ZGPdkl7Hn14J0O3nHyl2a+xjUlCtiWaoOyVSgpSVIZEImMB8rHGwnWDb3DzYduDR2zmAcIyU2cv834/4ule3IyfalPkLWiYAn8ZFnRWRiTLgU/MX7PzH0sVVA8p82xWTrmgxVvkf4IhCX1wC" +
            "BuwHjw23fv2cktKqUhnOOUCOBC6ruWL7lU1Xj+zX/e9ZjYTVJhMBmjSikhHtlbCC+Mq4GRUc+96plJR3H9I6d8Z49ubVNPx5DR1bOhGBsKRlU5bUsQkSDiYTGiZ0N5q2TMLC0yVbMylXmOAsPgnXmU" +
            "jaesSxJHFWJG312fHfDlpf2Mq2J5rZ7xOzqTyg+/vm+DMmsvOZTTTf09jN2iPS64Pb5XrsK1SH/mVXFSorMBe/G3PSkVBWqCAnzRcJ6nefTltRb3SYjT97EI4ELpvScMmVa+tu7HH86ZUAfeXM6iM+" +
            "/99dH3z7qgIkOVYFtUhpOaFJkwnvP5vwrDmEptTijRmLqayCSAliFGwnGt8B0Wa0fTW0voDuehHtaAS/DTfSDDEZUpCQXuI3lfwJeCpHR30fcOzQXsgehWNA5wHX5uJgVjkWl2NpWMAq+s5DQ217AP" +
            "lJ4GLU3IWL1OszQlbFBAQoafHJVi4iIEaegYPOrGHcjO4vyZ0tMZ769UpW3N2IRi0R093qQ0JvRBq5SUsoCKns0Mm/JdMC5EgOidToyWORRpoS9CiZNjGxXSL0Lu6z9V/r8bd1MOuKg6mcNSLjWrzy" +
            "EDXvmMbOpzYS3diWdIXlHKpD/4JlLXLUQZgzTshXLp4+Xjv5IkD9ZnSqHENhxx8lMGBCBs/fU3CxQe+il/GnRwI089rTw1HhE3+cWzbz4M0xO2OHb+xQXHpw83njJ1B67ImUnnQqkdlz8caMcRafPs" +
            "F3ZKj1OXTL39Bt/0I715EyTg8ZJqJ8PPbvcc+FT940KEH0/AUtU3C+zcJnbxu+8IAF8xe03L10cXXjYA404Us7I6CXATWFvihwRtADJ5r2r59T4u0h5Adc311Ws3Dn8qZFVX3Okh62ViySJD7pRUHT" +
            "61+ZQBw7ako5B5w8vtvQbH3l5Vtf57W7VmNi1pWbSC8tkWG90S7WHE3+0NLLS5C+jaQIE+mESLo+LSQ4RrBGFTFCuLqE8IgI8R0xYjuiwb6GXc818+bPXmT/rx1BSU0mF6k6aBQjjxrD5ntb6cezqL" +
            "8PriHwNWVp5NSJhSU/APkglA79+s1OXVEfwVl/cjn+KC4zdQsuW/92YHMw7QimFlydyzgQC+bgxlYPxxlKcC7VRI63UThN6kic3mwkLvItQmEJUw1wWW3Dxcsb627KOv70ZgE63lPetbbK408HlMnl" +
            "y1vx8nZvQMLV5U2oofzMcyk/6zzC0/dzIY79hgeRicjoicioM9G2V9CNt2E33Qkd64If2ZB9L+9G5XfAvwd5nHnAoUPV6D0YBwPzgWsGcxAxeiLw9kJfDLhRqzRM/LOnR/wpo8yepgU4H/QEXE2kPs" +
            "ERoK5kJWUNSpZ8UDdmzDhqNNUTuxstNi7fxOt3r8JEY4Qk3ZqUph9K08ykSkhkFiF17ixNkpiEMDqDBAXlK0i61Fwb0keahOsrVBVm/Pn7Mfb0WkJVEeI7o2z++xo2/XU1/q4YEhJ2Pr2BTX9exeRL" +
            "5zoLUeIYYcOoUyaz9cG12Giesj6oFiZ3QGiA0Vs5vXbyZQHqV5+KMtjxx+LIzHrgFeA1XJ6uVcBakB2gLQJtFvHX1N04oCzVtS9fLBjjgQ2jUoEjRCNxyWqn40LT9wumScFnQ/lFnw/S4/iTtSEzrz" +
            "01hDO9jUHhwWklcvLaTo5qipEXK5C1SEkJZSefTuVFFxOZPTd3bwLiIRV1yMyvI+MuwK69Dt1yL9gOhsiYMhr4UPQ/Yx+NvGXzgG6y+QtapgIXs2eZHwuJD85f0HLz0sXVawayc82Xd4RxmaZHFfpC" +
            "wAXFnLhfqONtdaES9rx7YBRwycQvtzy64Zq+hcWH1BcSVdYTlp/EckYIvBKp8Jh06Ei8cOZv2e/0efP+N4htaiViJMOVllFHS9MExMmK65CM9JKuVqI0K0/ShaUp4kPa0CWSYSFCwSvxmDh/FpPrD8" +
            "JEUs/EyjmjiFR5bPjdS+AraoWtD6xm7Fm1lE7LlI9UzB5JyeRK2le19PVu6N89UwgCpHnT3vSnEflsR5/7tLbh4oGOPztwJOe/wDLgZZA3Qbc11i3JeXZHgMa5NynOShTHlYTaHHz0TPJ6Xq6PIIwE" +
            "puCI0CG4vEgH4ohSPuvNjQIumdrw4UfX1P222/jTAxMzB+OiahBge4lw2+wy5myNUxHT3BoJrcUbP4GqD11KxbkXIGU9u59VoaVD2d5m2dZm6Yi5lpSGhVHlhpHlhupS6YE7CVJ1KN6sH2M3Hott/C" +
            "l0rh8qbdB5Ys0hpN0U/cQFuJuliL7hQODdwE8HtLfIYcBZhb6IBEpC+POPDGtpeI9xfXXF2SochhuYd4uwWklWWMdmuKwS1h8PwFqqR5cyZv8R3Y7R8sYOtj67kbD4aZXTtXs2ZUlbJ5oSOyesQ+li" +
            "54Srq4vwGRwJShAjcKHvCSSIkapSXjuG8efvl0F+AEyJx/h3zGTHQ6/T0bgTPEOsuZUdj6+ndNrszP4ZWULF7FG0vbYD8frMbfpDgoaeZBea+6Q3JEFYc4t+HFEOp3/jz3bgJlzalRVi2PLm7CVDVp" +
            "Nyd2icuyQKNAfTcuC22ob6UpxFaC4ume2JuHE7V2WY0nG2YA4jy/jTkynqQtIKaxqF/9aE+feUCOeu6kRzdXNYS3j/WYy8/EuUHH1c1k1UYc02nydWxXhydZSGDXE2tljao0rMd7+asCeURYQJ1Ya6" +
            "iSGOnhHh2Blhakd73cmQV46Z9BGkfH/s6/+Ltr40FCRoYtCn/SZA8xfsHAf6QYran/7AAB+ct6Bl6S2LqzcOYP8LGSZ5lqzCjLEmesJMryC6jBxhPPAe+kyAfBHtTliSwucEUcFSNSZM5cTuSYtbXt" +
            "1GrGlHIHrWLmLntOKikkq4mAotT2mOSBQkVRu4tRQTlGs3SdFzKlJVEMRIhhbILTrtT+n4EkomZE/ZFBpZSunUSqJrdqACtjPKrhease/cH1OSIkymLETZjKr+GMn75/PXnI3w/UAiCU+BEXzHeWhK" +
            "f/r0PfR9/NkJfFGVG9fMHT6kZ3dorFvSgXPHrQLuqW2orwJm4RIZngkcTe7SMfQ4/nQjQDOvPb2GwPqTjk5PuGNWGUdujDF+lx08CbKWyNyDGfmlrzmXVxeowkvr49z+dDv/eLmTxq0+0UCOlYy2SM" +
            "vcqbtgzVafp96Icct/25kyyuPMuSVceGQpB00OdxssZOTJmNk/w776JbRl+VCQoHNjD4+/NnxKc1P/dtOzcObCIvqHQwXOwNXO6TNqvtwyBTiv0I1PQBWOne7Fx1ZKrkoT+HGL+NZJaNIRMhDP3xB6" +
            "Xs3ClmubFlXvNkV9ROOBV8omCVBS95PQ/qAYUUZMLMN0cX9p3NL66mbCGktab1zGZJth/Um52Bz5SRKfIESeZNSZEqouoWRCFSWTqymbMpLQ6HK8SAj1LX5LB9GmFjrXbCe2sQV/yy5HiBIusGCwUl" +
            "VMtAPbGceUdeez6lt0VycSBN4Ygej6ncQ2t1EyOdMNFhlfhikPYdv93FsrCuGKKrj7i+5ZpwuA2ob6/o4/fxIrv2088MY9hvxkQ2Pdkp3A08DTtQ31v8RZg84Bzse5zAZr/T6vtqH+2q4lMrJZgE4i" +
            "S9puo/DKqBD3zizl4hfbBtcUawkfMJuRX/o6kdndM4Q377T8dlkbNz/ZzvrtqcHA64mjdCFEvoXVm31u+Hcb9zzXwbxjyrj4hHImVGceQCoPwRxwDXblZ4bCElSHM/P1OTv0vI/tLEd1HoP/8vdFhI" +
            "GL5i9ouatf2aGFt+DeRIYFQh7+UdM8Sz9FlF2g29q089HX/fhTjX589WYbbunQMquZVkUB1my39N2r0i/MxqXyX7q7DcPqi2TT/3T9W5TK8aXJjMsJ2Lilc+02wsTSdDyZFiUyjuv+FtFkqQmsIgZK" +
            "JlQx8sT9qDqqlvI5EwiPLkeM6U46VPF3RelcvZldz6ylddlrdLyy0THKIAu0AvF1m2l/fh0Vx07vdt1tLzfT+eYWRKw7vhHiW3YR39HZjQCFx5TilYWw7XH6wID6awHKyw2w23Pm87S+hdZd6JZtsG" +
            "4j+uY66IwiZ5yITJuc3pA8XX+fu78/448P/O3NA2/MT8mlAqGxbkkbzlrz39qG+l8ApwHvB06lfwk905F1/MkgQDN++lYP9Fx6ECVZgXtmlnLCuiizt8YHJogOND8jL/9SVvLz1BsxFt3XyrLXo1gd" +
            "eGXqxH7rd1h++o9dPLEqxhXnVnL09Mw3L6k8FDPzW/grL4foevLoaSoBzo39Z8Jd4bds7JMYWlSPwJGmIgaGk4CjgIf7svGEL7eEgLMpUBhwVyhQERY9YJwZDAHWf74Sb73m71Hz4jq/rDPeO5ESGV" +
            "Q1+N4QBs6esHDnbRsXVfm9bxjPSoAMNnOdUUpHhLo/W6xit7QQlpgLfZegRlYW0pMiU2n1tFQJjyln1Ol1jD7vYEqnj0HCu+GfIniVJZQfPJnygycz8uw6Wh95lZZ7nqVz9WZAUE+w21rZ/NvHkbIw" +
            "ZXMnIiGDxi1tL26g+cYnsS3tjmCpO6bf2oHd1T2CN1QZxpSYVM7XIlLwLexqyyA72rge1jWhm7fDrjaIxyEwg8ql81L75o2E7Z5VTV1RH0L7Nf7EcPqfvRaNdUuagVumrrjkL6J6Ii4VzDm4cPv+IA" +
            "ycXdtwyW2NaRFvGQRIjNbgBElZYRSaKgx3HlDK55/aRdj2825RRUpKqPrQpZQc1T2f3wMvdfKNu3eyerOPZ3IzECeO8ehrUS7/4w6uekcVZx+Uye9k1MmY2s9gV33DZZLOnwbwOKzWALt1A3zgI5vF" +
            "d37LYRGJtIdiBE5A3icCJCKTQY8vdKMTUIWR5dI5oXrAjzh9cGW89TO3dkSad2qJZ3qxog4NThB0CrspyhnBD9xAKdJjyNT+iIAnUFKVxZUUiyPtbYSJujpc6ftKWhh918rpAfkpm1PD+A+fRNVx++" +
            "+e+PSA8PhqRr37SCoOm8rWPzxG639ecWHronS8tIam791H2eFTCY2uJLa5jV3PrCe6YWca+cH91xnFtnd/wffKQ5hIEJLft/Fq+FuABsI+rIVd7eiW7bBhI/rGOvSNtQHZ2Qa72iEWS/VpIl9BMOnO" +
            "XWSyyMK5wESZDPRn/CnFhZkPCtNWXBJR1QiOD4SD44ZRQkiSI1gSlVygA4gGyzGDdL4xwDD6vmLNnBvbgL/XNtT/B6cT+iTwNvqXYPIEuow/XV1gh+2uQ0Xh4aklnLI2ygnrov2zAqlSdvLpVJx3Qb" +
            "eP/vZSJ1+5o4UNO2xeBmnPwJtbfL5yZwtQ3Y0EmQnz0R1PoM135vOVagauj3dLgHwvMoVhFIm0B+Os+QtapvYtJF4PA2oL3eB0jChDqksHdj9u2aWd1zzQ6SXIzzBALS6XVa8EKEwsRUrEBuHpQWkM" +
            "SViBbFBYtPuF2c44IRslYmLJyugi6cVCM7U/qXMJFUfOZPwnzqRkvwk5ueDIzPGM/+xZhGuq2f6n5Y7MiCG2YSvRddtADGoFNQYxHqhNhIw5l7yC7ehOgCRigkpANj04vycMfxtRX1xg6WRn/Ua0cR" +
            "36xroU2WltC8iOpkgOuKKq2U9Kt5MmVhWmxw6j/+PPe2sbLr61se6mTb1tNPXlS0IIIwWdQCpHz2RggqqOx71oV+HqaJUCHoIhlQTdpk0xXLLEXcAOi26pbajfjIvyWgusATYCm4CWXIbgB+LpB2ob" +
            "6pfhglW+Dszs4+7dxp+uBOh4dsOoBNgZEW6bVcaBm2NUR/sYFq8uyWHlRRcjpZmh7k+9EeOqu3eyYYfNl/kdcNagph2Wb/55J2MrDUelu8O8csyU/8FveQI615EnV1hZ0Md/7cO2JwH756839hkkIg" +
            "v6IoY+gfzmpOgXVKEkJKHQAEU5D78aj7+43pYNE/IDrm9PAP7c20Zh4o7gSMLaoylBtKTcYUYEL9L94jQWJ0QUJBaEp3clO5auVdRRpeLI/Rn7mXOITBnT60VoZxSN+YGlQJCQQSLhHs1rpqqUUR86" +
            "CfEM2257AtvhI8agxoXGE5S0UPWTpAcxCNbZwWLdX65N2CCeuxZEUE1lMOoBw9sClA3RGLqh2ZGdN9Y53U6C7Ozc1Z3spE99uZ6spCtgQIXpgoGMP28B+U5tQ/03G+uWrE+snPryJSUiOgU4CDgYdC" +
            "4wB5iAIzul5IfmWZyFaDuwBXiztqH+JeAloAHkDVW2rpk7ONF2Y92SVmBJbUP9RlwKgL6Ez3cbf5IEaOa1p5fTx2gjo/DM+DD/rC3hna929DkirPzMc7tFfDW3WK6+rzXp9so3jDiB9NX3tXLdB0Yw" +
            "Pk0YLVWHYMa/B7smJ6WkesJhsYcnlIdP2dijknz+x1pDqD2PYaJF2cMRAs6d/9HWW5b+ujLe00Y1C3dWBhagYYWQITTAUcp/6k0/HvPxhhEBAji8ZmFLZdOi6taeNggTQyQgQJpJgEwaiTEihLIQIA" +
            "ICJCaaJEAmw/KTyvYM7hwlsyYx5uNn9Uh+NBYnvmo90Rdep/PlN4hv2Iq2RSEcwhs7kvB+kyg5dD8ic2ox1d0D9kxpmJHzj8ff1krLvc8Gz+S0SmKB5idlfVBQ46rKR7vfthJyFiBc0RAQ2xsJ6m8i" +
            "xLzeAD2fM+28O3dhFy/FPvkctO6CaDwgO/RMdvrb7mybFygKrLahvhJnAeovDLAAOKK2of5enHehBvQoHPmZxNC+1BmgPJgm4TLzvx3nPtsBulqE52sb6p8EngBeDcjMgKDwN4G7gUv7uMvhtQ31lY" +
            "lzpluAJuOU0n1CzIM7Dyjj6A0xJrf6vbvCAutP+Vlvz7hhVeGmx9p47PXokGoTPAOPvR7lpsfa+OLbKtOaJMj4C6H5TuhcS56sQLNBJ+FSk/fQX3YGzgJURG5wPMZOp7c+RycDBxS6oV0hMrCbMOYj" +
            "a7bpcIwe3B831qzsaYOwiQUuL4sxgcUmzXKTIDPG0IMFKEaITozpTBYMlYA8QVc3mMWrKmfk+08jsv+krO2Jr22m/Z7/0LHsefzm7cGzOpUOMd7YROfTK9l17xNEDp5J5QUnUnr4/t1EjKY8wsh5xx" +
            "NdvZGOl9aBeCCKqHEvkZqWOChYVlU0loUAhY3bHQtiQXNIgoZBFJiuXoP91+PQ0ZklxXaO2tiN7Gg+S2HsDoMZfwQX7HFUIRreR3i4qgijcZXa63EuspdqG+ofAf4BPNdYt2RHfw66pm6JDdxhfa2T" +
            "mTH+mC4f9Dn5m1FYNcLjL/uV4u/up2UtpcecQHjGfhmrX1wfY+mT7fRXS50LWIWlT7Tz4rpM/7qUz8KMOjWfP4Lx7N61dRzuSyoiN6jFmT57w/7kJwtpQeArprWzAFW9d49xuHT4PSIiUcISJWxihC" +
            "VKRGJEjNP0RCRK2ESJSCcRE8NksY+JHyeC2y5sOomYTsJeZ3I5klj2OgmbKJWnHETp8Qd1b4gq0WdXsPMHN9J+90PYjZudJsloMNm0SdFdu+h87AW2/egWWv+8DO3srt0JTxnNiHcfg1cZQfBTOids" +
            "ap62bEQh7nezVohnXBuSbkKbcud1x/DXAHVFR6eL5spriJv2cd2QYK8af/oAwT0LT8PpeP4M3F3bUP+F2ob6udNevrg/0QfxfmybMf50JUD9S7YmcP+MEhrGhDA93jeKlJVTetKpGWI0Vbj9qQ7Wb8" +
            "+v7qcnGHEh8rc/3ZHJdcRDxpwFXjl5+jFU0AsBeu9Ht3vA6Qxtwbi9HR5w2vxLW3p7Q5hDf+//4YwglU2hm5EFFbi+7hFhiQVT1M1NghClSE1iOdsDX9QGZCdKJNjOkaBokgiFvSgh6SQyvoKyM49D" +
            "wt1/brHnV7LrupuJv7LKueQ8RcTH4Lu5OOJhsO5vYxEDdvM2Wm66j11/fRyNd9fvlB97AGUHTw0Ijp8iMGmTCdaBn/1lLBm273cnUJJVXtE/C1Ahpm7j7VCdN/OUQ3Ke7ti7xp/+YwRwCvBD4H4Vua" +
            "62of7kqS9f0hf33RH03V2TMf6k7zSX/lesZVO54Y5ZZXSEJPsvzCqhSZO7aX/WbPX5R0Ne6rP1C4ks0xnXVXkoUjotn0Xx5vb4oTETgWP7frgBoxNXKXgFLh15v0yPg8SO4JwrgjYMxY1wNEJNL5/P" +
            "plhuZChg2I2rPZwkLdEuywGpkZRlx2QjQFhCJkrY6wjITmeSOIVMDM/E8CSGIU7kiDq8/boH3vhNm2j73Z+wa9Y6C4/4gcUmjaikW2uS5MNHjMtD07r0QTqebOjeARUlVJ5xECbigmvcvmnHxg+0PS" +
            "kheDa482o38pNoV7du6SsKRYB0qNvR9Xx5PmfvGA7jTyLUPYqL8GpNmzpwlhaf/JvJpgIfA+4S0RtrG+pPm7qiPqsetvbl+mOBd/Xj2BnjT/prz/SBtFQUHp0c4fGJYU5dE+0uiFYlfMBsvDGZ4sIn" +
            "VsdYs9UviPUn2RPi6ow9uTrGtDFp3C8yHioPgl0NAz9475jey2cHAtPyeNktwD24jNQv4mrJhHA33VuB+fRC0AaJBuBm4EFcqGQcF3p5EK546dvpf4KrvmJGcJ71PXyezz4vIhO99nXERDPdQAkikC" +
            "QFLkeQZyS7BQhLyIuiJppM7t59WFKkoozw4XNdBFc64j7Rvz2MXflaIKIOQs2D0haKICqoCIKgGszF6W9EBTWC3b6dXX/6NyVzp2NGVmacomT2ZCK1Y+h8bWOmviWIAEuEw7vnZnYLEJKKAnOaIRvM" +
            "E5FMyvA0AvYBQ6LDGVYusKEaf1pxL6AbcSHriSKlG4Ftwee7cC+l6Sw6kR+oHJeNeVzaNBEneB6DG79z5XofBVwEnCXKbbUN9TeAvtRYd1Nn7cv1FQgnAd8ZQN8lt08nQAPyPwqwKyzcPruMQzbFGd" +
            "XRpU6YEcKz6nAhCw6q8OTqKNF4wROzEY27tlx4ZGnK3SweUnkQ2nx7vk7bW18fQ/5MoSuAr4nyl5t/Vd01vewaYNn8BS1/BK4EPkzu3HBx4I/Ad5Yurn61y2cbgFfmf7zlHiznAN8jPwSsHGdZe6CH" +
            "z2v6cawiBode+zocECCTZtUwib/TLR6BDqYrBMWTOFZ6zs0mKGZkBaHZ3eVI/oaNxB95AmwMCRiUJILpNci5I8Fc05cVwaCSWh9fuZqOx16k/JzM/LLe+BGUHFBD9NX1gVg6LQJM1QmkNZAHqCN86T" +
            "RORILcRhbSosAcWQsOIzhxdH9J0HCpBZbviKzeXGBDj9wknsqEjyM3rwIvA88Br+CIzxagdbA5eqaurBexlONcS2NxesvZuBf52Ti5x1gGV85pNPBx4B0gy2sb6rfgNLJHAiMHcLzk+DNoAgROEP3C" +
            "2DB/n1bC+1a2Z3wmkRJCUzJNzC0dSsOG/uiW8ouGDXFaOpQRZWkDTOkMkBLQvJRZydrX8y5tKcURoHxgJfDRpYurl/W20dLF1a/Pu3TnZ0S0FfgUgzfLKrAYuGLp4uqWHs/7y+oocPf8BS0bgN/gfk" +
            "C5xpHzFrSU3LK4OtuPfmQezldEdvSa3TxsOpMaGBe9FbiWxIXCk9DIGK8H0a9zIxnxexHRKt6EMZhR3Q2OfsMraPNGjHHEIxHtlbL6pFuBTNIK5M6lQUSWICJoRzvRZ1dSdsphSHkqxZqEQ4SnjsVE" +
            "BPV9kmXnkxYg31mUerIAkdAAJaLA3A/VihuPrYAE1qAg5H74R4ExxGREe1hZGAKUq4z/Fmdp/zfwOLAceDMoNppzrJm9RHEWo104svUycD/A1Ib6anGWoYNwgT3H42piDvRaJ5KbQtXJ86cToKoBHC" +
            "iJuIG7DyjluA1RprUEYfGqSGkZ3ujMqvbb2ywbW+ywqGEjAhtbLNvbLCPK0t1gE5wQOr6dPARRZO1rcRqVun4eqy/YAVy5O/KTwC2/qmqd/7GWb6EcgKu7Mhg8CHLV0sVVLX3ZeOni6ifnL2j5Ci65" +
            "Va7LgMwVYQLQmOWzfLneiuiOXgsaRkxnhq4mqYMJQtdToew9HEDTwsN7/Okq3sRx4HUxclqLXflKYP1xlpxEwYkMqw/phCexbJIuKEeKDBjw31iH3d6KV56ZYzZUMxJTGnK1vpLkx3mwbJobTHoSQS" +
            "ctQDZon9tXRdw+ATEK3mGGwWjbC7JpoBNh6XlreQ8WoMIgF+NPHPgFwjWNc5b0IfN9frGmbkkLTnKxAri9tqF+JE6AfBJwJi5sf3QBmpYcf9Lf7geVLMkoNFZ73L1/KfG0o0okgqnKfN5v22Vpiw4P" +
            "77QA7VFlW1sX0WCoGkwJefpF9NTXM8iPK+ZORf7Snx2W3lC9BfgBzi88ULQAP1y6uKq5PzsJci9wSx76YRLaYwh2f2rKDArqIrT6NA3mZbQ/5xnsufqJXvs65EUJmRghieGZOEbiXaKv/KRFKDsJSo" +
            "mWE64zN/nBFLjTqiu7FxxURTdtxBBPRnelztVF9Nzlb0O27RS7dRva3tGtlaaqDBOWbgLmpIUrKYDOIoIWSVrISG7bNSw+LTRe+pqulmESAUZq/VAKkwsngs5FssJ/Al8fDuQnGxrrlmxvrFvyeGPd" +
            "kh/iNJ/nAVcBT+GE10OF5PiT/vqTk2yRf59ewlvWRjm8OebeSzwPiWS6/9pjStzX4fFOIhDzlY5o5g0qptT54fODnvr6IJwvNZdoAX57y+Kq/vvyRB5D9V/0T2Wfjv8EU79w8+Iqf/6Clt8D88itFa" +
            "gCZ2H7Z5bPhiTtgBF0TKVoJCRmd0VkfAvjq2RAllIRt++UUdInnZ0gxHy1W3ap+Dbvv8xeM5y70PCUpSfd8kNaEkPws44hKdeQ76w4WaDi3FDZyiZIZ0cQiZXS/jiDduDWSri/SPydsPwEzjENdEAo" +
            "YCDaGbi5urQz7CVF1k7IbJOWIE26spL2p2xXEexrMvZNEwAF2iDo1100HFxgiSitfLvAMo6fRriGHrnI+n9vY92S7YVofH/RWLdkF85F93htQ/31uHxA84FTyb8cIdnXOR30RWFrqeH22aXM3handC" +
            "g53R6Oiz7eImrzont5CSd+6zeW3lDVMX9By9+BdzIwuvrA0sXVbQPYD+AFXJTaW3LcHz0JrPNOx1Whqkw6fz6/NHrAeK/a7qYajqKUhITIAHh4xIOr31lKZzzx+O4dxkDDBj/68Zs7TEuHRgr5bpIM" +
            "4053eaVlcSbh/kqSjCzXIxYV2+M2oiCxzkBwnHa1Ikhp2LmWkpFZgQYonfxkuMMUEZMSSUtqH1CkxEOysdBYHFE/lbcnWQeMlGetF8ONBATH9VVwmZIIHUtFkYmICwgbzujRBaYM6A2gzyftoR3D4e" +
            "W8/xfTJ5nBcENj3ZJm4JZpDfV/VqcT+ihOepFrCUQ3pBOgTnIQfSQKT0yM8MjkCG9b3Q6+j3ZmMqGysBDyEr/OfF/ibqAQ9oTSLkO+2g5Qnzw1sBs1VEslu8mQO0C8tHRx9WDcWM/jQiP7qxHbxQCJ" +
            "F8DSxdUt8xe0vETuCdDs+Ze2VC79VbdaVDGGoGaOEXTiCKM11X25rwZ+74nA2MrdVgnPQEMTfnt0SMhPr9ZISbcA9UKCkhFTWa49lU+nF6HQzh2uwnh6tXARzPixqFEQP7D6EAihTYpkYLoQocDaky" +
            "AgQUg8Ct6YaqS8+62lO3dBPJbVApROaLIKvVVTLrD08Hd1ZEqDdkiwTnpIEZ21ZwpiAdFufyXbka/2qHa3rqmihSmGGqOfefi6QIAjZ6y+6MbVM27utfVTGy4OiZgKVMfiAnLG4rIyj8WN8xU4N1Hi" +
            "h6FkVoDfiitjsTlt2g6mo7HuNwMucvpm3ZJ24KHahosfATkBF4RzLrkLq0/vayAfBAhoDwl3zCrj8I1RxndGsa2ZxHRUhaE8ImzdNSz4D2URYVR5lze0eAvYvOXn68iybjQuF0+usXaQ+2/FvVn0lw" +
            "DtwP1IBoP1g9w/G6YiMhpH6tLRwRAVDSyMhX33aNyq0ZilbAh+kx29fShpmhaw3dxgiWd5mjy56wEQcckEU0yiKxQ2rgffh1DaMGgMZvYs7EN/d+RIggOmzCndljNcXiokkw+p2y40YxJmZHfdt9+8" +
            "BTo73OZKMvQ9gwQlosOyQbuGwZPmhutqFerHI304uMAS6/IeBp/+d/BfYX6gnQxeh/gev6PkfiBD7zm14ZJyQWtxAuSDgANRnYkjP2NwBMOj7xG/gf+ZOG6c3wpsBPtabUN9Ay4K7VVgXaMjNf1CY9" +
            "1NUeBf0xrq/6suN9xncVFkuUJy/EknQDvJkcnJKDSMCfG3GaV84NV2/C2bMz4fWW6YUG1Ys9UvOANShQnVhpFdCVB0I/ht5KmB2UISp+JuxlyjY5D7x+lfrZUEYuzmTb8PyIcTdSSuGG3XSLAW9u1I" +
            "MPvaJlvqW0wo/7m5ejXVmyB/jwQJD7NZgJywV3p8WCU0QOkWoEwqZKF5Pbp9KzJhYub559RhJoxDN6x3rq1kokOS0V0Jd1gq8aDTAbn1BO0SpKyE8CFzkLLMZ5vG4vhrNiDxKJhwYL3x00iQJK05WY" +
            "1YSQtQ4OpzOh+Sgulk3yjqLEzDlHanrqfHzMz5coH1wIvz63brETsY/PgzAfhFbUP98cAynNblMNDjca7/seTmJU9w3CGEI20TcNrKU4PP23Eh8StrG+qfCtryvKiuf3PuTX5fT/Km0wndUttQ/yjw" +
            "U5xwOhdIVj1IJ0CbcEmMcgJf4M/7l3H8uu2MXJP5rKkuFeomhnjqjbzk2Ok36iaGqC7t4gLrWA3aSZ6yk2ezjExmkKkIekDlIPcvZWBvJgPdLx356I8RwJQs67eRHwvcHgGrxNdtt1HJvbk5G3p1yQ" +
            "pWERXp5vZKRH0lVNo+2SOkEuSpuwss9ZdCy1ZY+TJ0IUAycSLmxJOwf7oVrJ9m9UmEvwfmmQwipEmy5NiIAQveAdMIH3No9/5u3kr89cbAUxaEqwf5fxwJCuaBFqobggd1giS6bWyaxSfQACHZw+h7" +
            "w3AwUaZbhPLWnmzWnnyfs0dsIzfP30nAV3AvvobBJSAcKMpw2ZanAW/DEaJGFXm8tqH+XmAZyrrGuUv61MmNdUvW1jbUfwenD5rYl312g+2JhfSn+2DdFRkwCusqDX/av5S211c6U3MAEThmRoTIMC" +
            "j3GQm5tmSMk+qjrS/k80eQra+nkptIgK6YftFHdw6GxU1kN3lbekA1g7hZL7x0pyE/6eEjZC9F0pSHc+0xaO1Qs2abRoboxbfXvs4MC0+EoQfFR/EzEiNm/Y0KqdB30qb0v0Ux7Tvh+acg2sXQ6IXw" +
            "zjgbU1eHaDyZkdp0C38P2tb1M1FEfbzRVZS+82zM6JHdmhh/dTV27fpkFFjqmJo5T5K+bsU80sLcM0PeXei8praRHkLpe0KhaoF1a8cQtMXzMklyPs85iN/EAFBKYchPNpThskJfDPweeADhJ7UN9W" +
            "+pbbi4r7KbV3D5hHKBZF+nPxjfyPVVi8JDtSU81bIa7eIGO2ZGmKmjPGwBXzaswtRRHsfM6MI7os3Q+hJ59M+9kWXdNPJjbjpEjY4fxP5HMzCrQBmDyGodEh0HHJyH/jA4a1tXvJmHc+0xaOnUzs2t" +
            "Nm95H7qg176WRJ4eSat0nrUIafa6jEkRdHLyEeNnzsV35OOF/8LqV7o3YkIN5gOXYKZNQzSelg/I7yHfT4KsWUeaKkopufB8Qscc0e3Q2tZO9J+PI7EoWQuZZsyzB4okaoQltkknQqSTolR+oGFg1u" +
            "kFWUlCnvQ4qknxu8yc2v2zwvTUvjL+hHHusk8Dd4MsrW2ov7D25fre3X+qhsGJxNPxRmIh/YHbgLMp5wwCbC/zWFq1lW2rV2Z8Vjva44y5Q6I57RVnzC1h6ujMftXW59CON/PlB/Zxfd0Vk/t7oD5i" +
            "FnDiQHact6BlFHDWIM59zvwFLQPN9HkCu6kaPghMyrJuBf16Td670LRDaekYEumDZTdvcglyY0hYXhKWFr8LEbFO7NvtAOKGSk8DpYKAlzaF0qbtzfDwfRDrLjeT2QdiPv5ppG6uI2QaT5XoSCdC+K" +
            "nJxjBjRxP54HzC57zNWRi6IPbks8RfXpnM5NwbCaKnZI+asvSkrDwJrVSK/JDcph9MYjhYfxLtyEV7rIW4D/G4W45EkInjMReegznjpK4nJUm8htYC9Ar73vgzCjgf+C3CHbUN9fNqV1ycPQ+eyMHk" +
            "pkqCxfU1kKkBehUX5pZT3YVReGJEjAfefIz5R52YHBBE4MIjS7nn+Q7Wb7dDXhXeKkwaabjwyNLMc6uPbvmbE0DnJxHiLlxfd0W+UoKXAh+Zv2Dn3/tajiIBcZk6B1Ob7CjgHcCS/uw0f0FLFXAJ+c" +
            "vOnK3w4Cu4+3+wmqk9Emu2WdqjGh6Cn2EbaQNQNohYTT3AM8tgpELg1VmA/Cz6/FAIwsYRnN3ZVK3A0/+GQ46C407r2hCoOwRz+RXo3++Bxx6GjU0pLRAJoXIQ8l5RhTnwEELnvR1z8MGZ4fWJ061r" +
            "IvqXv0FbK2I8UlXc6RYC7zI4WSQk3a1AvgVNiKA1RYgSOYhEUbVOGC1W3Qt0H1GwKLCu6wbZFt9CyINRI5CJ45HpU5D9pyMzpsKUiciEMd0J6mDPOXCswD0b8qF77A8UF7wSh4w05AkLTIjcSzXKgL" +
            "cCJ6Byf21D/c8EffTNuptiALUN9QcC32IQ9UrTsIu0F7B0AvQaTrmd0y9AgM6Q8PutT3PSxtVMmbR/8rODJoeZf0wZP/n7rhz35+5hBOYfU8ZBkzO/S21bid32z3y+Cjfj+ror8pn06QzQjwI/7usO" +
            "8xe0zAK+yOCiBiLAF+YvaHli6eLqhn7sV8/gLE+7w8gs617BfTf7IgHSNdu001fKh+BFJFGdukc4S08W4iOpOSaw8sSzBFKEwxBKEKDdXJAKtLfAX/8AE6fAtAO6b1MzCXn/R5ETTkFfeg55pQFtWo" +
            "+2tSOhCIwZDzP2Rw46BDNrNlRmH0K1rZ3onX/Gf+U1jDFYdSRO1RV1VQ2uTRPX6siVhLuLJTXug/XTrDwkI780yAuU6Ct1Yunh7wLrmgl6oIkQrYWyUuTwAzEnHY0cPAepGQsV5bs51iDOudvr2+0W" +
            "r+Hy6eSbAEVxKUA2AxtxepgmnC51E04g3B5M6RHAHu6FtCRo4xhc7qDJwVQTTFUMXHtUhqs6cLIiD9U21L8cnOMM4IABHrMrNgGvJ/5I/bJE1qG6kjwk4zMIDbHN3Prq3/ncxP2S6elF4OLjy3liVY" +
            "xHXo32KWV/LuBbOOmACBcfX97lPld04+3QuZ48RX+Bq8qeLb/NYEMge0MEuHL+gpZNGPnD0l9W9fpznL+gZRrw/4BD+3T03nEQ8OP5C1r+Z+ni6lW723j+gpZ5wNfIr4CvO8kR1qO8DszM43mHK/S1" +
            "TbbMKjIEBOg1dpPfyQSiXZFsxAdHagTnzopnyZQQDgcWIFIEKMPKm76sgIF1r8Gt18OHPgc1WYIBPQ/2m43sNxs6O5F4LLD+SGBximR1dyXR0UHsjj8Rf/g/GHxHbQSsGoxYbOKZm8USJNmiReI+Yv" +
            "0gE3SK6CAaRH2lQumFfobAF8QCRHeSMJBEiNYi+03DfHQe5oQjobSf72+JUw19H6zDvRjMyOExozii8wZOdrESWAWsBpoFWgTZ9UbdjQOWvsx84RKJh7QM9/yqwfGHQ3DW/zqc3KC/Y/kY4L057Id0" +
            "vIrrayCNAK361INtM689/Vlc5sWcwwJ3rPonZ9adzsHjU9KO8dWGK86p5PJtO3hji593V5hVmDHW44pzKhlfnUly/J3Poc13khp98oJnw6c0ZysPMegklLvBWOCnWJ0xf0HLr5Yurt7QdYN5H9sRFp" +
            "WTgW+Q2wzMZwG/m7+g5Vsg/1q6uKpbhsn5C1rGAx8BvhC0NZ/oRoCarq5urVnYshxXpXifQtQntmGHjQ1RCPzTTYu6ZeHOQELcnFbI07EFI0lvE0bc6OVnsQCFIt1dYBmRPumWBpetGSPw2nPwx5/C" +
            "hR+H2l5eOEtK3NRXtLYSu+NO4vc+4CLOxGBIkR7tRn4S+XyCyvLh7sTKWYBSmaBdxupE9XdJEaJAE6TaDxJUqEzQJZFuq/pNfmbNwPv6p5FZA3yPyXfyxR7QWLektbah/hlc2PhgEQf+jIu4agA2qN" +
            "ida+b8Nucao1UH36g4t3YbsAF4Brh9WsMlZeryrR2Oq/N1Ek6POmRFp3vAM411S5LjT9dXi8dw+QNy3kgjwvrWTfzqmdu4+q1fpCyUOsVR08NcdUEVX7mjhQ078qcHsgo1IwzfeEcVR03PdH3F4m10" +
            "Nl5Paee6VCbX3KMD18fZMBQ3xmhc9d0L5i9o+TPwX5xJsBSYhXImjgDkIyHjCcBS0AfmL2h5APc20oEjO0fhMn4eRe6U/r2hJ7L5OC4ja17V+f19sR2oNb4vxxeBbW1q1u0YkhD4Tlwf994mlwfIkZ" +
            "+ExceQaf1JKBJiWbK1l0RcfoseLUBdw57TOuyVp+F3P4BzPgiHHA+hwckd9I1VxG+/nfgT/4VoHAl0hdqjxSfQBJEocCqY0u5t0Gg86QLTgOQk6pJlaoKEwAfWj0YPIQFIiJTHjEIOmNH9s/60pbIC" +
            "7+MfGAT5Cf4rXMDcMnIz/twDXNpYt2RboS7kzbob23GuptenvlJ/h1iZgOrxONHzW8lhzsF+oJMuz9+uBOhZnHksF2rrbhAxPLDqEY6adDAfOviCjM/OOrAEqOaqu3eyerOfc3eYb53l56p3VHHWQZ" +
            "n3lwU2rL2DsVvuy3cYzGpcH2fDUDFjAxwZTB04wZsJzp9v8jESeB9wIc7HbHGCuqF+K+gpA9UzuAzRufI3Z0AEWjs18tU/d4RGlMluZQHWwuwJhi+cUUK4n99MzIcf/aOTlRttNi1uqk1Aayfe+u02" +
            "NATurzfp+f5P6yd10RNdiU+25Y4sxiQvDJXlsE1ShKkrNH0ehD5rkOxw/Wuw9CfwyrNw4jkwcXr/idDmZuzjy/D//jds4xoEk0psmBQ+p88T2hObbJsCUhJByrLUEWvvhFgssxYYFhVJRcaJoKms0o" +
            "XXAKVHRIlAJALVlciUiZh3nYUc2PVn148m+z7mqEOQYw4bVPsK3E3PMfjxJw7cVkjy0xVrZi1RnM7oT9MaPvxnxczCaX3ei3OXDZH4hUa61KfMeBBY1Q1G5HHyRYCAjngn1z31B2aOnMqJUzNzZJx1" +
            "YAljKwxX39fKstejWN29hnF3SBzjxP0jfOXcym6WH4CX1z9J5M1rKZF2NL/fxWNojwmvhuomSEcusjUPBAZXcK9Q6IFOyDrQx8kTAQKI+XgPv+p72gcva9yHE/fz+Ozp9JsA+RYeed3n0dd9Qr3t69" +
            "oxFOUvAB6XNP97j/DSyI/XA/ERcSSpvQW6uqw9D0aOgabXUqu75xFMzRMWoYQ1yALt2+GRu+HFZXDQ8TDnSKidBSPGuOiuri9KaqFtFzSuRl96Hvvfx9FVq5xWR0Jp5Mb0MO9yuIDImKqyrIVUbWs7" +
            "Go0mI+U0oZUKdEkpK1DCj9SPB3uuLSAJ0lNR7qKxZkxF9p8O+09Dpk5Cxo9xAuVu+/SjLcYgxxwKkUFY7OK+S9hbMAuQrgN5jMGNP4korj5jSsMlxqARIIJoCSplpBIpJm70uDuudIDuAqKKRNfU3d" +
            "ivc71Z99tEGpiGaQ31S9SVt7gEOIz8PwMfRTJrY2YQoDc+/U9/5rWn3wu8nzy5AYwYmlo38d1HruOaMxZy0LjM7/rI6WF+/sER/HZZGzc/2c767TbYr3/nSRD5SSMM844p4+ITyplQ3b1/n29+lede" +
            "vJr3RN5A8+f6Amd+uy98anNOcy0VMSBkpQRNi6riNQtb7gXmk5+s3O7kfbzNpB/b9nSesDe4Y+QQMeDeDYuqd3//e13JTxrx8dJcYKLQsql71I4XggmT4TUJsiJmOYdmmSceulZS2qCWZnjkLnjqQR" +
            "g5HsZMhHGToWoUhEpcbpnWFhcev24NbG6GrducFwvPkaWsVd67zgP3laYRGRXM6CpMdXfNvr+tFTo6ghIY3V1g6UJoVYuIGfqnekB8ZHINcurxmJOOQmbWwoiq3gXj6V9SXyKy1OmHZNKEPhyzF+xs" +
            "hfbBlk7s+VJ2h8a6m+K1DfX3Axcx8PEnDLy9tuHivzTW3ZRxMVMbLokIOgKXBmQqzg1Vi9PquMKoKiNwxCeC4weJzg+Kn2oMF0W2TdCNtQ31a3Ei61eANxXWr0nT2PSGN+uWrAf+b1pD/Z0KHwI+Rv" +
            "6CUKLA/Y1zlmSMP9lcAY/g4uRzEQGUFUYMDZtf52v//DHfOfWzHDR+Vsbn46sMX3hbJWcfVMrtT7fz95c7WbPVJxoE5CXHtMRX0+VlIRKCaaM8zpxbwoVHlnLQ5HDW39Dzza+yeNkiPlH2X0qN5DsL" +
            "1Yqgb4soPHobjh7B/ZgPLHQj9zK8gvJon7b0RJO1qRPh7hkusOBvLGxvcqHw4bT3NePB5P2dEBp2Q4ACFqKaIj02WG8J6nMpRFthw05Y97rb3koqS4pvIWYhngg/T1iIbOb5eiI/iCtYSpouKFgXmj" +
            "gGM6Z7gKjdtA1t73DWpYAo9G4F6mcpjMEiKDNhzjwJ85F5LvfOQI7Rl/YkiOsg3QW6ek2KABXOCvQfkJW46NmB4n0grbUN9X/ASQ32Aw4GPRgXZVaDS7uSbuEZVKNxcorNAqtqG+qX47R+TyM0Ns5Z" +
            "0quVKCBCi2ob6u8BvgrMI/fWoFfI8vztRoBWXf5QU2AFyhsBAkeCntvYwJcevIavnXQZJ049MuNzEThocogDJ1XxkZNcqPyTq6M0bIizscXSHlVivrtJw55QFhEmVBvqJoY4ekaEY2eEqR3t9fjy8O" +
            "ia5Xzvkes4N7yMOWXRoUjBeW/4lObe6r3EGRoBcBG9VJlvWlS9tmZhy18pEqBc456ma6rX9mnLEJoiPtBtOUGCMNC2DbY1wfhpmceYuB+MrYFtG4IHY1eXVeLhKqnIqUQyZaOO4BicKdlKqg1+ghil" +
            "R5Lh8g4Zce/JvjoLUHqW6mxC56TFxibrq5IspmoxJRHCc/dDurh1tD1KvHFjKjWAWpc0MasVSEFUCxEFZs47He/zl3Z3b/W5Hf1oSzSKNm0a+NM8FkefeMa5wQpoMm2su2ltUDB0MASoFPgfnFUljp" +
            "Mb5DOtiOAiSKcG0yk4i+9alP/WNtT/Ffh3xIu++dqsP/b4hTbWLXlpWkP959SVhTohx238a2Pdkm7u957EoLfjktHlovJqjzBiWLH5db70j0VcduT7eU/d2ZSHMyUpIq5sRu1ojwuPLKWlQ9neZtnW" +
            "5kgQQFlEGFVuGFluqC6VXi2m7fEO7mh4gGuf+gOT7Bu8Z8aOfF5iAhuA23azTd6jj4pIIrqbz+/A3f+DqaFWRArNuD7tGzyxySivrhagxHLCDda+FZpWdSdA42ph5iHw3IbsloF03Q84UuPhCI9Kmh" +
            "UozdIjgTvGKvhBG/xgnQTr0kw7SRLUhfxoQvsTZG6WdBF0wm1lLd74UYSP7P4ctDtaib22JiCBiWzZXbVAwd8psXV/CNDg8oBYRebsh1lw0cDJT+LL6SsB8n30yWfhvLfSu+ithzM98yL2yefcvVL4" +
            "smmJ5+9gx59CZpUO46xNM3A6n1VRP3JvbUP9bQhPNc5ZknUMfrNuycbahvp/k1sC1OP4k5UAKfZ5wdyHy8uSVxgxbGjdzHcf/QX/3fACCw5/HweNn+VSuHeBCIwoE0aUeUwb07+bXFFean6VXz17G/" +
            "e//h/EdnDl1G2MD8ewmgsrYK+4V4UXdrNNBwOrul5E/9ErARL0GUXuBz5c6IbuJbhfVZ7t89YefkoHRC+CaIF4G6x9AQ48yUV/JRCKwKFnQuNyaN2SRbScPk9of4LjWrJYgXB/JwgPpAiR37N/SxJE" +
            "KiA4SWsPpCUB6pq/xyKhMCWnH483sXv2/9jra/CbNjsBdHBsDchCwgqkAZEKiFB/n+iDI0AC5uxTkJpBVC7wrQuD7GtLRLCPLcc8/QJy7GH9u9imTfg3/BF2tNBryOTg0Gcng4o+K7pXjT8hXA6gWc" +
            "CHUO6vbaj/NfBoY11WIpRr4nYfPUSfZv22V1/+rzjwW2DrUPSOESHqx/jLKw/xiXv/l2uW/YoVW1bh6+AdU1Ytr2xZzTXLFvPxe7/O3Sv/QUc8xmnVuzi9eieaf/KzFfht5OTm+G62a+vLwYrICXoV" +
            "6W1YNCKGq182bEJJ92BsA27ceE1V36NFPIm7YqaJ4qUEBU1JK2YaLIcNvPmM0wJ1xZSD4IjzXF4gj8wiqOEux8kokpq2bXoR1cQxvPT9usy7rjcBwUkUNiW9Snuq4nsynB2LqE/4sLlEznxL9wdy3K" +
            "dz2fMQ7UxWgCdREDUZxta9blo/o8D8QRUerSxHDps7uLumvd25o/pamBRg2w78636LvtE3TyuArmrE/+616PIXU4Q0P1OfH2Zr5ty0N48/Y4AP4Cwy19c21B+e/mFtQ/3RwDk5PN9WhCWNddl1SKEe" +
            "dxOWodzFEFiB3OlcnqD1Ozfxy6dv5u6V/+CUaUfz1hkncPD4WYwtH43XxygtXy2b27byQvMrPLj6Mf7T+BTrd24Mgi0MY0NxLh67mUrPx88/AfoT0mPyw3TkyxfXgTNH7mn6Ih/nR85HmP5u+1qRRw" +
            "W9B+dHL2Lg+AvIsn7t4RFPkoh0/U+2qDBjoLUJXn0UxszPPI7x4IgLINYKL/wV/CgZ5oRk7p/EcnoUGJmWn3S3V8LdlcXtBeLC+NOE1UktTqJ0RqDbyXCJkZAVCd6Bcyi9ZB5mbPf6yLGG1USfewW6" +
            "kJ0M3U+6RSglpOmPC8xnoFFIqkh5OYweOcDbJcDGzS4kvT952UTQ5xvwv/5DvMs+hBx1SPaw+FgM3dCM/vtJ7B33oW+sSZGf/KF/0b8ij6L6F/YeK1BXjMJxizNrG+pvBZ4GpgAXk9tIsHtU6XH86Z" +
            "EArfrUQ7GZ157+Cxwby6sWKB0muOGbWjdx80t/5e6VDzJ1xETmjt2fA8ftz7QRkxlXMZrqSCUlIafr6oxHaYm2smnXVt7YsY6XN73Gy5tfY82ODbTFOxAEI5Icot4xcjuHV7QNBfnZAPwyfHJzX95+" +
            "+1WpvY94Cfg+TqD2fuA4hqbcwWDQDjwF/DHokyuAg3N8jp2722DjoqpozcKW63CZsWsK3Sl7KJqA65oWVe1Oc5UJT/yUBYWURaUnQTQWVv4TDjgOxkzPPFZJJRz3QSirhJfuhV1b3Hox6RwiFQWWKO" +
            "6eqFNhSNP5pC2TNu8pvEtTf4sfkKtk5XcJpDaBS8xaKCnHO/JoIhe9DzOte9SUtnfS8cCj2M1bg4zSgbsrEQqf0P10IUX0MxE0g3nxUBy5G0xCQWvRV1a5PulTuHwaRNAXVhC/4vuYIw9BjjgIasa5" +
            "72p7C7puA/p6I7z2Btq0yZ0jf26vdPTrN9A458ZobUP99bjSGHvz+DMVV/4oTm8GmYGhCbhuTXY3G+zuhIo8LeiNwJVD3SsigofQ4Ud5ZctqVm5exV0r/0FJKEx5qIyIF8Yz7sfhW5+oH6Mt3k5nPB" +
            "bkvRBETIbVyAL7l3Ry0ZithOhXYOhAcaNanu7jts/jhF+5stTsAL6/dHH1HwDmL2i5HVff65242izTKEzyxWxQYC3wT+BOhH8vvaF6W9BuC/yC3BWL9YEX+7KhVX3SiNwELCx0B+2hWKK+/W+/9/Jo" +
            "z3Qjpc/prgkSgZY18Oyd8JZPQKSL8DZSAUfOg0kHwcoHYOPLsLPZPfwgMwGi6TK3GhAfUpFf6ckVtZfJpOXnsC6wPZnl2QVnuYXKSszMAzAnvgXvxBOQyu55fwA6//NfOh99OpX8MNAvZRNAp5YB1F" +
            "dkdy74FFTbGYQOQ1taYdMWqJ00sP3Xb0SfayBpResvRKClFfvgI/DPZSkSZa3TFqGpZJb5t/wk0N7vPQxPYlmCewnc25Fr8gOwBOHJAZ909eUP2pnXnn497i346EL0SsI1lhh0Yn6c7XFnLNG0bcCR" +
            "JiMSpJzvjrAoF43ZyoySIQl7/y9wfeS05r6e6hu4KtmfxSWlGiyqgW/MX9AyGfjj0sXVa4G/zP9I61/x7H7A6bjv9ShgMvm5AXuDj2PoTwMPAA+J6qs3/2pEHGD+gpZJOF/xpeROHL4Z+DFwQ182br" +
            "5mhE2zAh3Rl32KSOJphes3/nBk/39qnmzEY1o3N1g2EpReIHX1v2FsLRz8Luf+SocJweRDYUIdbHsDNr8GW1dDy3rYtRU6d7mkhjbQsVh11p5EPiCf1LpEKLyvybB39zmpbeNp63yS0WRCCC2twFSP" +
            "RsdNhNoZyIz9kJn7IyN65vjx51fQcdt90N6BiOfKeyUTHQYWoPQCqEAaKWpFbd8tzKo7GUwE0q427BPP4B05MMOt3vMgumZ9QDAHQU4Slh0/zfuUnhJhaKO9dmt17orG2UtsbUP9L3Djz5H93X8fx9" +
            "PA9Y1zlvT6Je/2obfq8ofWzrz29GuA31DYsLokJLDn9seq66twTMUuzh+5fSiauBNYFD6luc9qvKWLq7fM+3jL98VZjL4JHDvYbsKlVL8amD9/QcuvgbuWLq5cB7wKvHrRx1puVGVacK7jcD+ymbii" +
            "qbkmRD5O1PcG7uZ8HHhShVW33FCdzFh60YKWyeqsVB8ht+nRnwCuQs3flv6qss8jX9Oi6saahS1XA79mmNz/ewB2AldvXFTdOKC9Q6zFyDFZ3WC9RYVpFF68AyIlMPscR3q6HTsC42a5yY85XZD1wc" +
            "YhHnV/+7FgCowmSauOdUkX0wOr0i0+YsCE09arWxeKuAi1cBjCEUwoAqGQqy/Wh6ryfsNrtP3qZvx1TY7YBdoeDQhCIh+Qpi9naoC2K2zpxzewGZc8b2BQRe/7F3r2qS7zc392ffhx/Fv+Qk7qIA0v" +
            "bB7ITo11S96sbahfhHv+Vg7kGPsgWoFFjXVLdjv+9Okhp6J3i8pi4POFvrKBQIEqz+fD47YwNhwfCu3PrxT9c393uuWX1Qr8bf6ClpeAzwAfxYnFBgMBDgd+Cnxs/oKWW4E/ofrqzTdURwnI0PyPtv" +
            "0BExsBMg03+B0EzMYJ0ybirDClOA1RmOzVleI4U28H7iZswrm2VuHcTiuANyxm662LUyRk/qU7wogcALxDXRmKg8idK3Ab8BuEny69oXrNQA6gwl2inAR8Okdt2ttxoyp3D3hvI69kRFelW4B2J4iO" +
            "t8DzfwDbCbPOg3AvkjcvnBk6P9ygSvyZF+i46Vbs62uQgPykBM8pUXWC/GgWYTSqmxDZ0I/zvslgXsBE0DfW4v/0N3hf+zQybvTu94nHsX9/BPvTX8PmrUEJkYLn48kl3hzojlbkbqP6a9wzoYjd49" +
            "egd/Vlwz4RoNWf+mds5rWn/xBnITil0FfXX6jCGdUtnFy1cyhy/vwL+EHklE39KhKXjqWLq9de9PGWK9TyEM7/exKDt4R4uMq7hwAfR2QhcHPynL8uV2B7MD0H3Pm+j7V6Rm0FzvIxGlfNvRqXWbSE" +
            "VCr1KC6RYxtOuLwdF/7foqptt/xqRO99IfI+nFh7APnye4QFHgW+ryIP3HJD1YBrsG28ujpWs7DlGlx29D3u/h9i/Bu4ZuM11QO+//F4GSOdGEq6kZ/dkSAR8Fvh5ZuhdQ3MeReMmF7oPuk3dMcOYv" +
            "/8D9G778fftA0klKH1ydD9pEeEJfINoQE3UlR0TWck1h8C1DDoCxDQfy7Db2/H+9gHkEPqukdkWQstO9EVr2P/8g/sg4/Crrah1OUMJVYMdMe1ThD9A5xFvDj+9I6HgR801t3Up/Gnz26OVZc/tGHm" +
            "tad/Bfg9+StYlnNYoCYS50Njt1BmdFDBCX3AKuDK8CnNfR9sesDNv6z2gfvmL2h5GvggLrX5wM3SmQgDr+9uo1tvqPRxhKaFvlTxHjhWkdss2KuBXwJLli6u3piLAzYtql5Xs7DlSuAPwPQ89sWejD" +
            "eArzQtqh7cveJJA4Y38GR2BukJ9RAV1o0EARKFtf+Ena9D7akw+UQoG5fdLTaMoNu3Y196idjfH8J/aSXaEQ8ivtIKpSaWIan7SbnBIGEBCshR3MB/D7n/f/sugoZncC8zg0nj7IjYo08Tf/k1zBEH" +
            "IQfOgjEjIe6jm7fCmvXoqjVo4zpo3ZUSJu992AUsH8wBGuuWrKttqL8CFx07o9AXNEyxGrgiW8mLntCv0WDV5Q89NvPa06/APVwG65oZEgjw7lHbOLi8Pd/kZxvwlfApzX3J+dNnLF1c3Qz8v/kLWv" +
            "4GfBK4kMGLpP/oC0/ltTf6ARF9QlWWMngX02ZcGvnrli6u3l3m7X6jaVH1spqFLV8BrsdZw4pIYTtwZdOi6v7l/MkGY17G0xfwmJ09uSA9CKLJLJMhwK43YeUfYO2DMP5wGHMgVNVC+QQw+SyP1EdY" +
            "H7ZtQ9c2Yl99FX/5cuzrq7HtMWf1MU7wTIaLi0ADlL4eUsSHtGgwtqnYf/WrTarPA2twLvBBfpcC23dg//EfePARp4lCgzB5TUViJQTLe5/lB5wM4PnBHqSxbsnjtQ31VwLXsYc8f4cQ24ArG+uWPN" +
            "6fnQbwOqR3gEwFvsMwzyljgTmlHbxv9DaCrBn5QjvwbYlze75OsHRx9UvzLt35aRH9PfAJ4B0MLDT8FeCG226oHoJAuL7h5htG2PkLWn4BnAvsP4BD7ADuBa5XI4/d8suq/rzt9gtGvFut+hOB7zLM" +
            "7/8hRDvwbZBbcnEw+dr9bXrNWffg8XY8SrNmXO6tTEYif4+QqsresQ4a18L6h6BsDJSMhrIJUDoOwlUQrgRT4ixEJuLEzOJllsww4cA9k7YuMQ8sL8RimeH11rp10SjEom7eugt2tsCWzWhTE7p1K3" +
            "bzVuyOnaiVTOKTbs3pFuKeRnxEg4oeiWiw5Pp/W8ur/fwKGlF9jFwQoASSuXaCTutaoHbvJD4JLBNkQPrDrvBDeqsXlxrgexTHnwTagW8bX27t744DsjfO/NnpEYQvA19jGBfwDInyv5M2cNGYrfkk" +
            "P1Hgu4heHT55U/8Svg0QFy3YUaLIibiCeefi0ov3BT7wxaWLq38yFO3sL+YvaPkisIi+65224uq8LEH0kaU3jOjo436DwoQvt0RE+CpOn5U3M4Jv4fiZHrd8tJzSfmp1O2Iw79dtPLbKz3dx6yhwtc" +
            "B3Nyyqztn9rz86ZyKe3oXHMRklMboJo8nuBksQIQiIUPLIaeUJ0nxmiSSIyczPpPIAdQ11T4a5a2bIu69uOa4uHCDjb4WYQty6ecxCzEfjoGqwEkIJoRiseqgaFA9VDxssJ9erl7Zd5rJN20/VawVz" +
            "6fQHv9lvYho98K0XAEvJTyb2fQkdoPMiLz3U76CYnjD15UtKRPQrwFfIb5X3PQFRXKTz9xrrlnT2d+cBDY2rPv1QFPgh8P/oZ4bLoYKvwrGVuzhn5I7+VMHpL6LAj1B+MFTkB+DmxSM6ly6ufgiRS3" +
            "GWoOtx+ovd4UGU3w5VOweAJTgR+e7QiEuO+C6FjyxdXP2PoSI/ABuvqY6K+9H9kGF6/w8RosCPFK7OJfkBkC/ctwEjv8JIewbR6VZzK72OF5k1vEKk1fxKTAbCHoRDwWcKxoLxwcTdJDGnISLLZDuz" +
            "T35iSoTSpy8HofU25sLtNWBSAuIJeMZxNUm5txx3S69gkajvlbldVzNUImF1UAPsQRV9YEBfgOq/UH08j7Wx9pXpcZSHc/nbWDP3xk7ci+KPKI4/PwKuHgj5gUFEFq26/KEO4Ns4V0D/s1zmEQqMDM" +
            "WpH7uFUaF4vghQO/BdVb4VPrW5INe/9Iaq6NLF1ctU7KeAs3EZix/Die66YhNw9dJfVQ9JgdsBXc/i6s04YpEtZ0YbLpfPlcA5avnk0sXV/75lcW4fvH3FhkXV7SjfwZmih9X9P0RoB64W5dsbF1Xn" +
            "5/o98yc8+VuP1p6uZKgnEpRR5JTu26UXWu2p0GlXV5snWSxPaRaobpXre1hOK1iaUcA0LZmhK5xK2nbBMgRsR1PevtT+G8BeO+Mf39o2kK6PvPzQDlSvR7VjGJCIPXXqQPW6yMsP5bzOY2PdksDtvE" +
            "+PP98Hvh30xYAwKOP4qssfasc9sL7KMKpcq8BZI1o4vrI1Xzl/tgFfE+HqyKnNQ2Z56Am33DDSLl1cvXLp4uprgLfjhNLXAy/jcvJY4FovlNs3kXzAiDyIE/lZHMNfiRPdz1M4b+ni6u8vXVz98i2/" +
            "LryGqema6nbQ7+NcwcPm/h8CbHPXLN/dcE2eyA8gn/zrZgzfx+OVDBLUaxX2RMQYPRCftIiybCQpm9aoWybqbBokuguxE6wkXY8k3ZeFdFKjyVIX3Za7FkDNQpoctAP4WUwjg/u9u2KcedM17gO4HV" +
            "dQOS8IHvzfx7nChu2LbR6wDfci/L3BkB8YoAaoKw74+enGt7wH92XkKlR7QLDAlHCM66a/yYFlHfnQ/qwGviLKbaFT+1zmYsjxvktbjRE7FZc34kDgx0sXVzcVul19wfwFLRNx1qwVwD8ssurWxVXD" +
            "tq8nXNFmROPvw72N5SxEdZhqgFYDX0W4penq/JNQ/fYxwtRxFxKSn+AxqRvR6U0Y3ZV0ZBwYkmUu0vU+2UpcdNX6JPQ/cVL6nsT69HU9Lqf9HVPUSqDZydT6WPUCPY/T/Vi663xs4rOUFkhVvV9YNV" +
            "dO+8ei7YPt/+icU2cDt+LyhxXRdzwPvDey4l+v5PtEk19eYDyJvQ/njdljUtQMEG8AV3rW3LL6wN8MevzJqXlk5rWnH4ezCJ1SmL5x+PSEZj45oTkfh36YPIS6F7F3oGZhS07v/2FIgP4NXNG0qHpI" +
            "739dcrZHJPQhPL5LSCZltdRkWGzoQoLogQCRSXz6Sn56IzxdhdCxgCzFgs9i2YgRaYQnU9zchdwkxM3Y9M9SxCmGmj+qmism//1HOXvZic4+5QzgRlxW+CJ2j7VAfWTlww8O5UlrG+qPxWmDCvr8zS" +
            "MeBr7SWLckZ+NPTt8NV13+0OPARThxdL+Lvw0WVoWDytq5cPS2XJc534krovn+Ivkpoic0Lap+HHg/ruxIa6Hbk0O0Btf0/qEmPwBSf7+PxH+Hx2fwWNHNLdU1WWI2jU+2Kd395e2GVKWTqwyi1WXq" +
            "6uLKFpafTsqS4mftIoLOFDcDmW6yYFlEEzqgXSL6f2Lsl3NJfgAiKx/+B/ApYO1eHq4+OLi+WQt8aqjJD0Bj3ZInQN8P/IQCPH/ziFbgZ8AHckl+IMcECFzGaDVcAVwCvZeizyUUKDWWD43dwsRILJ" +
            "eur6eAjyC6MHxK8/qhup4i9kw0LapeD/Jl3P3/dKHbkwMsBz6iypcGneF5EJCL7vcxFXcg8gEMt+LR2iMJyhBE0wsJgn4Jn3cnaO5JA5ROdrKRpAwtUB+IT1Ls7GaCvgT6WUG/PvH+n+bF9B1Z+fDd" +
            "qNYDzw0DcfHwnOB5VC+JrHz47kL9Thrrblqv6JdxxaSHTbLbQWA57vn7pf5keO4r8pp3fOa1p0/GlXCoBybl81y+CmeOaOGHtWuoNDYXkV8bgCWg14dP2ZSTJFZF7FuoWdhSC3wcNxjV9Hf/ArvAmo" +
            "CbgOubFlW/OdR91xv0/vNH4Jl3EZKP4clhhCjrkbxkJERMP0gXt1dX91e6Oyubu8sncGf1QfcTy/Y3GZog9RM6oCx5f5J6nwxXmFU1a616t1u830647xfPDUXfRw94yyxc0Mt7KSbiS6AduAPh25FX" +
            "/pN3zU9fUbuivhblE7jn78RCt6efSI4/jXVL8jb+5L3wysyfnGrwzOG4B8F7cEU1cwoFRnk+P53WyIlVg4782grcBfxCrTwdOW3jsBXfFjH8UbNwq0DoGNz9/076kcK+QARoG/AX4HoJ8eSG7xY+2q" +
            "4n6D8vmEDYvJUQ5+HJIYSkFo/qbrXCsg0H6SLorpqf3ZGfnpYzdD69EJ5sf/uSEjQnExmmEyEPqyaqeBuseq+g5mGr3t2+mpXj7/vVwAvPDgDRA95Sios2/R9Uj2ffTZbYgcjjuIjbv0Re/c+wC0ef" +
            "/MIl4oX0GFLVA3L+/M0xkuMPRp9snH1TXsefvBOgBGZee2oYzPHAh3HZi3PGSC3woTFb+eqkDXgyYNtPEy6r8E0Iy8InNw/poFLE3o0JV+yMiOoJuLexc4Dxu9tniAlQM3A/sERVHt14TdUek2BNn3" +
            "p3BGE2IZmFx354UocnkzCMRRhD9qKeApRiMclszxnZnckmbg4R1wgxeiNDcWIa7Z0AkYUMgVWjiteh6qmqiVm8bapmi1Vvs6r3qsVrUPVWod5LI+753ZZC93t0/5NG4AS3FwAnAFOBikK3K8/YhdP5" +
            "PIZ7UX448toj2wvdqN1hakN9WNx3dAkuZ9yEQrepCxLjz41qdNma2TcNyfgzZAQogRn/d1pIVA7G5ao5F6hjEOU0LDA9EuUX09/kgNLO/mp/okADro7UHao8Fzm1OW91pIooYsKXW8IiHIJzIZyLq7" +
            "eUNZ39EBCgGPAqcA8uZ8mzTYtGFIl/Ef1CbP+TPIWpKIeCHo4b02uBsUAVzlUWIS2dZaHb3AOS9kDcs6EdJybeDLwJrAB5BuF5oDHy2iN+oRvcX9SuuCSE6mHAu4HzgDkUrpxGDFeb8q/A7QrPrqlb" +
            "MqTjz5AToHTM/NnpExBOwn0RxwHT6adf2QBfnNjEpeM291X304HLJfAYzuLzSPiU5g2F7Ici9k3ULGyZBJwMnAmcBEwj7WUgTwSoE1dKJHn/Ny2qXlvoviiiiCKGFrUN9ZOAtwBvI8v4kydkjj/KI4" +
            "1zlxRs/CkoAUpgxs9O80SkBjgMOD6Yz8aZ6cpxbw3dYIGjK9rstdMaZWwons355eNMls24N93lwOPAs1g2hE9r3uMYfBF7HyZ+pcVTyxTgYOBE4Ahg/7hl3IkzvYqlHy03AyFA83/dZh9d5e8KGTYB" +
            "rwHPAMuA5xTWblxUXbz/iyhiH0dtw4c9MFOAQ3GGiMNwz99xOJfmQC12Fvf83Ywbf5YDj+KSRK5rrFtScG/LsCBAXTHz/04vR5kEHADsD8zFWYfG4cyq1QolEdHQ96eujb5z1HbxVTpJmSubcVaeBh" +
            "zxeQ1hQ/jk5l39b00RRQwtaha2VAKTO+Psf9bc0JwlHy6bVRJiOu6FYDTOrVCOC94GpyJpw93/W4GNnXHeqP9t+yt/ezm+oiTEawLrNiyq3ptyExVRRBF5QG1DfQUu6eV+OBfZbJx1qAYXxFGNE74n" +
            "XstiOM9KC07E3IR7/r6Cy+b/Oo7wFMefIooooogiiiiiiCKKKKKIIooooogiiiiiiCKKKKKIIooooogiiiiiiCKKKCKnGJYi6CKKKKKIQmHurdsqEJ2MC8CYjROCpotAR9BdBNpOpgg0yBvDSlwgxv" +
            "qX3zu6GIRRRBHDCEUCVEQRRezTqLt1sydiJuPSEBwPHIUjP+PJTRhwM6k0BI8Bz+LbdS/PH1tMQ1BEEQVEkQAB46588KRIWcXnIhUjTi2tHj3SeKH11vr3x2PRG9eufP6J9h+fWxyoiihiL8Pc27ZM" +
            "xCWCOwuXf2ka+a9r1YmzDj0G3Ivw6MsXjsl5let9Ajs3TkPlP7gSHP3Fj6ke//lCX0IRhcU+T4BGffZP7wNZBDodMZRWjWLklAMIlZaj1m7w/fhdfix605YNq5/e8s2TCp64qYgiihg45t6yJYQrRe" +
            "JK8Qh1FK4UQBR4BeUe4A4Ree6l944uliLpKwZHgH5C9fjPFfoSiigs9lkCNPLTt3pI6FLgu8CY5AeqVIydzKhpcxBx3aPWbrY2fo8fjd3YsqX58Q1fPWyPKRRZxMAwZuTIAVfVLaI7tmzfXtCx5sDb" +
            "tkVU7XGkikHWFLpPuqAZV5pkCcKyl987pjjG7A7ZCJDnKbLbW00QWULZqEsKfQlFFBb7JAEa9bm7I9b6n0P5Ki6rbhqUcGkF42cfgRcuQYNOUkCt3WZ95xpr277lP+uuOLij0NcyFPjcsuPNKU3e3P" +
            "JOfVtppz0lFOPgcFTHhjvwQlHUxCVmYrLNRGnA8hhWH9haZZ477huPdha67QNFkQDlFoUiQIfcvENiXvwogU8C5+MyaQ9nbAP+onBdzIT++9qFI/pZ33kfQlcCZK3l3r+1smq1j+mFBYnIlI07Vzx9" +
            "/at/Hd+pFqfxWg1yi3BX0QK3D2GfI0CjPvOnclX9qsIXyFr4TQmVlDNu9hGEImWQpcSqWrvTWv/vfiz6m/adLf9a88U5e210xy33vOXgipj9SElUz4/EmBKKqReKYkNRfC+KhqKoFxUbioIXRbwYvo" +
            "mzSa38W2HJxumdy4758lN7nIaqSIByi0IQoLpbN9cCnwAuBiYVug/6iSZgCXB9w/vGNha6McMSXQlQPO5z4ft9HvrXbivnTaEk9h9OlulUhIMx/t/AucLde+1YXkR3hAZ/iD0HIz9950ir+i3gssFc" +
            "uxhT5RnzbuN5Z3nhyL9m39D06472nf948zMH7Cz0NeYK1//j1IoxUf1oWdx+NmxlhlF8VaxV8S2oDyqpORase+lSRBnvxZhnfN46ZUXJ79/4xInXTv/FoxsLfU1F7BuYe+vmsMIFwEJcRNeeiBrgCu" +
            "BtdbduvlqVu1fMG1t0i+0OTrewW7LdRNQ8T0vUESDApTQYaLRfEXso9pkvfOSn76xR+CnwKXJE/ERMhRcKnxcqKf1DefXoO2bd0DRvxk9eG1noax0srvvHGRNH+fy0RLlGVKZbJO5jrC/GWoz6GM2c" +
            "i1oRLKKJSUXiWBkdislnynfJ4rWXvOXAQl9XEXs/6m7dPFnhGuA37LnkJx1HAL8R4Qd1t26eXOjG7C2Io94DNCtowsU4hm5yiCL2duwTBGjEp++cpvBL4MPkwe0nImWeFzozXFJ6U9mIUX+avbjpw9" +
            "N/tmrM4I889Lj2oTMnV6PXhVUusSohH/F9R3asrwHZQWwwD/42SeJjxahiVB0psoqo8eWtpR38Yv0lJx9R6OsrYu9F3a2bjwP+AHyWvethVgl8Gvhj3a2bjy90Y/YSyAM0e+voiAePhHFAkWDuY9jr" +
            "CdCIT985B/c2+I4+7aBd5v2AiJQYL3RqKFL6q7KqEX+efUPTgunXrh5f6D7oK370z7PHVAk/CsE7EqTHqmd99Wzwt/p4jgipl7QAOSuQpxZPLQYrohaDIiiiivjiy5Elbfx4w4dOnl3o6yxi70LdzZ" +
            "tM3S2b5gN/BE4pdHvyiJOBP9bdsumig25u3uvH7nzjNXZF/kxTQvQ8Ajio0G0qYmixV/+Iqi+/8yhVblLldFXo00TanD7u02UCCRsTOiEUKb2+rKL6nlk3NH1o0jXPFSrXSJ/w5UfOCleLLgypvMeq" +
            "sb4a6+NpHGN9jPXxbGAFsvHEcnJu1KpRX1IusIQ1yIpJusSML0dHOuW76+pPG1vo6y1i70DdLZtKMHwGuA7VGQP6we5Z03Tg576Rz869tblkkN23T0PBLOYN00xHFPcsPFl5x179TCwiE3vtl119+Z" +
            "2nATcBxwz4IIONAxLxjBc6OhQpuaFy5ISFo696fLfRCYXCVN+8J4R8XNWIc3UZdXMPX43GndXHxvHUx9g0YuS2FaMWg49JEh/FqIqoilFFsCK+icvZJW36qWeuPNMr9DUXsWdj7i2by3BC4e/ianTt" +
            "KxgFfFdVvlJ3y6ayQjdmT8Yz7ChZzJsJcflJILWFblMRQ4e9kgBVX37n+Ti319xCtwVAxJSGwiVfGFNTe0Gh25INi/799lklYq4EUxnH+M7N5dk4no0nLD7q2SQJ0lDgAgvID8bahBZIjPoYrBh8J4" +
            "xGRXCESFQR8eKyYNLr/hmFvu4i9lzU3bKpVNGvAVcC+yIJKAW+Anx9zq1FEjQImJ+xKryMre0gM3FJMovYR7BXEaBRn75bqi+/8/3ADcD0QrcnHWLMCC8c+Vih29EVH3jgnaEykU8bzFwfL56y/AQW" +
            "HqcB0jiexklZgHxJaoLUiiND8SwRYgEhUisuUkxFLMroUIzPr/nAGUVXWBH9Rt3SzRFciPsXKVwZi+GACPAFUa6ou2VT0R02QDTTWfIlXtJ1tCvIhywX7JEBLEX0H3sNAar+1G0hX/3LgGsZfmnuAT" +
            "Be6LBCt6ErDi7TU8Ni5lnEOldXkuwkl2OO+ASaIDf5hGxcPI2LI0Vx8dQPprjxnEvMBK6xjElUxcSN5fiyTt5f6OsvYs/C7Js3GsR+EnQhaCRNrbevThHQL4N+8sClTXvNeD7UWMbWss/xQsc2oocL" +
            "Zl6h21PE0GCv+MGM+PSdJSrmS6CLGGSqezes5CcJsIgMqzT8l//7PeWlIpeBjI5rEOYe6H3i6hEQIJsgPTFCKYIkaXNJEaB4YA3yTWKdUd9kIUFIyPjUr5//tumF7oci9hwYI+8Dvs6+6fbqCaXA16" +
            "wUH9yDgNzG+rJP84JupP0y5cK6QjeoiPxjjydA1Zf/qcKqfgP4hkKlMrh/CeVznt7XhlV/1xje6ok53Vcv7mtg8VEP3xEdR3w0RJyQxglpXEM2LiEbl7DGCGlMnBUoJiGNS0hjgfXHWYAcCfJNJgny" +
            "E1YhY3xUZoVizC90PxSxZ2DO0ubjFL6nMKrgdpfhN41S+N6cpc3FPEEDh/k9a0o/xrP7PU7zl5VLKwvdoCLyiz26FEb15XeMUuy3cfV+ilFF/cDH/nNhWUS4RNVUW5WYRVAVFBSLigqoYBQ1iloVtU" +
            "AwqaKaIIwqIKI4jbOKGKvB3yA2mKtgrHqaWK8Kaoxl3tr55908Zelf3yx0n+Qbvu+jmh/rYq4gInje8PspzVnaPAm4GmVGodsyjDEduHrO0ub3r5g/fl2hG7OHwvyZprJXaH3PsfLGipNOfuePHnn4" +
            "rnihG1VEfrDHEqCqy++cqOgPgPezDxZ1HSzG4x1n4OQ4ErcqqlbUqglYjSgqwT/UU1FfUaOiIVCLBkRIE0RIlOB/R2xQsW4yCsaCVYtYg1gwCqqKsb6x7OfFOR/4v0L3Sb6gqpSVlXHkUUdRVlaWSB" +
            "Y1/CBCe3s7Tz/1FO3t7UFZpcJj9s0bw8CX2LuTHOYKJwNfmn3zxi+tvGhCsbL5ALGC1qpXabtSQ/tNYPuGXzGipsG95RWxN2GPJEBVl98xHfRa4O2FbsueiMMe+KAXEXuRVUZZa2LWClYFVaNqRdUK" +
            "gjjKAxgEo6IeqE1M4siPFcXtkrLsiFhRY1FjUWtJkR6rbm8FsRYRg2hIrLx79QfedfOMP/xpS6H7Jh9QVcaOHctPfvYzamtrsdYO/qB5gDGGxsZG3vWOd9DY2DhsCJAIF4B+tNDt2IPwEREeAW4vdE" +
            "P2ZPhqq/nvU5/hmh+fw+cuv5fOHXfR0fksI8bvNUWv93XscQSo8lN31AHXAafm4/iJLNB7M04rkQM8vDN8FRtXg1XBWX8CN5gasIKz+YgaN+EBvoKvqK+oL6ph5zFzNqHAAqRisRIQH7GBBcii4ltE" +
            "jbMMWVStIuqL6sEmyonAnwvdN3mDCOFwGM/zhqWLKYFwOAzDhPgAzFm6cSou5H1vqu2Vb1QBC+cs3fjEivkT1hS6MXs0WnYa/t/PZtPSMo3PffqDTKx5mZ2bHkX1KeB1YDPQAXRSPb6t0M0ton/oFw" +
            "Gq+NZyT5QyhI7W/z1iyP2ilZ+64xjg/1Q5Oq8nSmmh90qUGnOuIlOiaqxVg69GnRXIqKrBsRgTaIBERQ0GUS+wAvnBZHGCIetcXppwgyG++1ss6pYDwmNAVVV9AgeaBYtnbblRueC/l37kvqN/9Zu9" +
            "12w/XF1fw7SNs27dKFguY++o6j7UOAq4bM4tTV9dMa9m+HypeyI6OoT/+0Upy58VFn7heE4+6VQikRi+vx3YBrQC/6RlwxVUTyzqhfYg9JkAVV61/HQsHwbmoLxSedXy3yHeg63fOHRI7PmVn7rjdJ" +
            "xOpBieOAhc/PAlI0LI231rPN+auG+NWvXw1WCtoOqpqrP+oAZRwVmBDAbwFA0h+IBVdXogJ3ZWNYq1VtRYTRAfjEXVB2vB+KhaVfVQ9Z2bzB3FF9WTRrR27A80FLqPihgeMJajgfpCt2MPRj0qdwFP" +
            "FrohewGEZY+X8sGPxHnHebv46MWGQw8ZQ1nZOKwF1S0YM6yifIvYPXZLgMq/9ZQx1lwCfA9IVDY/FjgP9X9cedXyn7VedURLPhtZ+ak73gH8DJg2dF2zd740Vat3OGoOjVvjx62nVg2+9fCtwapBrV" +
            "G1BrUGcSRIxVmCSLrBEA3h8iVZCVxgoupE0D4EFh/rCA9q/YD8OMsQ4qPGWMUaVQvG941qjbFyGkUCVAQwe+nGCOhlwMRCt2UPxkTgstm3ND27cl5NdNBHKwJ27gzxh6Uh/npfjJNO6ODcs5UTjouY" +
            "8eNidmIxsf2ehl4JUOW3no1g7eXA/wLVXT4eDVwFHFx51fKvtV51xKu5blzFZXeKePp+4IcMbXbnmIgR0D1OI7U7hCV0jsWMdLl/AvLjLEBq1UPVODG0GpwFyM0DAqQGwVPwg2gwX1HrtD9YsWoDt5" +
            "cVKwmykyQ/blJVH8UPrD8+iodnfQPytuUXf+KmI276xa5C91MRhYWoHge8o9Dt2AvwDlFuBP5d6IbsVdi+I8w994X56/2WmvH+kaNn1j28YvzPyrjgDaAZ2CXcfUuhm1lE7+jxAV951TPlWHsl8AVc" +
            "ptFs8ID3AbMqrlr+lV1XHXF/rhpW8anbQ4J+HPg2Q1jp2YisHlFV+YdQJHKJwuShOu9Q4IP/vGycwZwetx7xwOrjWw9rvcAK5OGsP55zhTkrkNMtI0E0mFEnhlYJIsKwzvoTECE/QYBUxRc1aaSnCw" +
            "GyJJdFMb5RDg3H7Rzg6UL3VRGFw5ylTSGUSxhkVvc9AQpYDQIjBYzkPKfHaOCSOTc3LVtxUU1Rn5JrqBo2bDSjNvjTPMZ+PC3XrQWKBGiYIysBqvjG0yMU/Q4uwWBfrCCHAb+tuGr5IoHrW686YlBq" +
            "+MrL7yxR1S+qq3ZcMWSdYeThaaNLv37o8UdvXt4U/dAw0oPmBGV4R6iGZsXU+L46whO3Htb31NqQI0MakB81oB5YA9aIUbEmsAT56pivBXyBMNYN5AmrjlissaLGERwrvqj4qPFB42qTpCeeIECq+N" +
            "azdrSqOZkiAdq3oRzCXlyVO0F6jMDIiGFqpceEMkObr7y8Nc72qM01CTobOJTi7ypvUExCC2u6zIsYxuhGbiquWj4GuAa4hP69jIwDvq9wUMU3ll+165tHDCizb+Xld1aq6teBzzJ0lZ47SsLmppMP" +
            "GPeDP1124pr337dr/72M+wAQIvRWq6HKuPXivvU0MSXIj29Daq0H6qHWU7VGsYELzBpM4BIzCp66QdwmCoiIiwezgfjZip8IdQeNO8sPcayGJKLxgPSEsMRR8dXiE8IX4NRHP7LwhhN/s6joBttnoR" +
            "cyTAsaD/iKSKXYGBExHDQ6zEk1EY4eH6G20qMybIir8vD6Tq56qoVtnTklQTUK76FIgIooIgPZrDtfwkVeDOT3FwbqEeoqrlp+xa6rjvhXf3au+NQdY1T1O8AChqi0hQjrqkvDi77zzoP+cMkJM9oB" +
            "b2/UP7/7wc+MRkNviWuIuA3hJ0mPh68htRpSXz2sDakGrjACTRDWYPAwCUE0QlpZjCALkKZ0P8YXq1bV2sDyE1dVX1TjWOOIkJt8LCFR4mrxUYn7Ru1c49v9gOcL3WeFgvV9/BwnS/SMwQzj/EMJzL" +
            "55w0SF8wrdjlwhYe2JGJhWHeKkmghvnVzKQWPCVIQyh9gQwmmTSrhlVIj/bIji5dYMdN7smzdcu/KiiRsK3SfDBEqxgsA+j2wE6CIGb747FvhjxVXLv62qN7Z988iO3e1Q8ak7JgE/AuYxRDemZ+Tx" +
            "SSNLv9HwzXMeAVesVNwzfa9DGZE6NHRAzIZ834Y0bkPqa0it9dS3IXzfw2pIrQ05DZD1RK0XWIA8JGkBEoyK+CrqoWIRddaf4H+sIzaJbNDqO7KjvrP2EPxNPPG3WjxxBMizIeuPUfWOYR8mQHfeeS" +
            "e3LF2Kl6OoWt9a5s2fz4XvfW+hL60vOAmYU+hGDBY2eIkaVWI4alyYM6eUcsz4CBMrvF4HN88Io0ry4j2Zg+vb2wrdN8MBJzC6NYIx/2JzGUV31T6LbARoZI6OPRH4sYgcXH7V8u+0XXXE+p42rPjk" +
            "HTNwOX7OHaLrjpaEzM1HTx/z/fs/85Y3CaxNyYFpL3wv8Gz4LZbQSN+G/LifsACFSHN/YYNJA2E0gTsM9RD1XJ1TDMZVChOrJEqb4pxdFpXA6kOiFlggfjZxVOPu7zQCZCVORDxV8bHWE4vvAW/56y" +
            "d+eNN5v/ji3psUsRe89tpr3H/ffTnLGO37PkceNfxzCc7+wwYPp1cZKtd3TpGw9oQNzKgOcdqkEs6cUkrdqBClfTTnqELUz0vzIsDZdUvX39kwf1J+zrDnQI9gpPkWc8LXs7rt56wOr6cjwl458hfR" +
            "G7IRoMeBt+Xo+CXAZcDc8quWX9F21RGPd92g4pN3HAj8nCEqdCjQXFES+uHnz5x145fPmrOLLK62vU38fPL9XywXDZ0c17Ckkx/fhvA1hPWT5EesTbMCBeQH6yHWiKhBrFGjIsaRHzTpDlNJ5gByeY" +
            "DUqhWVOGp8UUKOAElXC1CwLHGshFQlbo3qYSE/NgVYXei+KwSMMYRCoZwRIBHZM3K0iU5C5cRCN6O/cDnQoTpiOHRMmLOmlvKWiSVMquj/9xe1ytYOPxiEcv48PtEqk4DhUR6jpTmEC3KpwD0rErEV" +
            "caAd2EH1+LzkL7Ioo4hErmRW+Hxqs83GRAAANC5JREFUOn/O6rY7WB/ZTDREkQjtM+hGgFT5PrBfMOUKpwBLy69afhXYP7RddVQMoPyTtx+n6P8BRw6F7sYzsnxcVck3XvvOuQ+JSCLytOuZ1Xclzv" +
            "caKdBoLZupNnxw3IZtSv8TxvdDaZYfD2vDaq2H2hCqYTRpBTKI9RA1ghUJ8gE5y48KiZIYEGSEloQlyAqOAIH64qxAAQESR3pcyHwMaxPLcetZf6LFHM4+SoD2YRwKOoTJTgeHRCRXbaXHiRNLOHtq" +
            "KYeMjXTT9vQHu2JKSzIKLOcj0DTgEApFgHZuLEVletCGQ4HZwCRcmpMKnIbUBzpx5SWuAf6QxxYpIAczovQ6DtlWT+22P7J2zN1sMI20hym6xvZ6dCNAbd884l/l31j+cZxVZnYOzzUN5edgDin/xt" +
            "OL2LTqIJzbayj8/fGwZ+44cNKI7zy68PRXcW8aw6jkY37hET7G2vB4a8PWtyH1bRg3D2FtGKsJAhQS9UNYDavakKqGUGtErKcSiKFRYxwdQtXlBhJV0ITlB5VgHuQBCgWZoONiE1YgQkmrjyNCnptb" +
            "nzBxwhIvUadXuLPQfVfEkOIEes45NiyQcHOVesKckSHOri3lrVNKqa0MYXIwoOyMWXZENV8miFJcH/91yDpsa7MQYj/gbShnA0cAE+hbepWpQ9NIxSAvHsfYRccy6lOfYebJD9Bs76LJPs328BZnFS" +
            "qSob0QWW/Ctm8e8WD5N5bX4wjKkTk8XznwWVRPIlJeQ6w97ze4wNayiPeTDx8/45c/eu+hLQxRdNlwQdXd9UZs5C2+RsK+Dcec4Dmk1pEgZ/3x3bK6KSA+nqiGUPUU9UQw4CTQoEZUwVMjLoebirOZ" +
            "JWLCXIkMNb5gfVcc1YRQ4qI2hJp4yiUWWINSFqEQqnE16JG3ffKGMe/9+ce2FLoPi8g/Zv9xfQVweKHb0RPSRc1Hj49wbm0px9WUMDrHguWtnZbWmM2nE+aI2Tevr1h50aT8ppnYsVEQORT4MHABMI" +
            "PerkoEjAm2kMS6oUzc6IP/oCDL9qPyw5dR+fFLmDbrNVr9x9jW/ihbeJ4WWUdHaBsxiWFdNSDXWPH3ztiZvR49svC2bx7xePk3ll9M7vU5gpijqRoHbduhc2feRDdG5MXRFZFvPrLw9Pumjiq3qph9" +
            "xuwT4Biz3wS14SN9jdi4Dan1Uy4wa8Pq9D/hRASYuhxAjhihRpwWKITYVFkMdQVSURWMIp4zBoFaAdUEBQIvID+JemAhVOKCDYHERa2XtArZpA7Ix2rceurPsMhsYFmh+7CIIcEk4IBCNyIdCWuPJz" +
            "CtyuPUSaWcXVvKgaPDfRY19xdNbT5RP28WIIADxOmAcl66KImW5unAx4EP0VM2/QThASUatWzdFmfDBsva9T7r10fYtSv60SeaT/sV76gCieOqrj8HPCLcnY8HhgCecNc24KfKBX8pxXzwIEZcdBAj" +
            "Zi1gmtlBLN5EZ3wN7bqW9tha2qPbiYfb8EvrqBSz7zgV9hr0aoZs++YRL5Vf9fQlqFxLrnNzmBBUjAEvAu3bwOY0MMGGPfOXAyZUfvO/V575MgmX1z54e4YpPVA1Uhvzw9ZFfIVd4sME8bFh1WCd1R" +
            "AEIfDBsqo1kogEc6Joo6oiAqIISqAAVQRRVK2ooEh6piAfjAX1UeuJqw3mOVeYOKuQlThqA0uQhgjZeDXC0RQJ0D4C3Z9UseXCtgRHfMpDQt2oMGdNLeP0ySXUVoX6RUxiVmmPK1Xhvj8am9p8Ylbz" +
            "+Sgdr7A/+SBATtT8LuBKXHWA7kgQn1274qx8NcZ/HvFZ9oRh5SuGjc1h2trCxOMeEJ5F3Tkw+9w0LdStoI8yBPJM4e5VwLeUC27CPfveM4LwkSOIjJhNVWKz8tQee4tidN/Cbv2wbVcdubr8f5d/DO" +
            "FHmuscPSJQVg2hMOzaCrHOXBxyR2nY+/k7Dp30fzfWH7MV57vtz92pvqYyt+YShSBgYiPHWxuptDbsJzU/CcLjll3ou7ooMNUQBHXAAjeYijUCBveZwagojvxgVU0mF1IUFcQJorEBAcI6axBG0AQB" +
            "Cubii5t7To+kcax4xqDHXfeZ237xPz997+BvjCKGO2YzhGVvsiHh5hpdYjh2QoTzppVzzIQIIyP9d3Ot2Bbjtyt3saHN5/vHjaSmvG+e9w27/KTVKU+owPX1fTk9akvzaGAhLuq3qtvnjvgoTU1R7v" +
            "97jDvuMix/Nsz27aVkf6aougwb6Z8ZhjhCS7j7TeA65YLf4UT6b8V5ROqAsfRNy1TEMEWfvry2bx2xvuwbz3wKdDv5yNIcLoOqCdC2FTp2MVA2bUReqS4LffPOy07683EzR8cH6vKyeSLzQx1ef/hd" +
            "3ykXW3K8byOuzIUfVrVhfHUuL9WwWpcFOun2UuuBhlB1lp9EYVRRAxhBDRYjoqKiAFZ8EacBElBJXKmC+o4IufrxohjUeGD9QPfjg/VENY6qJyoean2UEFbi6qk9yDgT+qqh7bnCQlWx1uYsdN1a6y" +
            "RawxlKHQUSmvoB4ait9Dhtcinn1pYxd3SYkgGwkNaY8qdVbSxZ0cqbO33On1FGZbhvl9XpK+t2+Yn+yBcMuQ48aWmehkti+26yERTPg02bo9x+Z5QbfxeiYUU51u5RomLh7p3AI8AjyjsqQaYBc4GD" +
            "gFnAFBwhqsDlXNqntKZ7KvrMXtu/efiWsm8s/xKwA/gcuU5W5oWgcix4JdC+vb8uMQ158repo8u/8dJVZz8HGN1HXV7pqNSqaWojc+N+2KoNq9Uwvoacy8tPkJ6wqNP/iLoyGJLI/6Mu+iv42xC8gI" +
            "mqUUlwS1UMzr6DJh6zKohqyvjmCxIUV8VHjQmO5weJEh0JsuqJ0wD5+OLZkPo1oIeyjxGgiooKxo8fjxfKzculH49TUVFQ48puoS5EeyjPl4zmOnBkiLNryzhjSinTq/vn5krH81ui/PKlVv61roNO" +
            "C6dPKWXh4dVUhvt2xLa4siEgQHmmq7nr65bmA4Drgbd2+8wYiMV97n+ggx/+xPDfp8tdbZ09G8KfW4GXguk25QIP5w4rx1m/yihahvYI9OtLav/mEa3lVy3/hiotOD9vbkdVMVA+IuUSi/cpB1ZrSd" +
            "i74fQ54398xydOaKZrVud9GJ4tO8LayHi1EevcXAHx0TAJF5hqMvrLuaOcCFpUPRVMsM5ZfsAETMeIImpVEHGJ4FLhG04QlLBgC1Yd+Um4wgyIh6jvNEEEOYKsR1AlnoAMoeqXitrjgD8Vui+HEhMn" +
            "TuSII4/MqQVo4sSJhb6s3WFIip8mkhaOiBiOGl/C+dPLOH5CCWNKB97XO6KW215v47crW1m/y0eA0yaX8o2jR/TZ9QWwpcOyrdNH8l+mKjd97Sw/2cmPZ6B5Uyc//GmMJb8rZdeuvZYQCHf7wM5g2l" +
            "jo9hTRd/T7pmy76ojOkv996hojpgX4Fi6JVW4RKQcvIEGdPUdrivBGVWn4Oz+df/ht846a2qmKt69bfZL4x4EiW0tOsrYkbG04rr4Lb3eZnsMB4Um5vnAEKBH1pYHoWRQTRHwZQY0GPi4ksAQpyP9v" +
            "78wD5Kiq/f85t6p7emYymclCNhISsgBhhyCbPEFRUXzI08eiIhDQnxD2fQt7EgIGFREhKKuIomELyvZUFkH2QCABQjYIZM8kk8w+3VX3/P6o6p4ly2zd0zOT+miRTKe7+tad7qpvnXvO9xg0XDaUsH" +
            "zFgqqAqogIQfvUICIkNhBDkm62Gooex0etLwR5QWI1aKFh1D9gxpUvlV06/YiN+Z7SriLt3JxN9+buHw7V7J9HmmBD19NhxQ5fGZbgOyML2WdAnMJOmBYCzC1Pcuf8Kl5dVU/KBsaIR+6Y4JoDytrt" +
            "BF1e77MpacNcwZzGgDo/10HOzy/Yovhx4MOP6rjsKuWlV4qJ7kcjuikdUuUNNx7gFV0757cqshGYQS7u3pwYlOwAbhxqN4URhCb/bOSloaWJaxdOPfotgn5UWStx7w0m0PtVnDNQbWJ/38ZU/cDsMB" +
            "3pCSM/mon8WEfQsAu8Zvp/hT5AEhR4YUADMUNg9kNwuhdsWAUfPjGI+KCIWvFIR3+MIlbTlWFB7rSPSrgcpgacQBClxY+qbx38sVh/LPBOvuc0IqeUZnuHTTux71oW45sjCvnmiARjS2OdNi2sSlke" +
            "XRLk+qyo8TESfBu+OaKQqyeUMrgdkZ80K2p8GnKVgNiczs111VoX5XKCnJ/mGKO8/mYt517k8PGCwq44mIiIjtLhsGTtjRMU+GPi2ncrgdvJyRq+gcJ+Qal8TQX4SYC6uGPunzCy34wXLj5iBY1LXt" +
            "k6c6hvNXSz6bnE/OLd1I+PtjbuW+tqsLQVa1zuahIBSi97EZgeouoI6mhm6SuIACHh/1SRdLaziKAYUMSKZqRREMcXUMUXIUiPFkWNitgwEiRhCw2DShgNEoOqQXHEqq+u+mUi9ktEAqi3kzUH6LQl" +
            "Z0lM2HdgUM31X8MKGFyYnbzUD9YnmflhFS+taIz6CPCdkYVcuX8pO3Twfb6o8vDD/eWYzs218j3gLFpGdhxH+c/rtZx5rsPST7u1o3dEBGQhUav+xv2fSlw7pwbV+xGTG2fneDGYGFJXsbGIhmtvOn" +
            "b8Az87fJeGXFWLdveCmbZgbOFB1haUYF3b2NurSdQnFD/pSi8IRFKj548RGpe+CJ2gwyZpQVQoeEAACWv8gxJ4DbKhRcVRi4bRIwuIBFEgIUgQCh8XH1UbBJjUqIojmRJ5fNdY/9Drr3njnuunHLxd" +
            "doffTshKjohV2KHQcNjQBMeMKmS/gQVtTkJujXTU58EmUZ90TPR/Rhdx2X6lHXaG9hWW1/h0kVtrrMOvDEwOrwL6NHvccWDuB/Wcc0EkfiJ6DNlJTCtf2pdYUZziAcGSVU5GGkdLBrm+6/Sbs7GwAG" +
            "jI2Wmih69Yj5l1ewH1BYeqjRm1rh+InaC5aSB63CDROSh5TwsfaWJ2GDo+B9Ef1EhjhbIJUzQlXCsMc4LCk3bQxjHI/8nkcipB4jMCTcRQEEsyYW6QH7yvWKNYtaE/kMWxrvh7Ic5Q4PN8z21EjsjC" +
            "XYdrhK/vlOC03UrYs38MN4uhlHnrg1yfl1fUk7KKCT7huCL8YFwxF+zTl74d8AtKU+cpq2o8Mi4S3ZFN6wX8M2hpcmgMLF/RwEWXwcLFHRU/YTflYI+EMeJ8H3JE76ZTAih+xl+NccwpwC2k6gZRvS" +
            "4oZXcLcjRc6VPv2Wv+NHf9Hm9+UX3j3HPGLyTyW9iMPg2DR+IX7GU1FogfP4j4kPb5yVR8uWHEx23q9IyqSFMRJIiEJj+CignzSSWIBQlBaTyKiIpg0xEgi6qoYjOeZo6m86J90hEjG+5KwmaqFlUr" +
            "VoI8IRerVpwdDf4+RAKoN+PRie+yVfj2ToXccGA/irMU8QGoTlkeW1LL/QuqWF7t44S5PgrEjTBxtz6ctVdfijqZTF2Vsqyp9bvq3qtjkVTx9yFob9HkMYH6eo+pN3u8+XZRO/amfXG98ZSk9qGUUR" +
            "RqMW7KR2UdyYIP2OQNI1FA1IQ0Iod0WAAVnP1oTJSzgetJJ9V5DVC1NhBBsZzlv7me1RMWldePG37LvGs/vWTPf8YcUdUeUOjSRRhbPAFbMNhqzDYKHhdCnx8yTU5dWrS5kKB4K93w1CBBoN+EPs+V" +
            "iF2O2OXWuitEqAZVUZMQ8YeADEfNCBUZYAVXAgMgDV6sWNFASxEum2VCRFYUCVOpg5oyxYJYUbUotsgYOQz4W77nNiJn1AEdvnMSgdF93ayKn/kbktw1r4qXVtaT9DWz3q4Kha7wsz1K+OnuJR0yTG" +
            "zJmtqmFWA5p77dr9iwXsDfvLeXMcqjT9Tzl0cLaWPsfBAFyRMYlvwRw5096RsvwTVBWWgGTeHHbFZTOyMiNqdDAihx1uMJtf7lGlifN1c6XhKq1gV9vgrSNkHZ/xD7yn7ra717B01//9Yf7zPg3t8c" +
            "M6KK7NwtqNUgCJ3tUXfFuc08e5Ixqwu+Ym2sAOt6pHt6aabUHcIydxoND8NWF02WvALx4wAp8N5X4/1dJfWSSGoRsfWV752/d13T9z38l+/Hk6khxWJjO6HxQ0Sc7yjmUIuUAH4gfILsaSto4A6t0r" +
            "gkZsNfnw1bjRkUG3SVx2LUHHzBlCX9b7tmzIYumMaIrqcSKOvwqxUeXVLLkGKHr+5YSL9OdGmvSSmPL63hvo+DqE+6wguCSFNJXDhnr76cvGsfYllaZltZ41Gdsl0VAdrU7le4/miCru6NGAOfftbA" +
            "L3/tkky2JXpnv83guhvYzXyJsqLQCyP8p2ZnW4kF556IiJzSbgFUcNasElX/OuA8tpZM56egeh2oD4mSdu2/PSg6qC6lU+9/t3yPV5dVT3vvnPGfkoUlMT9XrTByNhON7LLue4PwCw5QG7Ooq9iMuW" +
            "F6qSuM/ITOzNYRcELbnnTVVxD1UfEXqCTvUlP9xPsXj9ymwdfLF+2TBJKEXZu/evOKhzzte4QSO0cxh1twELGSkZaZ2QjL5kUCESRhNEgJG4yhGOtgxorIbkTNUXspWgHs1NFXi8Dy6hTXvVnBn/tV" +
            "8+WhCQ4eXMCu/eLtEkMfbkgyc34lL6wIoj5N9Y1V6FdguGjfUo4f2yerFRjLqjw8q11RAQbBd7S9fB0Y3ewRay33PuCxcHGrhrgOYiexc+0UdisoIx5rcQ5oihIItPVA2gSumMBqJQoHRWSVdgmggk" +
            "mP7oDqTcDptBZtsT5Urw/jxSXkMP4R96ye+kl53a473vLBNSsu3/vfEPgQb49LYq5fuqfaglHWupZ0d/dMno+roo2tLkhHfqyQ7vMV9KnAU5P6q5rqm96/eMdPOjKOF6/YsQZ4+qtTK173ncRZKs55" +
            "FikTET/I+4HGZbC0c3T4s4qoZASQWlWsmDJjOJRIAPVWVgH7dGYHItBglffKk8wtT/LgAmF03xgTBhXwpUEF7FoWY3CRs8Ulq1W1Pk99WsOfF1VvFvWBQPwMSBiu2L+MY0cXZ/VspsBnVV4mBtoFrG" +
            "7Xs6vWJFC+RdOTuDHw8YIGHpkVp/WTuz2TUbU/Z/dEIa67FR2zEXgFeA6YE46xqQDaEXCDfMGIiOzQZgFUMOnR4aC/Ao5r897VBm7OaqGwNKft0K1y8IZa78H+U+fedM4hgx+68cihdV1TUdq9MF7i" +
            "MGysWK1rG5OcHRVtUvKeyflJdy9tJn7q1Wm4I1VQfsuH5+5S1dnxvHh1vw3fvfmtmzax56cWd7pFhhqMb9OVYpApoSfTS17UESVYlrPiiKKoMYbDfjrli9/ec82Ius6MKaL7obAsW/tKC5dqT5m7Ps" +
            "nc9UkeXljN4CKHcaUxdusXY+e+Lv0KHKqSlnnrk7y6qp7FlalmPjzpK226tP6qCf04ZlR78nzbRm3KsqLaa/aeOaZ9c60yBtivxaOWWY/7rFrdatXX19mh7kbGF2xF/KSAZ4BfA68Ls7eUn1Te7jFH" +
            "RLSBNgmggkmzxoLeARzV7ndQC7UVwZ9FZS1y3bKLwrDalL31V6+u3usfizbd/PqZuy1nO6oSG/vAk6U0JA5TG2uy1OU0iQKFG04TV+dm4idpnfpf1hcvvuWTSQc1ZGtcT11xoAUePmJ6Tb2V2K+tmM" +
            "FBK3iVdOF8xudbwuKyQAqpE5ooalCPtrdxC8YC8/I91xFZRlkA2Q2CCI1f/pSvfF7lsazS419f1BEz4BjBVyUV9l3OmD00uUYrwbLXFfuX5UT8AGxKBk1Quyi24QML2vma/Wnq9i8Cq9ekeOppl1ai" +
            "P/2JJa9nN+mfWfZqRgUwHWSm8GSnb7YiItpLqyeb+Jmz9gHupyPiJ40q1G6E6g3t7fLeERIpq2e8v7rugZ1+Pu8QQn+J7mqtkU1iXv/dxY+PV+tagv5emnZ3DsWQBIIo7ceTTnw2AmKtk/x9qujzGd" +
            "kUP0156crix4z6k1GtVMGoCFaM+Ij4GLEY8VUyP6c3Txx8cdQ37iDfxL6c73mOyAmf0LjkkRMMZMrYfYWkr5mIz9Zybwxw8q59+O7O2e373JS1dR4bk2GdQO6pJZjr9nAATSv0HANvvOmxeElrhop6" +
            "LEOTh9AvsQXxsx64ALxbI/ETkS+2KYDik2Z9GeEBhcOapq52eKuvRKvXo76HKjndfKuHr61OPdRvytxTbn1lbUyCm702DdOzoeFxDrac/jK9oq9gC/oS+P9oOvk56OnlBC0mVFCCEndVIxKYHBo1qW" +
            "dSbsW0j87aL6fLS/0a1vxR1L9dVa0FoyJiCTZfDFYkEEIIvhjxxOAjeBg8jOuJ87VTp6zMldFURN7QxaBrs3CWydqmKKUFwteHF+a0Omt5tUdtpgIs58e1NpjrdrFHs5883/LPF8HzthldT+D4P2S4" +
            "MWzW1bcBuEGY/Qfh6e3g1jSiu7JVARSfNOso4AFaun52loZqj9qKZ4CPcn1wCiNrU/bX1/9rxdRDZy4YLEKbwk898Rs55r7n+oqfOAJ1JRQ+2pgDlClvb7qJqAGMUfEWek7VDR9dMDrnJeZPXD/Kj/" +
            "kNv0Z5RhXHBj0xAuGj6chPGBEKo0Fe+jEx6oszIRUvGpvv+Y7IMspKYFG+h9GSBl9ZXZvbqPXnVR4p2/n9tJGFwMp2vqaxOk8EKjZ6vDOn1dSCnSlK7Uvplpa+ZgH3dNkRR0RshS0KoPikWd8H7gWy" +
            "faHZAFxL1bofAKcAb3bBMRanrJ7/3qq6+0b8fN4E2rAk1hPzpmPJ/nuKLdgjs/ylDtiwsaiaMALkAMEyWCh+BLTWmvoZ8y8a3mV5Nf+8unSj8b1pqnyqKsYGTtKB9SEiPkIQERIsJhMd8lTUE2eoJ+" +
            "4R+Z7viOyy6JSRNcC7+R5HU4TAE2jm/EoWbcpNGzqrsLTS68qbrncXnTyyvUuNAzJ/MwY+/9zn8+Wt5o/uTgn9ibW8xqwCbhNmR4UMEXlnMwEUP3PWMcBvaOn42XnmAxNTys3Je06uSk6ZMAeYCLzQ" +
            "BccpVvWb62pSD/efOvfEP82tcEV6V16Q8YqPxMbKAtND06ynVzoKJOmfg04WAMaa1KP18dV/7erxvnR14RxR+ytVUqqI1aDdhlVIi6Am0SB8RKwYsYjri3PUiTdtyE1GakQ+eZ2OuBTnECPw3roGLn" +
            "l1PS8sr8u6R1iNZ/kirADrAuoJ5ri9NDY+FYFFi5Xq6tbuE3UYCd/ZfPnrWdC5XXXAERHbYvMIkHApMCyL72GBJ1BOSN51/N905vGZU0hyyoQFIKcDT3XFwaoytiZp7/zZ7M+u/cZ9i/q3dUmsuzP2" +
            "d68NFJv4GtYl6LflNBE+GSEU1rgIooKqOIpd7Dk1v1p43l55ueg4NvUQ6P+p4mrQ/FA0iAaJVYxVQiEk4qsRL1gOs56YCSm3YM98z3tE1nkfdFm+c39abiLKhxsauOy1cma8W5HVJbEN9ZbVtR7SNc" +
            "eyTOGDDgyzabRH+XSZxdpWl8AKcVqGzZLA34WnsjOBKumeOu2mJ0b5I7LPlpbA9mv3XrZOJco0VTk9OfP4j7f0hOSU/ZcBZwB/pGvSb/qmfL3s1WXVd4+cMW9PgrLQZsEgqwSNznsIbrLsILHx8aKO" +
            "TZe9S9Oy96ChKWEnClEVAUlZk7zrw4uG5TwXa2u8eHVxpWB/YYXVFjGqkhZBhNEgsYr4ivggVoMmqj5mB0/co/M977nCWovv+1ndrO26JJOOompXovynG2iezTYDbGqw3PdRJee+vI6XVtRhs3CGWF" +
            "XjsbE+bIKa++N4FWl3/g/Q5EbR95VVq9skYJJsJpJW0zEBtjUK6WA7JwfpFTe/EZ1jsw+PKquAcVnY90LgGqzzWOp339/mhy05ZcLq2DVzziPwhZhEJ7vUtwHjqx67uio1tmzK3Gv/fvK4pw8bVexb" +
            "RYygfrg41hMU0KAH73ecisKjjXWLUONn2lkQbioSiJ8g+hMYH4qj4r2Ycjc9nO/xF9evfbWqcOgfFC6xIBI2mZdQtqGBdrOgGraiDyvHvn3M9Oo7/3Zln7X5PoZsM3ToUCZMmICY7FjiqLUMHTo034" +
            "fVKotP2dkf94fPngN+DMTzPZ6WpKMG765r4NJXyzlxXAmnjC9hUGHHrcY+q/Ko97QrIhJJ4PnFPx7ZkQt/LemG174vlJe3pdO1rKEhrkGTnfThrQTWZfGYdiBwiW43xTjd/44gIudsSWg8QNDhvTWP" +
            "h23xHMIVqbuOf7+tL0hNmVARu/bdK1CtAi6mE52h24rCHrUp+/ujHlx425d36nPn/502bmOu3zPblFUduItoweGoG+gHwmgPImmnZ8WIaDpaLAJaYU3y1x9fOKoi3+N/9obh9r+mJ+9Wcb+lInuD+h" +
            "YJlwRCyRbcgQtI0C0MVDC7Y9wjgC7PX8o1hxx6KAcdfHDWLooKmCyJqZwj8iqqC4C98z2UreEIbGyw/O7DTcxZV89Ze5Xy5aGFHerj9VllCk/Jal+xrbAA5dUOvnYDaQGkCnV1bbpB/Ygqu5GU368x" +
            "EboCNJnFY9qNpvlJ0Oa1rSEkcn2THdED2OysqOjtwO0EFuXtpQa4FdGT2yN+0qRu3L8WqzcA1wFdZY7VP+Xrda98Vn3nqBnzdhERvyetD7te8bfFujuiRrHNzA0zeT+h+JFQFBkr3mM1Rcu7Ivm8Tb" +
            "xyZXypqP2tKg0aJkMrIlaabEFlGBbSidJFVpzj/3t6ZatW/D0NYwyu6+JkaXNdt8cIoEUnj1yl8PdusOq1zS0ITsJba+q56NVyfjW3gnV17QuuJK3yaWUqdBzK+ZifXnTqqFUd/LWsyPwtMwGts4Sa" +
            "2EdUeU1Uic1a9s2mtS5wBE13qFj81p12DWJHUNjSxTqKCG2HbHZW9GaeUK3KNcBNBKHPtvIZcJaqvSp11wnlHR1QatoBSbXOrcClBG6hXYHjq56wqjr1cL8b3/22Ve0RGmjs7fMGiZ84BuuaTJl7uP" +
            "wVlLwHIkgxoqQ9f+yn1mm4c+nZe+emrreDuJr6K+iLCiZMPUVVwtL4dIk8YkWwIljEWsxXUiaxf77HHpFt9DHQ1fmXOa1vRqCi3mfm/E2c/8o6/rOq7blBmxosX1SnusIAcTXoo534hTS2zhCBgnib" +
            "xEI1njuLFT5o+vmlZCu9QdgdOLzZuFJJS3V1qwKoBNeOpLDlMTQQiaDtji3eFnp3H1+n2GnAlcCmNuznReAHqZnH/8G7+8ROX1i9afv6qSkT7gbOpv2mXR1Glf2qU3r/vCUrzlHVbpeD0JKY3+8bYu" +
            "N7gONn8n4yOUCZfJ/0Jgq+Nf498y8ZOD/fY2/JS1cVbhS1tym6QTUjekLn6lD8pBOjg7+rLzLQF+eko67d0DPCGxFtQoQPgGfzPY52jBeAN1bXc+Er6/jNBxvZUN96NGhZVYrVNX4ue0SneVZEO5N8" +
            "/A7pFQHHKP37t9XDR/7KytgHVCbDYMtQoH+nj6ZqtQFOp2m1sgis3wCrVreaujGUAm8EhS0NGitButVNYUTu2eqFw5t5YkpT3h2qer6qrlNVtrDVq+pvFT0pNfP4rJsapqZM+Isq/0+VpblundFkG9" +
            "yQ9M72fH9wvn8522LcHR+XGj9xoqhTkBY6wVJXYHAYtLgI/X5UEBUH7NvW1D6U77FvjViy7gXQRxUM6d8HaREkGaPEoDpMA5Ekcoxf3GevfI89InssOnlnj6D/YFdFgLOCI0FZ+28/2MiFr5QzZ+22" +
            "W+q9sbqeykwLjJyxAbh/0cmjO2M2NIf078JxYOiQNteHrKI+Po2Ffi2eTyBYxnf6iNQcBZzc7DEjsOATj7XrWs1I35dSO4B4y+etEZ7sMkOmiO7BNu+cvXt/aL27T3gQOBNY2uKfvwAuUMzF3swTOr" +
            "q23Cre1AnPAKcRGCl25bx06y7ybkPZkcbGDgBjJSN4AtEjmRW8IPIjiFG0yprk7R9eMmhNvse+NV66riSFtb9R1cUKjoKoarg1DeoHTtFWUasM9zEnf2/ypz1i2TKijQhvoPytG6xytWsTAuH+6spa" +
            "zv/3Wu75cBMbGzZfWVlWleKZz2qCxaHcjukpkDc6+dv4hPT5V8QwYniMti8XyWOsTPyCxfU+Wgh8q1MjqVy7JzCdlpEk37c89w9IJls7b9uvMpAt9Cf7rJNzFNEDadPSgXf3CY8DxxF88P4I3Az6fe" +
            "/uE+727z4uJ53Dm73/1An/Bk4FOvtF7hWMu31RmWMTE0WdYlHRTAQoEwXKJDyHFWEYFe+JBnfd0/kee2u8flVsPqp3WDSlGU8gsJuJoIwQwoo5YWPJ8H3zPfaI7LH45J1ToHeCrsy7qulgbtCqGo9b" +
            "363gnJfX8NiSaj6tTFFe7/PRhiS3zNnAoo1JjOR0HCtB71x8yqjOLe30HVQF/AMI1N0u4yxFRW3Ol/FR5yYWxm9lcW099jvKcbt2aByVa/cF7gb2afa4MbBwSQPPPNfq8tcQEqnDGdhSJDUQiLyI7Y" +
            "w2J6R5d5/wHvCeO+kvjnfXiV1uIuVNnfCue/WcU4HfAl/v6vfvTsRTZUcbjR0UpsaEUR8al7yAUBAJKo6KXWKdhl8vvGhMzsVqNjDq/8FX52gVvgmimWNSldAWSJvkTaiqjFAxPzvy5spz/3VF3yiM" +
            "3Usw4r1j1X2QIBexx2EEfFVeW1XPO2vqGVjo0Cdm2NhgKU+bH+aWB9T138nSvp4HLsTaIYwa6TJ0iMeSpW2+ftRjY9ewwCyiZseJ7HS6Mv5K4eO2iajKtQXAsQT2LM2X0ATwPJ+Zv/dZsbLVitCvMs" +
            "AbS3GiRf7PGiIBtF3S7uTRfIifzHtPnbAQ+AnwZL7GkG/G37Z8mPET/w81ibDEvanHDxC4PUtoE69og0rq9vmX9ut2ic9b47XJ8QqDTgdZo2ACd2jCyjAIW2WIVUQDpzVVMcelpPiIfI99m3RBtmtv" +
            "GuPCU3ZR4C7g7XyPpTM4Ar7CqhqfRRtTlNd1ifh5B5i55KRxbc7XaYUPgedRhYEDXfbZq93XgRTWuZdlRSfy9sT+R4+9ANXRNGzauoiqXFdG5dpvEOSD3ceW8oeMozzxVB1/eiRBKzX2CYx3EiPEwb" +
            "SMAM0HlmdpniJ6ED3ODMqbOuFzd/KcMxE2atBRPusVQEHibfj3bJ0+soST6jPRqLtvYB2Svlqle+JIYKDT+LODeI977qY/5nvc7WXnmkUvL+mz6x2KXC9BabwoGfuVzA1cOAmqMFBULvqvm5Jvv3JV" +
            "vC2Vi12LKqlUqlu3pTDGkEqlutWHfvGpo78Y++DSWwgugiX5Hk9n6IhRYgepAm5efOroL7K2x76DPCrXPgAcS0G8jK8dAY/PtnTg/LuS+kHMe28aT/zlNL591Hyq1r2P6rJw3C4wCNgN9CACQ8w+W9" +
            "yR4yj/erGWydfFqKlt9Vr2FQY2HMHAghbRH4AXhNndqglvRNfQ4wQQgDdtwhrnmncuQGUTQal8To6jG10HANhjRvkhxsZPRcUhsMZpku2cifqkHzIqdpE1Dbd8dPGw6nyPvb38aep4PXha6i41zmEq" +
            "chSNZ63mQqgRVZEjxTinEhh5dhtEhPLyci447zwKCwu73wercaDU1dVRXl6OdKNIkBjzlFp7D+iF+R5LD+FeFZOLBtOvAU9g7Wn815cddtwxxYoVHXPs/2J5ggsv2436hrF851sn4ji2yZ1BS5PC5h" +
            "gTLHs9PruOydfFWLmq1TEU4aTOY7QU47pbWP76Vw7mKqIH0H3Och3AufqdQpArCUwTs+YI7LoxBg8dhutmXVfp0p+UdShiNf6XKwbEUqX3irpHht6AQcVJ86hP+LAYoMaa5AUfXF7U46I/TTnoJu9g" +
            "Nc4jwEjCM1fLD206Qyhsd/+5qD3+tSudtzrzvgPKyrKuUnzfR7ur+AkRERwn+wWQ6zdu7NS5ZuyDS4YBDxO4/0ZsnZdRfrR44pjc+KcFicizUd2J8y+p5oGH+nRqfyV9PE79cT0/+4nLzqPiGGNQ2z" +
            "wMH9Z0BElV1rJ4SZKZv/f44yMJamracpLWUxhR+3v2TcQ3X/56BDhVmJ3NFh0RPYQeLYAAnMnvxEHOQ7gG6JuNfXY3AbTT3c+b0k2HXGls/BJBDEFlVGggK4iE7dPTy2CAGu+OVFH51R+dO7zHf7EP" +
            "mm5PtyK3A8UtIz9b+ACLqD5r1D/ltatiHXYkz4UA2p7prAACGPvgkoNQ/gzsnO/j6ZYInwI/WnzqmNxWy1auvQDHmcF/Xk9x3A9dKqs60zcSQBm5U5L/PtrjqK8Lu+1q6Ns3RjwWfAeTKWHTphQfL7" +
            "A8/w/L35+N8cXyOG28fo2huP7vHMxulLRMfq4BThRmd/vq2Ijc0OMFEIBzxdsOrjmNoEx/YGf3l0MB5C39SVm7TxZ7/Xzj/xqbuE0wpYBqUPEV/L9R+BD8iavi/913qs+Yf+mADguA7sTBU+vj1olP" +
            "VZGLCaI8zXqVbOFDrIL+okCSk1++PNGhEuBIAGWXbAgggDEPLPkBcCfQL9/H1M2oAM5aMnHMIzl/p01rSzByN6nUD5h0Xi1/ebRDHdm3gJJI+AwZ7DNkiNKvLIkIbNgQZ9VqYfUal4aGdoUni3BS97" +
            "Bv8oeMKN5C7s+TwEnC7Pa0fIroRfSKFgL+zV/y/akT7gHOomnjvg6R9tDIPqq6rr2v2XPGxoONJq4TTBkqqmGpe1jilU6CTv/HRezb1iSv6i3iB+CNqxNJY/3pYnVWk+TnDFtwQDGKnN1g4z/7+iUr" +
            "e4XIjwhQI38FbgTa2o5he6AOmGKt/LVL3q10UBWq11BQ8BZnnxljhx2yFWUW6utdPltWwBtvJnj2+b4881xf3ngrwbLPC9orfgTsRYxpOIEdC7dwTt8A/CYSP9s3vUIApfGnTpgVtM7QJVtp3dGGrU" +
            "kLhixvvrXtKufdc0bFXo5fMEOsGR36AEroitMk6tOk4gtd4EvDJfMuK+l1nhZvTI5VoHoZqv/EBkt+25CqqlBkRW6oHjD4R/kee0T2WHrKaBsaJN4Cmsy34WE32JKgMwR756enj+668sK+g5Zg7Xns" +
            "t/cizviJT/drJGpPY6faKxiXcIKcyJbcD7yc70FG5JdeJYAA7LQJzxK0zuhM87+so6prfN+/s63P33PGhvGOn7gNdfZTsE0VTzPPn+DvDtil1iQvnHd5Sa91y35rsvM5qmcr+qoqZIRQsDW7LIR/DF" +
            "Axtx483T8u32OPyB5LJo5NArcAtwI9PsetEySBXwA3L544rutNTkt2eItY7GxOP3UxXzuiOzUStScxvOZW9iwoJralPIbXgNuE2XnztIvoHvQ6AQRgpx3wCkHrjNfzPRYAVd3g+/71Kz779P/a8vw9" +
            "f16xk+MX3SrqHiSIlUykp6nwyeT9uGAXq6TO++Dy4hfyfay55u3JzkJR+zPQVzKFIs36YjQTRWqVIRbzywOn+9u1e3hvY8nEsfXAVOAmts/lsDqCnMcpSyaOzd/xJ/q9zKiRZ3DphW+xcydbbmQBB/" +
            "EnsXPtHeyd6Ee8Zcd3CFIkrhJmR8aHEb1TAAHYaQfMBSaS7mGTB1S1zlr7nO95PypfueZ33HJQq8lFu/9qTR9jE5NFncPDVhe0sOdtkvCsroo/z0ryrPevKPpnvo6zq3l7svuxoD9BeD5sdh9sNKme" +
            "zVhHgyojVM30g6b5Y/M99ojsEV74pxO0ytiQ7/F0IRXAVSg35VX8pDFFr/Otb/2U006eRWlp3iJyZcSSNzG+7pfsUVi2ZfFTCUwWZkdLXxFALxZAAHbaAenWGY915fuqao219m++7/2wrr72+C/O3O" +
            "H5uhv2aNMauZvs80OD+71Gv7+M4IFmljeIYl+ykvzpB1cU/7srj6878PZVziKwPwH9owadBmjaEURbCCOEA6xIZKTXy1gycWzSNf5vgEmoLm1M4uu122fA2Z7r3r7ktLHdZ/lPChYy+fKznJ1HXR/H" +
            "VHTxu9sJlNX9mQO8SxlXlMBxtiB+aoDrgIfyPVUR3YftokLGTJ6zA+jNGkSEWhV9QRn8jsRibjtNe7XSWv2Htf69DQ31L687f0S7Kwz2vbnhLdTZncw3WGhe9S0GtEHFPmKlfuq8y/t2suqtZ3PgTV" +
            "5fi7lQkQsRSlv+e/MPuJa/c6XZoS37jcrgs0u2yuC3xZj7Fx0E3EzvNUt8GbhiyWnjum2e32QGmhUUnfwJVVPeZdPwhiB9MVfoYAqSpzPSO4edY8MojG+lLGITcB3Ib4Uno2bJERm2CwEEwFVv9xWR" +
            "64BzgW168aQFUFt9gFS1QtU+5/v23vq62v+sv2hkh/vK7Ds9tTFIagZoUeauOIh+ruL90nfr/jD/kn5RCSdw0LSk4xv3u4rcAOy1jad6c66UNvkwRQIou3SFAAIYff+iYQIXAz8lS8ao3YAqgmagM5" +
            "acNq7b3/AoKov5xvdepPzGR1g+9jUqnHr8bJqq6RASyf9hSOoMRrn7UloQtgTc0nO/AK4C70/C092tUi0iz2w/AgiQq98tRO3lwGVA4dae11YBpKrlqvZvvu/fX1dT/eaGS0Z3OiS9z80NL4s6E5r1" +
            "+VIArULsC2q8X71/eVGn2jz0Vg64yR+nyMUg3weCSE/jJ9wX9Ml3rjRtqgiLBFB26SoBBDDmwcUxrB4DXA4cmO9j7yTvALeoyuylp4/Ne5Jxe1D+9+AK6m54gw2HPcYqXmSd+Zy6mIca2n/tsSW4/h" +
            "6UpI5hiP0fhrrjKYkHzvhb/aq+QpDz80q+5yKie7JdCSAAc/U7MVXOBa6FzZdMoHUBpKqr1drZvvXvr62snFNx+dishVX3url6f6Px80G+LJAAXQ/MUbFPWqf2hXmX9u9xjU27kgNvbIhbN3Yo8H1F" +
            "vgQ6GGQ98IwR+7u3r3TadAcdCaDs0pUCKM2Y+xcNByYRLH0Py/cctJNVwAPAXUtOG5e9ru5djPL9waBnK/anK6gb9C6bkv9hvf8+lc5SanQjXrwGT5NYDSs+cBAtxJhiXH8IBXZX+tgD6cch9De7Ux" +
            "LrS8xhi/2QM6wD7gVuF2avyvccRHRftjsBBMDkt40gpxJ4iWyWExKLxRk8dMfNmkKq6nJr7ePW9x8sX7/y/YZr9o18JHopkQDKLvkQQADj731fkqbwAGCSwneBAfmei1bYAPxN4M6Ym3p7wcl79PjP" +
            "oc8xYjAHg5wDfAcoTeJrBanURlKyjoaGKjybxAoIhRjtRzw2kLjbn5iW4LoGE+ZubnM6qoDngNtBXhOejJa8IrbJ9imA0gc/+Z3/BW4DhqcfU4W+paX0G7BDZnJU9TNr7Szf9x5aueCD+dz+jR5/Uo" +
            "rYNpEAyi75EkBpdr5vYUyEgwlMUr8NDMn3nLRgDfAs8IAVef2zieO6T4VXllCOLQAOAU4CvgmMaGHxscVXtYHlwL+Ah0FfEZ7qcA5mxPbFdi2AAJg855sCt4rIXiJCYVERZf0G4LiuVdVF1to/+773" +
            "yKqzBve69hIREdsbY+77xFWRvYHjgKNRxgPxPA0nCSxAeJrAquP9paft0uurlJRjHWAsQbXekcA+wFCgmNardJWgpH0Vgdv/S8ALIAujCq+I9hIJICAx9aM94rH4pIJE4rB4QaLUcZw11trnfd97eN" +
            "VZgxfme3wRERHZZ/R9i4aCHgYcBRwGjAQSOX7bemAZ8AbwNPCfpafvsjLfc5EvlGPjwI7AeGAPYBeCiHw/Gn8XDQTmj8uBRcCHwMfAcmF217cAieg1RAIoIiJiu2b0/Z84qAwD3YtgieYAYBwwiLZF" +
            "JbaGD9QCawku3O8RtOeZC2bl0tPHRTmEERF5JBJAEREREU0Yc+8nxSoMI1im2RXYjSA6NIQgMlFKEJ1Ie0qlCCI7mwgiFasJojwLgE+AxcDKpafvWpPvY4uIiIiIiIiIiIiIiIiIiIiIiIiI2H74/0" +
            "AVJEB3mwgwAAAAAElFTkSuQmCC";

        private static Image _sheet;
        private static bool _loadTried;

        public static bool Draw(Graphics graphics, BrandIcon icon, Rectangle bounds, bool enabled)
        {
            if (icon == BrandIcon.None || bounds.Width <= 0 || bounds.Height <= 0) { return false; }
            Image sheet = GetSheet();
            if (sheet == null) { return false; }

            int index = (int)icon;
            int sx = (index % Columns) * Cell;
            int sy = (index / Columns) * Cell;

            InterpolationMode oldInterpolation = graphics.InterpolationMode;
            PixelOffsetMode oldPixelOffset = graphics.PixelOffsetMode;
            CompositingQuality oldCompositing = graphics.CompositingQuality;
            graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
            graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
            graphics.CompositingQuality = CompositingQuality.HighQuality;

            if (enabled)
            {
                graphics.DrawImage(sheet, bounds, sx, sy, Cell, Cell, GraphicsUnit.Pixel);
            }
            else
            {
                // Disabled cards keep the mark recognisable but muted.
                ColorMatrix matrix = new ColorMatrix(new float[][]
                {
                    new float[] { 0.299f, 0.299f, 0.299f, 0f, 0f },
                    new float[] { 0.587f, 0.587f, 0.587f, 0f, 0f },
                    new float[] { 0.114f, 0.114f, 0.114f, 0f, 0f },
                    new float[] { 0f, 0f, 0f, 0.55f, 0f },
                    new float[] { 0f, 0f, 0f, 0f, 1f }
                });
                using (ImageAttributes attributes = new ImageAttributes())
                {
                    attributes.SetColorMatrix(matrix, ColorMatrixFlag.Default, ColorAdjustType.Bitmap);
                    graphics.DrawImage(sheet, bounds, sx, sy, Cell, Cell, GraphicsUnit.Pixel, attributes);
                }
            }

            graphics.InterpolationMode = oldInterpolation;
            graphics.PixelOffsetMode = oldPixelOffset;
            graphics.CompositingQuality = oldCompositing;
            return true;
        }

        private static Image GetSheet()
        {
            if (_loadTried) { return _sheet; }
            _loadTried = true;
            try
            {
                byte[] bytes = Convert.FromBase64String(SheetBase64);
                using (MemoryStream stream = new MemoryStream(bytes))
                using (Image loaded = Image.FromStream(stream))
                {
                    _sheet = new Bitmap(loaded);
                }
            }
            catch
            {
                _sheet = null;
            }
            return _sheet;
        }
    }

    /// <summary>Primary call-to-action card: icon tile, title, one-line summary, chevron.</summary>
    internal sealed class ActionCard : Control, IAnimatable
    {
        private float _hover;
        private float _target;
        private bool _pressed;

        public string CardTitle = string.Empty;
        public string CardDescription = string.Empty;
        public string Glyph = "\uE753";
        public BrandIcon Brand = BrandIcon.None;
        public Color Accent = Theme.Blue;
        public event EventHandler Activated;

        public ActionCard()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            TabStop = true;
            Cursor = Cursors.Hand;
            Height = Ui.S(Ui.CardHeight);
            Margin = new Padding(0);
            BackColor = Theme.Bg;
            AccessibleRole = AccessibleRole.PushButton;
            Ticker.Add(this);
        }

        protected override void OnEnabledChanged(EventArgs e)
        {
            base.OnEnabledChanged(e);
            if (!Enabled) { _hover = 0f; _target = 0f; _pressed = false; Cursor = Cursors.Default; }
            else { Cursor = Cursors.Hand; }
            Invalidate();
        }

        protected override void OnMouseEnter(EventArgs e) { AnimateTo(1f); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { _pressed = false; AnimateTo(0f); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left) { Focus(); _pressed = true; Invalidate(); }
            base.OnMouseDown(e);
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            bool activate = _pressed && ClientRectangle.Contains(e.Location) && Enabled;
            _pressed = false;
            Invalidate();
            base.OnMouseUp(e);
            if (activate && Activated != null) { Activated(this, EventArgs.Empty); }
        }

        protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
        protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }

        protected override bool IsInputKey(Keys keyData)
        {
            if (keyData == Keys.Enter || keyData == Keys.Space) { return true; }
            return base.IsInputKey(keyData);
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if ((e.KeyCode == Keys.Enter || e.KeyCode == Keys.Space) && Enabled && Activated != null)
            {
                Activated(this, EventArgs.Empty);
                e.Handled = true;
                e.SuppressKeyPress = true;
                return;
            }
            base.OnKeyDown(e);
        }

        private void AnimateTo(float target)
        {
            _target = Enabled ? target : 0f;
            if (!Ui.AnimationsEnabled) { _hover = _target; Invalidate(); return; }
            Ticker.Wake();
        }

        public bool AdvanceFrame()
        {
            float diff = _target - _hover;
            if (Math.Abs(diff) < 0.02f) { _hover = _target; Invalidate(); return false; }
            _hover += diff * 0.25f;
            Invalidate();
            return true;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics graphics = e.Graphics;
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle rect = new Rectangle(0, 0, Width - 1, Height - 1);
            int radius = Ui.S(Ui.RadiusMd);
            int pad = Ui.S(Ui.Space4);
            int tileSize = Ui.S(40);

            bool enabled = Enabled;
            Color accent = enabled ? Accent : Theme.TextMuted;
            Color background = enabled
                ? Gfx.Mix(Theme.Surface, Theme.SurfaceLo, _hover)
                : Theme.SurfaceLo;
            if (_pressed) { background = Gfx.Mix(background, Color.Black, 0.03f); }
            Color border = enabled
                ? Gfx.Mix(Theme.Border, Theme.BorderStrong, _hover)
                : Theme.Border;

            Gfx.FillRound(graphics, rect, radius, background);
            Gfx.StrokeRound(graphics, rect, radius, border, 1f);

            Rectangle tile = new Rectangle(pad, (Height - tileSize) / 2, tileSize, tileSize);
            bool brandDrawn = false;
            if (Brand != BrandIcon.None)
            {
                // A neutral plate lets the full-colour mark stay legible; the
                // faint accent wash keeps the tile tied to the rest of the UI.
                Color plate = enabled
                    ? Gfx.Mix(Theme.Surface, accent, 0.04f)
                    : Theme.SurfaceLo;
                Color plateBorder = enabled
                    ? Gfx.Mix(Theme.Border, Theme.BorderStrong, _hover)
                    : Theme.Border;
                Gfx.FillRound(graphics, tile, Ui.S(10), plate);
                Gfx.StrokeRound(graphics, tile, Ui.S(10), plateBorder, 1f);
                int iconSize = Ui.S(30);
                Rectangle iconRect = new Rectangle(
                    tile.X + (tile.Width - iconSize) / 2,
                    tile.Y + (tile.Height - iconSize) / 2,
                    iconSize, iconSize);
                brandDrawn = BrandIcons.Draw(graphics, Brand, iconRect, enabled);
            }
            if (!brandDrawn)
            {
                Gfx.FillRound(graphics, tile, Ui.S(10), Gfx.Mix(Theme.Surface, accent, enabled ? 0.09f : 0.04f));
                Gfx.DrawGlyph(graphics, Glyph, UiFonts.Glyph, tile, enabled ? accent : Theme.TextMuted, Gfx.Center);
            }

            int textX = pad + tileSize + Ui.S(14);
            int chevronSpace = Ui.S(38);
            int textWidth = Math.Max(Ui.S(40), Width - textX - chevronSpace);
            int titleHeight = UiFonts.H2.Height;
            // Two lines maximum; GDI ellipsizes the last visible line cleanly.
            int descHeight = UiFonts.Body.Height * 2;
            int block = titleHeight + Ui.S(4) + descHeight;
            int top = Math.Max(Ui.S(10), (Height - block) / 2);

            Color titleColor = enabled ? Theme.Text : Theme.TextMuted;
            TextRenderer.DrawText(graphics, CardTitle, UiFonts.H2,
                new Rectangle(textX, top, textWidth, titleHeight), titleColor,
                TextFormatFlags.Left | TextFormatFlags.Top | TextFormatFlags.NoPrefix |
                TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding);

            TextRenderer.DrawText(graphics, CardDescription, UiFonts.Body,
                new Rectangle(textX, top + titleHeight + Ui.S(4), textWidth, descHeight),
                enabled ? Theme.TextMuted : Theme.TextMuted,
                TextFormatFlags.Left | TextFormatFlags.Top | TextFormatFlags.WordBreak |
                TextFormatFlags.NoPrefix | TextFormatFlags.EndEllipsis);

            int chevronSize = Ui.S(18);
            int chevronShift = (int)Math.Round(_hover * Ui.S(2));
            Rectangle chevron = new Rectangle(Width - Ui.S(18) - chevronSize + chevronShift,
                (Height - chevronSize) / 2, chevronSize, chevronSize);
            Gfx.DrawGlyph(graphics, "\uE76C", UiFonts.GlyphSm, chevron,
                _hover > 0.01f ? Theme.TextSoft : Theme.TextMuted, Gfx.Center);

            if (Focused && enabled) { Gfx.FocusRing(graphics, rect, radius, Theme.Focus); }
        }
    }

    /// <summary>Rounded modal confirmation with Enter/Escape support and measured height.</summary>
    internal sealed class ConfirmDialog : Form
    {
        public bool Confirmed;
        private readonly PillButton _accept;
        private readonly PillButton _cancel;

        public ConfirmDialog(string title, string message, string acceptText, Color accent)
        {
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.CenterParent;
            Text = string.IsNullOrEmpty(title) ? "Sailuo Dashboard" : title;
            BackColor = Theme.Surface;
            ShowInTaskbar = false;
            KeyPreview = true;
            AutoScaleMode = AutoScaleMode.None;
            Font = UiFonts.Body;
            AccessibleRole = AccessibleRole.Dialog;
            AccessibleName = title;
            AccessibleDescription = message;

            int width = Ui.S(470);
            int pad = Ui.S(Ui.Space5);
            int titleHeight = UiFonts.Section.Height + Ui.S(4);
            int messageWidth = width - pad * 2;
            int messageHeight = Gfx.TextHeight(message, UiFonts.Body, messageWidth,
                TextFormatFlags.Left | TextFormatFlags.WordBreak);
            int buttonHeight = Ui.S(Ui.ButtonHeight);
            int height = pad + titleHeight + Ui.S(Ui.Space2) + messageHeight + Ui.S(Ui.Space5) + buttonHeight + pad;
            ClientSize = new Size(width, height);

            Label titleLabel = new Label();
            titleLabel.Text = title;
            titleLabel.Font = UiFonts.Section;
            titleLabel.ForeColor = Theme.Text;
            titleLabel.AutoSize = false;
            titleLabel.BackColor = Theme.Surface;
            titleLabel.SetBounds(pad, pad, messageWidth, titleHeight);
            titleLabel.TextAlign = ContentAlignment.MiddleLeft;

            Label messageLabel = new Label();
            messageLabel.Text = message;
            messageLabel.Font = UiFonts.Body;
            messageLabel.ForeColor = Theme.TextMuted;
            messageLabel.AutoSize = false;
            messageLabel.BackColor = Theme.Surface;
            messageLabel.SetBounds(pad, pad + titleHeight + Ui.S(Ui.Space2), messageWidth, messageHeight);

            _cancel = new PillButton();
            _cancel.Text = "Cancel";
            _cancel.Variant = ButtonVariant.Secondary;
            _cancel.Font = UiFonts.Button;
            _cancel.AccessibleName = "Cancel";
            _cancel.Click += delegate { DialogResult = DialogResult.Cancel; Close(); };

            _accept = new PillButton();
            _accept.Text = acceptText;
            _accept.Variant = accent == Theme.Red ? ButtonVariant.Destructive : ButtonVariant.Primary;
            _accept.Accent = accent;
            _accept.Font = UiFonts.Button;
            _accept.AccessibleName = acceptText;
            // DialogResult is what ShowDialog() returns - without it the accept
            // button used to close the dialog as Cancel and the action never ran.
            _accept.Click += delegate { Confirmed = true; DialogResult = DialogResult.OK; Close(); };

            int buttonY = height - pad - buttonHeight;
            _accept.SetBounds(width - pad - _accept.Width, buttonY, _accept.Width, buttonHeight);
            _cancel.SetBounds(_accept.Left - Ui.S(Ui.Space3) - _cancel.Width, buttonY, _cancel.Width, buttonHeight);

            Controls.Add(titleLabel);
            Controls.Add(messageLabel);
            Controls.Add(_cancel);
            Controls.Add(_accept);

            AcceptButton = _accept;
            CancelButton = _cancel;
            Shown += delegate { _accept.Focus(); };
        }

        protected override CreateParams CreateParams
        {
            get
            {
                const int CS_DROPSHADOW = 0x20000;
                CreateParams parameters = base.CreateParams;
                parameters.ClassStyle |= CS_DROPSHADOW;
                return parameters;
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Gfx.StrokeRound(e.Graphics, new Rectangle(0, 0, Width - 1, Height - 1), Ui.S(Ui.RadiusMd), Theme.BorderStrong, 1f);
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Escape) { Close(); }
            base.OnKeyDown(e);
        }
    }

    // ========================================================================
    //  Layout primitives
    // ========================================================================

    /// <summary>A vertical block that can measure itself for a given width.</summary>
    internal interface ISection
    {
        int MeasureHeight(int width);
    }

    /// <summary>
    /// Scrollable page canvas. Arranges ISection children top-to-bottom with a
    /// consistent gap, caps the line length on very wide monitors and reserves
    /// the scrollbar gutter so a vertical scrollbar never reflows the grid.
    /// </summary>
    internal sealed class PageView : Panel
    {
        public int ContentMaxWidth = 1240;
        public int SectionGap = 20;
        public int PagePadding = Ui.Space6;

        public PageView()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.Bg;
            AutoScroll = true;
            TabStop = false;
            Margin = new Padding(0);
            Gfx.DarkScroll(this);
        }

        public void RelayoutSections() { PerformLayout(); }

        protected override void OnVisibleChanged(EventArgs e)
        {
            base.OnVisibleChanged(e);
            if (Visible) { PerformLayout(); }
        }

        protected override void OnLayout(LayoutEventArgs e)
        {
            base.OnLayout(e);
            ArrangeSections();
        }

        private void ArrangeSections()
        {
            int scrollbar = SystemInformation.VerticalScrollBarWidth;
            int padding = Ui.S(PageMetrics.PaddingFor(ClientSize.Width, PagePadding));
            int available = ClientSize.Width - padding * 2 - scrollbar;
            if (available < Ui.S(220)) { available = Math.Max(Ui.S(180), ClientSize.Width - padding * 2); }
            int contentWidth = Math.Min(available, Ui.S(ContentMaxWidth));
            int left = padding + Math.Max(0, (available - contentWidth) / 2);
            int gap = Ui.S(SectionGap);
            int y = Ui.S(Ui.Space2);

            foreach (Control control in Controls)
            {
                if (!control.Visible) { continue; }
                ISection section = control as ISection;
                int height = section != null ? section.MeasureHeight(contentWidth) : control.Height;
                if (height < 0) { height = 0; }
                control.SetBounds(left, y, contentWidth, height);
                y += height + gap;
            }

            AutoScrollMinSize = new Size(0, y + Ui.S(Ui.Space4));
        }
    }

    /// <summary>Small section heading with an accent tick and optional meta text.</summary>
    internal sealed class SectionLabel : Control, ISection
    {
        public string Title = string.Empty;
        public string Meta = string.Empty;
        public Color Accent = Theme.Blue;

        public SectionLabel()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.Bg;
            TabStop = false;
            AccessibleRole = AccessibleRole.StaticText;
        }

        public int MeasureHeight(int width) { return Ui.S(30); }

        public void SetTitle(string title, string meta)
        {
            Title = title ?? string.Empty;
            Meta = meta ?? string.Empty;
            AccessibleName = Title;
            Invalidate();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics graphics = e.Graphics;
            int metaWidth = 0;
            if (!string.IsNullOrEmpty(Meta))
            {
                metaWidth = TextRenderer.MeasureText(Meta, UiFonts.Small).Width;
                Gfx.Ellipsis(graphics, Meta, UiFonts.Small,
                    new Rectangle(Width - metaWidth, 0, metaWidth, Height), Theme.TextMuted);
            }
            int titleWidth = Math.Max(0, Width - metaWidth - Ui.S(Ui.Space4));
            TextRenderer.DrawText(graphics, Title, UiFonts.Section,
                new Rectangle(0, 0, titleWidth, Height), Theme.Text,
                TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix |
                TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding);
        }
    }

    /// <summary>
    /// Responsive grid of ActionCards: 1-4 equal columns depending on the
    /// available width, capped at a comfortable maximum card width.
    /// </summary>
    internal sealed class CardGrid : Control, ISection
    {
        private readonly List<ActionCard> _cards = new List<ActionCard>();
        public int MinCardWidth = 340;
        public int MaxCardWidth = 540;

        public CardGrid()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.Bg;
            TabStop = false;
        }

        public void AddCard(ActionCard card)
        {
            _cards.Add(card);
            Controls.Add(card);
        }

        public int ColumnsFor(int width)
        {
            int gap = Ui.S(Ui.Space3);
            int min = Ui.S(MinCardWidth);
            int columns = (width + gap) / (min + gap);
            if (columns < 1) { columns = 1; }
            if (columns > 4) { columns = 4; }
            // Short lists read better as a balanced two-column block; wider
            // grids are reserved for longer catalogues like Applications.
            if (_cards.Count <= 6 && columns > 2) { columns = 2; }
            // Avoid a lonely single card on the last row: if the grid would
            // leave exactly one card behind, prefer a narrower layout that
            // balances the rows evenly (e.g. 4 cards -> 2x2 instead of 3+1).
            if (_cards.Count > columns && _cards.Count % columns == 1)
            {
                for (int candidate = columns - 1; candidate >= 2; candidate--)
                {
                    if (_cards.Count % candidate == 0) { columns = candidate; break; }
                }
            }
            return columns;
        }

        public int MeasureHeight(int width)
        {
            if (_cards.Count == 0) { return 0; }
            int columns = ColumnsFor(width);
            int rows = (int)Math.Ceiling((double)_cards.Count / columns);
            int gap = Ui.S(Ui.Space3);
            return rows * Ui.S(Ui.CardHeight) + (rows - 1) * gap;
        }

        protected override void OnLayout(LayoutEventArgs e)
        {
            base.OnLayout(e);
            ArrangeCards();
        }

        private void ArrangeCards()
        {
            if (_cards.Count == 0) { return; }
            int width = ClientSize.Width;
            int gap = Ui.S(Ui.Space3);
            int columns = ColumnsFor(width);
            int rows = (int)Math.Ceiling((double)_cards.Count / columns);
            int cardWidth = (width - (columns - 1) * gap) / columns;
            int maxWidth = Ui.S(MaxCardWidth);
            if (cardWidth > maxWidth) { cardWidth = maxWidth; }
            int totalWidth = columns * cardWidth + (columns - 1) * gap;
            int left = Math.Max(0, (width - totalWidth) / 2);
            int cardHeight = Ui.S(Ui.CardHeight);

            // A lone card on the final row stretches across the grid instead of
            // leaving an awkward empty slot beside it.
            bool loneLast = columns > 1 && _cards.Count % columns == 1;

            for (int index = 0; index < _cards.Count; index++)
            {
                int row = index / columns;
                int column = index % columns;
                int x = left + column * (cardWidth + gap);
                int w = cardWidth;
                if (loneLast && index == _cards.Count - 1)
                {
                    x = left;
                    w = totalWidth;
                }
                _cards[index].SetBounds(x, row * (cardHeight + gap), w, cardHeight);
            }
            int height = rows * cardHeight + (rows - 1) * gap;
            if (Height < height) { Height = height; }
        }

        public override Size GetPreferredSize(Size proposedSize)
        {
            return new Size(proposedSize.Width, MeasureHeight(proposedSize.Width > 0 ? proposedSize.Width : Width));
        }
    }

    /// <summary>
    /// Workspace hero: current session state, where persistent files live and
    /// the two primary shortcuts. Buttons sit beside the text when there is
    /// room and wrap below it when the window is narrow.
    /// </summary>
    internal sealed class HeroSection : Control, ISection
    {
        private readonly Label _caption;
        private readonly Label _state;
        private readonly Label _meta;
        private readonly Label _scope;
        private readonly Dot _dot;

        public readonly PillButton PrimaryButton;
        public readonly PillButton SecondaryButton;

        public HeroSection()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.Bg;
            TabStop = false;
            AccessibleRole = AccessibleRole.Grouping;

            _caption = MakeLabel("SESSION WORKSPACE", UiFonts.Micro, Theme.TextMuted);
            _state = MakeLabel("This session is ready", UiFonts.Hero, Theme.Text);
            _meta = MakeLabel(string.Empty, UiFonts.Body, Theme.TextSoft);
            _scope = MakeLabel(string.Empty, UiFonts.Small, Theme.TextMuted);

            _dot = new Dot();
            _dot.Size = new Size(Ui.S(7), Ui.S(7));
            _dot.BackColor = Theme.BlueSoft;

            PrimaryButton = new PillButton();
            PrimaryButton.Text = "Open workspace";
            PrimaryButton.Variant = ButtonVariant.Primary;
            PrimaryButton.Accent = Theme.Blue;
            PrimaryButton.Glyph = "\uE8B7";
            PrimaryButton.BackColor = Theme.BlueSoft;
            PrimaryButton.AccessibleName = "Open the permanent folder";
            PrimaryButton.AccessibleDescription = "Opens C:\\Persist in File Explorer.";

            SecondaryButton = new PillButton();
            SecondaryButton.Text = "Downloads";
            SecondaryButton.Variant = ButtonVariant.Secondary;
            SecondaryButton.Glyph = "\uE838";
            SecondaryButton.BackColor = Theme.BlueSoft;
            SecondaryButton.AccessibleName = "Open Downloads";
            SecondaryButton.AccessibleDescription = "Opens the Downloads folder in File Explorer.";

            Controls.Add(_caption);
            Controls.Add(_state);
            Controls.Add(_meta);
            Controls.Add(_scope);
            Controls.Add(_dot);
            Controls.Add(PrimaryButton);
            Controls.Add(SecondaryButton);
        }

        private Label MakeLabel(string text, Font font, Color color)
        {
            Label label = new Label();
            label.Text = text;
            label.Font = font;
            label.ForeColor = color;
            label.BackColor = Theme.BlueSoft;
            label.AutoSize = false;
            label.AutoEllipsis = true;
            label.UseMnemonic = false;
            return label;
        }

        public void SetState(string text, Color color)
        {
            _state.Text = text ?? string.Empty;
            _state.ForeColor = color;
            _dot.SetColor(color);
            AccessibleName = "Session workspace: " + (text ?? string.Empty);
            Invalidate();
        }

        public void SetMeta(string text) { _meta.Text = text ?? string.Empty; Invalidate(); }
        public void SetScope(string text) { _scope.Text = text ?? string.Empty; Invalidate(); }

        private bool Wide(int width) { return width >= Ui.S(700); }

        public int MeasureHeight(int width)
        {
            return Wide(width) ? Ui.S(120) : Ui.S(208);
        }

        protected override void OnLayout(LayoutEventArgs e)
        {
            base.OnLayout(e);
            int pad = Ui.S(Ui.Space5);
            int width = ClientSize.Width;
            int height = ClientSize.Height;
            int buttonHeight = Ui.S(Ui.ButtonHeight);
            int primaryWidth = PrimaryButton.Width;
            int secondaryWidth = SecondaryButton.Width;
            int buttonsWidth = primaryWidth + Ui.S(Ui.Space3) + secondaryWidth;
            bool wide = Wide(width);

            int textWidth = wide
                ? Math.Max(Ui.S(180), width - pad * 2 - buttonsWidth - Ui.S(Ui.Space5))
                : Math.Max(Ui.S(120), width - pad * 2);

            _caption.SetBounds(pad + Ui.S(13), Ui.S(18), Math.Max(Ui.S(60), textWidth - Ui.S(13)), Ui.S(14));
            _dot.SetBounds(pad, Ui.S(18) + (Ui.S(14) - _dot.Height) / 2, _dot.Width, _dot.Height);
            _state.SetBounds(pad, Ui.S(36), textWidth, Ui.S(38));
            _meta.SetBounds(pad, Ui.S(76), textWidth, Ui.S(18));
            _scope.SetBounds(pad, Ui.S(96), textWidth, Ui.S(16));

            if (wide)
            {
                int buttonY = (height - buttonHeight) / 2;
                PrimaryButton.SetBounds(width - pad - buttonsWidth, buttonY, primaryWidth, buttonHeight);
                SecondaryButton.SetBounds(width - pad - secondaryWidth, buttonY, secondaryWidth, buttonHeight);
            }
            else
            {
                int buttonY = height - pad - buttonHeight;
                PrimaryButton.SetBounds(pad, buttonY, primaryWidth, buttonHeight);
                SecondaryButton.SetBounds(pad + primaryWidth + Ui.S(Ui.Space3), buttonY, secondaryWidth, buttonHeight);
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics graphics = e.Graphics;
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle rect = new Rectangle(0, 0, Width - 1, Height - 1);
            Color border = Color.FromArgb(216, 228, 247);
            Gfx.FillRound(graphics, rect, Ui.S(Ui.RadiusLg), Theme.BlueSoft);
            Gfx.StrokeRound(graphics, rect, Ui.S(Ui.RadiusLg), border, 1f);
        }
    }

    /// <summary>Three responsive status tiles: storage, uptime and taskbar theme.</summary>
    internal sealed class StatStrip : Control, ISection
    {
        private const int TileCount = 3;
        private readonly string[] _captions = new string[TileCount];
        private readonly string[] _values = new string[TileCount];
        private readonly string[] _metas = new string[TileCount];
        private readonly float[] _progress = new float[TileCount];
        private readonly Color[] _accents = new Color[TileCount];

        public StatStrip()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.Bg;
            TabStop = false;
            AccessibleRole = AccessibleRole.StaticText;
            for (int index = 0; index < TileCount; index++)
            {
                _captions[index] = string.Empty;
                _values[index] = string.Empty;
                _metas[index] = string.Empty;
                _progress[index] = -1f;
                _accents[index] = Theme.Green;
            }
        }

        public void SetTile(int index, string caption, string value, string meta, float progress)
        {
            SetTile(index, caption, value, meta, progress, Theme.Green);
        }

        public void SetTile(int index, string caption, string value, string meta, float progress, Color accent)
        {
            if (index < 0 || index >= TileCount) { return; }
            _captions[index] = caption ?? string.Empty;
            _values[index] = value ?? string.Empty;
            _metas[index] = meta ?? string.Empty;
            _progress[index] = progress;
            _accents[index] = accent;
            AccessibleName = string.Format("{0}: {1}. {2}: {3}. {4}: {5}.",
                _captions[0], _values[0], _captions[1], _values[1], _captions[2], _values[2]);
            Invalidate();
        }

        private int Columns(int width)
        {
            if (width >= Ui.S(700)) { return 3; }
            if (width >= Ui.S(460)) { return 2; }
            return 1;
        }

        public int MeasureHeight(int width)
        {
            int columns = Columns(width);
            int rows = (TileCount + columns - 1) / columns;
            int pad = Ui.S(Ui.Space4);
            int rowHeight = Ui.S(72);
            int rowGap = Ui.S(Ui.Space4);
            return pad * 2 + rows * rowHeight + (rows - 1) * rowGap;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics graphics = e.Graphics;
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            int width = ClientSize.Width;
            int height = ClientSize.Height;
            int columns = Columns(width);
            int rows = (TileCount + columns - 1) / columns;
            int pad = Ui.S(Ui.Space4);
            int gap = Ui.S(Ui.Space5);
            int rowHeight = Ui.S(72);
            int rowGap = Ui.S(Ui.Space4);
            int tileWidth = (width - pad * 2 - (columns - 1) * gap) / columns;

            Rectangle card = new Rectangle(0, 0, width - 1, height - 1);
            Gfx.FillRound(graphics, card, Ui.S(Ui.RadiusMd), Theme.Surface);
            Gfx.StrokeRound(graphics, card, Ui.S(Ui.RadiusMd), Theme.Border, 1f);

            for (int column = 1; column < columns; column++)
            {
                int x = pad + column * (tileWidth + gap) - gap / 2;
                using (Pen divider = new Pen(Theme.ChromeLine, 1f))
                {
                    graphics.DrawLine(divider, x, pad, x, height - pad);
                }
            }
            for (int row = 1; row < rows; row++)
            {
                int y = pad + row * (rowHeight + rowGap) - rowGap / 2;
                using (Pen divider = new Pen(Theme.ChromeLine, 1f))
                {
                    graphics.DrawLine(divider, pad, y, width - pad, y);
                }
            }

            for (int index = 0; index < TileCount; index++)
            {
                int row = index / columns;
                int column = index % columns;
                int x = pad + column * (tileWidth + gap);
                int y = pad + row * (rowHeight + rowGap);
                if (tileWidth <= 0) { continue; }

                int markerSize = Ui.S(6);
                using (SolidBrush marker = new SolidBrush(_accents[index]))
                {
                    graphics.FillEllipse(marker, x, y + Ui.S(5), markerSize, markerSize);
                }

                TextRenderer.DrawText(graphics, _captions[index], UiFonts.Micro,
                    new Rectangle(x + Ui.S(13), y, tileWidth - Ui.S(13), Ui.S(14)),
                    Theme.TextMuted, TextFormatFlags.Left | TextFormatFlags.Top | TextFormatFlags.NoPrefix |
                    TextFormatFlags.EndEllipsis);

                TextRenderer.DrawText(graphics, _values[index], UiFonts.Value,
                    new Rectangle(x, y + Ui.S(19), tileWidth, Ui.S(28)),
                    Theme.Text, TextFormatFlags.Left | TextFormatFlags.Top | TextFormatFlags.NoPrefix |
                    TextFormatFlags.EndEllipsis);

                TextRenderer.DrawText(graphics, _metas[index], UiFonts.Small,
                    new Rectangle(x, y + Ui.S(49), tileWidth, Ui.S(16)),
                    Theme.TextMuted, TextFormatFlags.Left | TextFormatFlags.Top | TextFormatFlags.NoPrefix |
                    TextFormatFlags.EndEllipsis);

                if (_progress[index] >= 0f)
                {
                    int barY = y + rowHeight - Ui.S(4);
                    int barWidth = tileWidth;
                    Gfx.FillRound(graphics, new Rectangle(x, barY, barWidth, Ui.S(4)), Ui.S(2), Theme.SurfaceHi);
                    int filled = (int)Math.Round(barWidth * Math.Max(0f, Math.Min(1f, _progress[index])));
                    if (filled > 0)
                    {
                        Gfx.FillRound(graphics, new Rectangle(x, barY, filled, Ui.S(4)), Ui.S(2), _accents[index]);
                    }
                }
            }
        }
    }

    /// <summary>GitHub Actions panel: recent runs plus the log of the selected run.</summary>
    internal sealed class GitHubSection : Control, ISection
    {
        public readonly ListBox RunsList;
        public readonly TextBox LogView;

        private readonly Label _title;
        private readonly Label _status;
        private readonly PillButton _refresh;
        private readonly PillButton _viewLog;

        public event EventHandler RefreshRequested;
        public event EventHandler ViewLogRequested;

        public GitHubSection()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.Bg;
            TabStop = false;
            AccessibleRole = AccessibleRole.Grouping;

            _title = new Label();
            _title.Text = "GitHub Actions";
            _title.Font = UiFonts.Section;
            _title.ForeColor = Theme.Text;
            _title.BackColor = Theme.Surface;
            _title.AutoSize = false;
            _title.TextAlign = ContentAlignment.MiddleLeft;

            _status = new Label();
            _status.Text = string.Empty;
            _status.Font = UiFonts.Small;
            _status.ForeColor = Theme.TextMuted;
            _status.BackColor = Theme.Surface;
            _status.AutoSize = false;
            _status.TextAlign = ContentAlignment.MiddleLeft;

            _refresh = new PillButton();
            _refresh.Text = "Refresh";
            _refresh.Variant = ButtonVariant.Secondary;
            _refresh.Small = true;
            _refresh.Glyph = "\uE72C";
            _refresh.AccessibleName = "Refresh workflow runs";
            _refresh.Click += delegate { if (RefreshRequested != null) { RefreshRequested(this, EventArgs.Empty); } };

            _viewLog = new PillButton();
            _viewLog.Text = "View log";
            _viewLog.Variant = ButtonVariant.Ghost;
            _viewLog.Small = true;
            _viewLog.AccessibleName = "View the selected run log";
            _viewLog.Click += delegate { if (ViewLogRequested != null) { ViewLogRequested(this, EventArgs.Empty); } };

            RunsList = new ListBox();
            RunsList.Font = UiFonts.Small;
            RunsList.BackColor = Theme.SurfaceLo;
            RunsList.ForeColor = Theme.Text;
            RunsList.BorderStyle = BorderStyle.None;
            RunsList.DrawMode = DrawMode.OwnerDrawFixed;
            RunsList.IntegralHeight = false;
            RunsList.AccessibleName = "Workflow runs";
            RunsList.AccessibleDescription = "Recent GitHub Actions runs. Double-click or press View log for details.";
            RunsList.DrawItem += DrawRunItem;
            RunsList.DoubleClick += delegate { if (ViewLogRequested != null) { ViewLogRequested(this, EventArgs.Empty); } };

            LogView = new TextBox();
            LogView.Multiline = true;
            LogView.ReadOnly = true;
            LogView.ScrollBars = ScrollBars.Vertical;
            LogView.Font = UiFonts.Mono;
            LogView.BackColor = Theme.SurfaceLo;
            LogView.ForeColor = Theme.TextSoft;
            LogView.BorderStyle = BorderStyle.None;
            LogView.AccessibleName = "Run log";
            Gfx.DarkScroll(LogView);

            Controls.Add(_title);
            Controls.Add(_status);
            Controls.Add(_refresh);
            Controls.Add(_viewLog);
            Controls.Add(RunsList);
            Controls.Add(LogView);
        }

        public void SetStatus(string text)
        {
            _status.ForeColor = Theme.TextMuted;
            _status.Text = text ?? string.Empty;
            _status.AccessibleName = "Workflow runs status: " + (text ?? string.Empty);
            Invalidate(_status.Bounds);
        }

        /// <summary>Errors are surfaced in the warning colour, not muted grey.</summary>
        public void SetError(string text)
        {
            _status.ForeColor = Theme.Red;
            _status.Text = text ?? string.Empty;
            _status.AccessibleName = "Workflow runs error: " + (text ?? string.Empty);
            Invalidate(_status.Bounds);
        }

        public void SetLoading(bool loading)
        {
            _refresh.Enabled = !loading;
            _viewLog.Enabled = !loading;
        }

        public int SelectedRunIndex() { return RunsList.SelectedIndex; }

        private bool Wide(int width) { return width >= Ui.S(740); }

        public int MeasureHeight(int width)
        {
            return Wide(width) ? Ui.S(312) : Ui.S(468);
        }

        protected override void OnLayout(LayoutEventArgs e)
        {
            base.OnLayout(e);
            int pad = Ui.S(Ui.Space5);
            int width = ClientSize.Width;
            int height = ClientSize.Height;
            int headerHeight = Ui.S(28);
            bool wide = Wide(width);

            int refreshWidth = _refresh.Width;
            int viewWidth = _viewLog.Width;
            int buttonsWidth = refreshWidth + Ui.S(Ui.Space2) + viewWidth;
            _refresh.SetBounds(width - pad - buttonsWidth, Ui.S(16), refreshWidth, _refresh.Height);
            _viewLog.SetBounds(width - pad - viewWidth, Ui.S(16), viewWidth, _viewLog.Height);

            _title.SetBounds(pad, Ui.S(16), Math.Max(Ui.S(120), width - pad * 2 - buttonsWidth - Ui.S(Ui.Space4)), headerHeight);
            _status.SetBounds(pad, Ui.S(46), Math.Max(Ui.S(80), width - pad * 2), Ui.S(18));

            int contentTop = Ui.S(76);
            int contentHeight = height - contentTop - pad;
            if (contentHeight < Ui.S(80)) { contentHeight = Ui.S(80); }

            if (wide)
            {
                int gap = Ui.S(Ui.Space4);
                int listWidth = (width - pad * 2 - gap) * 45 / 100;
                int logWidth = width - pad * 2 - gap - listWidth;
                RunsList.SetBounds(pad, contentTop, listWidth, contentHeight);
                LogView.SetBounds(pad + listWidth + gap, contentTop, logWidth, contentHeight);
            }
            else
            {
                int listHeight = Ui.S(164);
                RunsList.SetBounds(pad, contentTop, width - pad * 2, listHeight);
                int logTop = contentTop + listHeight + Ui.S(Ui.Space3);
                int logHeight = Math.Max(Ui.S(90), height - logTop - pad);
                LogView.SetBounds(pad, logTop, width - pad * 2, logHeight);
            }
            RunsList.ItemHeight = Math.Max(Ui.S(28), UiFonts.Small.Height + Ui.S(10));
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics graphics = e.Graphics;
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle rect = new Rectangle(0, 0, Width - 1, Height - 1);
            Gfx.FillRound(graphics, rect, Ui.S(Ui.RadiusMd), Theme.Surface);
            Gfx.StrokeRound(graphics, rect, Ui.S(Ui.RadiusMd), Theme.Border, 1f);

            // Inset wells behind the list and the log keep both readable; the
            // 1px control border gives them the 3:1 boundary WCAG 1.4.11 asks for.
            Rectangle listWell = new Rectangle(RunsList.Left - Ui.S(1), RunsList.Top - Ui.S(1),
                RunsList.Width + Ui.S(2), RunsList.Height + Ui.S(2));
            Rectangle logWell = new Rectangle(LogView.Left - Ui.S(1), LogView.Top - Ui.S(1),
                LogView.Width + Ui.S(2), LogView.Height + Ui.S(2));
            Gfx.FillRound(graphics, listWell, Ui.S(Ui.RadiusSm), Theme.SurfaceLo);
            Gfx.FillRound(graphics, logWell, Ui.S(Ui.RadiusSm), Theme.SurfaceLo);
            Gfx.StrokeRound(graphics, listWell, Ui.S(Ui.RadiusSm), Theme.Border, 1f);
            Gfx.StrokeRound(graphics, logWell, Ui.S(Ui.RadiusSm), Theme.Border, 1f);
        }

        private void DrawRunItem(object sender, DrawItemEventArgs e)
        {
            if (e.Index < 0) { return; }
            bool selected = (e.State & DrawItemState.Selected) == DrawItemState.Selected;
            Color background = selected ? Theme.BlueSoft : Theme.SurfaceLo;
            using (SolidBrush brush = new SolidBrush(background))
            {
                e.Graphics.FillRectangle(brush, e.Bounds);
            }
            if (selected)
            {
                Gfx.FillRound(e.Graphics, new Rectangle(e.Bounds.X + Ui.S(2), e.Bounds.Y + Ui.S(5), Ui.S(2),
                    Math.Max(Ui.S(6), e.Bounds.Height - Ui.S(10))), 1, Theme.Blue);
            }
            string text = RunsList.Items[e.Index] as string ?? string.Empty;
            int split = text.IndexOf(' ');
            Color markerColor = Theme.TextMuted;
            if (split > 0)
            {
                string marker = text.Substring(0, split);
                if (marker == "\u2713") { markerColor = Theme.Green; }
                else if (marker == "\u2717") { markerColor = Theme.Red; }
                else if (marker == "\u25CF") { markerColor = Theme.Blue; }
                Gfx.Ellipsis(e.Graphics, marker, UiFonts.Body,
                    new Rectangle(e.Bounds.X + Ui.S(10), e.Bounds.Y, Ui.S(16), e.Bounds.Height),
                    markerColor);
                text = text.Substring(split + 1);
            }
            Gfx.Ellipsis(e.Graphics, text, UiFonts.Small,
                new Rectangle(e.Bounds.X + Ui.S(26), e.Bounds.Y, e.Bounds.Width - Ui.S(32), e.Bounds.Height),
                selected ? Theme.Text : Theme.TextMuted);
        }
    }

    /// <summary>
    /// Bottom activity panel: live status line and the read-only, scrollable
    /// activity log. The log band can be collapsed to give the page more room
    /// on short windows.
    /// </summary>
    internal sealed class ActivityFooter : Panel
    {
        public readonly RichTextBox Log;
        public readonly SlimProgress Progress;

        private readonly Dot _dot;
        private readonly Label _status;
        private readonly Label _detail;
        private readonly Label _logCaption;
        private readonly PillButton _toggle;
        private readonly PillButton _copy;
        private readonly PillButton _clear;
        private bool _collapsed;
        private int _logBoxHeight = 96;

        public event EventHandler CopyRequested;
        public event EventHandler ClearRequested;
        public event EventHandler CollapseToggled;

        public ActivityFooter()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.Surface;
            Padding = new Padding(0);

            _dot = new Dot();
            _dot.Size = new Size(Ui.S(7), Ui.S(7));
            _dot.BackColor = Theme.Surface;

            _status = new Label();
            _status.Text = "Ready";
            _status.Font = UiFonts.H2;
            _status.ForeColor = Theme.Text;
            _status.BackColor = Theme.Surface;
            _status.AutoSize = false;
            _status.AutoEllipsis = true;

            _detail = new Label();
            _detail.Text = string.Empty;
            _detail.Font = UiFonts.Small;
            _detail.ForeColor = Theme.TextMuted;
            _detail.BackColor = Theme.Surface;
            _detail.AutoSize = false;
            _detail.AutoEllipsis = true;

            _toggle = new PillButton();
            _toggle.Variant = ButtonVariant.Ghost;
            _toggle.Small = true;
            _toggle.AutoFit = false;
            _toggle.Glyph = "\uE70E";
            _toggle.Size = new Size(Ui.S(28), Ui.S(28));
            _toggle.AccessibleName = "Collapse activity log";
            _toggle.Click += delegate
            {
                SetCollapsed(!_collapsed);
                if (CollapseToggled != null) { CollapseToggled(this, EventArgs.Empty); }
            };

            _logCaption = new Label();
            _logCaption.Text = "ACTIVITY LOG";
            _logCaption.Font = UiFonts.Micro;
            _logCaption.ForeColor = Theme.TextMuted;
            _logCaption.BackColor = Theme.Surface;
            _logCaption.AutoSize = false;
            _logCaption.TextAlign = ContentAlignment.MiddleLeft;

            _copy = new PillButton();
            _copy.Text = "Copy";
            _copy.Variant = ButtonVariant.Ghost;
            _copy.Small = true;
            _copy.AccessibleName = "Copy activity log";
            _copy.Click += delegate { if (CopyRequested != null) { CopyRequested(this, EventArgs.Empty); } };

            _clear = new PillButton();
            _clear.Text = "Clear";
            _clear.Variant = ButtonVariant.Ghost;
            _clear.Small = true;
            _clear.AccessibleName = "Clear activity log";
            _clear.Click += delegate { if (ClearRequested != null) { ClearRequested(this, EventArgs.Empty); } };

            Log = new RichTextBox();
            Log.BackColor = Theme.SurfaceLo;
            Log.ForeColor = Theme.TextSoft;
            Log.Font = UiFonts.Mono;
            Log.BorderStyle = BorderStyle.None;
            Log.ReadOnly = true;
            Log.DetectUrls = false;
            Log.ScrollBars = RichTextBoxScrollBars.Vertical;
            Log.AccessibleName = "Activity log";
            Log.AccessibleDescription = "Read-only history of dashboard actions and background tasks.";
            Gfx.DarkScroll(Log);

            Progress = new SlimProgress();
            Progress.Visible = false;

            Controls.Add(_dot);
            Controls.Add(_status);
            Controls.Add(_detail);
            Controls.Add(_toggle);
            Controls.Add(_logCaption);
            Controls.Add(_copy);
            Controls.Add(_clear);
            Controls.Add(Log);
            Controls.Add(Progress);
        }

        public bool Collapsed { get { return _collapsed; } }
        public int StatusBandHeight { get { return Ui.S(48); } }
        public int LogBandHeight { get { return Ui.S(30) + _logBoxHeight + Ui.S(8); } }
        public int PreferredHeight { get { return StatusBandHeight + (_collapsed ? 0 : LogBandHeight); } }

        public int LogBoxHeight
        {
            get { return _logBoxHeight; }
            set { _logBoxHeight = Math.Max(Ui.S(48), value); Invalidate(); }
        }

        public void SetStatus(string text, Color color, string detail)
        {
            _status.Text = text ?? string.Empty;
            _detail.Text = detail ?? string.Empty;
            _dot.SetColor(color);
            Invalidate();
        }

        public void SetCollapsed(bool collapsed)
        {
            _collapsed = collapsed;
            _toggle.Glyph = collapsed ? "\uE70D" : "\uE70E";
            _toggle.AccessibleName = collapsed ? "Expand activity log" : "Collapse activity log";
            ApplyVisibility();
            PerformLayout();
            Invalidate();
        }

        private void ApplyVisibility()
        {
            bool visible = !_collapsed;
            Log.Visible = visible;
            _logCaption.Visible = visible;
            _copy.Visible = visible;
            _clear.Visible = visible;
        }

        protected override void OnLayout(LayoutEventArgs e)
        {
            base.OnLayout(e);
            int width = ClientSize.Width;
            int statusBand = StatusBandHeight;
            int left = Ui.S(Ui.Space5);

            int toggleSize = Ui.S(28);
            _toggle.SetBounds(width - left - toggleSize, (statusBand - toggleSize) / 2, toggleSize, toggleSize);
            Progress.SetBounds(0, statusBand - Progress.Height, width, Progress.Height);

            int statusLeft = left + Ui.S(15);
            int statusWidth = Math.Max(Ui.S(80), _toggle.Left - statusLeft - Ui.S(Ui.Space4));
            _dot.SetBounds(left, statusBand / 2 - _dot.Height / 2, _dot.Width, _dot.Height);
            _status.SetBounds(statusLeft, Ui.S(7), statusWidth, Ui.S(20));
            _detail.SetBounds(statusLeft, Ui.S(26), Math.Max(Ui.S(80), statusWidth), Ui.S(16));
            _detail.Visible = width > Ui.S(760);

            if (!_collapsed)
            {
                int logTop = statusBand;
                int captionHeight = Ui.S(30);
                _logCaption.SetBounds(left, logTop, Ui.S(120), captionHeight);

                int clearWidth = _clear.Width;
                int copyWidth = _copy.Width;
                _clear.SetBounds(width - left - clearWidth, logTop + (captionHeight - _clear.Height) / 2, clearWidth, _clear.Height);
                _copy.SetBounds(_clear.Left - Ui.S(Ui.Space1) - copyWidth, logTop + (captionHeight - _copy.Height) / 2, copyWidth, _copy.Height);

                Log.SetBounds(left, logTop + captionHeight, Math.Max(Ui.S(120), width - left * 2),
                    Math.Max(Ui.S(40), ClientSize.Height - logTop - captionHeight - Ui.S(10)));
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            using (Pen pen = new Pen(Theme.ChromeLine))
            {
                e.Graphics.DrawLine(pen, 0, 0, Width, 0);
            }
            // Subtle inset around the activity log keeps the white status bar
            // visually separate from the scrollable log well.
            if (!_collapsed && Log.Width > 0)
            {
                Graphics graphics = e.Graphics;
                graphics.SmoothingMode = SmoothingMode.AntiAlias;
                Rectangle well = new Rectangle(Log.Left - Ui.S(1), Log.Top - Ui.S(1),
                    Log.Width + Ui.S(2), Log.Height + Ui.S(2));
                Gfx.StrokeRound(graphics, well, Ui.S(Ui.RadiusSm), Theme.ChromeLine, 1f);
            }
        }
    }

    /// <summary>
    /// Page title block with live session / user status on the right. It shares
    /// the PageView content column so titles and cards line up exactly.
    /// </summary>
    internal sealed class PageHeader : Panel
    {
        private readonly Label _title;
        private readonly Label _subtitle;
        private readonly Chip _session;
        private readonly Chip _user;
        private bool _showUser = true;

        public PageHeader()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.Bg;
            Margin = new Padding(0);

            _title = new Label();
            _title.Text = string.Empty;
            _title.Font = UiFonts.PageTitle;
            _title.ForeColor = Theme.Text;
            _title.BackColor = Theme.Bg;
            _title.AutoSize = false;
            _title.AutoEllipsis = true;
            _title.UseMnemonic = false;

            _subtitle = new Label();
            _subtitle.Text = string.Empty;
            _subtitle.Font = UiFonts.Body;
            _subtitle.ForeColor = Theme.TextMuted;
            _subtitle.BackColor = Theme.Bg;
            _subtitle.AutoSize = false;
            _subtitle.AutoEllipsis = true;
            _subtitle.UseMnemonic = false;

            _session = new Chip("Session active", Theme.Green);
            _session.BackColor = Theme.Bg;
            _session.AccessibleDescription = "The dashboard session is connected.";

            _user = new Chip(Environment.UserName, Theme.Slate);
            _user.Glyph = "\uE77B";
            _user.BackColor = Theme.Bg;
            _user.SetLabel(Environment.UserName);
            _user.AccessibleName = "Signed in as " + Environment.UserName;

            Controls.Add(_title);
            Controls.Add(_subtitle);
            Controls.Add(_session);
            Controls.Add(_user);
        }

        public void SetPage(string title, string subtitle)
        {
            _title.Text = title ?? string.Empty;
            _subtitle.Text = subtitle ?? string.Empty;
            AccessibleName = _title.Text;
            AccessibleDescription = _subtitle.Text;
            Invalidate();
        }

        public void SetUser(string name)
        {
            _user.SetLabel(name ?? string.Empty);
            _user.AccessibleName = "Signed in as " + name;
            PerformLayout();
        }

        public void SetCompact(bool compact)
        {
            _showUser = !compact;
            PerformLayout();
        }

        protected override void OnLayout(LayoutEventArgs e)
        {
            base.OnLayout(e);
            int left;
            int width;
            int padding = PageMetrics.PaddingFor(ClientSize.Width, UiConstants.PagePadding);
            PageMetrics.ContentBounds(ClientSize.Width, padding, UiConstants.ContentMaxWidth, out left, out width);

            bool showUser = _showUser && width >= Ui.S(620);
            _user.Visible = showUser;
            int chipsWidth = _session.Width + (showUser ? Ui.S(Ui.Space2) + _user.Width : 0);
            int textWidth = Math.Max(Ui.S(180), width - chipsWidth - Ui.S(Ui.Space5));

            _title.SetBounds(left, Ui.S(20), textWidth, Ui.S(38));
            _subtitle.SetBounds(left, Ui.S(58), textWidth, Ui.S(20));

            int chipY = Ui.S(29);
            if (showUser)
            {
                _user.SetBounds(left + width - _user.Width, chipY, _user.Width, _user.Height);
            }
            _session.SetBounds(left + width - chipsWidth, chipY, _session.Width, _session.Height);
        }
    }

    /// <summary>Shared horizontal metrics so the header, page and footer line up.</summary>
    internal static class PageMetrics
    {
        public static int PaddingFor(int clientWidth, int fallbackDip)
        {
            return clientWidth < Ui.S(900) ? Math.Min(fallbackDip, Ui.Space5) : fallbackDip;
        }

        public static void ContentBounds(int clientWidth, int paddingDip, int maxWidthDip, out int left, out int width)
        {
            int scrollbar = SystemInformation.VerticalScrollBarWidth;
            int padding = Ui.S(paddingDip);
            int available = clientWidth - padding * 2 - scrollbar;
            if (available < Ui.S(220)) { available = Math.Max(Ui.S(180), clientWidth - padding * 2); }
            width = Math.Min(available, Ui.S(maxWidthDip));
            left = padding + Math.Max(0, (available - width) / 2);
        }
    }

    internal static class UiConstants
    {
        public const int PagePadding = Ui.Space6;
        public const int ContentMaxWidth = 1240;
        public const int SidebarWidth = 240;
        public const int SidebarRailWidth = 72;
    }

    /// <summary>
    /// Left navigation. Expands to a labelled sidebar on wide windows and
    /// collapses to an icon rail on narrow ones; the workspace summary is only
    /// shown when the labels fit.
    /// </summary>
    internal sealed class SidebarPanel : Panel
    {
        public readonly NavItem[] Items = new NavItem[3];

        private readonly LogoMark _logo;
        private readonly Label _brand;
        private readonly Label _brandSub;
        private readonly Label _navCaption;
        private readonly SurfacePanel _workspaceCard;
        private readonly Label _workspaceCaption;
        private readonly Label _workspaceValue;
        private readonly Label _workspaceMeta;
        private readonly Label _version;
        private bool _rail;

        public event EventHandler PageSelected;

        public SidebarPanel()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.Sidebar;

            _logo = new LogoMark();
            _logo.BackColor = Theme.Sidebar;
            Controls.Add(_logo);

            _brand = MakeChromeLabel("Sailuo", UiFonts.Brand, Theme.SidebarStrong);
            _brandSub = MakeChromeLabel("Control Center", UiFonts.BrandSub, Theme.SidebarMuted);
            _navCaption = MakeChromeLabel("NAVIGATION", UiFonts.Micro, Theme.SidebarMuted);
            Controls.Add(_brand);
            Controls.Add(_brandSub);
            Controls.Add(_navCaption);

            string[] captions = new string[] { "Overview", "Applications", "System" };
            string[] glyphs = new string[] { "\uE80F", "\uE71D", "\uE713" };
            string[] shortcuts = new string[] { "Ctrl+1", "Ctrl+2", "Ctrl+3" };

            for (int index = 0; index < 3; index++)
            {
                NavItem item = new NavItem();
                item.Caption = captions[index];
                item.Glyph = glyphs[index];
                item.PageIndex = index;
                item.Shortcut = shortcuts[index];
                item.AccessibleName = captions[index];
                item.AccessibleDescription = shortcuts[index];
                item.Click += OnItemClick;
                Items[index] = item;
                Controls.Add(item);
            }

            _workspaceCard = new SurfacePanel();
            _workspaceCard.SurfaceColor = Theme.SidebarCard;
            _workspaceCard.BorderColor = Theme.SidebarBorder;
            _workspaceCard.Radius = Ui.RadiusSm;
            _workspaceCard.BackColor = Theme.Sidebar;

            _workspaceCaption = MakeCardLabel("WORKSPACE", UiFonts.Micro, Theme.SidebarMuted);
            _workspaceValue = MakeCardLabel("C:\\Persist", UiFonts.H2, Theme.SidebarStrong);
            _workspaceMeta = MakeCardLabel("Permanent files", UiFonts.Small, Theme.SidebarMuted);
            _workspaceCard.Controls.Add(_workspaceCaption);
            _workspaceCard.Controls.Add(_workspaceValue);
            _workspaceCard.Controls.Add(_workspaceMeta);
            Controls.Add(_workspaceCard);

            _version = new Label();
            _version.Text = "Control Center 2.0";
            _version.Font = UiFonts.Small;
            _version.ForeColor = Theme.SidebarMuted;
            _version.BackColor = Theme.Sidebar;
            _version.AutoSize = false;
            _version.TextAlign = ContentAlignment.MiddleLeft;
            Controls.Add(_version);

            UpdateMode();
        }

        private Label MakeChromeLabel(string text, Font font, Color color)
        {
            Label label = new Label();
            label.Text = text;
            label.Font = font;
            label.ForeColor = color;
            label.BackColor = Theme.Sidebar;
            label.AutoSize = false;
            label.AutoEllipsis = true;
            label.UseMnemonic = false;
            return label;
        }

        private Label MakeCardLabel(string text, Font font, Color color)
        {
            Label label = new Label();
            label.Text = text;
            label.Font = font;
            label.ForeColor = color;
            label.BackColor = Theme.SidebarCard;
            label.AutoSize = false;
            label.AutoEllipsis = true;
            label.UseMnemonic = false;
            return label;
        }

        private void OnItemClick(object sender, EventArgs e)
        {
            NavItem item = sender as NavItem;
            if (item != null && PageSelected != null) { PageSelected(this, new PageEventArgs(item.PageIndex)); }
        }

        public void SetSelected(int page)
        {
            for (int index = 0; index < Items.Length; index++) { Items[index].Selected = index == page; }
        }

        public bool Rail { get { return _rail; } }

        private void UpdateMode()
        {
            if (_workspaceCard == null || _version == null) { return; }
            _rail = Width < Ui.S(160);
            foreach (NavItem item in Items)
            {
                item.Rail = _rail;
                item.Height = Ui.S(_rail ? 46 : Ui.NavHeight);
            }
            _brand.Visible = !_rail;
            _brandSub.Visible = !_rail;
            _navCaption.Visible = !_rail;
            _workspaceCard.Visible = !_rail;
            _version.Visible = !_rail;
            _logo.Size = new Size(Ui.S(34), Ui.S(34));
            PerformLayout();
        }

        protected override void OnSizeChanged(EventArgs e)
        {
            base.OnSizeChanged(e);
            UpdateMode();
        }

        protected override void OnLayout(LayoutEventArgs e)
        {
            base.OnLayout(e);
            if (_workspaceCard == null || _version == null) { return; }
            int width = ClientSize.Width;
            int height = ClientSize.Height;
            int padding = _rail ? Ui.S(Ui.Space2) : Ui.S(Ui.Space4);
            int logoSize = Ui.S(34);

            if (_rail)
            {
                _logo.SetBounds((width - logoSize) / 2, Ui.S(Ui.Space5), logoSize, logoSize);
                int railItemWidth = Math.Max(Ui.S(40), Math.Min(Ui.S(48), width - padding * 2));
                int railItemLeft = (width - railItemWidth) / 2;
                int railY = Ui.S(78);
                foreach (NavItem item in Items)
                {
                    item.SetBounds(railItemLeft, railY, railItemWidth, item.Height);
                    railY += item.Height + Ui.S(Ui.Space2);
                }
                return;
            }

            _logo.SetBounds(padding, Ui.S(Ui.Space5), logoSize, logoSize);
            int brandLeft = padding + logoSize + Ui.S(Ui.Space3);
            _brand.SetBounds(brandLeft, Ui.S(22), Math.Max(Ui.S(80), width - brandLeft - padding), Ui.S(22));
            _brandSub.SetBounds(brandLeft, Ui.S(44), Math.Max(Ui.S(80), width - brandLeft - padding), Ui.S(16));
            _navCaption.SetBounds(padding, Ui.S(88), Math.Max(Ui.S(80), width - padding * 2), Ui.S(14));

            int itemWidth = Math.Max(Ui.S(120), width - padding * 2);
            int y = Ui.S(108);
            foreach (NavItem item in Items)
            {
                item.SetBounds(padding, y, itemWidth, item.Height);
                y += item.Height + Ui.S(Ui.Space1);
            }

            int cardHeight = Ui.S(88);
            int versionHeight = Ui.S(18);
            int cardBottom = height - Ui.S(Ui.Space5) - versionHeight - Ui.S(Ui.Space2);
            _workspaceCard.SetBounds(padding, cardBottom - cardHeight, Math.Max(Ui.S(80), width - padding * 2), cardHeight);
            int innerPad = Ui.S(Ui.Space3);
            _workspaceCaption.SetBounds(innerPad, Ui.S(11), _workspaceCard.Width - innerPad * 2, Ui.S(13));
            _workspaceValue.SetBounds(innerPad, Ui.S(30), _workspaceCard.Width - innerPad * 2, Ui.S(22));
            _workspaceMeta.SetBounds(innerPad, Ui.S(56), _workspaceCard.Width - innerPad * 2, Ui.S(16));
            _version.SetBounds(padding, height - Ui.S(Ui.Space5) - versionHeight, Math.Max(Ui.S(80), width - padding * 2), versionHeight);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            using (Pen border = new Pen(Theme.SidebarBorder))
            {
                e.Graphics.DrawLine(border, Width - 1, 0, Width - 1, Height);
            }
            if (!_rail)
            {
                using (Pen divider = new Pen(Theme.SidebarBorder))
                {
                    e.Graphics.DrawLine(divider, Ui.S(Ui.Space4), Ui.S(72), Width - Ui.S(Ui.Space4), Ui.S(72));
                }
            }
        }
    }

    internal sealed class PageEventArgs : EventArgs
    {
        public readonly int Index;
        public PageEventArgs(int index) { Index = index; }
    }

    /// <summary>Rounded surface used by cards, wells and the save summary.</summary>
    internal sealed class SurfacePanel : Panel
    {
        public int Radius = Ui.RadiusMd;
        public Color SurfaceColor = Theme.Surface;
        public Color BorderColor = Theme.Border;

        public SurfacePanel()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.Bg;
            Margin = new Padding(0);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics graphics = e.Graphics;
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle rect = new Rectangle(0, 0, Width - 1, Height - 1);
            Gfx.FillRound(graphics, rect, Ui.S(Radius), SurfaceColor);
            Gfx.StrokeRound(graphics, rect, Ui.S(Radius), BorderColor, 1f);
            base.OnPaint(e);
        }
    }

    /// <summary>Section heading plus its responsive card grid, laid out as one block.</summary>
    internal sealed class CardGroup : Control, ISection
    {
        private readonly SectionLabel _label;
        private readonly CardGrid _grid;
        private readonly List<ActionCard> _cards = new List<ActionCard>();

        public CardGroup(string title, string meta, Color accent)
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.Bg;
            TabStop = false;

            _label = new SectionLabel();
            _label.Accent = accent;
            _label.SetTitle(title, meta);

            _grid = new CardGrid();
            Controls.Add(_label);
            Controls.Add(_grid);
        }

        public CardGrid Grid { get { return _grid; } }

        public void AddCard(ActionCard card)
        {
            _cards.Add(card);
            _grid.AddCard(card);
        }

        public int MeasureHeight(int width)
        {
            int labelHeight = _label.MeasureHeight(width);
            int gridHeight = _grid.MeasureHeight(width);
            return labelHeight + Ui.S(Ui.Space2) + gridHeight;
        }

        protected override void OnLayout(LayoutEventArgs e)
        {
            base.OnLayout(e);
            int width = ClientSize.Width;
            int labelHeight = _label.MeasureHeight(width);
            _label.SetBounds(0, 0, width, labelHeight);
            int gridHeight = _grid.MeasureHeight(width);
            _grid.SetBounds(0, labelHeight + Ui.S(Ui.Space2), width, gridHeight);
        }
    }

    // ========================================================================
    //  MainForm
    // ========================================================================
    public class MainForm : Form
    {
        // Chrome
        private TableLayoutPanel _root;
        private TableLayoutPanel _content;
        private SidebarPanel _sidebar;
        private PageHeader _pageHeader;
        private Panel _pagesHost;
        private ActivityFooter _footer;
        private readonly ToolTip _tips = new ToolTip();

        // Pages
        private PageView _pageHome;
        private PageView _pageApps;
        private PageView _pageSystem;
        private HeroSection _hero;
        private StatStrip _stats;
        private GitHubSection _github;

        // State
        private readonly List<Control> _busyControls = new List<Control>();
        private System.Windows.Forms.Timer _clock;
        private bool _running;
        private int _ticks;
        private string _runningLabel = string.Empty;
        private int _initialPage;
        private int _currentPage = -1;
        private bool _githubLoaded;
        private bool _loadedShown;
        private readonly List<string> _githubRunUrls = new List<string>();
        private readonly List<string> _githubRunIds = new List<string>();
        private readonly List<string> _githubRunStatuses = new List<string>();
        private int _appliedSidebarWidth = -1;
        private int _appliedFooterHeight = -1;
        private int _appliedPageHeaderHeight = -1;
        private bool _chromeReady;
        private bool _dpiApplied;
        private bool _autoCollapseDone;

        public MainForm()
        {
            ParseCommandLine();

            AutoScaleMode = AutoScaleMode.None;
            Text = "Sailuo Dashboard";
            BackColor = Theme.Bg;
            ForeColor = Theme.Text;
            Font = UiFonts.Body;
            DoubleBuffered = true;
            KeyPreview = true;

            if (Ui.ForcedDpi <= 0) { Ui.Dpi = Ui.ScreenDpi(); }
            Ui.Dpi = Math.Max(96, Ui.Dpi);

            LoadWindowIcon();
            SizeWindow();
            BuildUi();
            ApplyChrome();

            RefreshSystemInfo();
            SetStatus("Ready", Theme.Green, "Choose an action below to get started.");
            AppendLog("Dashboard started. Session tools and shortcuts are ready.", LogKind.Muted);

            KeyDown += OnFormKeyDown;
            _clock = new System.Windows.Forms.Timer();
            _clock.Interval = 1000;
            _clock.Tick += OnClock;
            _clock.Start();

            ShowPage(_initialPage, false);
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            _loadedShown = true;
            if (_currentPage == 0) { LoadGitHubRunsOnce(); }
            // Keep keyboard focus on the current page so the focus ring matches the selection.
            _sidebar.Items[_currentPage].Focus();
        }

        private void LoadGitHubRunsOnce()
        {
            if (_githubLoaded) { return; }
            _githubLoaded = true;
            RefreshGitHubRuns();
        }

        /// <summary>BeginInvoke that is safe during shutdown and before the handle exists.</summary>
        private void Post(Action action)
        {
            try
            {
                if (IsDisposed || Disposing || !IsHandleCreated) { return; }
                BeginInvoke(action);
            }
            catch { }
        }

        private void Post(Delegate method, params object[] arguments)
        {
            try
            {
                if (IsDisposed || Disposing || !IsHandleCreated) { return; }
                BeginInvoke(method, arguments);
            }
            catch { }
        }

        // ------------------------------------------------------------------
        //  Construction
        // ------------------------------------------------------------------
        private void ParseCommandLine()
        {
            string[] args = Environment.GetCommandLineArgs();
            for (int index = 1; index < args.Length; index++)
            {
                string argument = args[index].ToLowerInvariant();
                if (argument == "--system" || argument == "--page=system") { _initialPage = 2; }
                else if (argument == "--apps" || argument == "--applications" || argument == "--page=apps") { _initialPage = 1; }
                else if (argument == "--overview" || argument == "--page=overview") { _initialPage = 0; }
                else if (argument.StartsWith("--dpi=", StringComparison.Ordinal))
                {
                    int dpi;
                    if (int.TryParse(argument.Substring(6), NumberStyles.Integer, CultureInfo.InvariantCulture, out dpi) &&
                        dpi >= 96 && dpi <= 384)
                    {
                        Ui.ForcedDpi = dpi;
                    }
                }
            }
        }

        private void LoadWindowIcon()
        {
            try { Icon = new Icon(@"C:\Sailuo\icons\sailuo-dashboard.ico"); }
            catch
            {
                try { Icon = SystemIcons.Application; } catch { }
            }
        }

        private void SizeWindow()
        {
            Rectangle work;
            try { work = Screen.FromPoint(Cursor.Position).WorkingArea; }
            catch { work = Screen.PrimaryScreen.WorkingArea; }

            int width = Math.Min(Ui.S(1240), Math.Max(Ui.S(960), work.Width - Ui.S(80)));
            int height = Math.Min(Ui.S(820), Math.Max(Ui.S(620), work.Height - Ui.S(40)));
            MinimumSize = ClampMinimumSize(work);
            ClientSize = new Size(width, height);
            StartPosition = FormStartPosition.CenterScreen;
        }

        /// <summary>
        /// The minimum window must always fit the current monitor: on a
        /// 1366x768 display at 150% scaling an unclamped 880x600 DIP minimum
        /// would be 1320x900 physical pixels and could not be shown at all.
        /// </summary>
        private static Size ClampMinimumSize(Rectangle work)
        {
            return new Size(
                Math.Min(Ui.S(880), Math.Max(Ui.S(640), work.Width)),
                Math.Min(Ui.S(600), Math.Max(Ui.S(480), work.Height)));
        }

        private void BuildUi()
        {
            _root = new TableLayoutPanel();
            _root.Dock = DockStyle.Fill;
            _root.ColumnCount = 2;
            _root.RowCount = 1;
            _root.BackColor = Theme.Bg;
            _root.Margin = new Padding(0);
            _root.Padding = new Padding(0);
            _root.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, Ui.S(UiConstants.SidebarWidth)));
            _root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
            Controls.Add(_root);

            _sidebar = new SidebarPanel();
            _sidebar.Dock = DockStyle.Fill;
            _sidebar.PageSelected += delegate(object sender, EventArgs e)
            {
                PageEventArgs args = e as PageEventArgs;
                if (args != null) { ShowPage(args.Index, false); }
            };
            _root.Controls.Add(_sidebar, 0, 0);

            // The main column owns the page title, scrollable content and the
            // compact status / activity panel. The navigation rail runs the
            // full height of the window.
            _content = new TableLayoutPanel();
            _content.Dock = DockStyle.Fill;
            _content.ColumnCount = 1;
            _content.RowCount = 3;
            _content.BackColor = Theme.Bg;
            _content.Margin = new Padding(0);
            _content.Padding = new Padding(0);
            _content.RowStyles.Add(new RowStyle(SizeType.Absolute, Ui.S(Ui.PageHeader)));
            _content.RowStyles.Add(new RowStyle(SizeType.Percent, 100f));
            _content.RowStyles.Add(new RowStyle(SizeType.Absolute, Ui.S(160)));
            _root.Controls.Add(_content, 1, 0);

            _pageHeader = new PageHeader();
            _pageHeader.Dock = DockStyle.Fill;
            _content.Controls.Add(_pageHeader, 0, 0);

            _pagesHost = new Panel();
            _pagesHost.Dock = DockStyle.Fill;
            _pagesHost.BackColor = Theme.Bg;
            _pagesHost.Margin = new Padding(0);
            _content.Controls.Add(_pagesHost, 0, 1);

            _pageHome = BuildOverviewPage();
            _pageApps = BuildApplicationsPage();
            _pageSystem = BuildSystemPage();
            _pagesHost.Controls.Add(_pageHome);
            _pagesHost.Controls.Add(_pageApps);
            _pagesHost.Controls.Add(_pageSystem);

            _footer = new ActivityFooter();
            _footer.Dock = DockStyle.Fill;
            _footer.CopyRequested += delegate { CopyLogToClipboard(); };
            _footer.ClearRequested += delegate { ClearLog(); };
            _footer.CollapseToggled += delegate { ApplyChrome(); };
            _content.Controls.Add(_footer, 0, 2);

            _tips.SetToolTip(_hero.PrimaryButton, "Open the permanent folder (C:\\Persist)");
            _tips.SetToolTip(_hero.SecondaryButton, "Open the Downloads folder");
            _tips.SetToolTip(_footer.Log, "Activity history (Ctrl+Shift+L toggles this panel)");
            _tips.SetToolTip(_sidebar.Items[0], "Overview (Ctrl+1)");
            _tips.SetToolTip(_sidebar.Items[1], "Applications (Ctrl+2)");
            _tips.SetToolTip(_sidebar.Items[2], "System (Ctrl+3)");
            _tips.SetToolTip(_github.RunsList, "Double-click a run to load its log. Shift+Enter opens the run on GitHub.");
            _tips.SetToolTip(_github.LogView, "Read-only log of the selected workflow run");
            _tips.SetToolTip(_footer.Progress, string.Empty);
        }

        private PageView NewPage()
        {
            PageView page = new PageView();
            page.Dock = DockStyle.Fill;
            page.Visible = false;
            return page;
        }

        private PageView BuildOverviewPage()
        {
            PageView page = NewPage();

            _hero = new HeroSection();
            _hero.SetMeta("Your files stay on this machine. Keep what you need.");
            _hero.SetScope("C:\\Persist  \u00B7  Downloads  \u00B7  Desktop  \u00B7  Documents");
            _hero.PrimaryButton.Click += delegate { OpenPersistFolder(); };
            _hero.SecondaryButton.Click += delegate { OpenDownloadsFolder(); };
            page.Controls.Add(_hero);

            _stats = new StatStrip();
            _stats.SetTile(0, "STORAGE", "-- GB free", "Checking the C: drive...", -1f);
            _stats.SetTile(1, "SYSTEM UPTIME", "--", "Waiting for the session clock", -1f);
            _stats.SetTile(2, "TASKBAR THEME", "--", "Checking the Windhawk mod", -1f);
            page.Controls.Add(_stats);

            _github = new GitHubSection();
            _github.RefreshRequested += delegate { RefreshGitHubRuns(); };
            _github.ViewLogRequested += delegate { ViewGitHubRunLog(); };
            _github.RunsList.KeyDown += delegate(object sender, KeyEventArgs e)
            {
                if (e.KeyCode != Keys.Enter) { return; }
                if (e.Shift) { OpenSelectedGitHubRun(); } else { ViewGitHubRunLog(); }
                e.SuppressKeyPress = true;
            };

            CardGroup quick = new CardGroup("Quick actions", "Common tasks for this session", Theme.Blue);
            quick.AddCard(Card("Open permanent folder", "Files kept on this machine in C:\\Persist.",
                "\uE8B7", Theme.Blue, delegate { OpenPersistFolder(); }));
            quick.AddCard(Card("Performance boost", "Raw mouse input, audio refresh, lower latency.",
                "\uE945", Theme.Amber, delegate
                {
                    ConfirmAction("Apply performance tuning?",
                        "Mouse acceleration is disabled, audio services restart and desktop latency settings change for this session.",
                        "Apply now", Theme.Amber, ApplyPerformanceBoost);
                }));
            quick.AddCard(Card("Clean temp and refresh RAM", "Clear temp files and free cached memory.",
                "\uE74D", Theme.Red, delegate
                {
                    ConfirmAction("Clear temporary files?",
                        "User and Windows temporary files are deleted and cached memory is released. Open files are not affected.",
                        "Clear now", Theme.Red, CleanTemporaryFiles);
                }));
            quick.AddCard(Card("Open Downloads", "Open the Downloads folder in File Explorer.",
                "\uE838", Theme.Cyan, delegate { OpenDownloadsFolder(); }));
            quick.AddCard(Card("Sharpen text", "Enable ClearType font smoothing for sharper text on this display.",
                "\uE8D2", Theme.Violet, delegate
                {
                    RunTask("Enabling ClearType text smoothing...", @"
                        Set-ItemProperty -Path 'HKCU:\\Control Panel\\Desktop' -Name 'FontSmoothing' -Value '2' -ErrorAction SilentlyContinue
                        Set-ItemProperty -Path 'HKCU:\\Control Panel\\Desktop' -Name 'FontSmoothingType' -Value 2 -ErrorAction SilentlyContinue
                        Write-Host 'ClearType font smoothing enabled. Sign out and back in if text does not change immediately.'
                    ");
                }));
            page.Controls.Add(quick);
            page.Controls.Add(_github);

            return page;
        }

        private void OpenPersistFolder()
        {
            try
            {
                Directory.CreateDirectory(@"C:\Persist");
                Process.Start("explorer.exe", @"C:\Persist");
                AppendLog("Opened C:\\Persist.", LogKind.Info);
            }
            catch (Exception ex)
            {
                AppendLog("Could not open C:\\Persist: " + ex.Message, LogKind.Warn);
            }
        }

        private void OpenDownloadsFolder()
        {
            try
            {
                string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
                Directory.CreateDirectory(path);
                Process.Start("explorer.exe", path);
                AppendLog("Opened the Downloads folder.", LogKind.Info);
            }
            catch (Exception ex)
            {
                AppendLog("Could not open Downloads: " + ex.Message, LogKind.Warn);
            }
        }

        private void ApplyPerformanceBoost(object sender, EventArgs e)
        {
            RunTask("Applying performance boost...", @"
                if (Test-Path 'C:\Sailuo\tools\Apply-AntiVM-Boost.ps1') {
                    & 'C:\Sailuo\tools\Apply-AntiVM-Boost.ps1'
                }
                Set-ItemProperty -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseSpeed' -Value '0' -ErrorAction SilentlyContinue
                Set-ItemProperty -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseThreshold1' -Value '0' -ErrorAction SilentlyContinue
                Set-ItemProperty -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseThreshold2' -Value '0' -ErrorAction SilentlyContinue
                Restart-Service Audiosrv -Force -ErrorAction SilentlyContinue
                Restart-Service AudioEndpointBuilder -Force -ErrorAction SilentlyContinue
                Write-Host 'Performance boost and audio refresh applied.'
            ");
        }

        private void CleanTemporaryFiles(object sender, EventArgs e)
        {
            RunTask("Cleaning temporary files...", @"
                Remove-Item -Path ""$env:TEMP\*"" -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -Path 'C:\Windows\Temp\*' -Recurse -Force -ErrorAction SilentlyContinue
                [System.GC]::Collect()
                [System.GC]::WaitForPendingFinalizers()
                $freeGB = [math]::Round((Get-PSDrive C).Free / 1GB, 2)
                Write-Host ""Temporary files cleared. C: has $freeGB GB free.""
            ");
        }

        private PageView BuildApplicationsPage()
        {
            PageView page = NewPage();

            CardGroup essentials = new CardGroup("Essentials", "One-click installs", Theme.Violet);
            essentials.AddCard(Card("Install Google Chrome", "A current browser build with sign-in data preserved across sessions.",
                "\uE774", Theme.Blue, BrandIcon.Chrome, delegate
                {
                    RunTask("Installing Google Chrome...", @"
                        & winget install --id Google.Chrome --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
                        Write-Host 'Google Chrome is ready to use.'
                    ");
                }));
            essentials.AddCard(Card("Install Discord", "Voice, video and text chat for your communities.",
                "\uE8BD", Theme.Violet, BrandIcon.Discord, delegate
                {
                    RunTask("Installing Discord...", @"
                        & 'C:\Sailuo\scripts\install-app.ps1' -App 'discord'
                    ");
                }));
            page.Controls.Add(essentials);

            CardGroup apps = new CardGroup("Apps", "Install one at a time", Theme.Cyan);
            apps.AddCard(Card("Facebook", "Installs the Facebook app with its own window and desktop shortcut.",
                "\uE8D4", Theme.Blue, BrandIcon.Facebook, delegate
                {
                    RunTask("Installing Facebook...", @"
                        & 'C:\Sailuo\scripts\install-app.ps1' -App 'facebook'
                    ");
                }));
            apps.AddCard(Card("Instagram", "Installs the Instagram app from the Microsoft Store.",
                "\uE722", Theme.Violet, BrandIcon.Instagram, delegate
                {
                    RunTask("Installing Instagram...", @"
                        & 'C:\Sailuo\scripts\install-app.ps1' -App 'instagram'
                    ");
                }));
            apps.AddCard(Card("Apple Music", "Installs the Apple Music app for Windows.",
                "\uE90B", Theme.Red, BrandIcon.AppleMusic, delegate
                {
                    RunTask("Installing Apple Music...", @"
                        & 'C:\Sailuo\scripts\install-app.ps1' -App 'apple-music'
                    ");
                }));
            apps.AddCard(Card("Spotify", "Installs the Spotify desktop player.",
                "\uE768", Theme.Green, BrandIcon.Spotify, delegate
                {
                    RunTask("Installing Spotify...", @"
                        & 'C:\Sailuo\scripts\install-app.ps1' -App 'spotify'
                    ");
                }));
            apps.AddCard(Card("Visual Studio Code", "Installs the standalone VS Code editor.",
                "\uE943", Theme.Blue, BrandIcon.VisualStudioCode, delegate
                {
                    RunTask("Installing Visual Studio Code...", @"
                        & 'C:\Sailuo\scripts\install-app.ps1' -App 'vscode'
                    ");
                }));
            apps.AddCard(Card("Antigravity IDE", "Installs Google's standalone Antigravity IDE.",
                "\uE945", Theme.Amber, BrandIcon.Antigravity, delegate
                {
                    RunTask("Installing Antigravity IDE...", @"
                        & 'C:\Sailuo\scripts\install-app.ps1' -App 'antigravity'
                    ");
                }));
            apps.AddCard(Card("OpenCode Desktop", "Installs the OpenCode desktop application.",
                "\uE756", Theme.Cyan, BrandIcon.OpenCode, delegate
                {
                    RunTask("Installing OpenCode Desktop...", @"
                        & 'C:\Sailuo\scripts\install-app.ps1' -App 'opencode'
                    ");
                }));
            apps.AddCard(Card("Telegram Web", "Opens Telegram Web in its own window with a desktop shortcut.",
                "\uE8BD", Theme.Blue, BrandIcon.Telegram, delegate
                {
                    RunTask("Installing Telegram Web...", @"
                        & 'C:\Sailuo\scripts\install-app.ps1' -App 'telegram'
                    ");
                }));
            apps.AddCard(Card("TikTok Web", "Opens TikTok Web in its own window with a desktop shortcut.",
                "\uE8D4", Theme.Red, BrandIcon.TikTok, delegate
                {
                    RunTask("Installing TikTok Web...", @"
                        & 'C:\Sailuo\scripts\install-app.ps1' -App 'tiktok'
                    ");
                }));
            page.Controls.Add(apps);

            CardGroup personalize = new CardGroup("Personalization", "Look and feel", Theme.Cyan);
            personalize.AddCard(Card("Change desktop wallpaper", "Pick an image and apply it to this desktop now.",
                "\uE91B", Theme.Cyan, delegate { ChooseWallpaper(); }));
            page.Controls.Add(personalize);

            CardGroup maintenance = new CardGroup("Maintenance", "Keep the engine current", Theme.Green);
            maintenance.AddCard(Card("Update Sailuo engine", "Pull the latest scripts from GitHub without disconnecting the session.",
                "\uE72C", Theme.Green, delegate
                {
                    ConfirmAction("Update the Sailuo engine?",
                        "The latest scripts are pulled from GitHub and replace the files in C:\\Sailuo\\scripts. Your session stays connected.",
                        "Update now", Theme.Green, UpdateSailuoEngine);
                }));
            page.Controls.Add(maintenance);

            return page;
        }

        private void UpdateSailuoEngine(object sender, EventArgs e)
        {
            RunTask("Updating the Sailuo engine...", @"
                if (Test-Path 'C:\Sailuo\.git') {
                    Set-Location 'C:\Sailuo'
                    & git pull --rebase --autostash 2>&1 | ForEach-Object { Write-Host $_ }
                    Write-Host 'Sailuo engine updated.'
                } else {
                    Write-Host 'C:\Sailuo is not a git checkout - nothing to pull.'
                }
            ");
        }

        private PageView BuildSystemPage()
        {
            PageView page = NewPage();

            CardGroup display = new CardGroup("Display and performance", "Tune this desktop", Theme.Cyan);
            display.AddCard(Card("Sharpen text and display", "ClearType tuning plus a smoother desktop refresh for RDP.",
                "\uE7F4", Theme.Cyan, delegate
                {
                    RunTask("Tuning display sharpness...", @"
                        Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'FontSmoothing' -Value '2' -Force -ErrorAction SilentlyContinue
                        Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'FontSmoothingType' -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue
                        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
                        if ($isAdmin) {
                            Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations' -Name 'DWMFRAMEINTERVAL' -Value 8 -Type DWord -Force -ErrorAction SilentlyContinue
                            Write-Host 'Display sharpness settings applied.'
                        } else {
                            Write-Host 'Text smoothing applied. The desktop frame interval needs administrator rights and was skipped.'
                        }
                    ");
                }));
            page.Controls.Add(display);

            CardGroup automation = new CardGroup("Automation", "Taskbar and appearance", Theme.Green);
            automation.AddCard(Card("Apply Liquid Glass taskbar", "From inside this VM, install or repair the Windhawk clear taskbar theme.",
                "\uE790", Theme.Green, delegate
                {
                    RunTask("Applying the Liquid Glass taskbar theme...", @"
                        $setup = 'C:\Sailuo\scripts\setup-taskbar.ps1'
                        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
                        if ($isAdmin) {
                            & $setup
                        } else {
                            Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File C:\Sailuo\scripts\setup-taskbar.ps1'
                        }
                    ", delegate { RefreshSystemInfo(); });
                }));
            page.Controls.Add(automation);

            CardGroup diagnostics = new CardGroup("Files and diagnostics", "Inspect and export", Theme.Slate);
            diagnostics.AddCard(Card("Open Sailuo folder", "Inspect scripts, tools and the generated dashboard log files.",
                "\uE8B7", Theme.Blue, delegate
                {
                    Directory.CreateDirectory(@"C:\Sailuo");
                    Process.Start("explorer.exe", @"C:\Sailuo");
                    AppendLog("Opened C:\\Sailuo.", LogKind.Info);
                }));
            diagnostics.AddCard(Card("View this session log", "Open the activity history in a readable text window.",
                "\uE8A5", Theme.Slate, delegate
                {
                    string path = Path.Combine(Path.GetTempPath(), "sailuo-dashboard-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".log");
                    try
                    {
                        File.WriteAllText(path, _footer.Log.Text);
                        Process.Start("notepad.exe", path);
                        AppendLog("Session log written to " + path, LogKind.Info);
                    }
                    catch (Exception ex)
                    {
                        AppendLog("Could not write the log file: " + ex.Message, LogKind.Error);
                    }
                }));
            page.Controls.Add(diagnostics);

            return page;
        }

        private ActionCard Card(string title, string description, string glyph, Color accent, EventHandler action)
        {
            return Card(title, description, glyph, accent, BrandIcon.None, action);
        }

        private ActionCard Card(string title, string description, string glyph, Color accent, BrandIcon brand, EventHandler action)
        {
            ActionCard card = new ActionCard();
            card.CardTitle = title;
            card.CardDescription = description;
            card.Glyph = glyph;
            card.Brand = brand;
            card.Accent = accent;
            card.AccessibleName = title;
            card.AccessibleDescription = description;
            card.Activated += action;
            _busyControls.Add(card);
            return card;
        }

        // ------------------------------------------------------------------
        //  Responsive chrome
        // ------------------------------------------------------------------
        private void ApplyChrome()
        {
            if (_root == null || IsDisposed) { return; }
            int width = ClientSize.Width;
            int height = ClientSize.Height;
            if (width <= 0 || height <= 0) { return; }

            bool rail = width < Ui.S(1000);
            int sidebarWidth = Ui.S(rail ? UiConstants.SidebarRailWidth : UiConstants.SidebarWidth);
            _root.ColumnStyles[0].Width = sidebarWidth;
            _appliedSidebarWidth = sidebarWidth;

            int pageHeaderHeight = Ui.S(Ui.PageHeader);
            if (pageHeaderHeight != _appliedPageHeaderHeight)
            {
                _content.RowStyles[0].Height = pageHeaderHeight;
                _appliedPageHeaderHeight = pageHeaderHeight;
            }

            // On typical window sizes the activity log starts collapsed so the
            // actions stay above the fold; the reader can expand it at any time.
            if (!_autoCollapseDone)
            {
                _autoCollapseDone = true;
                if (height < Ui.S(1000) && !_footer.Collapsed) { _footer.SetCollapsed(true); }
            }

            int logLines = height >= Ui.S(900) ? 8 : (height >= Ui.S(780) ? 6 : 4);
            if (height < Ui.S(680)) { logLines = 3; }
            int logBoxHeight = logLines * (UiFonts.Mono.Height + Ui.S(2)) + Ui.S(6);
            _footer.LogBoxHeight = logBoxHeight;
            int footerHeight = _footer.PreferredHeight;
            int footerCap = Math.Max(Ui.S(120), height / 3);
            if (footerHeight > footerCap) { footerHeight = footerCap; }
            if (footerHeight != _appliedFooterHeight)
            {
                _content.RowStyles[2].Height = footerHeight;
                _appliedFooterHeight = footerHeight;
            }

            _pageHeader.SetCompact(width - sidebarWidth < Ui.S(760));
            _chromeReady = true;
            _root.PerformLayout();
        }

        protected override void OnClientSizeChanged(EventArgs e)
        {
            base.OnClientSizeChanged(e);
            if (!_chromeReady) { return; }
            ApplyChrome();
            // Page metrics depend on the new width; refresh the active page immediately.
            PageView active = ActivePage;
            if (active != null) { active.RelayoutSections(); }
            _pageHeader.PerformLayout();
            _footer.PerformLayout();
        }

        private PageView ActivePage
        {
            get
            {
                if (_currentPage == 1) { return _pageApps; }
                if (_currentPage == 2) { return _pageSystem; }
                return _pageHome;
            }
        }

        private void ShowPage(int index, bool focusNav)
        {
            if (index < 0 || index > 2) { index = 0; }
            _currentPage = index;
            _pageHome.Visible = index == 0;
            _pageApps.Visible = index == 1;
            _pageSystem.Visible = index == 2;
            _sidebar.SetSelected(index);

            if (index == 0)
            {
                _pageHeader.SetPage("Overview", "Session status, workspace shortcuts, and system maintenance.");
            }
            else if (index == 1)
            {
                _pageHeader.SetPage("Applications", "Install essential apps, personalize the desktop, and update Sailuo.");
            }
            else
            {
                _pageHeader.SetPage("System", "Display tuning, taskbar appearance, and diagnostics.");
            }

            PageView active = ActivePage;
            active.Visible = true;
            active.BringToFront();
            active.RelayoutSections();
            if (focusNav) { _sidebar.Items[index].Focus(); }

            if (index == 0 && _loadedShown) { LoadGitHubRunsOnce(); }
            if (index == 2) { RefreshSystemInfo(); }
        }

        private void OnFormKeyDown(object sender, KeyEventArgs e)
        {
            if (e.Control && e.Shift && e.KeyCode == Keys.L)
            {
                _footer.SetCollapsed(!_footer.Collapsed);
                ApplyChrome();
                e.SuppressKeyPress = true;
            }
            else if (e.Control && e.KeyCode == Keys.D1) { ShowPage(0, true); e.SuppressKeyPress = true; }
            else if (e.Control && e.KeyCode == Keys.D2) { ShowPage(1, true); e.SuppressKeyPress = true; }
            else if (e.Control && e.KeyCode == Keys.D3) { ShowPage(2, true); e.SuppressKeyPress = true; }
            else if (e.KeyCode == Keys.F5) { RefreshSystemInfo(); if (_currentPage == 0) { LoadGitHubRunsOnce(); } e.SuppressKeyPress = true; }
        }

        // ------------------------------------------------------------------
        //  DPI
        // ------------------------------------------------------------------
        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            ApplyDarkTitleBar();
            if (!_dpiApplied)
            {
                _dpiApplied = true;
                int dpi = Ui.Dpi;
                try
                {
                    uint current = Ui.GetDpiForWindow(Handle);
                    if (current >= 96) { dpi = (int)current; }
                }
                catch { }
                if (dpi != Ui.Dpi) { ApplyDpi(dpi); }
            }
        }

        private const int WM_DPICHANGED = 0x02E0;
        private const int WM_SETTINGCHANGE = 0x001A;

        [StructLayout(LayoutKind.Sequential)]
        private struct NativeRect
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [DllImport("user32.dll")]
        private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int x, int y, int cx, int cy, uint flags);

        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

        protected override void WndProc(ref Message message)
        {
            if (message.Msg == WM_DPICHANGED)
            {
                int dpi = (int)(message.WParam.ToInt64() & 0xFFFF);
                try
                {
                    NativeRect suggested = (NativeRect)Marshal.PtrToStructure(message.LParam, typeof(NativeRect));
                    SetWindowPos(Handle, IntPtr.Zero, suggested.Left, suggested.Top,
                        suggested.Right - suggested.Left, suggested.Bottom - suggested.Top, 0x0014 /* NOZORDER|NOACTIVATE */);
                }
                catch { }
                ApplyDpi(dpi);
                return;
            }
            base.WndProc(ref message);
        }

        private void ApplyDpi(int dpi)
        {
            if (dpi < 96) { dpi = 96; }
            Ui.Dpi = dpi;
            if (IsHandleCreated) { ApplyDarkTitleBar(); }
            Rectangle work;
            try { work = Screen.FromControl(this).WorkingArea; }
            catch { work = Screen.PrimaryScreen.WorkingArea; }
            MinimumSize = ClampMinimumSize(work);
            _appliedSidebarWidth = -1;
            _appliedFooterHeight = -1;
            _appliedPageHeaderHeight = -1;
            ApplyChrome();
            RelayoutTree(this);
            Invalidate(true);
            AppendLog("Display scaling changed: layout refreshed for " + (dpi * 100 / 96) + "% scaling.", LogKind.Muted);
        }

        private void RelayoutTree(Control root)
        {
            PageView page = root as PageView;
            if (page != null) { page.RelayoutSections(); }
            CardGrid grid = root as CardGrid;
            if (grid != null) { grid.PerformLayout(); }
            CardGroup group = root as CardGroup;
            if (group != null) { group.PerformLayout(); }
            foreach (Control child in root.Controls) { RelayoutTree(child); }
            root.PerformLayout();
            root.Invalidate();
        }

        private void ApplyDarkTitleBar()
        {
            try
            {
                int enabled = 1;
                if (DwmSetWindowAttribute(Handle, 20, ref enabled, sizeof(int)) != 0)
                {
                    DwmSetWindowAttribute(Handle, 19, ref enabled, sizeof(int));
                }
            }
            catch { }
        }

        // ------------------------------------------------------------------
        //  Status / log helpers
        // ------------------------------------------------------------------
        private void SetStatus(string text, Color color, string detail)
        {
            if (InvokeRequired)
            {
                Post(delegate { SetStatus(text, color, detail); });
                return;
            }
            _footer.SetStatus(text, color, detail);
            _footer.AccessibleName = "Status: " + text;
        }

        private void CopyLogToClipboard()
        {
            try
            {
                Clipboard.SetText(_footer.Log.Text);
                SetStatus("Log copied", Theme.Green, "Activity copied to the clipboard.");
            }
            catch { }
        }

        private void ClearLog()
        {
            _footer.Log.Clear();
            AppendLog("Activity cleared.", LogKind.Muted);
        }

        private void AppendLog(string message, LogKind kind)
        {
            if (_footer == null) { return; }
            if (InvokeRequired) { Post(delegate { AppendLog(message, kind); }); return; }

            RichTextBox log = _footer.Log;
            Color color;
            switch (kind)
            {
                case LogKind.Ok: color = Theme.Green; break;
                case LogKind.Warn: color = Theme.Amber; break;
                case LogKind.Error: color = Theme.Red; break;
                case LogKind.Muted: color = Theme.TextMuted; break;
                default: color = Theme.TextSoft; break;
            }

            // Only auto-scroll when the reader is already at the bottom (or the
            // panel is collapsed, so re-opening it shows the newest entries).
            bool atBottom = !log.Visible || log.TextLength == 0 ||
                            log.GetCharIndexFromPosition(new Point(1, Math.Max(1, log.ClientSize.Height - 2))) >= log.TextLength - 2;

            log.SelectionStart = log.TextLength;
            log.SelectionColor = Theme.TextMuted;
            log.AppendText("[" + DateTime.Now.ToString("HH:mm:ss") + "]  ");
            log.SelectionColor = color;
            log.AppendText(message + Environment.NewLine);
            log.SelectionColor = Theme.TextSoft;
            log.SelectionStart = log.TextLength;
            if (atBottom) { log.ScrollToCaret(); }
        }

        private void SetBusy(bool busy)
        {
            foreach (Control control in _busyControls)
            {
                control.Enabled = !busy;
            }
            _footer.Progress.Visible = busy;
            _footer.Progress.Active = busy;
        }

        // ------------------------------------------------------------------
        //  Clock and system status
        // ------------------------------------------------------------------
        private void OnClock(object sender, EventArgs e)
        {
            _ticks++;
            if (_ticks % 30 == 0) { RefreshSystemInfo(); }
        }

        private void RefreshSystemInfo()
        {
            try
            {
                DriveInfo drive = new DriveInfo("C");
                if (drive.IsReady)
                {
                    double freeGb = drive.AvailableFreeSpace / (1024.0 * 1024 * 1024);
                    double totalGb = drive.TotalSize / (1024.0 * 1024 * 1024);
                    double usedRatio = totalGb > 0 ? 1.0 - freeGb / totalGb : 0.0;
                    string meta = string.Format("of {0:0.#} GB ({1:0}% used)", totalGb, usedRatio * 100);
                    _stats.SetTile(0, "STORAGE", string.Format("{0:0.#} GB free", freeGb), meta,
                        (float)usedRatio, usedRatio > 0.9 ? Theme.Red : (usedRatio > 0.8 ? Theme.Amber : Theme.Green));
                }
                else
                {
                    _stats.SetTile(0, "STORAGE", "Unavailable", "The C: drive is not ready", -1f);
                }

                TimeSpan uptime = TimeSpan.FromMilliseconds(GetTickCount64());
                string uptimeValue = uptime.TotalDays >= 1
                    ? string.Format("{0}d {1}h {2}m", (int)uptime.TotalDays, uptime.Hours, uptime.Minutes)
                    : string.Format("{0}h {1}m", uptime.Hours, uptime.Minutes);
                _stats.SetTile(1, "SYSTEM UPTIME", uptimeValue, "Time since the last reboot", -1f);
                RefreshTaskbarInfo();
            }
            catch { }
        }

        private void RefreshTaskbarInfo()
        {
            try
            {
                using (Microsoft.Win32.RegistryKey key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(
                    @"SOFTWARE\Windhawk\Engine\Mods\windows-11-taskbar-styler"))
                {
                    if (key == null)
                    {
                        _stats.SetTile(2, "TASKBAR THEME", "Not installed", "Apply it from the System page", -1f, Theme.Amber);
                        return;
                    }

                    object disabled = key.GetValue("Disabled");
                    bool off = disabled != null && Convert.ToInt32(disabled, CultureInfo.InvariantCulture) != 0;
                    using (Microsoft.Win32.RegistryKey settings = key.OpenSubKey("Settings"))
                    {
                        string theme = settings == null ? string.Empty : (settings.GetValue("theme") as string) ?? string.Empty;
                        bool clear = theme.IndexOf("ClearTaskbar", StringComparison.OrdinalIgnoreCase) >= 0;
                        string value = clear ? "Liquid Glass" : (string.IsNullOrEmpty(theme) ? "Not configured" : theme);
                        string meta = off ? "Mod is disabled" : (clear ? "Clear taskbar style" : "Theme applied");
                        _stats.SetTile(2, "TASKBAR THEME", value, meta, -1f, off ? Theme.Amber : Theme.Green);
                    }
                }
            }
            catch
            {
                _stats.SetTile(2, "TASKBAR THEME", "Unknown", "Could not read the Windhawk configuration", -1f, Theme.Slate);
            }
        }

        [DllImport("kernel32.dll")]
        private static extern ulong GetTickCount64();

        // ------------------------------------------------------------------
        //  Actions
        // ------------------------------------------------------------------
        private void ConfirmAction(string title, string message, string acceptText, Color accent, EventHandler action)
        {
            using (ConfirmDialog dialog = new ConfirmDialog(title, message, acceptText, accent))
            {
                if (dialog.ShowDialog(this) == DialogResult.OK && dialog.Confirmed)
                {
                    if (action != null) { action(this, EventArgs.Empty); }
                }
            }
        }

        private void ChooseWallpaper()
        {
            using (OpenFileDialog dialog = new OpenFileDialog())
            {
                dialog.Title = "Choose a desktop wallpaper";
                dialog.Filter = "Images (*.jpg;*.jpeg;*.png;*.bmp)|*.jpg;*.jpeg;*.png;*.bmp";
                if (dialog.ShowDialog(this) != DialogResult.OK) { return; }
                string chosen = dialog.FileName.Replace("'", "''");
                RunTask("Applying and saving the wallpaper...", @"
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
                    Write-Host ""Wallpaper applied and saved to $dstPer.""
                ");
            }
        }

        private static string GetSessionEnv(string key)
        {
            try
            {
                string path = @"C:\Sailuo\tools\session-env.json";
                if (!File.Exists(path)) { return string.Empty; }
                string json = File.ReadAllText(path);
                Match match = Regex.Match(json, "\"" + key + "\"\\s*:\\s*\"([^\"]*)\"");
                return match.Success ? match.Groups[1].Value : string.Empty;
            }
            catch { return string.Empty; }
        }

        //  GitHub Actions
        // ------------------------------------------------------------------
        private void RefreshGitHubRuns()
        {
            if (_github == null) { return; }
            _github.SetStatus("Loading...");
            _github.SetLoading(true);
            _github.RunsList.Items.Clear();
            _githubRunUrls.Clear();
            ThreadPool.QueueUserWorkItem(delegate
            {
                try
                {
                    string token = Environment.GetEnvironmentVariable("GITHUB_TOKEN");
                    string repo = Environment.GetEnvironmentVariable("GITHUB_REPOSITORY");
                    if (string.IsNullOrEmpty(repo)) { repo = GetSessionEnv("GITHUB_REPOSITORY"); }
                    if (string.IsNullOrEmpty(token)) { token = GetSessionEnv("GITHUB_TOKEN"); }
                    if (string.IsNullOrEmpty(repo)) { repo = "Seijii-Dev/Sailuo"; }
                    string url = "https://api.github.com/repos/" + repo + "/actions/runs?per_page=8";
                    System.Net.WebRequest request = System.Net.WebRequest.Create(url);
                    request.Method = "GET";
                    System.Net.HttpWebRequest http = (System.Net.HttpWebRequest)request;
                    http.UserAgent = "Sailuo-Dashboard";
                    http.Accept = "application/vnd.github+json";
                    http.Timeout = 15000;
                    if (!string.IsNullOrEmpty(token)) { request.Headers["Authorization"] = "Bearer " + token; }
                    using (System.Net.WebResponse response = request.GetResponse())
                    using (StreamReader reader = new StreamReader(response.GetResponseStream()))
                    {
                        string json = reader.ReadToEnd();
                        int marker = json.IndexOf("\"workflow_runs\"");
                        if (marker >= 0) { json = json.Substring(marker); }
                        int arrayStart = json.IndexOf('[');
                        if (arrayStart < 0) { throw new Exception("no runs array"); }
                        int depth = 0;
                        int arrayEnd = -1;
                        for (int index = arrayStart; index < json.Length; index++)
                        {
                            char character = json[index];
                            if (character == '[' || character == '{') { depth++; }
                            else if (character == ']' || character == '}') { depth--; if (depth == 0) { arrayEnd = index; break; } }
                        }
                        if (arrayEnd < 0) { throw new Exception("unterminated array"); }
                        string body = json.Substring(arrayStart + 1, arrayEnd - arrayStart - 1);
                        List<string> runObjects = new List<string>();
                        int level = 0;
                        int start = -1;
                        for (int index = 0; index < body.Length; index++)
                        {
                            char character = body[index];
                            if (character == '{') { if (level == 0) { start = index; } level++; }
                            else if (character == '}') { level--; if (level == 0 && start >= 0) { runObjects.Add(body.Substring(start, index - start + 1)); start = -1; } }
                        }
                        List<string> lines = new List<string>();
                        List<string> urls = new List<string>();
                        List<string> ids = new List<string>();
                        List<string> statuses = new List<string>();
                        foreach (string runObject in runObjects)
                        {
                            Match idMatch = Regex.Match(runObject, "\"id\"\\s*:\\s*(\\d+)");
                            Match nameMatch = Regex.Match(runObject, "\"name\"\\s*:\\s*\"([^\"]*)\"");
                            Match statusMatch = Regex.Match(runObject, "\"status\"\\s*:\\s*\"([^\"]*)\"");
                            Match conclusionMatch = Regex.Match(runObject, "\"conclusion\"\\s*:\\s*(\"[^\"]*\"|null)");
                            Match createdMatch = Regex.Match(runObject, "\"created_at\"\\s*:\\s*\"([^\"]*)\"");
                            Match urlMatch = Regex.Match(runObject, "\"html_url\"\\s*:\\s*\"([^\"]*)\"");
                            if (!nameMatch.Success || !urlMatch.Success) { continue; }
                            string name = nameMatch.Groups[1].Value;
                            string status = statusMatch.Success ? statusMatch.Groups[1].Value : string.Empty;
                            string conclusion = conclusionMatch.Success ? conclusionMatch.Groups[1].Value.Trim('"') : string.Empty;
                            if (conclusion == "null") { conclusion = string.Empty; }
                            string created = createdMatch.Success ? createdMatch.Groups[1].Value : string.Empty;
                            string tag = status == "completed"
                                ? (string.IsNullOrEmpty(conclusion) ? "done" : conclusion)
                                : (string.IsNullOrEmpty(status) ? "unknown" : status);
                            string markerGlyph = status == "completed"
                                ? (conclusion == "success" ? "\u2713" : (conclusion == "failure" ? "\u2717" : "\u2022"))
                                : "\u25CF";
                            string when = created.Length >= 16 ? created.Substring(0, 16).Replace("T", " ") : created;
                            lines.Add(string.Format("{0} {1}  [{2}]  {3}", markerGlyph, tag.ToUpperInvariant(), when, name));
                            urls.Add(urlMatch.Groups[1].Value);
                            ids.Add(idMatch.Success ? idMatch.Groups[1].Value : string.Empty);
                            statuses.Add(status);
                        }
                        Post(new Action<List<string>, List<string>, List<string>, List<string>>(
                            delegate(List<string> lineList, List<string> urlList, List<string> idList, List<string> statusList)
                            {
                                _github.RunsList.Items.Clear();
                                _githubRunUrls.Clear();
                                _githubRunIds.Clear();
                                _githubRunStatuses.Clear();
                                foreach (string line in lineList) { _github.RunsList.Items.Add(line); }
                                foreach (string address in urlList) { _githubRunUrls.Add(address); }
                                foreach (string id in idList) { _githubRunIds.Add(id); }
                                foreach (string state in statusList) { _githubRunStatuses.Add(state); }
                                _github.SetStatus(lineList.Count == 0 ? "No runs yet" : lineList.Count + " runs");
                                _github.SetLoading(false);
                                int autoIndex = -1;
                                for (int index = 0; index < _githubRunStatuses.Count; index++)
                                {
                                    if (_githubRunStatuses[index] == "completed") { autoIndex = index; break; }
                                }
                                if (autoIndex >= 0)
                                {
                                    _github.RunsList.SelectedIndex = autoIndex;
                                    ViewGitHubRunLog();
                                }
                            }), lines, urls, ids, statuses);
                    }
                }
                catch (Exception ex)
                {
                    Post(new Action<string>(delegate(string message)
                    {
                        _github.SetError("Error: " + message);
                        _github.SetLoading(false);
                    }), ex.Message);
                }
            });
        }

        private void OpenSelectedGitHubRun()
        {
            if (_github == null) { return; }
            int index = _github.SelectedRunIndex();
            if (index < 0 || index >= _githubRunUrls.Count) { return; }
            try { Process.Start(_githubRunUrls[index]); }
            catch (Exception ex) { AppendLog("Could not open run: " + ex.Message, LogKind.Warn); }
        }

        private void ViewGitHubRunLog()
        {
            if (_github == null) { return; }
            int index = _github.SelectedRunIndex();
            if (index < 0 || index >= _githubRunIds.Count) { return; }
            string runId = _githubRunIds[index];
            if (string.IsNullOrEmpty(runId)) { return; }
            _github.SetStatus("Loading log...");
            _github.LogView.Text = "Loading...";
            ThreadPool.QueueUserWorkItem(delegate
            {
                try
                {
                    string token = Environment.GetEnvironmentVariable("GITHUB_TOKEN");
                    string repo = Environment.GetEnvironmentVariable("GITHUB_REPOSITORY");
                    if (string.IsNullOrEmpty(repo)) { repo = GetSessionEnv("GITHUB_REPOSITORY"); }
                    if (string.IsNullOrEmpty(token)) { token = GetSessionEnv("GITHUB_TOKEN"); }
                    if (string.IsNullOrEmpty(repo)) { repo = "Seijii-Dev/Sailuo"; }

                    string jobsUrl = "https://api.github.com/repos/" + repo + "/actions/runs/" + runId + "/jobs";
                    System.Net.HttpWebRequest jobsRequest = (System.Net.HttpWebRequest)System.Net.WebRequest.Create(jobsUrl);
                    jobsRequest.Method = "GET";
                    jobsRequest.UserAgent = "Sailuo-Dashboard";
                    jobsRequest.Accept = "application/vnd.github+json";
                    jobsRequest.Timeout = 15000;
                    if (!string.IsNullOrEmpty(token)) { jobsRequest.Headers["Authorization"] = "Bearer " + token; }
                    string jobsJson;
                    using (System.Net.WebResponse jobsResponse = jobsRequest.GetResponse())
                    using (StreamReader jobsReader = new StreamReader(jobsResponse.GetResponseStream()))
                    {
                        jobsJson = jobsReader.ReadToEnd();
                    }

                    string jobId = string.Empty;
                    int jobsMarker = jobsJson.IndexOf("\"jobs\"");
                    if (jobsMarker >= 0)
                    {
                        string tail = jobsJson.Substring(jobsMarker);
                        int arrayStart = tail.IndexOf('[');
                        int depth = 0;
                        int end = -1;
                        for (int scanIndex = arrayStart; scanIndex < tail.Length; scanIndex++)
                        {
                            char character = tail[scanIndex];
                            if (character == '[' || character == '{') { depth++; }
                            else if (character == ']' || character == '}') { depth--; if (depth == 0) { end = scanIndex; break; } }
                        }
                        if (end >= 0)
                        {
                            string body = tail.Substring(arrayStart + 1, end - arrayStart - 1);
                            int level = 0;
                            int start = -1;
                            for (int bodyIndex = 0; bodyIndex < body.Length; bodyIndex++)
                            {
                                char character = body[bodyIndex];
                                if (character == '{') { if (level == 0) { start = bodyIndex; } level++; }
                                else if (character == '}')
                                {
                                    level--;
                                    if (level == 0 && start >= 0)
                                    {
                                        string jobObject = body.Substring(start, bodyIndex - start + 1);
                                        Match idMatch = Regex.Match(jobObject, "\"id\"\\s*:\\s*(\\d+)");
                                        if (idMatch.Success) { jobId = idMatch.Groups[1].Value; break; }
                                        start = -1;
                                    }
                                }
                            }
                        }
                    }
                    if (string.IsNullOrEmpty(jobId)) { throw new Exception("no job found"); }

                    string logUrl = "https://api.github.com/repos/" + repo + "/actions/jobs/" + jobId + "/logs";
                    System.Net.HttpWebRequest logRequest = (System.Net.HttpWebRequest)System.Net.WebRequest.Create(logUrl);
                    logRequest.Method = "GET";
                    logRequest.UserAgent = "Sailuo-Dashboard";
                    logRequest.Accept = "*/*";
                    if (!string.IsNullOrEmpty(token)) { logRequest.Headers["Authorization"] = "Bearer " + token; }
                    logRequest.AllowAutoRedirect = true;
                    logRequest.Timeout = 15000;
                    byte[] logBytes;
                    using (System.Net.WebResponse logResponse = logRequest.GetResponse())
                    using (Stream stream = logResponse.GetResponseStream())
                    using (MemoryStream memory = new MemoryStream())
                    {
                        byte[] buffer = new byte[8192];
                        int read;
                        while ((read = stream.Read(buffer, 0, buffer.Length)) > 0) { memory.Write(buffer, 0, read); }
                        logBytes = memory.ToArray();
                    }

                    string logText = string.Empty;
                    try
                    {
                        using (MemoryStream memory = new MemoryStream(logBytes))
                        using (ZipArchive archive = new ZipArchive(memory))
                        {
                            ZipArchiveEntry entry = null;
                            foreach (ZipArchiveEntry candidate in archive.Entries)
                            {
                                if (candidate.Name.EndsWith(".txt", StringComparison.OrdinalIgnoreCase)) { entry = candidate; break; }
                            }
                            if (entry == null && archive.Entries.Count > 0) { entry = archive.Entries[0]; }
                            if (entry != null)
                            {
                                using (StreamReader reader = new StreamReader(entry.Open())) { logText = reader.ReadToEnd(); }
                            }
                        }
                    }
                    catch
                    {
                        logText = Encoding.UTF8.GetString(logBytes);
                    }
                    if (string.IsNullOrEmpty(logText)) { logText = Encoding.UTF8.GetString(logBytes); }
                    if (logText.Length > 25000) { logText = logText.Substring(logText.Length - 25000); }

                    string statusMessage = "Log loaded (" + logBytes.Length + " bytes).";
                    AppendLog("GitHub log loaded: " + logBytes.Length + " bytes", LogKind.Ok);
                    Post(new Action<string, string>(delegate(string text, string status)
                    {
                        if (_github != null) { _github.LogView.Text = text; }
                        if (_github != null) { _github.SetStatus(status); }
                    }), logText, statusMessage);
                }
                catch (Exception ex)
                {
                    AppendLog("GitHub log error: " + ex.Message, LogKind.Error);
                    Post(new Action<string>(delegate(string message)
                    {
                        if (_github == null) { return; }
                        _github.SetError("Error: " + message);
                        _github.LogView.Text = message;
                    }), ex.Message);
                }
            });
        }

        // ------------------------------------------------------------------
        //  Task runner
        // ------------------------------------------------------------------
        /// <summary>
        /// Runs a PowerShell snippet in the background, streams its output into
        /// the activity log and reports the real process exit code.
        /// </summary>
        private void RunTask(string label, string psCommand)
        {
            RunTask(label, psCommand, null);
        }

        private void RunTask(string label, string psCommand, Action onComplete)
        {
            if (_running)
            {
                AppendLog("A task is already running. Wait for it to finish.", LogKind.Warn);
                SetStatus("Busy", Theme.Amber, _runningLabel + " is still running.");
                return;
            }

            _running = true;
            _runningLabel = label;
            SetStatus(label, Theme.Blue, "Working in the background...");
            SetBusy(true);
            AppendLog(label, LogKind.Info);

            ThreadPool.QueueUserWorkItem(delegate
            {
                int exitCode = -1;
                string temporaryScript = Path.Combine(Path.GetTempPath(), "sailuo_task_" + Guid.NewGuid().ToString("N") + ".ps1");
                try
                {
                    File.WriteAllText(temporaryScript, psCommand, Encoding.UTF8);

                    ProcessStartInfo info = new ProcessStartInfo();
                    info.FileName = "powershell.exe";
                    info.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File \"" + temporaryScript + "\"";
                    info.UseShellExecute = false;
                    info.RedirectStandardOutput = true;
                    info.RedirectStandardError = true;
                    info.CreateNoWindow = true;
                    info.StandardOutputEncoding = Encoding.UTF8;
                    info.StandardErrorEncoding = Encoding.UTF8;

                    using (Process process = Process.Start(info))
                    {
                        process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs args)
                        {
                            if (!string.IsNullOrEmpty(args.Data)) { AppendOutput(args.Data, false); }
                        };
                        process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs args)
                        {
                            if (!string.IsNullOrEmpty(args.Data)) { AppendOutput(args.Data, true); }
                        };
                        process.BeginOutputReadLine();
                        process.BeginErrorReadLine();
                        process.WaitForExit();
                        exitCode = process.ExitCode;
                    }
                }
                catch (Exception ex)
                {
                    AppendLog("Task failed: " + ex.Message, LogKind.Error);
                }
                finally
                {
                    try { File.Delete(temporaryScript); } catch { }
                    try
                    {
                        Post(delegate
                        {
                            _running = false;
                            _runningLabel = string.Empty;
                            SetBusy(false);
                            if (exitCode == 0)
                            {
                                SetStatus("Ready", Theme.Green, label.TrimEnd('.') + " completed.");
                                AppendLog("Done: " + label.TrimEnd('.'), LogKind.Ok);
                            }
                            else
                            {
                                SetStatus("Finished with warnings", Theme.Amber, "Check the activity log for details.");
                                AppendLog("Finished with exit code " + exitCode + ": " + label.TrimEnd('.'), LogKind.Warn);
                            }
                            if (onComplete != null) { onComplete(); }
                        });
                    }
                    catch { }
                }
            });
        }

        private void AppendOutput(string line, bool stderr)
        {
            string lower = line.ToLowerInvariant();
            LogKind kind;
            if (stderr) { kind = LogKind.Warn; }
            else if (lower.Contains("error") || lower.Contains("failed") || lower.Contains("gagal")) { kind = LogKind.Error; }
            else if (lower.Contains("success") || lower.Contains("berhasil") || lower.Contains("[ok]") || lower.Contains("ready")) { kind = LogKind.Ok; }
            else { kind = LogKind.Info; }
            AppendLog(line, kind);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                try { if (_clock != null) { _clock.Stop(); _clock.Dispose(); } } catch { }
                try { _tips.Dispose(); } catch { }
            }
            base.Dispose(disposing);
        }

        // ------------------------------------------------------------------
        //  Entry point
        // ------------------------------------------------------------------
        [STAThread]
        public static void Main()
        {
            Ui.EnableDpiAwareness();
            string dpiOverride = Environment.GetEnvironmentVariable("SAILUO_DASH_DPI");
            int forcedDpi;
            if (!string.IsNullOrEmpty(dpiOverride) &&
                int.TryParse(dpiOverride, NumberStyles.Integer, CultureInfo.InvariantCulture, out forcedDpi) &&
                forcedDpi >= 96 && forcedDpi <= 384)
            {
                Ui.ForcedDpi = forcedDpi;
            }

            bool createdNew = false;
            using (Mutex mutex = new Mutex(true, "Global\\SailuoDashboardSingleton", out createdNew))
            {
                if (!createdNew)
                {
                    ActivateExistingDashboard();
                    return;
                }
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new MainForm());
            }
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr FindWindow(string className, string windowName);

        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int command);

        private static void ActivateExistingDashboard()
        {
            try
            {
                IntPtr handle = FindWindow(null, "Sailuo Dashboard");
                if (handle != IntPtr.Zero)
                {
                    ShowWindow(handle, 9 /* SW_RESTORE */);
                    SetForegroundWindow(handle);
                }
            }
            catch { }
        }
    }

    internal enum LogKind
    {
        Info,
        Ok,
        Warn,
        Error,
        Muted
    }
}

'@

try {
  $csFile = Join-Path $toolsDir 'SailuoDashboard.cs'
  Set-Content -LiteralPath $csFile -Value $csharpSource -Encoding UTF8 -Force
  $cscExe = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
  Remove-Item -LiteralPath $exePath -Force -ErrorAction SilentlyContinue
  if (Test-Path $cscExe) {
    # System.IO.Compression* is required by the GitHub run-log viewer (ZipArchive).
    $cscArgs = @('/nologo', '/target:winexe', "/out:$exePath",
      '/r:System.dll', '/r:System.Drawing.dll', '/r:System.Windows.Forms.dll',
      '/r:System.IO.Compression.dll', '/r:System.IO.Compression.FileSystem.dll', '/r:System.Web.Extensions.dll')
    if (Test-Path $dashIco) { $cscArgs += "/win32icon:$dashIco" }
    $cscArgs += $csFile
    $cscOutput = & $cscExe @cscArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
      # Never leave a stale exe in place behind a failed compile.
      $cscOutput | Select-Object -First 20 | ForEach-Object { Log "csc: $_" }
      throw "SailuoDashboard.cs did not compile (csc exit code $LASTEXITCODE)."
    }
  } else {
    Add-Type -TypeDefinition $csharpSource `
      -ReferencedAssemblies @('System.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll', 'System.IO.Compression.dll', 'System.IO.Compression.FileSystem.dll', 'System.Web.Extensions.dll') `
      -OutputAssembly $exePath `
      -OutputType WindowsApplication `
      -ErrorAction Stop
  }
  if (-not (Test-Path $exePath)) { throw 'SailuoDashboard.exe was not produced by the build step.' }

  if (Test-Path $exePath) {
    Copy-Item -LiteralPath $exePath -Destination $legacyExePath -Force -ErrorAction SilentlyContinue
    Log "SailuoDashboard.exe compiled successfully at $exePath"

    # Exactly one dashboard shortcut, on the shared Public desktop. Keeping a
    # copy on both the user and Public desktops made Windows show it twice.
    $publicDesk = 'C:\Users\Public\Desktop'
    foreach ($desk in @("C:\Users\$u\Desktop", $publicDesk, 'C:\Users\Default\Desktop')) {
      if (-not (Test-Path $desk)) {
        New-Item -ItemType Directory -Path $desk -Force -ErrorAction SilentlyContinue | Out-Null
      }
      try {
        Remove-Item -LiteralPath (Join-Path $desk 'SailuoTools.exe') -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $desk 'Sailuo Gaming & Tools Hub.lnk') -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $desk 'SailuoRemote Dashboard.lnk') -Force -ErrorAction SilentlyContinue
        if ($desk -ne $publicDesk) {
          Remove-Item -LiteralPath (Join-Path $desk 'Sailuo Dashboard.lnk') -Force -ErrorAction SilentlyContinue
        }
      } catch {}
    }
    try {
      $wsh = New-Object -ComObject WScript.Shell
      $lnk = $wsh.CreateShortcut((Join-Path $publicDesk 'Sailuo Dashboard.lnk'))
      $lnk.TargetPath = $exePath
      $lnk.WorkingDirectory = $toolsDir
      $lnk.Description = 'Sailuo Dashboard - applications and system tools'
      $lnk.IconLocation = "$exePath,0"
      $lnk.Save()
    } catch {}

    # Open the dashboard automatically on the first RDP desktop sign-in.
    try {
      Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' 'SailuoDashboard' "`"$exePath`"" 'String' | Out-Null
      Set-RegBoth 'Software\Microsoft\Windows\CurrentVersion\Run' 'SailuoDashboard' "`"$exePath`"" 'String' | Out-Null
      # The Run entry is enough; a Startup-folder shortcut would launch it twice.
      $commonStartup = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp'
      Remove-Item -LiteralPath (Join-Path $commonStartup 'Sailuo Dashboard.lnk') -Force -ErrorAction SilentlyContinue
      Log 'Sailuo Dashboard registered for auto-start on the next desktop sign-in.'
    } catch {}

    Update-Status @{ tools_hub = @{ installed = $true; exe = $exePath; auto_start = $true } } | Out-Null
  }
} catch {
  Log "SailuoDashboard.exe compile warning: $($_.Exception.Message)"
}

# Remove shortcuts, scripts and the scheduled task left behind by the retired
# save/restore session feature. This is best-effort and never blocks the setup.
$retiredShortcuts = @(
  'Save Session Data Now (Cloud Save).lnk',
  'Permanent Folder (Anti-Reset).lnk',
  'Save Session.lnk',
  'Restore Session.lnk',
  'Restore Session Data.lnk'
)
foreach ($desk in @("C:\Users\$u\Desktop", "C:\Users\Public\Desktop", 'C:\Users\Default\Desktop')) {
  foreach ($shortcut in $retiredShortcuts) {
    Remove-Item -LiteralPath (Join-Path $desk $shortcut) -Force -ErrorAction SilentlyContinue
  }
}
foreach ($retiredScript in @('install-state-sync.ps1', 'persist-state.ps1', 'restore-state.ps1', 'save-snapshot.ps1')) {
  Remove-Item -LiteralPath (Join-Path $scriptsDir $retiredScript) -Force -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath (Join-Path $toolsDir 'last-checkpoint-sig.txt') -Force -ErrorAction SilentlyContinue
foreach ($workDir in @('restore-work', 'state-work')) {
  Remove-Item -LiteralPath (Join-Path (Split-Path -Parent $toolsDir) $workDir) -Recurse -Force -ErrorAction SilentlyContinue
}
try { $null = & schtasks.exe /Delete /TN 'Sailuo Cloud Save' /F 2>&1 } catch {}
try {
  $statusPath = Get-StatusPath
  if (Test-Path $statusPath) {
    $status = Get-Content $statusPath -Raw | ConvertFrom-Json
    $changed = $false
    foreach ($retired in @('persist', 'state_sync')) {
      if ($status.PSObject.Properties[$retired]) { $status.PSObject.Properties.Remove($retired); $changed = $true }
    }
    if ($changed) { ($status | ConvertTo-Json -Depth 8) | Set-Content -Path $statusPath -Encoding utf8 }
  }
} catch {}

# Taskbar theme setup is launched on demand from the Dashboard's Automation card.
Log 'Dashboard setup complete; apply the taskbar theme from the Dashboard inside the VM.'
exit 0
