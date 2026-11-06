# ============================================================================
#  setup-tools-hub.ps1 - Build & Install "Sailuo Dashboard" (GUI Desktop)
# ----------------------------------------------------------------------------
#  Compiles the native WinForms dashboard (C:\Sailuo\tools\SailuoDashboard.exe)
#  with the .NET Framework 4.x C# compiler bundled with Windows Server 2022/2025.
#  The dashboard opens automatically the first time the user signs in to the
#  RDP desktop and provides one-click control for:
#    1. Overview  - workspace shortcuts, session status and maintenance
#    2. Apps      - Chrome, Discord, Facebook, Instagram, Apple Music, Spotify,
#                   VS Code, Antigravity IDE, OpenCode Desktop, wallpaper,
#                   engine updates
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
        OpenCode = 8
    }

    /// <summary>
    /// Draws the embedded brand-icon sprite sheet. Keeping the sheet in the
    /// assembly means the dashboard still ships as one self-contained exe and
    /// never depends on an external asset folder at runtime.
    /// </summary>
    internal static class BrandIcons
    {
        private const int Cell = 96;
        private const int Columns = 5;

        private static readonly string SheetBase64 =
            "iVBORw0KGgoAAAANSUhEUgAAAeAAAADACAYAAADcD7AXAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAAGYktHRAAAAAAA" +
            "APlDu38AAIAASURBVHja7J13nFxl2f6/93NmZvum92RTCAmBhJIgvYkgTawoQUWCEhUF7AZUBAVfCfq+FlSU6I9gI0gTQUGkKl0InSUBEti0TU82my0zc577" +
            "98dzpu3ObnZ2Z3Y2yVz5nEw95zznmbPnOne7biihhBJKKKGEEkoooYQSSiihhL0BUuwBZMOqow+sBMYBU4F9gRnAJGBEsNQAZcEC0B4sO4CNwfI28Brwpltk" +
            "7YTHX9xZ7GMroYRdYfSCpipgPO783w+YDkwERgFDgEG4cz8SrBLFnf/bga1AI/AOsBx4neD8b1xYs6PYx1ZCCSWkMCAIeNXRB3mgo4GDgSODx+m4C04l4PVy" +
            "0z7QAmzAEfFS4AnQF4ywbtxjL/vFPvYSShj7zSbPCuOBA4GjcOf/NGAk7vw3vdy0BXYCm4C3gBeAxwWet7Bm/cLaeLGPvYQS9mYUlYBXHXXgKIRjgDOAI3BW" +
            "bkWBd9uGs46fBO4FHpvw+EvrijkPJeydGL2gaSxwHPBe4BigjpRXp1BoBxpw5/99wH8aF9auLvZclFDC3oh+J+DVxxzoqTIL+ChwOs69XOiLTleI4lx0fwdu" +
            "R/XFCU+8XLIKSigYxixoCikcApwFnIZzMYeLNJwYzk39D+A2tTy//ke1sWLPUa743gcfGNZYET58fVm4LuJzWFh1tg+jo+INUvBEwSKeKIgCKgYEUTDBe8lH" +
            "6y6K6a8Tz7N+P/FZsI5RTb1P+nqafG3UuTSMqhrFF1BRxYAaVV8UP/g8atAdBt0gKssUno+gy8s09sq5z574drHnPYH4ud/wVHUCcBDu3J6BC5kMx4ULK3Dn" +
            "uBcsvfXoFBoW5zX1cX8brbiw5iZcSOd1nBf1JaAh/Mcf99mD2m8EvPrIWWE1ciRwLo54x/bXvnuIRpxFfJMoT4x/4qXd7kJUwsDF6AVNEZx7+XzgFFx4ZSBh" +
            "I84iXgw83riwtr3YA+oOz777b95vJgya3CreR7eFvfeIcmBMzHCLSJLkFMQmSE86EWq+yNeRrXZ+H5CAkFOvU+ScTsoBAWeul3ytiXGpQbcYdLmn+rgn9vaw" +
            "ib/4iWdOai3GbxD75NcHAScAH8CFDicAVcU+NwqMFmAVzoN0F/BI+I8/3tbbjRWcgNcec6D4ymzgs7i7/qH9M0+9xhbgTuA3Ynlu/JMv2WIPqITdF6O/uk0I" +
            "m8OBC4EzcUlUAxnbgHuAX2Hk6cYf1gy48//iTzwyZX15+FM7PfOpNmPqVPEEcYRps5Nv4nVW8kxfp8Nj1wQcEC6CsdqBWBPEK0kyzSBf1dT3SN9W2nc7fC4E" +
            "RJxO3sIGD3t3WPW3n1h6wlP9Nf+xT3y1HOR9wBcQORIoL/Y5USS0o/oUcD3o38J/+r+cb4QKSsCrjj5wHO7Ccz4Dz+LdFdYBNwK/nvD4S6uKPZgSdj+MXtA0" +
            "EXf+fwoYU+zx5Ij1OGv4+saFte8UezAAvz317vCjowa9b2tZ6FstnpljEUmRpyPZpNVqs1uyRqVbwu3K8u1IrkmLWjsSaLoF3NH61SykK5nu6STJpn03eC9B" +
            "zJL+HcCovhXC/tKT+I1nLz15WyF/g9jHvzYN4Ts4Y6rQ+Tq7C9qA21GuCv/5f5flsmJBCHj1MTPDquZM4JvA4cWenT7iWWChqN41/omXS27pEnaJUQu2hwX5" +
            "AHApMKfY4+kjlgILUf1r47WDosUaxHfOeqBiZU3kyxvKwl+NGTOcNKI0FmdtJp+TScYdv5PxXs+t36wWcIZrOd1Czfws3QrOcFd3fI+OlrBmuKGTrmnSXNiO" +
            "iKMG+4cw+r2znn9PQQyG2Me/ehLwv7hs/RI642Xga+E//9+/erpC3gl41dEHjga+DswHaos9I3nCDuC3ID+e8PiLa4s9mBIGLkYvaBoHfAP4NC4BZU9AM84b" +
            "tLBxYe2a/t755R/+Z+VbtZXf2lge/mpMpCKTYCVFpB2IOINMbdcE2z0Rp7mXEy5lm7JUs1q7WVzLiThxV6Sb/nlHd3MGGZNJvEnCdtvyPdG7POzXPvz8SW/n" +
            "8zeInfOVDwC/QGQ8qv19CuweEAHV1cDF4Zt/8tcerZLP/a86+sDDgR8C7y72XBQIjwKXTnj8pX6Lt5Sw+2D0gqYjgYXAscUeS4Hwb+CyxoW1T/TXDm889e7w" +
            "Q6MGfX19eeQ7MZHKzBhvmkWbRsbduZSNFUdiVtPItLs4cIL0JCvxppNv18Tb0b1MF27nDqTc4f0MSxhNI+R0MlaM6JKQxL/8gaWnrs/HbxA75ysn4W7AxvfX" +
            "776bYzXw6fDNP9mlJZwXAl519CEG/A8D1wD7FPvoC4wVwGVxy22Td9MErXPmN9UqTAFmAYcFj1OAy5Ysqv1TIfc9d37Tp3DnyVvA88AzONfN20sW1W4v9tz0" +
            "BiMvbTZG7dnAD4DJxR5PgfEO8C1UljReW/gErfPO/fcHN5RHFkVFhicIMmnpdmXxdmHRZrOCExZp5mdpSVO2o1VLZyuYNDdzdxZvRxLOeJ7uXs6MFae5mTOJ" +
            "F0iPB6dZxTGD/q9nY1ee+dLpfcpmj8398nTgL5TczrniZeCj4SU/7TYm3GcCXnXUgWGELwLfZeBneOYLW4GrEH454bGXihYX6ynOmd8UUifteQhO8ORQXP3p" +
            "cDJrsO8Hzl6yqHZbIcYxd37TYOA24D1pb7fjSmDexJHxk8ALBlb/edHAV2oavaCpDPgicDkwuNjj6SdsA65G+EXjNYUrV/rS2Q9NXVVZvqTZC83pRK4dLdZs" +
            "pNvBuu0u3tuJZLORb+Izm5nFnEG2WUuMOpD1Li3ejiVIaXHfxHekM/Gmu6kF3WLEznvf86fe3dv5j539pQrgBuCTBT+j9kz8EdXPhv/y8y6zo0N92fqqYw4s" +
            "R/ka8C2cZN7egiHA1SjVq44+8EcTHn+prdgD6oi5n9kRQnQSwjHqlJYOZddKS8cDpwJLCjSs03CKT+kow7m2xuNqCtuBVRaemTu/6UHgP2Jl5c2/qxlwZDx6" +
            "QVMFsCBY9qZSjMG487929Debrmm8tjbvdai3HvOX0F2hsnnteLNDfmcLNz2r2aj2yJXcLfFmIeAMqzZZUtRRWEPS4r/piVbZrGDNYu2mk3A2N3P2OHAWwnWL" +
            "BNsWHWrgovsOvvvpU184c0Mvf4YzcdnOJfQOZyFyN86DkBW9toBXHX1gOfAdXMJVsZSsio0o8GPgqoFCwnPnN40GjsYVxx+LK47PRUv7XkU/esuiQV02rvjY" +
            "FzZKOBpJXINQVPE8e/MNNV1mZ8yd31QF3Ioj4Z7CxxW9Pwb8DfjPkkW1jUWa2gwE5Hs58DVSTRH2NkSB/wO+37gwvyR80ccenb4+Evlnm/EmdrJqs1qzmiTk" +
            "BGlmTaQKtI5EFU8EzzhC9HAEm1jSM5kzYrmkRD0S79MhCSsjmUoTNcEaqHCBWPca3y0ubgtGyCDljlaxEUC1M/lKlriwe91q0M+99/nT/5Dr/Mc+dslgnB7C" +
            "Cf17Su1xeAT4UPgvP9+W7cNeEfDqow8Mq7vr/w57L/kmEAWuRnXhhCdeLoo7eu5nm0IoM4EP4oi3L/KeO4DPAC/iarcTHahG4rrw1OC8HSFSxO4DcZzw/w6c" +
            "i3Jj2rIOF0P6f/Q+MzgKvIpTn7kL9JUliwYVxSoetWB7mSCXAZex95JvAlHgGkT+p/Gamry5o+d/9LHvbolErlAwKdLVNIKVNBLWTpZsZwvWWcmVlR6Dh0UY" +
            "PDzC0FFlDBlZRlVNiIpqj0iZIRQxhMKGUFjwvNTl0fMEE3Kv0/93GcGSvJCqVfyYdUQbfGyjFj+xtFtizT7R7TFaNkZpXtNK64Z2Wte3074lilhHtCIdLGJJ" +
            "t5rTHsV9DonHNHIWEOw9ovrJk54/M6f8ithHL/4AcAul63tf0Q6cHb71uruyfZgzAa86Yn+DF7oEl3CyN7mdu0Mr8G3E/mzCY6/0W2LW2fN3hAQ9Bif0cCr5" +
            "E3vYiLuwDiI/3XiacEQ1Ik/jW4eTTfyDqvz7lt/W9FtXq1HfbjYSt18C/oe9y+3cHdqAb1vMTzcsrO7z+f/D0x4a8VpN5c3txryno/u4M9FqFjdyygLGV0Ke" +
            "MHxMOfvNGcyUWTWMnljJ0NFlhCLFlyRWX2nbEmX7ihY2v9JE4+Nb2Fa/A78ljjFkuJtJczMHSlgdk6+CzzOeb1bVM05a+v6nezqm2Ecu8jDyW2Besecn/xOu" +
            "wRK89gyURdx77VF355N/LEa5IHzbdZ2uU7nHgL3Qh3GutxL5puDckWrW0I2/P98Q9ExcksTwPG86X0RpcBZvvuthx+DU1d4nohfg3NP9Aonbs3Hn/4An3/Tr" +
            "TMYxJB7zd60pB75jsOuAm/u6sa1hc2jI6oG+gpckWE1mPEuneK6SoTQVLB4welIFs08cwaxjhjFkVBleaEB0YE1CPKFiRBkVI8oYffgQ9vngGDYt3cbbd65l" +
            "89Kt2DY/cE13cDdncTt3es+9Hiyi7wZ6TMAIdageWey56TOUFOEK4HlQVYEMGQSjhyPjx8DYkcio4RD3sX97AH2hvhAknNDJfrvjBzkRcFDnew0DX8+5GBgC" +
            "/HDV0Qc29Eed8NzPNo1DuZT8k+/uhBHAZXPnNz27ZFFtwQVSRi9oOgpn+Q7IbH+buNYIWh4iXlUmfnkYzzPiGUGsotaqH/Ox7XG0La5eNE7IpowCScQie4Eh" +
            "wP+MXtD0duPC2if7chw7vMgkrAyPZBCrdnBBk5HclF6Li1XKygwHHjec4z86jlGTdh9boXxYhPEnj2TEoYNZ/fdGVvzxHdoaWxGTLTmrg7VLgoQznnugsx88" +
            "6q/h9zzxwZ4p+akehCOM3QsJsgVHtpXlyJBaGDUcmTAGmTgWxo5Chg+B6koIZdKfMYL/+gpoy3ti/3hcp6i3O37QYwJedfSBY9g76nz7gik4Ev54IXsMz71w" +
            "iyHOF3A1vHs7jgC++NH5Wy+/ddGQgrn/A4Wra3A9qwcMFLAWIiH8SUNMdPYEz59dZ/x9hpvw2MEmVl1G2BMRBA/FWiUe9TXW3I5uatbIlp3WbmulpWGLNau2" +
            "2bIXV1tZtcWW9dIImARcM3rBjo83LqzptWJWedw/NGaMpCQbU1Zwimi1k8tZcAlOVbUhjj97Aoe9bzRllbnkHw4clA2JsM8n6qjdp4plP1/Ojte3By7nbMSb" +
            "5o7ObgWPj8R1LK6Guyc4hIHs4Uy6kdPItqID2daNddbtiKFQXQXhHlDdkEFQUQatbfm2gqtwc9opDtwjAl511EFh0K9RyojrCU4Avr7qqFmXTiiUdnQ8dDRw" +
            "QbEPdADhMx7eP4DHC7HxMZc2RVT5JgNM4coqlIWIH7mv1/6x2WH/6H1CkVE1UiGSTOTtiJBbJE1E34NUIpn9wX3t+tOHovTBU3sc6DdHL2j6euPC3vUWDvt2" +
            "VriDVZupoZyyjBNJSgnLt3pQmHd/qo5DzxizS3dzPEiKsnFLPGqJt/qpZKmoxcbS7uc0zXWfdOwLCSe/JJ5rKiVLBEzE4IWNe4wYvDKDV+4hnrjX5V7XmTgC" +
            "I44cRrhyBvULX2XH69sz3NGIphK0AsIlPTFLkuQ8QtEx9JSAVffr9a+fb6S7kcHFbCvKkUE1AdmOhrqxyPjRjmxrqntGtl3Md3D8hTiSGdne7NlIRc/EtRMs" +
            "oWeYj8gTwO353vDZn22uQu2XcVnJJTiMAr4yd37TC0sW1e7s89Y6QJUP4rSdBwysojNGm9ZL3h2Jn7p/qLwyIn3pw5q49Hih/OQlfRpXOnZrb1Y2ljERNMPy" +
            "TRe3SDU9yLSQy8oMx509nne9bwzGy85qsVafTW/uYMPrTWx6cwfbV7XQurmdWEscrMuUdo+pfRC4upOPiUxjdaQrSIe63uCGIbCijAgi4ojRCKFyj8jgCFVj" +
            "K6idWsOgGbUMmlFD2bDsCceDDxrMfl/dj9d/8DKt7zQjppOFm/Y8RchI8mZhELmEDVUn5uUs6C1scONjDJSXIYNrUzHburHI+FEpso2E87dfJUX4+UfWOd0l" +
            "Aa8+6sBxQcnRwBGWT05Q+p1o+mPRUQN8s2HOQU/XPffi6nxuWNSeSW61tHsLTseVYP05nxsNWgouAKqLfYDgzngD9gMHhnZ+57Qyr26oqWEAnfgBqoEFoxc0" +
            "PdObVoZGqQ77NlO8IoN0O7bsc4Q464SRzDkzO/n6McvqpVuov2cN61/Zxs4NbWlN7ztLO3ZUrLI4UtXgmpN4nbEnzfiNkrk/FkCdXezq9YT21bDjFVh/vxCu" +
            "CVM7vYYxJ49hzHtHEx7cubJtyKHDmHT+Prz545fRlniSeJNWcIJwRdMs9IzfI5fGOMXJK1GFsgiyTx0yeQLUjXGW7cjhUJtnsu1uDIVB1jntloBvO3OO2C2x" +
            "z0pRY42akV0ikTKkogKJRMAE7huNg20H2+Ieg+/2vnomDxAOkwp7of/HQZd7M7bnJTY5d37TKOASSn04s6ECuGju/B0PLFlU01vlnwyMvbTJWOULwOxiH1wC" +
            "BuwnDw83X35aWXlNuQzkGuQ5wIWjL932rcZrBud0/ntWI2G1SSEKk0aUmX11A4vPV0ZMruLwj06grLLzJa19R4wXbl5J/d9W0ba5HREIB2RlgktFYtsEghdJ" +
            "QY1E3FXTnpOwcDuoVZFyRQvO4k24rkXS3kccS4uzorXZZ/t/22h+eQtbn97APp+fTvW+ne2dkSeNYcfzG9lwT0Mna1ekW+JwWiM9hWr/G1uqUF2FOe/DmGPm" +
            "QEWxigy0UCScdU67JeDLTq6d/dX/7vzk+1YUQeRJFdQi5ZWExo4jPHU64Wn7ERpfhzdsOKa6BiJliFGw7Wh8O0Q3oK0roflldOcraFsD+C24M72fyVhBQnq+" +
            "31h2J66ncD7wMXb//sqFxGGgZwPX5WNjVjkcV2M9IGAV/eBBoZbdgHwTOA81fwVyqgoIWRUTEHDS4s0m1xgQs2dg5smjGTG5s5OivSnGs79bxut3NaBRS8R0" +
            "tnpJxJtJI9c0QQtIqWMlX0umBexIloQ0XHJbpJF2gp6Tsh2J7yVSz+M+Wx5Zi7+1jWmXzqJ62qCMY/EqQ4x+/0R2PLue6PqWpCs671Dt/xt8a5FDZ2JOOqpQ" +
            "tbg9PHYKRcBZ7yi6JOAp150Yjgqf//P+FVNmbYrZydt9Y/tjXoKD90aOovzwoyk/5gQi0/fHGzbMWbw9gu/IuPlFdPM/0a2PoO1rSDmH+g1jUD4X+/eIF8PH" +
            "bexTQtbc+U3jcbG14qsHDFx4wPy585vuWrKotqEvGxr1jR0R0AuB0cU+KHBOoAPGmNbLTyvzdhPyBTd3F45esGNp48KaHqvEha0ViySJN70pQXrrPRMk5wwZ" +
            "X8m+x43s5Ii3vvLaX97izb+uxMSsk3tMl3bs0E+3U3/dYDvp8o6kf0dShE06IWdISro3JLB+QZycpBHCtWWEB0WIb48R2x4N1jXsfHED7/z8FaZ+ZzZlozO5" +
            "sGbmEAYfOoxN/2im0wF3Dcnly0A/+HqzDHLCmOKSL0Ahbmgcsv7NdmcBH+kpH1pd43HnvhVy8dJmvIKNLThwq3ijRlN58ulUnnIG4Un7uBTznOFBZAwydAwy" +
            "5GS0ZTm6/lbsxjugbU3wI/fbD/1hVP6A66XaF5yNqyUroXvMAuYC1/ZlI2L0aOB9xT4YcJeE8jDxL58Y8ccPMQMiFp0DzgQ9CqeJ2yM4Au5IlilrOCm5qO6a" +
            "MfnQodSO6Wy0rV+6kbfuWoGJxghJujWdFj9Oi5mmJBwzmyA4d7ImSTSRmJVBwoF8JEmXthtD+pUm4XoO1YQZeeY+DD+xjlBNhPiOKJv+tYqNf1+JvzOGhIQd" +
            "z61j499WMO6C/Z2FnNhG2DDk+HFseXA1NlqgqjvV4tRuhfrUGyhPx06hLOCsc5r1iKdcd0II53obhsKDE8vkuNXtHNoYoyBWsLVIWRkVx51I9TnnEZm+f/7u" +
            "hMRDqmYgUy5HRnwAu/pX6OZ/gG2jn4zJocC50f8Mfzxy7KZeSSbOnd80ATiPgZdsM1Dxybnzm25esqh2VW9WHv3N7WGc0taAENywFo7eJ9T23hmhMna/c2AI" +
            "cP6YbzY9vu7anpUlhdQXEl2GEpZv4nlGCZISqfIYe9BgvHDm37Lf7vPOfW8T29hMxEiGKztDR1nTEpiSHYcgmeksHa3kNCs36ULWFPGSdukSybCQUfDKPMbM" +
            "nca4eTMxkdQ1uXq/IURqPNb94VXwFbXClvtXMvyUOsonZoYPq6YPpmxcNa0rmnp6NuR2zhSDgLVgsddcBlHIcfScgMHMwmWVIsC2MuHW6RXstyVOVUzza6Rb" +
            "izdyFDXnXkDV6R9AKroOP6hCU5uyrcWytcXSFnMjKQ8LQyoNgysNteXSBXcLUnMQ3rSfYNcfjm34GbSv7a/Y8BlizYG4BvS9wQeAA/pjoHsIDgA+DPysV2uL" +
            "HAycUuyDSKAshD93TljLw7uN67kjTlXhYOC/PflyWK0kOwxhM1zGCevXA7CW2qHlDJs6qNM2mt7ezpYX1hMWP6ORfSc1KUl7TzSVbJWwjtOTrRKu5g6JV+BI" +
            "OEHM4EqPEkgQs6pSWTeMkWfuk0G+AKbMY+T7p7D9obdoa9gBniG2oZntT62lfOL0zPkZXEbV9CG0vLkd8XJyQxfiu/lBsbk3fSCJG6b8IusWu7L5zyJN2N8o" +
            "/Hd0mH+Pj3D6inY0X4OzlvDUaQy++BuUveuI7NOhsGqrz9MrYjyzMkr9ujjrmyytUSXmu18t7AkVEWFUrWHGmBDvmhzh8Mlh6oZ6ncnYq8SM/TRSORX71nfR" +
            "5lf7g4THBHOaMwHPnb9jBOgnKcV+c4EBPnn2/KYltyyqXd+L9c9igNRZW4XJw030qCleUeJyecJI4CP0mIB9Ee1MmMnEqwRRYqkZFqZ6TGfRpqY3thJr3B4k" +
            "XWmHZKu05gaSEvxIlfakYs4kGiKoDdzKignaFSXaB6KpSg1BECMZsWD31MV+y0eWUTYqe8l2aHA55ROqia7ajgrY9ig7X96A/eBUTFmKsE1FiIrJNbk4CXOL" +
            "uWnervA5IFGEW2QEv3EBhtIzAp5y3YmjCazfdLR7wu3TKpizPsbInbbvJGwtkf1nMfgb33Eu547zoPDq2ji3PdfKA6+107DFJxo0n0tmG6Ypl+hOWLXF59m3" +
            "Y9zy31bGD/E4ef8yzppTzsxx4U4nqww+DjP959g3voE2Le0PEj499ujI68LHb8ixn62egpMxKyE3HCRwEvCnXFYa/c2m8cAZxR58Aqpw+CQvPrxa8iUN6Mct" +
            "4lsXQk1HyEC8cL28zhi9oOm6xoW1u5SojGg88ArbJAGnWu0FsV8UI8qgMRWYDu5njVua39hEWGNJ69UpRtkM6zfl4nbkmyTeoESJZNa1Eqoto2xUDWXjaqkY" +
            "P5jQ0Eq8SAj1LX5TG9HGJtpXbSO2vgl/805HyAkXdHCxUlVMtA3bHsdUdL6fUt+iO9sRVzmMEYiu3UFsUwtl4zLd0JGRFZjKELbVz7+1VgxXcNHdz3RW3eoH" +
            "ZLOAjyGLbJZRWD4kxD+mlHPeKy1926u1hPedzuBvXE5kemeFrg07LL9/ooWbn2ll7bbUyeh1xZEdCNm3sHKTzw3/buGeF9s4+7AKzjuqklG1mRuQ6gMx+16L" +
            "Xfal/rCEZwBHk4M61tmf3VGJ6tmUes72BmHgnLnzm/6akzqWcCwwrdiDTyDk4R860bPkUsfZGbq1Rdsff8uPP9vgx1dusuGmNq2wmulVEWDVNkvPvZo5YTpO" +
            "ynPJrr4YVl8kW/y342tRqkeWJxWnErBxS/vqrYSJpcVxMy1qMrbrXotoUuoRq4iBslE1DD56H2oOraNyv1GEh1YiiT6BGTOs+DujtK/cxM7nV9P8xJu0LV/v" +
            "7mgCFSwF4ms20frSGqoOn9TpuFte20D7O5sRsW77Rohv3kl8e3snAg4PK8erCGFb4/SAgXO1gAtyAuxyn4XcrW+heSe6eSusWY++swbao8hJRyMTx6UPpEDH" +
            "n336Mwh48s/e44GeThdNmK3APVPKOWpNlOlb4r1LyApivoMv/kZW8n327RgL723mibeiWO11Z5bkemu3W372wE6eXhHj0tOredekzDtPqT4IM+X7+Msuhuha" +
            "CujpLQNOj/1n1F/Dx67vUTKWqM7GkXYJvcMxwKHAoz358qhvNoVwfZUHhLtXgaqw6L4jTF9uwPTh5fHma/8VNa+s8Sva490TuUjv/+Z2gTBw6qgFO25dv7D7" +
            "/s1h4lkJ2GAz3zNK+aBQ52ubVezmJsISc6VHEmgkZyHdFJmn6SmrEh5WyZATZzD0jFmUTxqGhHdx/yOCV11G5axxVM4ax+BTZ9D82Bs03fMC7Ss3AYJ6gt3a" +
            "zKbfP4VUhKnYfwwSMmjc0vLKOjbc+Ay2qdURvLpt+s1t2J2dK7hC1WFMmUlpDpWQgm9hZ0sG2WrDWljTiG7aBjtbIB6HwA0kF5ydWrdgNwHZWT2DgMXoaFx3" +
            "mawwCo1Vhjv2Leerz+4kbHMcrSpSVkbNuRdQdmhnPYn7X23nirt2sHKTj2fycyFIbOPxN6Nc/OftXPn+Gk6dmXl/IUOOw9R9CbviCqekVbgchCOwOhrYpRvu" +
            "E5/eJL6Lmw2ITNzdFINwCWw9ImARGQcDpw+qKgyulPZRtb2+xOqDy+LNX/pLW2TDDi3zTDdepP7BUYKOZxdNASL4gRs2RbqGzNivCHgCZTVZXLmxONLaQpio" +
            "02FOX1fSypg69dR15Fux32hGfuoYao6Yumvi7QLhkbUM+fAcqg6ewJY/PUnzf5a7siFR2l5dReP/3EvFIRMIDa0mtqmFnc+vJbpuRxr54v5rj2JbOyePe5Uh" +
            "TCQoierZ9WrgW8C9YT9rYWcrunkbrFuPvr0GfXt1QLZbYWcrxGKpOU3UiwWL7thJ5l1McV3QBwOTu1tBFB6dUMbxq6MctSaamxWsSsVxJ1J1xgc6ffTPV9u5" +
            "7PYm1m23BblIeAbe2exz2R1NQG0nEjaj5qLbn0Y33FHIW8rJuDneJQH7XmQ8AygTdzfGKXPnN03oWUmSHgzUFXvA6RhUgdSW9+583LxT26+9v91LkO8AQB2u" +
            "lr1bAg4TS5Gi2KA8KJCmlIQVbIPGBp0PzLbHCdkoERNLdgYSSW9W0KlnbvC+UDVnCiM/fzJl+4zKywFHpoxk5JdPITy6lm13LnVkKobYui1E12wFMagV1BjE" +
            "eKA2kTLtQmIKtq0zAUvEBEq8Nr04qisMfBu5Jy7odLJdux5tWIO+vSZFts0tAdlqimTBNXXIvlM67TTxVj/NWEcCPpIuJLMSEGBHRLh1WgUHbIpRG+1hWZI6" +
            "kY3qc85DyjNLjZ59O8aVd+1g3XZbKPcX4Kzhxu2W7/1tB8OrDYemu6O9Ssz4L+A3PQ3tayiQK7oimOO/9+C7xwBTCzcbew2mAcfRs2Sso+gi/FIMqEJZSEKh" +
            "XgZlH30jHn9lra0YIOQLbm6PAv7W3ZfCxB3BSsLa1VRClqTc0UZcS79O8xaLEyIKEgvKgzqSraVjFyFUqZozleFfOo3I+GHdHoS2R9GYH1hKgoQMEgl36V4w" +
            "NeUMOfcYxDNsvfVpbJuPGIMaV5pEICmp6idJFzEI1vkBYp099iZsEM8dCyKodtWBMomBbQFnQzSGrtvgyPbtNS5umyDbHTs7k2360pPjyUr6AQP30xQkCXjK" +
            "dSdW0sNsW6Pw/MgwD9eV8cE32nqcEV158umdMp43NFmuubc56XYuNIy4BK1r7m3mV58YxMi0xCypORAz8iPYVXmREu4KB8ceHVUZPn59l5lscz/bHELtGQyQ" +
            "WORujhBw+tzPNN+y5HfV8a6+NHrBjurAAh5QCJlet+b1n33Hj8d8vAFEwACHjF7QVN24sLa5qy+EiSESELBmErBJI1EjQigLARMQsJhokoBNhuWbUrsCt4+y" +
            "aWMZ9rlTuiRfjcWJr1hL9OW3aH/tbeLrtqAtUQiH8IYPJrzPWMoO2ofIfnWY2s4J66Y8zOC5R+JvbabpHy8EnJCmJB3EfFPWl4Ia11Up2vm0lZCzgHGinSC2" +
            "OxLOVYijoCdA1/tM2++OndhFS7DPvAjNOyEaT7WX6opscx13tq8XMQt6HC5TsUeIeXDHvhW8a12Mcc1+967owPqtPOV9GROmCjc92cKTb0X7NTblGXjyrSg3" +
            "PdnC199bnTYkQUaeBRvugPbVFMgKng46Fniz6/myk3EWcAn5wZEYO4nu5hwdB+xb7IF2hEjvTsKYj6zaqgMxe34q7lqzrKsvhE0scDlbjAks1jTLNUGmxtCF" +
            "BRwjRDvGtGf0zk1Pxkq3hr2aSgZ//N1Epo7NOp746g203vMf2p54CX/DtoArUnIc8YZG2p9bxs5/PE1k1hSqP3A05YdM7ZTEYiojDD77SKIr19P26hoQD0QR" +
            "Nc6I0bTC4eC5qqKxLAQcNm51LIgFzSMJD4AsaF25CvvIU9DWnkViLE9j7ES2WkgpyqxIP3unkoP4gFFYMcjj7n3K8Xf101pL+WFHEZ68T8bbr6yNseSZVnLN" +
            "5coHrMKSp1t5ZU1mfEUqp2GGnFDIH2Eku3YtH4G7SJWQH9ThXJ/dYSowotgDzRd8xTS3F6Grza4xAtinuy9EJEpYooRNjLBEiUiMiHEx3YhECZsoEWknYmKY" +
            "LP4B8eNEcN8Lm3Yipp2w1558Hkk899oJmyjVx8+k/MiZnQeiSvSF19nxoxtpvesh7PpNLiZtNFhs2qLozp20P/kyW//3Fpr/9gTa3jl2Gx4/lEEfPgyvOoLg" +
            "p+Lc2NRj2nMjCnG/k7UmnnFjSLrpbcqd3hkDPwbcEW3tLpu5oCne2sP3CoeOBJxbsb/AfZPLqB8WwnQ5bkUqKik/5oSMYLgq3PZsG2u3FTbu2+WBiytRuu25" +
            "tkyuFQ8Zdgp4lRTox6iiGwL+6Ge2ecCJ7KJVZAk5wQPePfeCpu6syf3I9fwfyAhKWYs9jCyows11lwhLLFii7tEkCDlFqonn2QhH1AZkGyUSfM+RcDRJxGEv" +
            "SkjaiYysouLkI5Bw5z+32EvL2Pmrm4kvX+Fc4p4i4mPw3aM44jNY99pYxIDdtJWmm+5l59+fQuOd47eVh+9LxawJAcH6KQJNW0zwHvjZjYFk2ZTfmcAlq5pK" +
            "bhZwMZZO19v+2m/mLvtlPwHSL0j7k2OxvyhsrDTcPq2CtpBk/4WtEho7rlPsd9UWnwfq23PZXUGQUNnKOK7qg5DyiYUU5d6/yw+NGUP/9PxtB9YCrwMrgO39" +
            "sM8Etgf7fD0YQ3+cCO9Cum0tOJ2S3Gd/wLCLUFc4SZrRDs8DUpWUZWuyETCWkIkS9toCsm1PEnfIxPBMDE9iGOJEZs/A26dz4rvfuJGWP9yJXbXaWbjiBxZr" +
            "GlGmW6tJ8vMR4+pQm5c8SNsz9Z0noKqM6pNmYiICSeJM2zZ+ENtNJaJlg9uvdiLfxLg6TUtPUSwC1v4eR8f9FXifWZB+2zepN39NovD4uAhPjQlzwqpo54Qs" +
            "VcL7Tnf9fNPw9MoYq7b4RbF+EzDidKafWRlj4rC0e4/ISKieCTvre7/x7jGpm88OACYW8LCbgHtwilyvADtw58EE4D24Vn7793rr3aMeuBl4EFgFxIEaYCau" +
            "ecL7cLW7hcDkYD9ru/i8kHNeQia6neuIiWa6YRNElCQlVyPsGcluAWMJeVHURJPidp0vS4pUVRA+ZH+XwZyOuE/0n49il70ZJHEFpT6BtKQiiAoqQXNCDR7F" +
            "xV9FBTWC3baNnXf+m7L9J2EGZ3aRLJs+jkjdMNrfXJ8Z3wwyoBPlSO66nd0CRlJZ0C5mbIPHRCavMjCdID1Av8Rhi++CTifgXsW/BNgZFm6bXsGBG+MMaeug" +
            "E22E8LQZuJS94BAVnlkZJRovujAA0bgby1lzytPaiHlI9Ux0w22F2m13c30YhXOFvg58R5S7b/5tbUd5nVXAE3PnN/0Z+BauHWW+3OBx4M/A1UsW1b7R4bN1" +
            "wPK5n2u6B8tpwP9QmBuASpxn4f4uPh+dw7ZK6Bu6netwQMAmzaozidfpFl8QB+0IQfEkjpWuBbcExQyuIjS9czjaX7ee+GNPg40hAYNLophJg5rbRE9xTX+u" +
            "CAaV1PvxZStpe/IVKk/L1DfyRg6ibN/RRN9YGyRrpWVAq7oELQ3Cc+puONJvI0SCHsVB5+REApa7WQg2I7jkrFxJeKBoQRc6I7k7F3Q/IZ3+ep2AYhReHh7m" +
            "XxM7l1BKpIzQ+EwXT1ObUr8u3tPNFxz16+I0tWVOupRPBilYSWjWuT77gqZyHAEXAsuAzyxZVHt7FvJNYsmi2rdU5UvAr4B8SPMrsAi4OAv5pvb7m9rokkW1" +
            "d+H68L5aoDmYc/b8pq5+1MEF2mcJndGtulsycSqI9UaMi92Ggvht4rGrGDA4N64J4rRdLd6oYZghnR0ufv1ydMN6jAlitB3isu69RCw480ZB0mK6xlhoayX6" +
            "wjK0pS1jHxIOEZ4wPFCz8ju4kTXphoYE+XZGKjM85SlAUo+ppKyMmqddY6DEgAvtEs46rf3rgk4n4Br6gLiBu/Ytp6HWSyVkqSLlFXhDh2d8d1uLZX2THRAa" +
            "piKwvsmyraUD10RGFTIRK+tci4tRzshxWz3BduBbSxbVPtGTL9/y25pmhO8D/8zDvh8EuXLJotqmnnx5yaLaZ4DLgK0FmIf9RehK4qhQru8SOqO2uw+TWcte" +
            "u4vjBjHcVPw2HpBrFxaukkmIXSzemBHgdXDyWItdtjywflPEJqStS0fCTXyWigMnk6uM4r+9Brutc9lzaPRgTHmoUwzX0MHS7yoJK80tT5J0beCaTsuudqVX" +
            "A+Bq2w2y8C8FF8TowgLuR6QTcJ/MPaPQUOtx19Ry4mlblUgEU5PJN1t3WlqiAyM6IUBrVNnakYBDtWDKKNAv0tVcT6YwrtA7FLk7lxWW3FC7GfgRfSPCJuDH" +
            "SxbVbMhlJUH+AdxSgHkYi3ZZAlOe05b6AFVXBteTpS/esFz209d95Yhu5zrkObINSQzPxDES75B9nEZ42TM/k8SYcF2bwHJNt4qltrqz4LwqunE9hngyu1nS" +
            "rOBOGctprxMWceb7it2yFW1t6zRKU1OBCUunBCo6kHBWR5Qk1tPgeNPrm20m+YqC5EDAA8H6TYyj0JnQ/Xns2c71tOd58bf+a1IZx66OcsiGmItGeB4SydQD" +
            "aI0pcV8HRnWaQMxX2qIdXNCm3MVhCoOu5nomrkwjn2gCfn/LoppYzmuKPInqI8CHernv/wRLTrh5UY0/d37TH4GzyW8ziiqch+HhLJ/1S9mXEXRYtWgkJGZX" +
            "Iq6+hZE10itPkYhbd/wQ6VGehSDEfLWbd6r4tuB/md0qvDnr0V18XWNgTb4mTUQDsvfCTbhmEb9Tq8IEVJwbOJtsobS3BS7gVOzXhWYFCfo0SSDE4V6btFhw" +
            "QlhDgvEaiLajfmdrXcJeMsnLJVIldKDd5oyClUTDhaxHEaxrMtZNCwAHsWHI6SwqWgxYM18XOh7baftphN9PyOtFRxS2lBtum17O9K1xyqN93+begnM+1yRq" +
            "OaAAm34VeLE3Ky65oaZt7vymfwEfpHe3S/cvWVTb2+bRL+OytI/N83x0leBV8NtBVaipkPZfzi2P7jvSq7W7iLArSllIiPTiPjDiwTUfLKc9nqCP7mEM1K/z" +
            "o5+7uc00tWmkmPfGyTKaNOKVNBUrgvaBJEkuy/GIRcV2+R1RkFh7kPCUdrQiSHk46MmbyEx2SVIZ5JuehIUiYlJJWpJaBxQp8xAvu2SmqJ+q203qQJMk4e4M" +
            "VwkI1s1VcJiSSJ1OZVGLiEuIHsjo0gWt9OoOtMc77WIcRWjG0E4esm9F4ekxER4bF+G9K1vB99H2TCauCAshL3F29M+BdgmFsCeUd7jkqG0D9SnQADvdmqil" +
            "ml0oBPUSry5ZVNsXN/JLQDO55wjspJfED7BkUW3T3PlNr5J/Ap4+94Km6iW/7aRFHKMfGjEYQccMMjq6tifnVe/PPREYXp1bH/b6RvzWaL+Qb7feGEm3gLsh" +
            "4WTGcJZjT9XTdnU0Cju2uw476d1yRDAjh6NGQfzA6iUo50n16QXTgYgDazdBgEFJEgresFqksvOppTt2QjyW1QJOJ9SsiWaqKRd0evmROjLXYBwSvCddSGRl" +
            "nZliWMAdyFDTx1Go8ah29i6oov3YjCH9tiwvYggCtIaE26dVsLHSc/0smzPzb4ZUGSojMiBuyRSoiAhDKjvcocabgt7ABUFblveG4mpx843VfVx/C86NnSu2" +
            "Axv7uO+1fVw/GyYgMjTL+205b6mXKMr1rQdo2KLRWD7y3neNbuc6mYyUFKhIJD9lJjwlegVn2UBmUhR+1oX1a6Gja9gYzPRpSZ3lzPhvx+eJbOiOCVlpMVj1" +
            "CU0eixncOe/M37AZ2tuc0Ad+dlEN6cZISSNhSWRMS8Jl3zGrOoezbsBkQffHftP3F/xXpCzoHfn66zIK9cNC/HNyObatFX/zpozPB1caRtWaAXEhUoVRtYbB" +
            "HQk4uh78FgpkAWeb6wnAsFw31AP0lVjiwZIrYuzC0ukBChHEGIxrhtERvbnJ2JNg39xoy33bL2pg3c51Sp6xi+QnUuVBXV1EJEsClUlPnhIfNqxFt23pvP/9" +
            "ZmBGjUCIJ0uMTIfsZpMxLj9tXOnKVj6mIkz4wP2Qisy8M43F8VetQ+LRtOSpdBJONKHoItFM0zKgA/JNliWlJ2WRcEcXQ3E/B2QrC+qPGHC29/qRmNL/2Ppq" +
            "rWTAF/jb1ApWVPrYVQ0Zn9WWCzPGDByp4xljQnRseq5tK0ELZgFnm+tx9LEUrAtU93H9cnqXIdzb9dJRiPkYBIzP8n5f3PS7PawSX7PNRvspItTtXAtWpQPR" +
            "Jaxhk15ri0/2DGE6WakifpCUlUbKTVtg2WudVx8zBnP0MYEVnK38KPU6nXBNusUtgfW770TChx3Ueb43bCH+VoPr1tSh/jfjUQKrtiMCokhvwpC5HZtcN0XE" +
            "PURRrN8sY0iMuZAWd6d9F3CfWVAwAjYKa6oNd04tp+WtZRmuHhE4bHKEyADg4EjIjSXjLlN9tPnlQt4JZZvrCRSm/++kcz6zoy9WzRh2UbfZBWqDdXuFsy7Y" +
            "YSiMPGSE7FKgjQXY126D5jY1q7ZqpJ9q87ud68yynDRXb0cS7soCFlKlR6Qt6a9FMa074KVnIdrB0eKF8E46FTNjBqJpVnCn8qMsRJxQ61Ifb2gN5R88FTN0" +
            "cKchxt9YiV29NpkF3Zk8O1rAncQ008qMMkuOJCnekUbEuWjqFM0F3ekQC79Pz+vQ5rCA+8yC9Avz23n8A3N/BwoP1ZXxbNNKtIMb+rDJYSYM8YrSijABqzBh" +
            "iMdhkzvwXnQDNL9KATPE3s7y3kQK0wzgQDXa4zaTWfAuoDdt7Srog6pXSHQEMKsA82HI3urxnQLsa7dBU7u2b2q2Bau764Bu5zrlLk6P42ZrguCTzY+YTMJK" +
            "czeL8TMfxXfk9/J/YeXyzoMYNRrzifMxEyciGs+wpLPX+6ZbvnFMVTllZ51J6LDZnTatLa1EH34KiUXpFPPt9KhZL0MaxCuTFnAaEUNHa1gR0SJeaXuArCTV" +
            "NXH1eV9B8p1MmdD5s36cqfQLfj3g93ZD2SDAtgqPJTVb2Loys/923VCPk/YveNLpLnHS/mVMGJp53dHmF9G2dwqV/u7j5rojCtX/dxpwdG9WPHt+0xDglD7s" +
            "+7S585uG9nLdo9hF15w+IFsM+HXyI725W6Jxu9LUVuD2qw4WN9ddIqkmRXq81+/kUjZYRLOLVOABnro6j5CAl7aE0pZtG+DReyHWOd1Aph+A+dwlyIz93Q2B" +
            "xjMSrpJEnJ7cZWOY4UOJfHIu4dPe6yysDog98wLx15Z1cBtnf6QrsRFNWbopKzewetPIl+R3BngSVlfjyMd4rHU9leNx9zwSQcaMxJx1GuakYzruFAqViJUF" +
            "6U7gN4AW8hx3MwpPD4px/ztPMvfQo5MnpAicNaece14qTk9gqzB2sOGsOeWZ+1Yf3fxPl4BVGCGOnbi57ojeEtWuUA58eu78Hf9asqgmp0QjgTPomzb1ocD7" +
            "gcW5rDR3flMNThO6UOpU2eQol+PO/77GzHdLrNpqaY1quB/+DFtwc90lRKymCCQhNpEey1T3Wnzws+QHhkIQNo5gd+VTsgLP/RsOPBSOeHfHgcCMAzEXX4r+" +
            "6x548lFY30iqxjcoHSIoOaqqwRxwIKEz3oeZNSuzvCmxuzWNRO/+J7Q0I8Yj1cWITiVIroLbIiHpbAX7FtQRrYqmCDlRgyyKqnU14GJVNQfnWjGM5e5c0L2F" +
            "byHkwZBByJiRyKTxyNRJyOQJMH4MMmpY5xukvu4zR6QT8JvABvJMwAK0h4Q/bnmOY9avZPzYVC/6mePCzD2sgp/+a2e/HXACRmDuYRXMHJfpftaWZditDxfS" +
            "FNiAm+uOyKfiU0ecBPoZ4Cc9XWHu/KZpwNfpW21sBPja3PlNTy9ZVJtLb8d59M3y3hUGZ3lvOe632RsJWFdt1XZfqeyHG+ENZL8BTSI9GziDeCX1iAms3HiW" +
            "RPtwGEIJAt7FAalAaxP8/U8wZjxM3Lfzd0aPRT7+GeSo49FXX0SW16ONa9GWViQUgWEjYfJUZOaBmGnToTr7JVRbWone8Tf85W9ijMGqu4lQ9RBRVINjU02W" +
            "EoFxil0dtxX3wfppVi7JGmQN6oITc6UuWWvgu6A7KmH1VojDWqgoRw45AHPMu5BZ+yGjh0NV5S621Yd97vL4sr+d+mVF1qC6jAKIQRiE+tgm/vLGv/jKmH2S" +
            "8nAicN6RlTy9IsZjb0T7rTWhb+GYfSOcd2Rlh3lWdP1t0L6WAvZmX0b2+tZBBTzkCPCtufObNmLkT0t+U9PtH+Pc+U0Tgf8DDsrDvmcCP5k7v+kLSxbVrtjV" +
            "l+fObzob+E4w5kKhM8kKa1HeAqYUcL8DFfrmRlthFekHAn6TXdR3m0RZjWQjXhypCs6dHM9SqRYOBxYwKQLO8HKlP1fAwJo34S/Xw7lfgdFZyvE9D/aZjuwz" +
            "HdrbkXgssH4lsLgjWd3NSbS1Ebv9TuKP/geD76hVwKrBiMUmrvlZLGHJlq0a9xHrJ7sekUbgLtybEvcQei7CkZqTfkYH/s0YRy7jsRbZZyLmM2djjpoD5Tna" +
            "D4ld9dMcJFlmxUUPtgAvFGpHFrh9xcO8sjHT+zSy1nDpadVMHt4/CVlWYfJwj0tPq2ZkbSbJ+jtexG64gwJH4V8IH78hmzxjoXoAJzAc+BlWvzN3flPW7OSz" +
            "P7s9PHd+03uAP+Dcz/nCKcAf5s5vOmXu/B1Z/yLmzm8aOXd+06XAL4C+JI31BJ0IuPGa2mZgaYH3OyAR9Ymt225j/RQFeq5xYW1zd1/I7CwUxDc9UnHb5HPA" +
            "z2IBhyIpF3SIVBw4uZD5vifOYn7zRfjzz6ChWwMdysqgqhqqa521W17RPfk2NxO75S/E7/kHRNtBNO0mI/WYnniVkdUc7rxtZwGni3B0zoZOjwmTy9W1KDFg" +
            "hbIO99y5ZiT7PrLvJLwrvoQ58ajcybfQx54FHW+tnsQJN+Q99mZEWNu8kd8+fyvXvOfrVIRSuzh0UpgrP1DDZbc3sW574eLBVmH0IMMV76/h0EmZrudYvIX2" +
            "huspb18TyMgVBG24Oc6G/ujGMxS4EvjA3PlNfwP+iyuJKgemoZwMnExhBEGOApaA3j93ftP9OE9AG+7G4FDgfcFjf2TidnWz8xROEa6g2YG53tj31hvWk+2L" +
            "wNYWNWu290sJUjtujrsfE1ZdjDfN4jVkWr8Gd6bEstTql0VcfWGXFnDHspO0CVv+HPzhR3DaJ+HAIyHUt8pAfXsF8dtuI/70fyEaR4K8kqSXs5PFG8SESTRY" +
            "EEx55zFoNJ50QWuCZANd6syYsBD4oHMYdD9awIkkqWFDkH0nd/4sl7FUV+F97hPItF46sYLM8mLFgMFZwCspTE9aRAz3r3iMQ8fO4txZH8j47JQDyoBarrxr" +
            "Bys3+Xl3R/vWWb5Xvr+GU2ZmXl8tsG717QzffG+h00BX0rWXob/a4RlgTrC04dSqTLD/QpPfYOBjwFlAK27qw/147Al0VYH+PNAA7JvDtnoMEWhu18i3/9YW" +
            "GlSxa2kEa2H6KMPXTiojnOMvE/Phfx9oZ9l6my0XKDUmoLkdb+02G+oH9/M79MDL5ohXOxNvtudtWYxpLwzVlbBVUoTdEZr+GJSeaNBMYe2bsOSnsPwFOPo0" +
            "GDMpdyLetAH71BP4//ontmEVggmSOm2KZDMeE7FHmxybAlIWQSqy6Ei3tkMslqkFjUVFUpnhIqgmXdHFjwGnW4MiEIlAbTUyfgzmQ6cgB3T8s8thyL6POfRA" +
            "5LCD+zS+/p6mjAuRVV1nRJ6iUAQMtMXb+dWzf2LK4AkcPSGzRu6UA8oYXmW45t5mnngritVd51DsColtHD01wmWnV3eyfAFeW/sMkXeuo0xaXWuxwuFJtEsR" +
            "gn6KgGcgH2pVvYEh/20Xc0EXdCZrQJ+iQAQMEPPxHn3D9zRh8XSDuA9H7+Px5RPJmYB9C4+95fP4Wz6h7tZ14zCh/jn7nhJYs8tveWnk63VBvBL062ttImU+" +
            "Jtb3YPAwaHwz9XZnHYvUY8IiTljDFmjdBo/dBa88ATOPhP3mQN00GDTMZTd3amNooWUnNKxEX30J+9+n0BUrXKxWQmnkarp47LC5gEhNTUXWRg62uRWNRpOu" +
            "Zk3EyoO4dMoKTvpxe/4r5dsCTJBuVaXLRp48AZk6CaZORCaMRUYOcwlSndbJYSzGIIcdBJE+eCzivhOMKpYF/PYlD/tTrjvxH8DHKZAbzoihsXkjP3jsV1x7" +
            "0gJmjsi81s2ZFOaXnxzE759o4eZnWlm7zQbr5bafxI3M2EGGsw+r4LyjKhlV2/kq89KGN3jxlWv4SORttHCuZ3Dut3vDJ2zIa611Cb1CVkpqXFgTH72g6R/A" +
            "XAqjSuZ23sPTTHL4blf7CXt920YeEQP+sW5h7a7Pf68j+aYRr5fmghaFpo2ds1a9EIwaB28GPXp3aQFDBk/ZwBJWoGkDPPZXePZBGDwSho2BEeOgZgiEylxt" +
            "aXOTK09aswo2bYAtW50XGc+RddYuRx0fA/exphGpCmZoDaa2c86gv7UZ2toCmcrOLuj0RCxVi4jpfws4IF4ZNxo54UjMMYciU+pgUE33MfP0H6knGcnq4scy" +
            "dlQPttkNdjRDa4F6suwyCzqFx3CF8vnIgM0KI4b6TW/xnYd/wtUnfJmZI6dlfD6yxvC191Zz6sxybnuulX+91s6qLT7RoOQv+TeV+F063CxFQjBxiMfJ+5dx" +
            "1pxyZo4LZ/0NX9rwBoueWMjnK/5LuZFCqzC8HsxtCcVHdxejx3AlSYXozbw3YznK4z36pieKR4p8PTq4oIPXWNjW6EqRwmn2gvFg3FSXiAW7IOCABVVTpGuD" +
            "9y1Bj16FaDOs2wFr3nLft+I+tzh3Q8xCPFH+k7CQbeb+uiJfBA2+Kx3eC40ZhhnWuUDCbtyKtrY56zogqu6t4BylKPuKQObRnHwM5tNnu9rb3myjJ+NJ3Dj1" +
            "0V2qK1elCLifrOBOBLzi4ocaAyu4YAQMjoRfXF/PNx68lu8ccyFHT5iT8bkIzBwX4oCxNXz6GFeq9MzKKPXr4qxvsrRGlZjvJinsCRURYVStYcaYEO+aHOHw" +
            "yWHqhnpd3jw9vmop//PYrzg9/AT7VUT7QwLpH+HjN3SngRunfxKQSuimy1LjwtrVoxc0/Z0SAecb9zReW9uz1pghNEW80Ol5goQx0LIVtjbCyImZ2xizDwwf" +
            "DVvXBRfmji7jxMVdkoSXlFA26gjW4FxpVlJj8BPEnF6zisuiNuJ07nx1FnC6Sle2RKukxWrd5hKfBXFdUxYhvP8+SAe3qrZGiTesT5VmqXWiHVmtYAVRVc2h" +
            "FClP5GPOOBHvqxd0di/3eBw5jCUaRRs39l48OBZHn37euaH70WXUVTLKbTgxhF6L6fcERgyvb3qLbzywkAvnfJyPzDiVynBmSFLEyVbWDfU4a045TW3KthbL" +
            "1hZHwpDq5zu40lBbLt16LFrjbdxefz/XPfsnxtq3+cjk7f0xz+uAW3fxnYJn35aQxK7aHN6OO/8LXQ61t2ADbk57Bk9sMsu5owWceJ5wQ7dugcYVnQl4RB1M" +
            "ORBeXJfdMkqP+4IjVQ9HuCppVnCapSuBO9Sqa/cmOEKWIInKzzRtkyTcgXw1EfsNlKskPQkr4Ta2Fm/kEMJzZnYaut3eTOzNVcFNSOCCpmMsOHidSvbKhYB7" +
            "kKHQDawi++2DmX9O78k38eP0lIB9H33mBTjjPXSf9NDFnp5/BfvMi+5cKWIWdHDY9iXB3At8utADMGJY17yJHzz+a/677mXmH/IxZo6c5iTUOkAEBlUIgyo8" +
            "Jg7LbZIV5dUNb/DbF27lvrf+g9g2vjVhKyPDMaz2zXXRA/xDhZd38Z02etd1qITc0S0BC/q8IvcBnyr2QPcQ3KcqL/T42x5+Kg5MNwlZAvEWWP0yHHCMy35O" +
            "IBSBg06GhqXQvDlL0lT6YyL2G2zXksUKxr1OEC6kCNnv2r8sCSIPCDZp7UJSuSqVhJUmIRkKU3bikXhjRnSanthbq/AbN7kErGDbGpBVwgrWgMgDIs6VUfpG" +
            "wALm1OOR0SN6vQl868oAejoSEeyTSzHPvYwcfnBuB9u4Ef+GP8P2JrotGegbsjpZs+5t5cWPxIHfA1voBxgRon6Mu5c/xOf/8V2ufeK3vL55Bb723TFs1bJ8" +
            "80qufWIRn/vH5dy17AHa4jHeXbuTE2t3oIUn3y3A7yPHbdhVU/uWnmyshLygWyGIdQsHxXD61VuLPdA9AFuBG9dfWxPr8RqexF0zhYRIBikBjmQzheB52MA7" +
            "z7tYcEeMnwmzz3B1welCHiGBcIftZDRpSPtuehOHxDa89PU6PHZ83wQEm2isQHqXonThjdT3RH3CB+9P5ORjOxNC3Kf9iZcg2p4pwhEIcKRbxOm62TlmQft9" +
            "anxQXYkcvH/fzprWVucO7mljBICt2/F/9Xv07Z5FOgB0RQP+D65Dl76SuiEqzJKVzLruyCs8gfJX+sEKdrtzdcJrd2zkN8/dzF3LHuD4ie/iPZOPYtbIaQyv" +
            "HIrXwyxlXy2bWrbw8oblPLjySf7T8Cxrd6wPkg0Nw0Nxzhu+iWrPxy88Ad+JdCm+kY5C+cLbcBm9u1t82cdlzhaiTGqXc63I44LeA5xb7InYzXE3yBM5reER" +
            "T5JYevw3W1a0MdDcCG88DsPmZm7HeDD7AxBrhpf/Dn6UDHMqWfubeJ6eBU2m5Zvudk64m7O4nUFcGVVaYlcyFpuQrgzithkuaRJhZcE7YD/Kzz8bM7xzf5ZY" +
            "/UqiLy6HDmSbEfdNt4hTgdRcXNA+va0CUEUqKyFLD+ScsH6TKwnKRZdBBH2pHv/yH+NdeC5y6IHZy5JiMXTdBvTfz2Bvvxd9e1WKfAuHrNn/XRLwioseik25" +
            "7sRfA6dR4FhwOkww4Y3NG7n51b9z17IHmTBoDPsPn8oBI6YycdA4RlQNpTZSTVnISZe1x6M0RZvZuHMLb29fw2sb3+S1TW+yavs6WuJtCIIRSf6JvH/wNg6p" +
            "aukP8l0H/CZ83Iae3P3n1Kmoh3gV+CGuN+/HgSPoXW/f/kQr8Czw52BOLiX/fYF37OoL6xfWREcvaPoVThlsdLEnZTdFI/CrxoU1u4q5Z8ITP2VBkrIou0rI" +
            "wsKyh2HfI2DYpMxtlVXDEZ+Eimp49R+wc7N7X0w6h6WyoBPNjRLizIa0OG/ac9Ieu0pv1tRr8QNyT3Y+kiDUGrikrYWySrw57yJyzscwEztnDWtrO233P47d" +
            "tCVQ1ArczYlSpETctwMpk6MQFn258VXczUVfBC2sRZevcHPSo3KlNIigL79O/NIfYuYciMyeCaNHuN9qWxO6Zh36VgO8+TbauDHZF7gfkPVvINTdGoo8J+iN" +
            "wLf6Y4SZ8yh4CG1+lOWbV7Js0wr+uuwBykJhKkMVRLwwnnE/jm99on6Mlngr7fFYUPcmiJgMq9kCU8vaOWfYFkL0S/PXG9XyXA+/+xJOrjFflup24IdLFtX+" +
            "CWDu/KbbgGOBDwLvBiZSHPGPbFBgNfAwcAfCv5fcULs1GLcFfk3+mlX4wCs9+aJVfcaI3AQsKPYE7aZYrL79b85rebRmunHTH+kcExaBplXwwh1w7Och0iHx" +
            "J1IFc86GsTNh2f2w/jXYscFdfCFTgMN0eLQaEC+pzOd0cQ/tZjFp9ZHWFRYlVa5ccrJ7Ul2NmbIv5uhj8Y4+CqnO3pCr/T//pf3x51LiG0H8OlsCVuo5gPqK" +
            "7CoEloJqK33oiqdNzbBxM9SN7d36a9ejL9aT9CLkChFoasY++Bg8/ESKxK11sWU0JaZSeMs3gdZsb3ZLwCsvftBOue7E63FWwLv6Y5QdkXBNJ076mB9nW9wZ" +
            "i5r2HXCkbUS67OMbFuWcYVuYXNYvZUf/Ba6PvHtDT3d1Ba5LzJeBPmQvJFELXDF3ftM44M9LFtWuBu6e++nmv+PZfYATcb/rocA4dnEuFAA+zkJ6DrgfeEhU" +
            "37j5t4PiAHPnN40FPgFcQP6S0zbhWjLe0JMvb7h2kE2zgmf3ZJ0SknhO4fr1Px6c+5+aJ+vxmNjJDZ2NhBOPAqz8Nwyvg1kfcu7ndJgQjDsIRs2ArW/Dpjdh" +
            "y0poWgs7t0D7zqBhexDHtOqs3UQ9sE/qvUQpkq/JsiP3OanvxtPe80lmUwshtLwKUzsUHTEG6iYjk/dBpkxFBnV9jxl/6XXabr0XWtsQ8Zy8c1JoI7CAEx2R" +
            "0OCamCTiZtT23MOmuoO+VADsbME+/TzenN45rvSeB9FVa4MbnD6QY8Ky9dO8v+klaf3b9Smr122XF90VFz+0esp1J14L/D/y3Cu4t0i2M8xhHV+Fw6p2cubg" +
            "bf0xxB3AwvDxG3qcDbBkUe3msz/X9ENxFvP3gMP7Ok04ScVrgLlz5zf9DvjrkkXVa3D9WN8457NNN6oyMdjXETh96Cm4pg35JmQfl5DzNo50nwKeUWHFLTfU" +
            "JuVnzpnfNE6dlf5p4GDyZ6U/DVyJmn8u+W11j//yGhfWNoxe0HQN8DsGyPm/G2AHcM36hbUNvVo7xGqMHJbVDd1dVrRG4ZXbIVIG009zpNtp2xEYMc0tfszF" +
            "ha0PNu5aG/rR4P0Y+IHRmLRqrRP9SE8sTrd4xYAJp72v7r1QxGVoh8MQjmBCEdfCMBR2nZV2Ab/+TVp+ezP+mkZ3YxHEdjUgqIy+v4nnmTHgbQqbc/gFNtGX" +
            "trSq6L2PoKee4JSvcln10afwb7mbvOgQDyxsyvZmjy6yKnqXqCwCvlrso+gNFKjxfD41YjPDw/H+iP3+VtG/5brSLb+pVeCfc+c3vQp8CfgMMKSPYxHgEOBn" +
            "wGfnzm/6C3Anqm/cfENtlICM536m5U+Y2CCQibg/vpnAdGA8LgegFhcXqsAlaGRT143jXC1tuEzjRpxreQXO7fs68LbFbPnLohQJzr1gexiRfYH3q5OBnEn+" +
            "XPFbgf+H8LMlN9Su6s0GVPirKMcAl+RpTHs6blTlrl6vbWR5RnZxugW8q4SseBO89Cew7TDtDAh3k/LghTNLlwYaVIk//zJtN/0F+9YqJCDfVMJVKqkrQb6a" +
            "JTEL1Y2IrMthv+/QFwNABH17Nf7P/h/edy5BRgzd9TrxOPZfj2F/9jvYtCWQ8OxXC7XQeCfbmz0i4JUXPRybct2JP8ZZSMcX+0hyhSqcVNvEcTU7+qPm9xHg" +
            "R5HjN/a87KIDliyqXX3O55ouVctDuCSkY+i7JegBBwbL5xBZANyc3OfvKhXYFiwvAnd87LPNnlFbhbP8huK6GdXiGimUAREcEUdxQiItuMSpbbjyqyZVbbnl" +
            "t4O6nwuRj+GSxXqhV9clLPA48EMVuf+WG2p6rcG9/pra2OgFTdfi1OF2u/O/n/Fv4Nr119b2+vzH4zWMtGMo60S+uyJhEfCb4bWboXkV7PchGDSp2HOSM3T7" +
            "dmIP/4foXffhb9wKEsqI9WbEfdMzohP1xmjAzYqKrmqPxHIh4Po+H4CAPvwEfmsr3mc/gRw4o3NGsrXQtAN9/S3s3Q9gH3wcdrb0Z1y2P/F6tjd77GZccfFD" +
            "66Zcd+JlwB9xbsrdAhYYHYlz7vDNVBjtU3JeD7AC+Fb4+A09P9m7wM2/qfWBe+fOb3oO+CTwBfriFspEGHhrV1/6yw3VPo5Qm+hJF5veYwX5VQFbCfwGWLxk" +
            "Ue36fGywcWHtmtELmr4F/AmYVMC52J3xNnBZ48Lavp0rntRjeBtPpmeQbqiLrOhOJAxIFFY/DDvegroTYNzRUDEiu1t6AEG3bcO++iqxfz2E/+oytC3RQzit" +
            "UUPiOSTjvik3NCQs4ICc4wb+e+B93+15EpZry9lC132ze3gwij7+HPHX3sTMnokcMA2GDYa4j27aAqvWoitWoQ1roHln9i5TewZ2AkuzfZDT2bji4oeenHLd" +
            "iZfiLm59dY32CwT48JCtzKpsLTT5bgUuCx+/oSc1vz3GkkW1G4D/mzu/6Z/AF3G9dPuapPVnX3i2oLORA0T0aVVZQt9dvJtwMqq/WrKodlfKYzmjcWHtE6MX" +
            "NF0GXI/zBpSQwjbgW40La3Or+c0GY17D05fxmJ5d3IIuErLIlKkUYOc7sOxPsPpBGHkIDDsAauqgchSYSLHnzMWft25FVzdg33gDf+lS7Fsrsa0xZ/Ual3BF" +
            "houZIAac/j6kiJe0bGi2qthHchqT6kvAKlwIqo+/pcC27dgH/gMPPuZi4mhQpqSpTOREwtSeZ/mCC8O9lO2DXtwO6u0gE4CrGeA1pRbYr7yNjw3dSlA1Vyi0" +
            "AldJnNsKtYMli2pfPfuCHZeI6B+BzwPvp3elOcuBG269obYfEsF7hptvGGTnzm/6NXA6MLUXm9gO/AO4Xo08ectvanK5288JRry/WPXHAD9ggJ///YhW4CqQ" +
            "W/KxMfnOfS167Sn34PE+PMqzKk51J1OZqN8VUl2J2tZAw2pY+xBUDIOyoVAxCspHQLgGwtVgypyFbCIumUq8TMlKEw7co2nvJR4Dy5NYLLO8yVr3XjQKsah7" +
            "bN4JO5pg8ya0sRHdsgW7aQt2+w7USibxpluznUqM0ohXNFDUTGRDJ9//t7W8keNP0IDqk+SDgBNI1toGk9axQcaeSbwJPCFI1vyTnAl4xcUP2yk/P/EXCJXA" +
            "dxjADQQionxy2BYmRApadhQFrkH0l6H3bCwoqd3y25o48MQ587c/p8hiXMOA04FhPdyED1y/ZFHtskKOszdYsqi2fu78pt8AC+l5vHsLcC+wGNHHltwwqEDN" +
            "PFNYe02VHfXNpl+KMBgXnx8AZlRREQV+JPCLdQtr8nf+e+Z+PH0Jj8MyBDg6JWaR3Q2dIGJII2KAVmhdBS0NsCXNZ50Q4UgqX5GqA+5YapQsM9LMkiNf3fO4" +
            "unTEjNcKMXUtC2Pq2hfGfPc9NUGMNwQmTaAjiIV2ItWOseC08qNMdSyaBb11ysNX7lJ4Jh2RVx7wowe856+4hMhCKNHtTWgD/Wv41Qez5qD0KrFnxSUPRYEf" +
            "A//HrjvLFAW+CodX7+S0wdtzUUHNFVHgf1F+FD5uY7/Nw82LBrUvWVT7ECIX4Czh63Hxt13hQZTf99c4e4HFuCS2XaEBJ87xIYVPL1lU+0B/kG8C66+tjYor" +
            "7/oxA/T87ydEgf9VuGbdwtq8zoN87d51GPktRloziLaT5nK6jjOZGs4h0jSfE4uBsAfhUPCZgrFgfDBxt0jMxZDJstj27IufWBKlTOnPg9ImG3PlThowuYB4" +
            "Ap5x9weSci+7+4V0BcmEvnPm9zqa4cle6Y6YH1TR+3v1A6g+gupTBdRG3luWp1Ae7Wqae51Zu+Lih9qAq3CuuNbebqcQUGBwKM684ZsZEooXioBbgR+o8v3w" +
            "CRuKcvxLbqiJLllU+4SKvQg4FafY9CQu6N8RG4Frlvy2tl8abPTqeBbVbsIRW7aauRZcLe+3gNPU8sUli2r/fcui/F74e4p1C2tbUa4G/ocBdv73E1qBa0S5" +
            "av3C2sIcv2fuxJN/dmntdiTjrkg4o8kCnb+X3uihq0YLHV3dnmSxvNMs8E6dm7p4ntYwIaOBQpqYhmvcQNr3gucQsK2mGfnJ9deBvW7yA9/f2pupj7z20HZU" +
            "r0e1bQCQ2O66tKH6q8hrD3WpPd+nlMAVFz/UOuW6E6/BFd5fzgBJzFLglEFNHFndXKia363A1SL8Inz8hqJbQLfcMNgCy4Br585v+i1wGM4yPh6XsR4BrvNC" +
            "Xd+JDRQYkQet6q9w4Y04LqP5EeAehSdvWVSbi6BAQdF4bW3r6AXbfwiyIxjvgDj/+wFbgatBfrHu2hx1nnOAfPHvm/SG03+Ix/4YmZYk4Wwx4U7JWKRiwRAQ" +
            "VUIBKXjuPL2p1oMJdauOGs/aocGCl3jEfWYSz0kRa0LCUhIdkUj1De7wXDQRyU1YsWmKVhnqVpl1viqZ+s9p1nAb8POYRvr29656NyK34aowSsgdt+EaunSJ" +
            "vLDTvr880fiWj+BqOfNVKtMrWGB8OMavJr3DARVthYj9rgQuE+XW0Ak9lpnsd3zsgmZjxE7AkfABwE+WLKpt7ONm+wVz5zeNwVnzrwMPWGTFXxblMb6YZ4y6" +
            "tMWIxj+Gs4Yn52u7voUjp3jc8plKynPUi2iLwdm/a+HJFT5efhW/VwLfRril8ZrCJ/LpVYcJE0acRUh+isfYTNcz3SdmJYmO7LIxCZnJ9HhvNonJjrHeRPw3" +
            "Tiq+m3g//b0un6e9jilqBVUPVYPiYYPnVj2U4H31sHjuMfhe8rkG62Cw6qmq92ur5lsTH1i4ra/zH93vhOnAX3D6ASX0HC8BH428/sjy7r6UV/NwynUnHoFz" +
            "IR5fzCO/ZNQGvjhqQyE2/SgFKDUqYc/A6AVNeT3/ByAB/xu4tHFhbb+e/7r4VI9I6Fw8fkBIxma6jOlMwh01orskYDKJt6fk2x3hdkzEigVkHQs+i2UjZtII" +
            "N3gMnncg14CoPWz6ZynijqHmz6rm0nH/+t+83WxHpx9/EnAjThWvhF1jNTAvsuzRB3f1xbzeG6+4+KGngHNwyVk5Zd7lA1aFmRWtnDV0a77b/OzAifh/vES+" +
            "JXSFxoW1T+HaPv4MJ8W5p6A5OKaP9zf5Asi8+3wk/gc8voTH61mzotPFOrLFeLMt6TFibxeknk7uXgdXd4bbm0zLO1tZVPpNQTL5SjskYWUmV0FaclWH+HAQ" +
            "B94por8QY7+ZT/IFiCx79AHgImD1Hl4u1De4uVkNXNQT8oUCtKNbcfFD69RwKXA+8Ey/HTtQbiznDt/MmEgsn67nZ4FPI7ogfPyGtf11PCXsnmhcWLsW5Ju4" +
            "87+nrSgHMpYCn1blG31WuOoD5Jz7fEzV7Yh8AsNf8GjukoQzErLohoTJLfFqVwlVHcVAshFuNpIOllQSFnRLvMlkK/cg6KugXxb08jH3/awgrr/IskfvQnUe" +
            "8OIASG4amAu8hOr5kWWP9lgHvaC6X1OuO3EcTkJxHtC75pA9hK/CyYOa+HHdKqqNzUfm8zpgMej14eM39krEv4S9G6MXNNUBn8N1dhqd6/pFdkE3AjcB1zcu" +
            "rH2nV1soEPS+MwfhmQ8Rks/iycGEqOg2ISujDjixkQ5u547u53R3cjZ3s0/gTu5B3DeW7TUZMWH1E3HgVIw33b2cxRVtVc1qq95tFu/3o+799Yv9MffRfY+d" +
            "Bnwb+CglIZoEWoHbEa6KLP/P8lxWLLjw5pSfnmDwzCG4C9FHcKL+eYUCQzyfn01s4OiaPmc+bwH+CvxarTwXeff6AZv8U8LAx+gFWwRCh+HO/w+SQ6Z0kQh4" +
            "K3A3cL2EeGbdDwaOYlpH6MMfGEXYvIcQZ+DJgYSkDo/aTlrR2S4H6UlYHWO+uyLfrp5nxHm7Idxsr31JJVSRiPWmE7GHVRNVvHVWveWoedSqd5evZtnIe3/b" +
            "+8YXvUB032PLgfcBX0D1SPZesY42RJ7C6TDcHXnjPzmX4/Wb8vWU604IgzkS+BROvWlMvrZtgXOHbeHbY9fhSa9t30acqtJNCE+Ej9vQryd1CXs2Rl26IyKq" +
            "R+G8QafRg4bn/UzAG4D7gMWq8vj6ApYX5Rv67IcjCNMJyTQ89sGTGXgyFsNwhGFkbyogQDkWk1S7ylC3IltyVYi4RojRHRnHiWm0ewImCxmDVaOK16bqqaqJ" +
            "WbytqmazVW+TqveGxatX9Vag3quD7vlD0cvxolOPGYRLOPwAcBSum1lVscdVYOzExXmfxBlqj0befGxbbzfW760nJv/i3SFRmYVrKnA6MIM+yFlaYFIkyq8n" +
            "vcO+5e25xn6jQD1OR/h2VV6MnLChYDrCJZQw6ptNYREOxLnwTsfp7WaVs+wHAo7h+kHfg6tZfKFx4aDSjWcJOSE29RhPYQLKQaCH4K7pdcBwXCvTCtw5npRT" +
            "KfaYu0DSH4LjhlZcAu4mXD/f10GeR3gJaIi8+VivW5wmUNTeT1N+fuIohGOAM4AjcG3ecoorGODrYxq5YMSmnsZ923CyjU/iLN7H8tE+sIQScsXoBU1jgeOA" +
            "k3E9nyeSdjNaIAJux0l5Js//xoW1q4s9FyWUsDdiQDRfnPzzd3siMho4GDgyeJwOjMK5j7xs61ngXVUt9rqJDTI8FM/mfPZxLoMNuDv9pcBTwAtY1oXfvaHP" +
            "dzAllNBXjLmsyVPLeGAWcDQwG5gat4w4eopXteQzlaY3BDz3dy328RX+zpBhI/Amrs/rE8CLCqvXL6wtnf8llFBEDIju1CsvedjHNXxfA/x9yi9OrEQZC+yL" +
            "a0+3P846HoFza9QqlJWJhs4Ztjk6MhwTX6WdlLtgA87KrccR75sI68LHbdiZ49BKKKHgWPfDWh/n4noHuGf0gqZqYJxvmVoRkf1EmIY7/0fhkhhrcDemib/f" +
            "OE4rewcuiXC9CG9XRGS5b3k9ZHhTYM26hbV7Um1yCSWUUEIJJZRQQgkllFBCCSWUUEIJJZRQQgkllFBCCSWUUEIJJZRQwoDBgMiC7oi6+vOqQMbjErD2w2VE" +
            "T8QloQwBBuHKNSI4TZsYrryoCafk04hLaFmGa2n3FrCmYcbiUhJKCSWUUEIJAwIDgoAnvD7PE5XxoAfiFFUOBqbh1IIq6X3htsWVIW3ClWG8ADwePK5pmLG4" +
            "JLpRQgkllFBCUVBUAq6rn5cQIngvToigjj6oYvUQnYQIGmYsLgkRFBEjvvXgMZGKqq9EqgadUF47dLDxQmut9e+Lx6I3rl720tOtPzm9VK9aQgkl7HHodwKu" +
            "e31eCOUQnBTlaTgXc44yA3lDDFgO/J1Aiq9hxk0lKb5+xJAv3/kxkIWgkxBDec0QBo/fl1B5JWrtOt+P/9WPRW/avG7lc5u/d0zJY1FCCSXsMeg3Ap7w+ryI" +
            "KEfh+qSegovnDiRsAP4JLFajj62aftNuI0a/O2LwJX/xkNAFwA+AYckPVKkaPo4hE/dDghZyau0ma+P3+NHYjU2bNzy17tsHl36bPRzDBg8udX7PIzZv2zYg" +
            "wo0lZKLgP8qEV88TMXI4cCFwJjm0YysSthG0Y0O9pxv2/92Abce2u2LIV+6KWOt/BeXbOFWnNCjh8ipGTp+NFy5DcSepAmrtVus713TLts3/WXPprLZiH0t/" +
            "4CtPHGmOb/T2r2zX95a32+NDMWaFozo83IYXiqImLjETk60mSj2WJ7F6/5Ya8+IRVzzeXuyx9xYlAs4vSgQ8MFHQH6Xu9XkTUS7EtSDMW/vBfsJ6YDFwfcOM" +
            "xQOqIfnujCFfurNSVb+t8DWyxvuVUFklI6bPJhSpgCwtNtTaHdb6//Jj0f/XuqPpkVVf32+PlRi95Z5jZ1XF7KfLonpmJMb4UEy9UBQbiuJ7UTQURb2o2FAU" +
            "vCjixfBNnI1q5d8Ki9dPan/isG8+u9vF0EsEnF+UCHhgoiA/St3r54dR/QBwKTCn2AfZRywFFqroX1ftV3JL9wWDL7ljsML3cd6QLnTId03AyW+q3Wl9/xEb" +
            "j/+urXXHA+98ad8dxT7GfOH6B06oGhbVz1TE7ZcjMZ0ciqnvxbBeDBuKoZ4jYU2QcCiKDcWEUFTxYoiJ4hmfTRb+GI1w3aRfP76+2MeUC0oEnF+UCHhgIu8/" +
            "Sl39vHHAN4BP08m9uNuiGbgRWNgwY/GaYg9md8TgS+4YrbAQOJduz7ueE3ByDdVWa/3H/Fjsd7GW5n+u/PLUbcU+3r7gVw+cNGaoH7+qIq6f9OIa8eLqezHU" +
            "iwekG3OEm7KAVcMxNBQVTRCwFwMvijE+AjwcDcll42/8z6vFPraeokTA+UWJgAcm8vqj1NXPOxJ3kT222AdWIPwbuKxhxuInij2Q3QmDLrljIvBz4P27/nbu" +
            "BJxcU7Vdrf+kH4/d2N7a8ve3L5myudjHniuue+jkcUOs/UVF3L7fxFWNr+rF0cD61VBMNRRLJ1/3GI6pI+AYhKKIF1NMDPHiGM/HQ1kaLZcvjb3x30uLfYw9" +
            "QYmA84sSAQ9M5OVHmfDauUbEOxuX0Tq52AdVYLwDfMtalqw+YHEpQWsXGHTJHfsBvwRO7NEKqoTKKxkxbTahstwIOLUJjVnr/9fGYovb21vvevviyRuKPQ89" +
            "wf8+fOqwYfi/LPftR00cNXG1Xhw1cdSLq7N8Y9hQVNWLiiPjhAs6hobdexKKaRAPVvHiiOcjJk4I4b/RCJ8d84d/Lyv2se4KJQLOL0oEPDDRW4WpJCbWzysT" +
            "8b4M/Io9n3zBSWL+0hi+VPf6eYUWDdmtUXvxHYeqcpMqJ6pCjxbSHunhOh0WkLAxoaNCkfLrK6pq75l2Q+O5Y699MVLs+egO33zslHCt6IKQykesGuursT6e" +
            "xjHWx1gfzz2qsfHE8+SjUatGfRG1pC1i3IKoisSNL++KtMsP1sx79/BiH28JJZTQRwKe8Nq8CoXLcJbv4GIfTD9iMPADVL5VVz+votiDGYiovfiOdwM3AYf1" +
            "eiN9tYFEPOOF3hWKlN1QPXjUgqFXPlUswZddYoJvPhJCPqdqxFejPkbdo4evRuNq1FfPxvHUx9g0YnbfFaMWg49JEq9iVEVUxagiWBHfxOXUsha96PlvnewV" +
            "+5hLKGFvR68JuK5+XoUIl+MIuLzYB1IEVOCyvL87oUTCGai9+I4zgf8H7F/ssQCImPJQuOxrw0bXfaDYY8mGhf9+37QyMd8CUx3H+D6eDcjWxhMWr3o2ScIa" +
            "Ul89TZIvxjqr1xGvj8GKwRfBIqgIjpBFFREvLvPHvuWfVOzjLqGEvR29IuCJ9fPKgAW4Ws4B7dorMCLAVwUurasvuaOHXHKX1F58x8eBG4BJxR5POsSYQV44" +
            "8tlij6MjPnH/B0MVIpcYzP4+Xjxl+QYWrnrWV0/jeBonZQH7EljJeGrFkXHckbHatMeAkNWKqBVBRSzK0FCMr676xEklV3QJJRQRORNw3aufMgpfwBHw3ky+" +
            "CUSAb4J8se6VT/c5pr67ovaiW0O++hcC1wGjiz2ebDBe6OBij6EjZlXoCWExZ1vEOldzkmyTz2OOeIOYsFt8QjYunsbFkXJcPPWDJW4855I2gWs6YxFVMXFj" +
            "ObKinY8X+/hLKGFvRu6EYczZwOXsnW7nrlAOfAfPnl3sgRQDgy65o0zFfAN0ITC0L9tyyVeFSYAVkT6NLd+4+N8fqSwXuRBkaNwlXmki3htXj4CAbYJ0Y4RS" +
            "BC1pj5Ii4HhgDfsm8Z5R32QhYSRkfOatnfveScWehxJK2FuREwHX1c87CvgfBr6eczEwBPhBUAu916D24jurrOoVwBUK1Urf/iUyr7Qwy4DyUIw2vMcTc6Kv" +
            "XtzXwOJVD98RrSNeDREnpHFCGteQjUvIxiWsMUIaE2cFxySkcQlpLLB+nQXsSNg3mSTsJ6xiY3xUpoVizC32PJRQwt6KUE+/GChcXcMAi+0NMEwGrqmrn/fx" +
            "vUExq/bi24co9irg80ApqzYHfPY/Z1VEhPNVTa1ViVkEVUFBsaiogApGUaOoVVELBIsqqokbFhUQUVyOlYoYq8FrEBs8qmCsepp4XxXUGMvZq+eecfP4JX/f" +
            "4/XOfd9HdWCXF4sInlf6U9pb0CMCrnv9/Aiq32TPVbjKJ44DvllXP+/rDTMW77G9hWsuvmOMoj8CPk4R+krv7hiJd4SB4+JI3KqoWlGrJmBVUVSCf6inor6i" +
            "RkVDoBYNiFgTRCxK8L8jVlSsW4yCsWDVItYgFoyCqmKsbyz7eHHOBH5R7DkpFFSViooK5hx6KBUVFYli8YEHEVpbW3nu2WdpbW1NtuMsYc9Fzyxg11jh08Ue" +
            "7G6ETwOPAbcWeyCFQM3Ft08CvQ54X7HHsjvi4Ps/6UXEnmOVIdaamLWCVUHVqFpRtYIgjnIBg2BU1AO1iUUc+VpR3Copy1bEihqLGotaS4p0rbq1FcRaRAyi" +
            "IbHy4ZWf+NDNk/90524n3dkTqCrDhw/npz//OXV1dVg7MAXsjDE0NDTwofe/n4aGhhIB7wXYJQHX1c+biKt3rS72YHcjVAML6urnPbOntTKsvuj2GTjVsxMK" +
            "sf2ECtaejHeXyb4e3km+io2rwargrN/ADa0GrOBsXlHjFjzAV/AV9RX1RTXsPNbOJg4sYBWLlYB4xQYWsEXFt4gaZxlbVK0i6ovqLBPlaOBvxZ6bgkGEcDiM" +
            "53kD2sUbDoehRLx7DbpNSpn4+jyDKzmaXeyB7oaYA1w4vv78vCX+VH1/qVf9vaXV1d9f2uPYfT5RfdHthwE3qXJCbyQieyYjCWm5WHskyo05XfHGRzVk4xoi" +
            "pmGN2RBRDWtUI8SCx6iGU8+JaFTLNEqZtgdLlHKilNFOGe0SvCdlRCVCVCLaLhGNStgtJqyxYImbULCEbdyErBWv0qh84L8XfHrAKoXlBQPV9by7jbGEvKHb" +
            "C7kqhwGfKuL4FJd3Ai7OmFh2F5xn0L8CT/V1Q9VXLj0Ry6eA/VCWV1+59A+I92DzFQf1iz+t+qLbT8TFCWf0x/72VJz36PmDQsj7fGs835q4b41a9fDVYK2g" +
            "6qmqs35Rg6jgrGCDATxFQwg+YFVdPNglW6kaxVoraqyq+Ghg/ar6YC0YH1Wrqh6qvnNTu634onrMoOa2qUB9seeohBL2FnRJwBNenxdB+QL5FVVQoB1oArYF" +
            "y6Zg2R4sTUALEAdiwSO4LFsvGHMZUIvrN1yDKwEaidNoHhQ8VuFEMopJ2KOBC+vqz1vaMOOmaG82UPn9Z42x5nxc+dfI4O3DgTNQ/yfVVy79efOVs5sKeRDV" +
            "F93+flw7wYn9N3V7piVQq94hqDkobo0ft55aNfjWw7cGqwa1RtUa1BrEkbCKCiZYPMBHNISrl7YSuKBF1SVh+RC4mK0jXNT6Afn6qFhFfNQYq1ijasH4vlEd" +
            "bay8mxIBl1BCv6FLAhblaPqWZGNxZLoWWA68CbwNrABWg2wHbRJosYi/asaNfm92UvfaeYIxHtgwKlU4Qh4MjMGVTE0G9gmWscFn/enCPRPkKOCRXFes/v4L" +
            "Eay9GPgu7oYjHUOBK4FZ1Vcu/U7zlbPfyPfAqy68Q8TTjwM/pn/VrWIiRkCL4movJMISOs1iBrva34B8nQWsVj1UjUvGUoOzgN1jQMBqEDwFP8iG9hW1LvaL" +
            "FatWLCo+VqwkyDZJvm5RVR/FD6xfH8XDs74Bee/S8z5/0+ybfr2z2PNUQgl7A7Je4OrqzwsD55O74MZ2HMn+F3gCeA3kHdCtDTMWtxfiABr2v0lxVnIcaMVZ" +
            "0wDPJ4/ntXkRhMHAeBwRHwgcAhyAI+pC6jgPAc6fUP+px1fN+H2Py5Kqr3y+Emu/hdPb7kp1zAM+BkyrunLpZTuvnH1fvgZdddFtIUE/B1xFPwqvGJGVg2qq" +
            "/xSKRM5XGNdf++0PfPLhC0cYzIlx6xEPrF7feljrBVawh7N+PeeKdlawy5tCgmxooy4ZSyXIiMY66zcgYj9BwKrii5o00u1AwJbkc1GMb5SDwnG7H/Bcseeq" +
            "hBL2BnRhYcghwCk5bGcbrvXc7cDrYtj8zvSB06y+Yf/FUWBDsCwFbq2rn1eOs4j3B44AjsYR8ogCDOFUwRyMuzHZJaqueG6QolfjBC56YgUeDPy+6sqlCwWu" +
            "b75ydktfBlt98R1lqvr1oNVkVQHmIytCRh6dOLT88oOOfNempY3Rc/e0fJQKvNmqoWkxNb6vjnDj1sP6nlobcmSsAfmqAfXAGrBGjIo1gSXsq7vzsoAvEMYG" +
            "yRKBVSsWa6yocQRrxRcVHzU+aFxtknTjCQJWxbeetUNVzXGUCLiEEvoFXV3cP0Iq3rgr7AC+rsqNq/YfOKS7KzTMWNyGc4evAO6pq59XA0zDCWmcDLwLyFe3" +
            "mJG4Od0lAVdduXQYcC3OA5FL/HoE8EOFmVVXLL1y5/dm96r8qfriO6pV9XLgy/Rfs422srC56bh9R/zozguPXvXxe3dO3cO4F4AQofdYDVXHrRf3raeJJUG+" +
            "vg2ptR6oh1pP1RrFBi5oazCBS9ooeApWCUqQcC5oLDZIvrLiJ0qNQOPO8iWO1ZBENB6QbghLHBVfLT4hfAFOePzTC244+v8tLLmhSyihwOhEwHX188YDZ+Sw" +
            "jTvFyu8bDrhxtyHfbGiYsXgH7s7/ubr6eb/BWcOnAWfiXNZ9JaMz6urnXdcDicpvAPPoXfJYGJiHMKPqyqWX7rxy9iO5rFx10e3DVPVqYD79JC0pwpra8vDC" +
            "qz8480/nHzW5FfD2xPyrDz/4paFo6Ni4hojbEH6SdD18Dal1PX6xNqQauKIJYsJYg8HDJBKyENJkKYMqYE3FfY0vVq2qtYHlG1dVX1TjWOOI2C0+lpAocbX4" +
            "qMR9o3Z/49t9gJeKPWfFgvV9/DyLdXjGYAZw/XEJxUE2C/hYnCXYE/jAP9854MY9SnKxYcbiFpy1+t+6+nm/Bt6Nk1w8gc7JUD3FdNzcLtnF986h700DDgf+" +
            "XHXl0qtU9caW781p29UKVRfdPhb4X+Bs+ilz3DPy1NjB5VfUf++0x8A1S5BU2dkehQoiM9DQvjEb8n0b0rgNqa8htdZT34bwfQ+rIbU25GLA1hO1XmABe0jS" +
            "AhaMivgq6qFiEXXWb/A/1hFrQg1LfUe26jtrl+A18cRrtXjiCNizIesPU/UOYy8m4DvuuINblizBM/kp4fet5ey5cznrox8t9qGVMMCQQcATXp8XQjkVZ0n1" +
            "BDFc/HePRcOMxRuAWya8fv7dono0TmbyNFy5Uy4IA6fW1Z9/a0P3Gd+D8zT0McBPRGRW5ZVLr265cvbarr5Y9cXbJ+NqfE8v1Dx2QLQsZG5+16RhP7zvS8e+" +
            "Q2BtJ1l/d6r07iE8Gz7WEhrs25Af9xMWcIg09zM2WDRIzCJwR6Meop7rs4DBOKVosUqitQLO2WxRCaxeElrQQfKViaMad6/TCNhKnIh4quJjrScW3wOO/fvn" +
            "f3zTGb/++h51Y91TvPnmm9x37715U8zyfZ85hx5a7MMqYQAig4BFGQfk0k6vHFfm0ydMfP38iKpGgvGEg+2GUUJIcowWZ3HHgTYgGjyPGaT97V6WMfUUq/a7" +
            "sQX4V139vP/g4sRfBN5Lbn2RjwIdD3QXn30q2G4+UAZcCOxfeeXSS1uunN1JEKTqi7cfAPwSOL6Q85eAwIaqstCPv3rytBu/ecp+O8ni6t7Tkq+Ou+/rlaKh" +
            "4+IalnTy9W0IX0NYP0m+Ym2aFRyQL9ZDrBFRg1ijRkWMI1806Y5WSdYAuzpgtWpFJY4aX5SQI2DpaAEHzyWOlZCqxK1RPTjkx8YDK4s9d8WAMYZQKJQ3AhYR" +
            "TJ6s6RL2LHR0QR8M1OW4jY/W1Z/3l4YZN23s7ksTXjs/hDBY0FGkanTHAaNUdSSu1KUGp6NcDngIBueOFcgIe8VwYh07ge0W3VxXP28TLst5NbAKWA9sBJry" +
            "WQIVJG/dX1c/7wngLOByYEoPV68DDqIbAlblh6TqlvOF44EllVcuvRLsn1quPDQGUPnF245Q9BfAnP6Iu3pGlo6oKbvizatPf0hEVJ3qbcc9q+9a/OwxoeCh" +
            "WjFFbXhW3IZtKv4bxvdDaZavh7VhtdZDbQjVMJq0gg1iPUSNYEWCemBn+aoEcWD3P+KyoJ0lbAVHwKC+OCs4IGBxpOtKlmJYm3get571x1jMIeylBFxCCf2F" +
            "jgR8FLnXxB4LcnVd/bzvNcxYnHRzTnjt/DIRHQ/MBGaB7g/sB4zCkW05hXE2WpyFvA3YDLxTVz/vVeBVoB7kbVW2rNq/b0ljDTMWNwOL6+rnrceVYPWkfKks" +
            "mOMuRe9bvjf7kcorln4OZ5VOz+O8TET5JZgDK694biEbV8zEuZ33y+M+ukI87JnbDxg76OrHF5z4Bs7q3Wsk5z3Ch1kbHmlt2Po2pL4N4x5DWBvGaoKAQ6J+" +
            "CKthVRtS1RBqjYj1VIJkLNQYR8eoutpg14AwYfmiEjwGdcChQAkrLjZhBRNKWr2OiD33aH3CxAlLvEzhGOCOYs9dCSXsyUgScF39vGqcBZwrDC5rdnZd/bx/" +
            "AGuA0aCH4sh3LIUVusg2nspgGQvMwil6+cB20JUivFRXP+8Z4GngjYBMewWFfwrcBVzQw1UOqaufV93dPlu+N/vByiuWzsMR5Jw8zk0l8GVUjyFSOZpY64Q8" +
            "bjsrBLZURLyffurIyb/5348e1EQ/ZVcPFNTcNc+IjRzrayTs23DMJVyF1DoSdtav756rWwLi9UQ1hKqnqCfOGeRyoFEjquCpEdfDQsX5DBI50U6iUo0vWB8n" +
            "PRlCiYvaEGriKZd0YA2nLOIQqnE16Jxbv3jDsI/+8rN7ZIvCEkoYCEi3gMcB+/ZyOwIcGiwDFR5OvnEojtTm4VzUr9bVz3sMeAB4sWHG4u25bHTVjMU2cEd/" +
            "mp5lL0/FzfWy7r7U8r3ZT1VesfQ88h+fFcS8i5oR0LIN2ncULOhqRF4ZWhX53mMLTrx3wpBKq4rZa8zeAIeZfUapDc/xNWLjNqTWT7mgrQ2ri/+GExnQ6mqA" +
            "HTGjRlwsOITYlCylugYNqApGEc8Zw6BWXPdbR8HgBeSb0IMOoRIXbAgkLmq9pFVsk3FgH6tx66k/2SLTcYp2JZRQQgGQTsBTKYwK1ECF4AQyRuLKjC4BXqir" +
            "n3c3cK+oLntn/5t6mtgV7+H3wM3xPuyCgAFavjf71cornzsflevIrTZ71zAhqBoGXgRat4LNaw6bDXvm7n1HVX/vv986+TUSLue9jHwBwpQfoBqpi/lh6zKe" +
            "w054I0G8NqwavGc1BEEJUvBc1RpJZEK7pCyjqiICogiKBkocCKKoWlFBkfSUCd/1BFYftZ44bWjPuaLFWcVW4qgNLGENEbLxWoR3USLgEkooGNIttv1wLsq9" +
            "FYNwluaPgftU5Fd19fOOm/Da+T1xn8+m57W7VeQQd225cs5KlM8CSxItc/O2iKAVtWjNSDRUlq9+vtvLw941Hzpk3IUB+Zpch+UHCVgF6TXczxAbOdL6kWrf" +
            "hjVuwy75ykbU2giJxbdhrIaxNiy+RsRqJGEFB8/DohoSq2GxGhbVMEoEJYTVkPEJG1/C4hOWOBGJEzZxiZi4iUhM0hYTkWhyKZN2U0bUlBH1yiTqldHuldHu" +
            "lRP1yoh6ZSZuIkf86ku39mf4qIQS9iqkW8DT6bsARF8RpHLi4zKd0y+boWARUpnRhcIE4LPAR0X0vrr6eYtUeGzVfos71UXWvTbvcOBDOWzbkGNyVcv3Z6+t" +
            "uOL5i0C3UQiVqnAF1IyCli3QtpPe5h8bkeW1FaHv3XHhMX87YsrQeG9dzrZAZNnfJHzIX6+uFFt2pG8jTmbSD6vaML46l7NqWK1TwUq6ndV6oCFUneWbaMwg" +
            "agAjqMFiRFRUFMCKL+JiwAIqiSNVUF9clbCnuIYLqPHA+kHc1wfriWocVU9UPNT6jtglrp7amcaFS1b078wVF6qKtTZvpUPWWheiL6GEDkgn4P7q9dqM65q0" +
            "HlcylGiSsB7YGny+E9c3OD1TOVEfXIlToxqRtozBJVwNw1myFXka6xCcMtUpotxaVz/vBtBXG2bc1F732rwqhGOAq3sxdznPdev3DtlcccXSbwRz9xXyrdPs" +
            "haB6OHhl0LotV5e0hjz554ShlVe8euWpLwJG91KXczqqtWai2sj+cT9s1YbVahhfQ87l7CdINyzq4r+iToZSEvW/6rKfg9fJijxRNSqJextVDGBB0MRlXgVR" +
            "TTkffEGC5g74qDHB9vxAqMORsFVPXAzYxxfPhtQfDXoQexkBV1VVMXLkSLxQfrph+vE4VVX91tOkhN0I6WfYqAJs38eR6xvAa8CLuN7Aq3ElQs19rdGdsGye" +
            "iKUS59odjqu1nY7Tcp6Oi20Pp2+ENRT4HPB+kKV19fM24yyDOfROuapXvXVbvze7ufLKpVeo0gR8i3x3KhIDlYMgFIadWyAe7clazWVh74YT9xv5k9s/f9QG" +
            "Oqpa7cXwbMVsayMj1UasdbW9jng1HNT+hlFNZj+7uKxLwhJVTwUTvOcsXzAB0xpRRK0KImBVCWZc0jz56qLEVh35JnRsDIiHqO9iwgQ1wtbDJvoEOzJG1S8X" +
            "tUcAdxZ7LvsTY8aMYfacOXm1gMeMGVPswyphACKdgPPV89UC9cC/capOS4F3gmYHeceq6YsVZzHvxJH9a8B9ABPq59WKs4xn4loOHgnM6MOxjiE/yVC9nuuW" +
            "K2e3l3332WuNmCbg+33ZVpeIVIIXkHB7101xRHi7pjx89c/mHnLr2YdOaFfF29ut3iQeOEBkS9kx1paFrQ3H1XflRU7pKhwQbsr1jCPgRNazBklXopgg49kI" +
            "ajTwMSOBJawgBg3c9uKyobGgKqAqIoJr3+As4kQXYUk0ewhI1/NR6ws4i9gG/YON+of+6LJHBn/jhydsK/aU9hcSylX5VK/a691BJWRFOgHnqm2cDXHg1wjX" +
            "Nuy3eFWxD27VjMVNQBPwOnBbXf28wbgEqGNwLQcPxVm3/Y3eNnQAoP37h8Yrv/vcL1VkG/AjemlRdwsvDDUjIBSBlu2BBZX2sZFHxgwq/+7yq09/BqdHnLcS" +
            "oz1BBOuQrRcNV1s+27dhVd+JbSQs3cDy1aTlaz1Bgy5ImtR/DuqAxSU4Y1zWnEvTcJnPGAHBBlVIwRedxYsiaiVOwvo1ilhNZEarGleiJIE7Wg14jpAT5Kvq" +
            "Ww9/KtafCjxb7DktoYQ9DekEnI9sx4eByxv2W7yt2AeWDQ0zFm/DWeVP1dXPux4n0nEKTqgjHy0He4pc9KOzouX7cxT4Y/l3lzYBP6cgMXwDFUNcqdLOreBH" +
            "AVojnrlxzsQhP3roayesIeVyzhdpqm81qGbdfRH2q/ZTPzLF2ohvbUidazmccjenWcAJtzNOdANVT1BPk65nZwEjwT9VJJFtJSIoBhSxoklqRlD3qyi+CC49" +
            "SxQ1KmIDS1gCCUuDSmANi0HVoHhi1deQ+oNF7LsoEXAJJeQd6T6WnnZA6g7/CEhuwKNhxuKdDTMWP9UwY/H3cG7lTwF/pX+6O+VjrgFo+/7sv4F+BrWF8zhE" +
            "qqBmJFJWta2qLLTgRx854NKHvnbCWi2QqtWekDBqbMXh1pbV+EFzBVdyFNag9jdRdpQkYQgUsDQUZEF74kQ3jKh6Am5RFUGNKEYUY1SNUYxR8UTx3HuIqIpR" +
            "8cSKJ1ZC4uOJj2fiYkxcPBMXT+ImLHEJS8yEJCah4DFMzEQkZsLETISYFwnFTfioKy9/Km/nbAkllOCQnzQ/B8W5e3c7JFoOTqyf9zd1ceLP4FoO5j++Wghs" +
            "WlFLuDJC1TDnMi4EQhG0ZmTID3lDnttWUQa0FyyqtZuHy/a59edltJUdpTZs1IZ8R7LhoM9vQLA2JEHJkQZuZ0kT2wgUr5z1ixpJ3SsbXMqVBL76ICYc+P8t" +
            "CWs3cCEI7i9TPLdO0iXtapcQE8SGfbdfsUaxatVDxReLZ0Piz0K8MUBDsee2hBL2JKQTcIy+WTQCzJm88pwbV06+uVsbZkL9eSERU4XqcFwZ0XCcItVwXEek" +
            "KpybNnHVUTI7IG3ByUhuSlu2gWlrmPH/et1k4Z0Zi1uBh+rqz3sM5CjgIlyP3HyVNaXPdZ8R+dxfjPHMp4CFxFpH0rzRlRKFCqWdINVtcXv5n1/YfMDTq5q/" +
            "/8JFM5azl2k79wTV7aMm4pfNshp25OsHlm2izjeZ8RwK4r2hdKUrAis3ScKCSFDkK6iYoIuUqKs3wpUmoYioCM6Br4hFVVSxQUY0eJrIy/IDZnaSlaIgQTMH" +
            "i6oVKy5OHMKqFW+cwT+IEgGXUEJekU7A7fQ9NvkRv63sPuDu9Dcn1J9fKWgdLgFqJnAAqlNw5DsMR3AePRcCSYh1xHF1sVuA9WDfrKufV4/Lwn4DWNPgSDUn" +
            "NMy4KQo8MrF+3n/VxYe/jMuizhfa+rqBsi/eFhbli8CVJBLo4u2wY4Mj4XC+7xmSCMWtfuyNTW37jl/48ndXfn3mA2FPVLWU6JmAsVVzsGWjrIZtinBDENT5" +
            "kmyykCDgJPmKS15ONFwwiEu0MoHmZBNiVyN2tbWhNSI0g6qoKRfxR4OMR80EFRlmhZC4AmB1KytW1HG5I21ImshWFAlSuVxOtWJBrKhaFFtpjBxDh7/rEkoo" +
            "oW9IJ+Dt9D0TehTw67r6eUfiNGTDwMGgRwL74yzcfJhnQkoZqzzY7wzghODzVlxJ0rK6+nnPBmN5SVTX5qDvzDszFu8Ebqmrn/c48DPgw3kYO7i57jXKv3BH" +
            "uVp/gcICOlrn8Sjs2Oh0nssSZcL5D6r6yiGbW+K/G/nDF3/8yYOG/e66MyfsID9KamqTzebzi/64PzD3fsKYxrLjrA2XYUNxEprOmiw1gqDMiJTghkAHl7Mj" +
            "Xw+IQfxFNfF7VGKPiMTeILy56fkvHZhxY3n8/70YicZGV4kN16GRI0W8MxRzlEVqAN8Rr8vesoI6dSyVlEvaBj+fDaSmDYp1XZWwGDVHfPmqt4b+9PJ9tvTD" +
            "NJZQwl6BdALeihOx6CvGApfhrDxD/2UWp6MClxU8EXgvjpAbVOSpoGXiEyhrGvZf3KNrfMOMxavr6uddjYsP56OifltvVyz7wq01qv4VuOYR2RNj/Bg0bwT1" +
            "obwmj9OaCUVHtsb06huXbjrgsXeaf/D8RTNWkgeXtF8oKcqCzUQK0zZ+aCR+2aFqwxYNKTYprpFwNQeWb6BMZT0BLyjbTWQ9O6tXxX9dJXq9muY7X/zaxPXd" +
            "7ffRrx4UBaK4v+MX333Nmj/EtfYEJXyRYo634CFiJUNNPJgWcQpbjoQlsIaVoNkDirEeZqqI7EepOUMJJeQN6RZLY563XU5xyDcbKnCqWOcBfwTuR/hpXf28" +
            "Y+vqz+tpA4rluHrifKBXc1124W0jUP4PJ0XZfVaq9aF5M7Q2UWDqicStnrdsU+vvxy186QQSMkx7QCZzbxDyB81UWzbJ2pC1iX6/iZIjDWngfk5kP4viYa0E" +
            "2c4Gl9WMb01sifWaPvbCN4b9elfkmw0PXzpu538uq/l72G/9hMH/H4TtFvGsGHxELCIWI35qwRfPLXgSF09i4klcPGJ4xCQ0OG5CRxV7fksoYU9COgG/U+zB" +
            "9BPCOHf1JcBdIEvq6uedVffavO7d76qG/CUcvZ3rCmUX3jYe9FfABfTU1avWqVm1bC94bY9VjtjSEr9p6NUvzP/ug+vKRQKFxL0MJl5+DDZcpYnyoxTxaqK5" +
            "QtBy0IlsWCHRZMGJNNOmXvtPY+XrL3rxa+N22bJyV3j4O0O2DJaX/8cQ/wpoo4WQYsRijA2I2BfjFozEMRJPELGEiAVkHBfPxE3omAuuWlWw5IISStjbkH4h" +
            "X05m84O9AUOAM4HfI9xeVz/v7LrXW2Gt2gAAF31JREFUz8uurywyC0fcfYXFzXWPUXbhrVNBfwuclfPe1ELLVrdoYX9ehbEtMfvjnzzWeO2Rv359nAh5bTI8" +
            "0DF18V8HYcuP0UDpisQSZD8nlK4UL03VKoN8o9Zr+7/WqjeuevXiaXmTbv3bpYfZRy+t/JOnsa+ArrcinsV1VbLO5eyIGBErhjQyTljFEhdP4xI60A+VTS32" +
            "PJdQwp6CdAJ+HVfiU2woLpbVguuMlJCTbMbFcvNSwtMBFcB7gBtR+UNd/bwTJtafl3Tx1tXPOwCnuzwiD/vaSQ6u7Mjnbz0IuBGn2NU7qELLNmjekmuXo96g" +
            "PGb1cy82ti6uu/blIwlaTO4N1nA4PnR/8SMz1IYsTt9ZE+pWQfxXXNw3UY+bSLwyAmKtF10Uq2z40bILD+9Tg5Ku8MhlVbcb9b+NapMKRkWwYsRHxHdWsfgq" +
            "ydeJJbCI1Tehkb4JH13seS6hhD0F6UlYb+LqaQuXteMQxZHpJlwLwsZg2Rgs23BE24orM4oH63m4uHJZMMZhuNrhccEyOlhq6H3suQLX2/c4RR6qq5/3WrCP" +
            "k4B983T8G4G3evLFyIW3Hg38QuHgvOy5rclZwVVDweRTg6UzfNXjNzTH/jDkqheu+vYJY5d8/diR7T3sD6zxoH3q7sbZJl55HLasFg35iX6+mUuiYW8q2Uqc" +
            "yIZRE707Ftr6g9e+cEjOZXO5YEj7+j9uKRs9SfEusyLGiGiy/7KIursDAVRVRDSw2RXBoCEj3onnXbX2xpsuH1uQm4QSStibkH4VXoOrnZ2cx+1HcUT7Nq42" +
            "dxmut+hKYINAkyA7355xY6/Nsikvny/xkFbgSqhGA/vgdJ0PxbmMx5I7IQ8DPprHeUjHG7i57haRC289BfgFrp1i/tDeHEfkfqpHTMKVhhUMChNbYvZnVz64" +
            "ZuYdr2758ROf36+RHsTRdzfiBdjn/91XK63lJ6Ah17/XegqeSKLRQaq+l8D6dZ9hjEp8edzb8b3Xvjyl4CU+d145yT/p6u0/i3qVByl8wIJvELWujUOi5Ngp" +
            "bKlrvqQIHoqKqMIcIpVTgVeLPecllLC7I0nADTMWN9fVz3seV7bTV8SBv+EyjuuBdSp2x6r9fp/3IOSKWTcqzl3dAqwDngdum1h/foWiY4FDgHfjOiBNIw+N" +
            "EPqI5xtmLG7u7guRC2/9MK7Bwrg873sL8GN2bPwF1SOmAb8EDi/w8VbFrH7p+XWt+0+49uXLV31z1lJwqg9dWcO7o55HODp0ptiyA9SGrKTLSWJSJUcJYQ11" +
            "LQZdNyNtsabtR698dfzL/TXWB74zaNsJV7f+wPfCB4JMsoI1qmpBgi4OCbVLNYjTvBRRq6pGvDEqegIlAi6hhD6jYzbtEzhFrL7iHuCChhmL72yYsfj1hhmL" +
            "txeCfLvDOzNubG2YsfithhmLb1OPixA5Bfg4Lp5aLEm9duDJ7r4Q+fytZwLXkX/yfQWYF1Ouif723B3Rq+Y8B8wDHuqH4xar+t6NO2N/Gnr1C2f/+YWtIZE9" +
            "Ky5s4lXvwYYHO9ENk6HpnCTfpAUsgZsXY03strZI41/6e7yPfKfiOVH7E1ViqohVJ3fpGhaK+AguBiyuRMklaIlFQr54p5z9P1t6Wr5XQgkldIGOBPwifSen" +
            "OHBrw4zFW4t9cAmsmrZYG/a7sbFhxuI7BTsfOBX4NvAC/Zv53YCb464hfAPnNs8XLHAnysei13/0bv31R5O0F71qzusgn8Z5KwoOVabujNpfffaut7978v97" +
            "Y+iekiU99YYnhostPxEbwukte2nEmyTiIOtZEBVUxVPsm3Fv50+WXzKrz9KkvYFnY38AvV+VkLoGheI6KSFWMVYJiFjEVyNxROIYGxczJxYqm1nseS+hhN0d" +
            "HTJxdA3Ik/Qt4SjROKHHGF9/vjFoBIggWoZKBSkhj4RHMu62K22gO4GoItFVM27MaV/vzPi9j3OL10+sn7dYnbzk+bhEp3xIKXaHxxFW7+I7h+Rxf00oP1Pk" +
            "/2K/Pmtbti9Er5r9TuTy5z6HyzT/BIX3ANfGfP3mY+80z5j4o5eveOcbs14BEg0GALAKu1MOVig6+HCxkRmingUD1iCkx3sl0b1IXOMEEZCYNdHrX/3q2NeK" +
            "Ne6Hv1PVdNwPo//ri3eYICONYq0oxnVucKKUBMoqAkYDqWrMCJXQ6cAzxZ77QsBai+/7eXPRWGuxdm+r8CyhJ8gg4IYZN8Xr6ufdB5xD73vWhoH31dWfd3fD" +
            "jJsy7uwn1J8fEXQQTrt5Ak76sg4Xq3WNGVQG4Yg3EowvcV0Omi9oDJdFvVXQ9XX181bjkryWA+8orF21ixhrAu/MWLwW+MXE+nl3KJwLfBaYUqC5jgL3Ney3" +
            "uFurT5V15CfjejlwOda7PXbDh7vdZ/SqOY3hy5+7BCdjeCH5bVOZDcZX/UDjjtjUwVe98N17zt3378dMqvKtIkZQP7jy7Q4MPPKmGz1va8XpxoYqUeMn5SRJ" +
            "kq848nXWr8uCFk8l/nAstP1PxR5/VduGx3ZUjPm9wtctiARNliSIWKPu3sEGKVnGfSoWOe3MHzb/6u7LqjcU+xjyjTFjxjBnzhzE5Od+XK1lzJh8KNiWsKch" +
            "y4VW/wOyDNe1qLf4GEhzXf28P+HKifYBZoHOwmVZj8aJYKRbuH2B4rSnNwmsqKuftxR4CngOoaFhv8XdWskBES+sq593D841fTb5t4aXA4/14HuLcR2O+tIA" +
            "/T6ES2PXf/TFnq4Qu2rO1vB3l16K6g7ga+SnaUa3UDigJWYXnXLT8p8eXVf9q/vP33dbofeZbwzecdg00bLj0ZDjLwyJFoGJsiPFiEu6Ct5Ht1oT/Vn9VyYV" +
            "PUxz7/fG22N/GP2NSuhUFTkQ1LckUqKDW4agYzCIU4sGFcz+mNAJQL/HrwuNI486isOPOCJvriAFTJ7IvIQ9C53OioYZN60G/tHH7ZYDXwDuAx4E/gR8F1dj" +
            "ezCOgMvIn7tTcDW8E4DjcVrJfwT+hfLHuvp5n6qrnzdp6vKPd7u/hhmLXxW37lN5Glc6/t4wY/Euy48U/TkuA7o3giM7gR8jem4u5JtA7P+3d+5RVtXXHf/s" +
            "c84MA4iASIgC0zbRwPhoiINCrantMo/aNu2SylC1rWNtXFQaH/GBMBojzgCKVUsMMFkhDMY0NmqqpYmxyfKZGBWwKtShPoBc8EEYGERgmLnn/Hb/+J07Lxm5" +
            "M3PvnHtnfp+1DszjPvY55875nv377d93LzrjEEZvA24FcubEdBSOS0d663PbD6z43WWbPiMiUTFVQQfhyPPFBBNRTzFdzDXa531j8ZVYlD0j4SMHR+wciOK3" +
            "rHhuQelWUfNtVVo1LsZSRIx02hBMLMBxodYII/7sv1iyP+lVBTnH8zyCIMDP0RYEgRNgxxHp6VPxMLadX38ZRUemO9CUYLPtKmA18ERbVHp3eWP12eVbqnuM" +
            "5zcVDbuAZ3Mcy2+BR7J5YLiq6oAqtwCLsUursmU7cKWqWZheWdXU10DTddPb1Ph3ATcAe3J8HHrCj1Sr3juQ/sHYRS+fb1SLQoNPWr7pExKVfQUTeNrR0xfb" +
            "WjBub62eKJ4omTW/ZpvxW1dsnff7+XB06zOBpn8E+pTa+XjbCUnFdgWGzP9iRDAiGMQYvD9Ke2VnJB27w1GsHFGAVfQVbPY6WAiwa4CvAf4T5XvljdV/Ut7Y" +
            "oxDn2g3scWzFdVaE9bNbFFOHbeuYTe/gp4C/Sa+afX9YP6ffF/awblqUvr2yHpgHvJvjY9EjqnzuQFrXbHr7nX9W1ULppNUjJdHYL4opPRX8qLPBRrf53swm" +
            "tstR9N3N1x+/OenYu/P0wuH7RM29iu5VbRdd2zAiI752mVLma41Ejo/Ev+TL39jr0juHow8c8Q9nx9S1aexcZOJzVHlgHLba9xFgZXljdZeq4/LG6jOB83P4" +
            "fnsRGlIVDb0SxnDVnLSmw/tU9WpV3a2qHGE7rKrfVvSS9KrZL+b6QKVvr/x3Vb6qylZVayk9ANuE1rZwXhhFE3K9P7nk5PsaR3tR2RxRf1hGaGNzDSBjMRmv" +
            "91VBVHww64136PtJx94TJW0tT4I+rOCROR9kRDiTDYsYRYyqFWmRr0Qjjzk96dgdjmKk5ztXkV8B65IOMI+MBf4BeKy8sfqu8sbqi8obq2/AGnXkshL6v1T7" +
            "1sQ8XH2RCeur1gJzsRaendkBXKN414Wrqt7L10EKayt/il2mNZBZWy5bP+aFoHXMeZ4pmQ6ekXbBtaIr7SPoNvMVxFP0Q+O1Lf/f6z/R696+A8XTt45KY8y3" +
            "VPUtBV9BVDXeYjGGWIxFjKJGmRTh/d0FNduKYtrA4SgkehTg1NQ1bcBK+tg8voiYjK36vR+4Ezg1h6/9PrBiR0VDW39eJKyv+jG2FeESbHHZUtBZYX1VfVR/" +
            "Yd5N8cPaymeBS8lPcVrRcfLyN8f4pqxa1B8pKtqeAbdnwe0FV3FFNJ5K+B+twe6fJB370fj1wpLNqN5n0LRaYw4Uuya4qwi3CzFGvKp9oyZNSzp2h6PY8I7y" +
            "25ewQ9FDgXysfW1AcmNWENZX/U9YX7UQT6vD+qoFYf2cDQN5cMLaypexIvyLgXzfQqQ0PebPPC2ZYadGbeYrKmKXz3Zkv2JF2FfRt43f+q9vfP3TRdFByNPo" +
            "flSfUrsCibgqGlWNh5+7CLEalcmReFect3R/vtePOxyDio8V4NSUBgOsAjYmHWgRshFYmZrakFM/iXDlnMTsG8PayjeAy4FHk4ohaSru3XmiF5V9FfXK4iVG" +
            "ndf4Agj2ZwKIoq0q6eWbbxhbcIVXPfF8TWmzhy4B2aXgWYvKTGU0xFaVYhRRtVPEKt6FaRn5x0nH/rFk0QszcYohRkfOOGr1Yqqi4TfAHVj3KUd2HADuSFU0" +
            "JNX0IW+EtZUplLlAg9oloeRli29bcl3k1V/89DHVngbTREWlPeMV6TTsLGKvogLiI9G6MPjggaTPW2/5vYNvPgN6n1oHuvZK6M7nR+0HQNTOBR9vVL7++cVt" +
            "o5OO/Yiokk6niaKIdDpdkFsmtpx8UB1FQVZDRkbkMU91NXB10gEXCatBH006iHwR1lXu8m/ZcA0qH2CXKuVl6LHQrkOnLmv6A8+UXoqKj10a26naqj3rzfzI" +
            "UzFvGq/1jtevO7Hobl7/rbZCZ9alV6rnn6O2k1jmbIjtVfgRp1BVkfPE8y/FGskUDCJCU1MT11x1FcOHDy+8D1ZHoLS0tNDU1NRzr07HoCLrs1zeWD0R62h1" +
            "btJBFzjPAJdk43pV7Pg3bxgOsgBr2pEzR6QgKGHCCScSBDnXdd16+Zg+rVmtuPudcSXp0atFg/NibwpsowKxtlFdxdgDDhqv7ZrX5o8ouuy3MzMWhzPV8x8E" +
            "fodYdLtfNOLvNW73lBI1s59f4Per9mHcmDE5V8lcNljIFyKC7+d+AcCeffucohcgWV+MYkG5CdiWdNAFzDbgpqEgvgBR7fQWVGuxzl37k44nX5TXP+EF4ai5" +
            "osG5ghhpN9aIK507spV4KBpVL/xeOGJv0fskv7gweEFUFykc1FhrO08VdPpeDKiBcoN88+zF6eOTjr07vu8TxNaQhbrlQ3wdhUuvsoFURcMLwEIGp0FHf2kG" +
            "FsbHaMgQ1U1vIzL3YJdy9dkCc6DC7cuTRn8w4wLPlM4VPB9biCQdS4/iEuGOIixfJXo88g7e+frXJvVr+VmhIFHbA6K6AjvnL51zyCPkk6oiXzaef+O5dxzu" +
            "T0MRh2PQ0+vhuCjQHwGLsF2OHJYW4HYvkqLPePpCtPTMKKqt/C62AUc/s//OuVVuUdXdvX3Oacv2zfS07FbBG4OKauxuFZc4x6mvZP4JELPeeG0LN98wrtBv" +
            "RrLmhZvL2jwTLRGjD2VOTXcR7rZ5isxrNaVXfOH6d93Qp8PRA70W4HdOXmtUZSXWtGJQ3OH3kzZgGbBi+2lrhnTX7ai28iFrXalv92CdmcXWyQIxx1tkzPre" +
            "7M9py5pP96Nhy8R4n4p9KESUTulupgI6rnhGt0TSev2mG0f9X9LnIte8UFPSjOqNqP4CY7P+j7lVUoURRuS2A+MmXJx07A5HodKngpQdp6xpxS5N+heGtgi3" +
            "xcdgaaqioShMFvKNqat8HGtd+VrSsXRGVXdFUbQi28eftmxvhR+V3Yv6n1MwnRW3y5pf+7UPZqvx2q7dNH/UoJ2CeKnGT6E6T9FfqkK7ENut+9ywAuNUvLtm" +
            "LokuTDp2h6MQ6XMXk1RFQwtwO7Zt3lAcjm7BWkPeHh8LR4ypm/4c1jXr10nHAqCqe6Mo+uY727f9dzaPP+3O5nI/GnGXaDCjc9FVV+HNiC8BmLdU0le9Nn9k" +
            "wfT4zRfra/w3RM0VoM+1r9fu4kvZRZTVKJ80eHeftST6QtKxOxyFRr/aiMXCswTbNm9v0jszgDRji9EWO/E9MqZu+itANfDzpGJQ1RZjzM+iMLy46d1d3+GO" +
            "GUedXD7lnl3HeKasRtQ/N/aeoJs9kXSIsAYq0SYjbVe+etOIIWPRub4maBT0coQnMl0XVbqZqHR4WKLKZFVvyYy66KSkY3c4Col+9/FMVTS0RVryLawhw9b+" +
            "vl4RsB2Y5xtveaqfTRYGO6Zuesa68pGBfF9VPWiMWRdF4UUthw/N3jF3/BMtt52a1fx80HbMRR7BBR1+E+2CC12WvCKKedpI2z++dtPIZwdy/wqB9Qv9N8Fc" +
            "DvqAQqTtRwW6iHLGsUOYbkSuTTpuh6OQyGmFYnlj9Qzs3PBgNet4BliQqmgoiKHVYsGr2TgedKnajPioN33WiGMiJSVBL02LdL8x+nNjotWtrYef2X315EO9" +
            "jXXa0taXUP8U2qcyhVhaYsQDbVUxDxo5XLtp/rFDYs13T5y1ODzW4F2ryLUIH7Gh7HqB0aYNC7zx2bxuPow4hjLOiKMw6XcG3JlURcOLoBcD9wIfJr1zOeQA" +
            "1l7vEie+vcfUVe42qtdiPxfpbJ+XrfiqarMx0Q/T6XDWwQMf/u3OueMf74v42hfzPkMn20UrvvEwtEoAulMlXBAFB68b6uIL8NLCYL+vYa2IXgZs6v77bu0L" +
            "xyQdr8NRSOTlrmhy46UlgvwVMB+YnvRO9pOXgaWIPpaautYNOfcDufnl4aiZD9wIDO/pcZkM+GhWlKrapGrWRVG0puXggRf3Xv+pfp+fzy5tfUbUr+zi86wA" +
            "+iFinlQvvOfV+SNy0mJysDF9cXSyIteBzAJspttxhYkEfXTDAi+rimiXAecWlwEXJnk9KeVbqsvjzjnVwAlJ72wveR9YC6yMO0I5coB384YSVb4GfAM+OmQJ" +
            "RxdgVX1fjXksMtGaQ/v3b2yef1KYq/hOX3rgDE9Lrwb5Q4Ey0D3ARhXzqPEPPbnphuOKrrHCQHLWotZSE5ScDcxS5EzQCSB7gJ96Yr6zfoGf1aiBE+Dc4gS4" +
            "MMn7SZm46TLxAz0LmAv8JXBc0jt9FJqBdcBKPH0pNWXtkDbXyAs16z1BLsXWC3xkTrCkpJQJJ0z8iC+uqu40xvzYRNHapj3vvtp6y7TEeiM78osT4NziBLgw" +
            "GbCTMrmxukTgbKxJw58CE5Le+W78FvgZsEY9fX7HFDfcnG+kZsNfY+eFJ2V+pgrHjh7N2HHj2z+cqrrdGPNQFIXff3fLa5tZ/kV3cR7kOAHOLU6AC5MBPynl" +
            "Wy4LUJ0GzAL+HJgKlCa0/2ngDeAnwMMKr+yoaMi6SMiRA2o2fkngLhE5XUQYPmIEY8aOww8Co6pvGmN+GEXhg+9dOWHQ2Ts6HI6hTaJ3ReWN1ScCnwe+BJyD" +
            "7Tk6LM9v2wqksC5Nj6P8MnVKw84kj8NQp6z29VNLS0r/aVhZ2Tmlw8pG+76/yxjzRBSFP3jvyglvJB2fw+Fw5IOCGJYob/x7H7xJwGeBmcA0YAp2fnAkfV8u" +
            "ZYCD2DZ5b2Ermn+F9Sl+J1XRkLPiHYfD4XA4ekNBCHB3yhurR2LnBT+NHaKegs2OPwmMBY4FyoBMv9E0cBjbFL4ZW8G8HTu8vAV4Gyu4roLV4XA4HA6Hw+Fw" +
            "OBwOh8PhcDgGjP8HF7tXXL56rpkAAAAASUVORK5CYII=";

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
