# ============================================================================
#  setup-tools-hub.ps1 - Build & Install "Sailuo Dashboard" (GUI Desktop)
# ----------------------------------------------------------------------------
#  Compiles the native WinForms dashboard (C:\Sailuo\tools\SailuoDashboard.exe)
#  with the .NET Framework 4.x C# compiler bundled with Windows Server 2022/2025.
#  The dashboard opens automatically the first time the user signs in to the
#  RDP desktop and provides one-click control for:
#    1. Overview  - cloud save/restore status, workspace shortcuts, maintenance
#    2. Apps      - Chrome, Discord, VLC, 7-Zip, wallpaper, engine updates
#    3. System    - display tuning, auto-save repair, diagnostics
#
#  It also registers the "Sailuo Cloud Save" scheduled task (every 4 minutes)
#  and the dashboard auto-start entry.
# ============================================================================

$XyTag = 'Sailuo:dashboard'
. "$PSScriptRoot/lib-common.ps1"

$cfg = Get-Cfg
$u = if ($env:RDP_USER) { $env:RDP_USER.Trim() } else { $cfg.rdp_user }

$toolsDir = 'C:\Sailuo\tools'
New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null

# The dashboard starts cloud save/restore helpers from C:\Sailuo\scripts. The
# Actions checkout (D:\a\...) disappears when the session ends, so keep a
# durable copy next to the dashboard and refresh it on every setup run.
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

# Persist the session context so the dashboard and the scheduled task can run
# cloud save/restore without inheriting the setup process environment.
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
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

[assembly: System.Reflection.AssemblyTitle("Sailuo Dashboard")]
[assembly: System.Reflection.AssemblyProduct("Sailuo")]
[assembly: System.Reflection.AssemblyDescription("Sailuo control center for cloud save, applications and system tools.")]

namespace SailuoTools
{
    // ========================================================================
    //  Theme - single source of truth for colour
    // ========================================================================
    internal static class Theme
    {
        // Surfaces (darker to lighter)
        public static readonly Color Bg        = Color.FromArgb(11, 15, 20);   // window / page canvas
        public static readonly Color BgDeep    = Color.FromArgb(8, 11, 15);    // chrome (header, sidebar, activity)
        public static readonly Color SurfaceLo = Color.FromArgb(14, 21, 29);   // inset wells, subtle fills
        public static readonly Color Surface   = Color.FromArgb(18, 26, 35);   // cards, panels
        public static readonly Color SurfaceHi = Color.FromArgb(24, 34, 46);   // hover / raised

        // Lines
        public static readonly Color Border       = Color.FromArgb(34, 48, 65);
        public static readonly Color BorderStrong = Color.FromArgb(54, 74, 98);
        public static readonly Color ChromeLine   = Color.FromArgb(26, 37, 50);
        // Interactive boundaries (buttons, list/log wells) need 3:1 against the
        // surrounding surface (WCAG 1.4.11); decorative hairlines do not.
        public static readonly Color BorderControl = Color.FromArgb(92, 112, 134); // ~3.4:1 on Surface

        // Text.  Ratios measured against Surface (#121A23):
        //   Text       #E8EEF6 -> 14.6:1   TextSoft #A7B4C4 -> 7.9:1
        //   TextMuted  #7D8B9C -> 5.1:1    (still AA for small text)
        public static readonly Color Text      = Color.FromArgb(232, 238, 246);
        public static readonly Color TextSoft  = Color.FromArgb(167, 180, 196);
        public static readonly Color TextMuted = Color.FromArgb(125, 139, 156);

        // Accents.  All accents clear 4.5:1 on Surface and SurfaceLo.
        public static readonly Color Blue   = Color.FromArgb(90, 167, 255);
        public static readonly Color Green  = Color.FromArgb(74, 222, 128);
        public static readonly Color Violet = Color.FromArgb(167, 139, 250);
        public static readonly Color Amber  = Color.FromArgb(251, 191, 36);
        public static readonly Color Cyan   = Color.FromArgb(56, 189, 248);
        public static readonly Color Red    = Color.FromArgb(248, 113, 113);
        public static readonly Color Slate  = Color.FromArgb(148, 163, 184);

        // Text placed on top of a filled accent control.
        public static readonly Color OnAccent = Color.FromArgb(9, 13, 18);

        // Brand gradient for the logo mark. Dark enough that the white "S" keeps
        // contrast on both ends (4.1:1 / 7.9:1) instead of the old 2.14:1.
        public static readonly Color BrandFrom = Color.FromArgb(2, 132, 199);
        public static readonly Color BrandTo   = Color.FromArgb(67, 56, 202);

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

        // Corner radii (DIP)
        public const int RadiusSm = 8;
        public const int RadiusMd = 12;
        public const int RadiusLg = 16;

        // Control heights (DIP)
        public const int HeaderHeight   = 64;
        public const int PageHeader     = 76;
        public const int NavHeight      = 44;
        public const int CardHeight     = 92;
        public const int ButtonHeight   = 36;
        public const int ButtonHeightSm = 28;

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
                if (_textFamily == null) { _textFamily = Pick(new string[] { "Segoe UI Variable Text", "Segoe UI" }); }
                return _textFamily;
            }
        }

        private static string SemiFamily
        {
            get
            {
                if (_semiFamily == null) { _semiFamily = Pick(new string[] { "Segoe UI Semibold", "Segoe UI Variable Text", "Segoe UI" }); }
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

        public static Font Hero      { get { return Semi("hero", 21f, true); } }
        public static Font PageTitle { get { return Semi("pageTitle", 17.5f, true); } }
        public static Font Section   { get { return Semi("section", 11f, false); } }
        public static Font H1        { get { return Semi("h1", 12.5f, false); } }
        public static Font H2        { get { return Semi("h2", 10.5f, false); } }
        public static Font Brand     { get { return Semi("brand", 14.5f, true); } }
        public static Font BrandSub  { get { return Get("brandSub", TextFamily, 8.5f, FontStyle.Regular); } }
        public static Font Value     { get { return Semi("value", 16f, true); } }
        public static Font Body      { get { return Get("body", TextFamily, 9.5f, FontStyle.Regular); } }
        public static Font Small     { get { return Get("small", TextFamily, 8.5f, FontStyle.Regular); } }
        public static Font Micro     { get { return Semi("micro", 8f, false); } }
        public static Font Button    { get { return Semi("button", 9.5f, false); } }
        public static Font ButtonSm  { get { return Semi("buttonSm", 8.75f, false); } }
        public static Font Mono      { get { return Get("mono", MonoFamily, 8.75f, FontStyle.Regular); } }
        public static Font Glyph     { get { return Get("glyph", GlyphFamily(), 12f, FontStyle.Regular); } }
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
            if (control == null) { return; }
            if (control.IsHandleCreated) { ApplyDarkScroll(control.Handle); }
            else { control.HandleCreated += delegate { ApplyDarkScroll(control.Handle); }; }
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
        public LogoMark()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            Size = new Size(Ui.S(32), Ui.S(32));
            BackColor = Theme.BgDeep;
            TabStop = false;
            AccessibleRole = AccessibleRole.Graphic;
            AccessibleName = "Sailuo logo";
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics graphics = e.Graphics;
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle rect = new Rectangle(0, 0, Width - 1, Height - 1);
            using (LinearGradientBrush brush = new LinearGradientBrush(
                new Rectangle(0, 0, Math.Max(1, Width), Math.Max(1, Height)),
                Theme.BrandFrom, Theme.BrandTo, 45f))
            using (GraphicsPath path = Gfx.Round(rect, Ui.S(9)))
            {
                graphics.FillPath(brush, path);
            }
            using (Font font = new Font(UiFonts.Brand.FontFamily, 14f * Ui.FontScale, FontStyle.Bold))
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

        public Chip(string label, Color dotColor)
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.BgDeep;
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
            return Ui.S(12) + Ui.S(8) + Ui.S(8) + text.Width + Ui.S(14);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics graphics = e.Graphics;
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle rect = new Rectangle(0, 0, Width - 1, Height - 1);
            Gfx.FillRound(graphics, rect, Height / 2, Theme.SurfaceLo);
            Gfx.StrokeRound(graphics, rect, Height / 2, Theme.ChromeLine, 1f);
            using (SolidBrush dot = new SolidBrush(DotColor))
            {
                int size = Ui.S(7);
                graphics.FillEllipse(dot, Ui.S(11), (Height - size) / 2, size, size);
            }
            Gfx.Ellipsis(graphics, _label, UiFonts.Small,
                new Rectangle(Ui.S(12) + Ui.S(9), 0, Width - Ui.S(12) - Ui.S(9) - Ui.S(10), Height), Theme.TextSoft);
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
            using (SolidBrush track = new SolidBrush(Theme.SurfaceLo))
            {
                graphics.FillRectangle(track, 0, 0, Width, Height);
            }
            if (!_active) { return; }

            int segment = Ui.S(180);
            int x = Ui.AnimationsEnabled ? _offset : Math.Max(0, (Width - segment) / 4);
            Rectangle bar = new Rectangle(x, 0, segment, Height);
            using (LinearGradientBrush brush = new LinearGradientBrush(
                new Rectangle(bar.X - Ui.S(24), 0, segment + Ui.S(48), Math.Max(1, Height)),
                Gfx.Alpha(Theme.Blue, 0), Theme.Blue, LinearGradientMode.Horizontal))
            {
                graphics.FillRectangle(brush, bar);
            }
        }
    }

    internal enum ButtonVariant
    {
        Primary,
        Secondary,
        Ghost
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
            BackColor = Theme.BgDeep;
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
            int padding = Ui.S(_small ? 12 : 16);
            int glyphWidth = string.IsNullOrEmpty(_glyph) ? 0 : Ui.S(_small ? 18 : 22);
            Size text = TextRenderer.MeasureText(Text ?? string.Empty, Font);
            Width = Math.Max(Ui.S(_small ? 56 : 84), text.Width + padding * 2 + glyphWidth);
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
            if (e.Button == MouseButtons.Left) { _pressed = true; Invalidate(); }
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

            if (_variant == ButtonVariant.Primary)
            {
                face = Accent;
                if (_hover > 0.01f && Enabled) { face = Gfx.Mix(face, Color.White, 0.14f * _hover); }
                if (_pressed) { face = Gfx.Mix(face, Color.Black, 0.14f); }
                if (!Enabled) { face = Theme.SurfaceHi; }
                border = face;
                foreground = Enabled ? Theme.OnAccent : Theme.TextMuted;
            }
            else if (_variant == ButtonVariant.Secondary)
            {
                face = Theme.SurfaceLo;
                if (Enabled) { face = Gfx.Mix(face, Theme.SurfaceHi, _hover); }
                if (_pressed) { face = Gfx.Mix(face, Color.Black, 0.10f); }
                if (!Enabled) { face = Theme.SurfaceLo; }
                // 3:1 boundary so the control is identifiable at a glance (WCAG 1.4.11).
                border = Enabled ? Gfx.Mix(Theme.BorderControl, Theme.Text, 0.35f * _hover) : Theme.Border;
                foreground = Enabled ? Theme.Text : Theme.TextMuted;
            }
            else
            {
                face = Gfx.Mix(Theme.BgDeep, Theme.SurfaceHi, _hover);
                if (_pressed) { face = Gfx.Mix(face, Color.Black, 0.10f); }
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

            int glyphWidth = 0;
            Rectangle textRect = rect;
            if (!string.IsNullOrEmpty(_glyph) && string.IsNullOrEmpty(Text))
            {
                // Icon-only button: keep the glyph perfectly centred.
                int size = Ui.S(_small ? 16 : 18);
                Rectangle glyphOnly = new Rectangle((Width - size) / 2, (Height - size) / 2, size, size);
                Gfx.DrawGlyph(graphics, _glyph, UiFonts.Glyph, glyphOnly, foreground, Gfx.Center);
            }
            else
            {
                if (!string.IsNullOrEmpty(_glyph))
                {
                    glyphWidth = Ui.S(_small ? 18 : 22);
                    Rectangle glyphRect = new Rectangle(rect.X + Ui.S(_small ? 10 : 13), rect.Y, glyphWidth, rect.Height);
                    Gfx.DrawGlyph(graphics, _glyph, UiFonts.Glyph, glyphRect, foreground, Gfx.Center);
                    textRect = new Rectangle(rect.X + glyphWidth, rect.Y,
                        Math.Max(0, rect.Width - glyphWidth - Ui.S(_small ? 10 : 13)), rect.Height);
                }
                TextRenderer.DrawText(graphics, Text ?? string.Empty, Font, textRect, foreground, Gfx.Center);
            }
            if (Focused && Enabled) { Gfx.FocusRing(graphics, rect, radius, Theme.Blue); }
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
            BackColor = Theme.BgDeep;
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

            if (_selected || _hover > 0.01f)
            {
                Color background = _selected
                    ? Theme.Surface
                    : Gfx.Mix(Theme.BgDeep, Theme.Surface, _hover * 0.9f);
                Gfx.FillRound(graphics, rect, radius, background);
                if (!_selected && _hover > 0.01f)
                {
                    Gfx.StrokeRound(graphics, rect, radius, Gfx.Alpha(Theme.Border, (int)(90 * _hover)), 1f);
                }
            }
            if (_selected)
            {
                int barWidth = Ui.S(3);
                int barInset = Ui.S(10);
                Rectangle bar = new Rectangle(Ui.S(2), barInset, barWidth, Height - barInset * 2);
                Gfx.FillRound(graphics, bar, barWidth / 2 < 1 ? 1 : barWidth / 2, Theme.Blue);
            }

            Color foreground = _selected ? Theme.Text : Gfx.Mix(Theme.TextSoft, Theme.Text, _hover);
            Color glyphColor = _selected ? Theme.Blue : foreground;
            int glyphSize = Ui.S(20);
            Rectangle glyphRect = _rail
                ? new Rectangle((Width - glyphSize) / 2, (Height - glyphSize) / 2, glyphSize, glyphSize)
                : new Rectangle(Ui.S(18), (Height - glyphSize) / 2, glyphSize, glyphSize);
            Gfx.DrawGlyph(graphics, Glyph, UiFonts.Glyph, glyphRect, glyphColor, Gfx.Center);

            if (!_rail)
            {
                Rectangle textRect = new Rectangle(Ui.S(48), 0, Math.Max(0, Width - Ui.S(58)), Height);
                TextRenderer.DrawText(graphics, Caption, _selected ? UiFonts.H2 : UiFonts.Body, textRect, foreground,
                    TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix |
                    TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding);
            }

            if (Focused && Enabled) { Gfx.FocusRing(graphics, rect, radius, Theme.Blue); }
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

    /// <summary>Primary call-to-action card: icon tile, title, one-line summary, chevron.</summary>
    internal sealed class ActionCard : Control, IAnimatable
    {
        private float _hover;
        private float _target;
        private bool _pressed;

        public string CardTitle = string.Empty;
        public string CardDescription = string.Empty;
        public string Glyph = "\uE753";
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
            if (e.Button == MouseButtons.Left) { _pressed = true; Invalidate(); }
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
            int tileSize = Ui.S(42);

            bool enabled = Enabled;
            Color accent = enabled ? Accent : Theme.TextMuted;
            Color background = enabled ? Gfx.Mix(Theme.Surface, Theme.SurfaceHi, _hover) : Theme.SurfaceLo;
            if (_pressed) { background = Gfx.Mix(background, Color.Black, 0.16f); }
            Color border = enabled
                ? Gfx.Mix(Theme.Border, accent, 0.35f * _hover)
                : Theme.Border;

            Gfx.FillRound(graphics, rect, radius, background);
            Gfx.StrokeRound(graphics, rect, radius, border, 1f);

            // Accent rail on the left edge communicates the action family at a glance.
            if (enabled && _hover > 0.01f)
            {
                int barHeight = Height - Ui.S(28);
                Rectangle bar = new Rectangle(Ui.S(1), Ui.S(14), Math.Max(1, Ui.S(2)), barHeight);
                Gfx.FillRound(graphics, bar, 1, Gfx.Alpha(accent, (int)(210 * _hover)));
            }

            Rectangle tile = new Rectangle(pad, (Height - tileSize) / 2, tileSize, tileSize);
            Gfx.FillRound(graphics, tile, Ui.S(10), enabled
                ? Gfx.Mix(Theme.SurfaceLo, accent, 0.16f + 0.06f * _hover)
                : Gfx.Mix(Theme.SurfaceLo, Theme.TextMuted, 0.10f));
            Gfx.DrawGlyph(graphics, Glyph, UiFonts.GlyphLg, tile, accent, Gfx.Center);

            int textX = pad + tileSize + Ui.S(14);
            int chevronSpace = Ui.S(40);
            int textWidth = Math.Max(Ui.S(40), Width - textX - chevronSpace);
            int titleHeight = UiFonts.H2.Height;
            // Two lines maximum; GDI ellipsizes the last visible line cleanly.
            int descHeight = UiFonts.Body.Height * 2;
            int block = titleHeight + Ui.S(5) + descHeight;
            int top = Math.Max(Ui.S(12), (Height - block) / 2);

            Color titleColor = enabled ? Gfx.Mix(Theme.Text, accent, 0.10f * _hover) : Theme.TextMuted;
            TextRenderer.DrawText(graphics, CardTitle, UiFonts.H2,
                new Rectangle(textX, top, textWidth, titleHeight), titleColor,
                TextFormatFlags.Left | TextFormatFlags.Top | TextFormatFlags.NoPrefix |
                TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding);

            TextRenderer.DrawText(graphics, CardDescription, UiFonts.Body,
                new Rectangle(textX, top + titleHeight + Ui.S(5), textWidth, descHeight),
                enabled ? Theme.TextSoft : Theme.TextMuted,
                TextFormatFlags.Left | TextFormatFlags.Top | TextFormatFlags.WordBreak |
                TextFormatFlags.NoPrefix | TextFormatFlags.EndEllipsis);

            int chevronSize = Ui.S(20);
            int chevronShift = (int)(_hover * Ui.S(3));
            Rectangle chevron = new Rectangle(Width - Ui.S(20) - chevronSize + chevronShift,
                (Height - chevronSize) / 2, chevronSize, chevronSize);
            Gfx.DrawGlyph(graphics, "\uE76C", UiFonts.Glyph, chevron,
                enabled ? Gfx.Mix(Theme.TextMuted, accent, _hover) : Theme.TextMuted, Gfx.Center);

            if (Focused && enabled) { Gfx.FocusRing(graphics, rect, radius, Theme.Blue); }
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

            int width = Ui.S(500);
            int pad = Ui.S(Ui.Space5);
            int titleHeight = UiFonts.H1.Height + Ui.S(2);
            int messageWidth = width - pad * 2;
            int messageHeight = Gfx.TextHeight(message, UiFonts.Body, messageWidth,
                TextFormatFlags.Left | TextFormatFlags.WordBreak);
            int buttonHeight = Ui.S(Ui.ButtonHeight);
            int height = pad + titleHeight + Ui.S(Ui.Space2) + messageHeight + Ui.S(Ui.Space5) + buttonHeight + pad;
            ClientSize = new Size(width, height);

            Label titleLabel = new Label();
            titleLabel.Text = title;
            titleLabel.Font = UiFonts.H1;
            titleLabel.ForeColor = Theme.Text;
            titleLabel.AutoSize = false;
            titleLabel.BackColor = Theme.Surface;
            titleLabel.SetBounds(pad, pad, messageWidth, titleHeight);
            titleLabel.TextAlign = ContentAlignment.MiddleLeft;

            Label messageLabel = new Label();
            messageLabel.Text = message;
            messageLabel.Font = UiFonts.Body;
            messageLabel.ForeColor = Theme.TextSoft;
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
            _accept.Variant = ButtonVariant.Primary;
            _accept.Accent = accent;
            _accept.Font = UiFonts.Button;
            _accept.AccessibleName = acceptText;
            // DialogResult is what ShowDialog() returns - without it the accept
            // button used to close the dialog as Cancel and the action never ran.
            _accept.Click += delegate { Confirmed = true; DialogResult = DialogResult.OK; Close(); };

            int buttonY = height - pad - buttonHeight;
            _accept.SetBounds(width - pad - _accept.Width, buttonY, _accept.Width, buttonHeight);
            _cancel.SetBounds(_accept.Left - Ui.S(Ui.Space2) - _cancel.Width, buttonY, _cancel.Width, buttonHeight);

            Controls.Add(titleLabel);
            Controls.Add(messageLabel);
            Controls.Add(_cancel);
            Controls.Add(_accept);

            AcceptButton = _accept;
            CancelButton = _cancel;
            Shown += delegate { _accept.Focus(); };
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            Gfx.StrokeRound(e.Graphics, new Rectangle(0, 0, Width - 1, Height - 1), Ui.S(Ui.RadiusMd), Theme.BorderStrong, 1f);
            using (SolidBrush accent = new SolidBrush(Theme.Blue))
            {
                e.Graphics.FillRectangle(accent, 0, 0, Width, Ui.S(2));
            }
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
        public int ContentMaxWidth = 1440;
        public int SectionGap = 12;
        public int PagePadding = Ui.Space5;

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
            int padding = Ui.S(PagePadding);
            int available = ClientSize.Width - padding * 2 - scrollbar;
            if (available < Ui.S(220)) { available = Math.Max(Ui.S(180), ClientSize.Width - padding * 2); }
            int contentWidth = Math.Min(available, Ui.S(ContentMaxWidth));
            int left = padding + Math.Max(0, (available - contentWidth) / 2);
            int gap = Ui.S(SectionGap);
            int y = Ui.S(Ui.Space3);

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

        public int MeasureHeight(int width) { return Ui.S(24); }

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
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            int barHeight = Ui.S(13);
            Gfx.FillRound(graphics, new Rectangle(0, (Height - barHeight) / 2, Ui.S(3), barHeight), Ui.S(2), Accent);

            int left = Ui.S(12);
            int metaWidth = 0;
            if (!string.IsNullOrEmpty(Meta))
            {
                metaWidth = TextRenderer.MeasureText(Meta, UiFonts.Small).Width;
                Gfx.Ellipsis(graphics, Meta, UiFonts.Small,
                    new Rectangle(Width - metaWidth - Ui.S(2), 0, metaWidth + Ui.S(2), Height), Theme.TextMuted);
            }
            int titleWidth = Math.Max(0, Width - left - metaWidth - Ui.S(16));
            TextRenderer.DrawText(graphics, Title, UiFonts.Section,
                new Rectangle(left, 0, titleWidth, Height), Theme.Text,
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
        public int MinCardWidth = 300;
        public int MaxCardWidth = 460;

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
            int gap = Ui.S(Ui.Space4);
            int min = Ui.S(MinCardWidth);
            int columns = (width + gap) / (min + gap);
            if (columns < 1) { columns = 1; }
            if (columns > 4) { columns = 4; }
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
            int gap = Ui.S(Ui.Space4);
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
            int gap = Ui.S(Ui.Space4);
            int columns = ColumnsFor(width);
            int rows = (int)Math.Ceiling((double)_cards.Count / columns);
            int cardWidth = (width - (columns - 1) * gap) / columns;
            int maxWidth = Ui.S(MaxCardWidth);
            if (cardWidth > maxWidth) { cardWidth = maxWidth; }
            int totalWidth = columns * cardWidth + (columns - 1) * gap;
            int left = Math.Max(0, (width - totalWidth) / 2);
            int cardHeight = Ui.S(Ui.CardHeight);

            for (int index = 0; index < _cards.Count; index++)
            {
                int row = index / columns;
                int column = index % columns;
                _cards[index].SetBounds(left + column * (cardWidth + gap), row * (cardHeight + gap), cardWidth, cardHeight);
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
    /// Cloud-backup hero: state, freshness, backup scope and the two primary
    /// actions. Buttons sit beside the text when there is room and wrap below
    /// it when the window is narrow.
    /// </summary>
    internal sealed class HeroSection : Control, ISection
    {
        private readonly Label _caption;
        private readonly Label _state;
        private readonly Label _meta;
        private readonly Label _scope;
        private readonly Dot _dot;

        public readonly PillButton SaveButton;
        public readonly PillButton RestoreButton;

        public HeroSection()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.Bg;
            TabStop = false;
            AccessibleRole = AccessibleRole.Grouping;

            _caption = MakeLabel("CLOUD BACKUP", UiFonts.Micro, Theme.TextMuted);
            _state = MakeLabel("No snapshot yet", UiFonts.Hero, Theme.Text);
            _meta = MakeLabel(string.Empty, UiFonts.Body, Theme.TextSoft);
            _scope = MakeLabel(string.Empty, UiFonts.Small, Theme.TextMuted);

            _dot = new Dot();
            _dot.Size = new Size(Ui.S(8), Ui.S(8));
            _dot.BackColor = Theme.Surface;

            SaveButton = new PillButton();
            SaveButton.Text = "Save now";
            SaveButton.Variant = ButtonVariant.Primary;
            SaveButton.Accent = Theme.Green;
            SaveButton.AccessibleName = "Save session now";
            SaveButton.AccessibleDescription = "Creates a cloud checkpoint of this session (Ctrl+S).";

            RestoreButton = new PillButton();
            RestoreButton.Text = "Restore";
            RestoreButton.Variant = ButtonVariant.Secondary;
            RestoreButton.AccessibleName = "Restore from cloud";
            RestoreButton.AccessibleDescription = "Replaces this session with the latest snapshot (Ctrl+R).";

            Controls.Add(_caption);
            Controls.Add(_state);
            Controls.Add(_meta);
            Controls.Add(_scope);
            Controls.Add(_dot);
            Controls.Add(SaveButton);
            Controls.Add(RestoreButton);
        }

        private Label MakeLabel(string text, Font font, Color color)
        {
            Label label = new Label();
            label.Text = text;
            label.Font = font;
            label.ForeColor = color;
            label.BackColor = Theme.Surface;
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
            AccessibleName = "Cloud backup: " + (text ?? string.Empty);
            Invalidate();
        }

        public void SetMeta(string text) { _meta.Text = text ?? string.Empty; Invalidate(); }
        public void SetScope(string text) { _scope.Text = text ?? string.Empty; Invalidate(); }

        private bool Wide(int width) { return width >= Ui.S(700); }

        public int MeasureHeight(int width)
        {
            return Wide(width) ? Ui.S(118) : Ui.S(176);
        }

        protected override void OnLayout(LayoutEventArgs e)
        {
            base.OnLayout(e);
            int pad = Ui.S(Ui.Space5);
            int width = ClientSize.Width;
            int height = ClientSize.Height;
            int buttonHeight = Ui.S(Ui.ButtonHeight);
            int saveWidth = SaveButton.Width;
            int restoreWidth = RestoreButton.Width;
            int buttonsWidth = saveWidth + Ui.S(Ui.Space3) + restoreWidth;
            bool wide = Wide(width);

            int textWidth = wide
                ? Math.Max(Ui.S(160), width - pad * 2 - buttonsWidth - Ui.S(Ui.Space5))
                : Math.Max(Ui.S(120), width - pad * 2);

            _caption.SetBounds(pad, Ui.S(16), textWidth, Ui.S(13));
            _state.SetBounds(pad + Ui.S(14), Ui.S(32), Math.Max(Ui.S(60), textWidth - Ui.S(14)), Ui.S(30));
            _dot.SetBounds(pad, Ui.S(32) + (Ui.S(30) - _dot.Height) / 2, _dot.Width, _dot.Height);
            _meta.SetBounds(pad, Ui.S(64), textWidth, Ui.S(17));
            _scope.SetBounds(pad, Ui.S(86), textWidth, Ui.S(16));

            if (wide)
            {
                int buttonY = (height - buttonHeight) / 2;
                SaveButton.SetBounds(width - pad - buttonsWidth, buttonY, saveWidth, buttonHeight);
                RestoreButton.SetBounds(width - pad - restoreWidth, buttonY, restoreWidth, buttonHeight);
            }
            else
            {
                int buttonY = height - pad - buttonHeight;
                SaveButton.SetBounds(pad, buttonY, saveWidth, buttonHeight);
                RestoreButton.SetBounds(pad + saveWidth + Ui.S(Ui.Space3), buttonY, restoreWidth, buttonHeight);
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics graphics = e.Graphics;
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle rect = new Rectangle(0, 0, Width - 1, Height - 1);
            Gfx.FillRound(graphics, rect, Ui.S(Ui.RadiusLg), Theme.Surface);
            Gfx.StrokeRound(graphics, rect, Ui.S(Ui.RadiusLg), Theme.BorderStrong, 1f);
            // 1px inner highlight keeps the panel from looking flat on dark screens.
            using (Pen highlight = new Pen(Gfx.Alpha(Color.White, 10), 1f))
            using (GraphicsPath path = Gfx.Round(new Rectangle(1, 1, Width - 3, Height - 3), Ui.S(Ui.RadiusLg - 1)))
            {
                graphics.DrawPath(highlight, path);
            }
        }
    }

    /// <summary>Three responsive status tiles: storage, uptime and last snapshot.</summary>
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
            if (width >= Ui.S(760)) { return 3; }
            if (width >= Ui.S(440)) { return 2; }
            return 1;
        }

        public int MeasureHeight(int width)
        {
            int columns = Columns(width);
            int rows = (TileCount + columns - 1) / columns;
            int gap = Ui.S(Ui.Space4);
            return rows * Ui.S(88) + (rows - 1) * gap;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics graphics = e.Graphics;
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            int width = ClientSize.Width;
            int columns = Columns(width);
            int gap = Ui.S(Ui.Space4);
            int tileHeight = Ui.S(88);
            int tileWidth = (width - (columns - 1) * gap) / columns;

            for (int index = 0; index < TileCount; index++)
            {
                int row = index / columns;
                int column = index % columns;
                Rectangle tile = new Rectangle(column * (tileWidth + gap), row * (tileHeight + gap), tileWidth, tileHeight);
                if (tile.Width <= 0) { continue; }

                Gfx.FillRound(graphics, tile, Ui.S(Ui.RadiusMd), Theme.Surface);
                Gfx.StrokeRound(graphics, tile, Ui.S(Ui.RadiusMd), Theme.Border, 1f);

                int pad = Ui.S(Ui.Space4);
                TextRenderer.DrawText(graphics, _captions[index], UiFonts.Micro,
                    new Rectangle(tile.X + pad, tile.Y + Ui.S(10), tile.Width - pad * 2, Ui.S(14)),
                    Theme.TextMuted, TextFormatFlags.Left | TextFormatFlags.Top | TextFormatFlags.NoPrefix |
                    TextFormatFlags.EndEllipsis);

                TextRenderer.DrawText(graphics, _values[index], UiFonts.Value,
                    new Rectangle(tile.X + pad, tile.Y + Ui.S(26), tile.Width - pad * 2, Ui.S(26)),
                    Theme.Text, TextFormatFlags.Left | TextFormatFlags.Top | TextFormatFlags.NoPrefix |
                    TextFormatFlags.EndEllipsis);

                TextRenderer.DrawText(graphics, _metas[index], UiFonts.Small,
                    new Rectangle(tile.X + pad, tile.Y + Ui.S(53), tile.Width - pad * 2, Ui.S(16)),
                    Theme.TextSoft, TextFormatFlags.Left | TextFormatFlags.Top | TextFormatFlags.NoPrefix |
                    TextFormatFlags.EndEllipsis);

                if (_progress[index] >= 0f)
                {
                    int barY = tile.Y + tileHeight - Ui.S(12);
                    int barWidth = tile.Width - pad * 2;
                    Gfx.FillRound(graphics, new Rectangle(tile.X + pad, barY, barWidth, Ui.S(4)), Ui.S(2), Theme.SurfaceLo);
                    int filled = (int)Math.Round(barWidth * Math.Max(0f, Math.Min(1f, _progress[index])));
                    if (filled > 0)
                    {
                        Gfx.FillRound(graphics, new Rectangle(tile.X + pad, barY, filled, Ui.S(4)), Ui.S(2), _accents[index]);
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
            return Wide(width) ? Ui.S(286) : Ui.S(432);
        }

        protected override void OnLayout(LayoutEventArgs e)
        {
            base.OnLayout(e);
            int pad = Ui.S(Ui.Space4);
            int width = ClientSize.Width;
            int height = ClientSize.Height;
            int headerHeight = Ui.S(30);
            bool wide = Wide(width);

            int refreshWidth = _refresh.Width;
            int viewWidth = _viewLog.Width;
            int buttonsWidth = refreshWidth + Ui.S(Ui.Space2) + viewWidth;
            _refresh.SetBounds(width - pad - buttonsWidth, Ui.S(14), refreshWidth, _refresh.Height);
            _viewLog.SetBounds(width - pad - viewWidth, Ui.S(14), viewWidth, _viewLog.Height);

            _title.SetBounds(pad, Ui.S(14), Math.Max(Ui.S(120), width - pad * 2 - buttonsWidth - Ui.S(Ui.Space4)), headerHeight);
            _status.SetBounds(pad, Ui.S(44), Math.Max(Ui.S(80), width - pad * 2), Ui.S(18));

            int contentTop = Ui.S(68);
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
                int listHeight = Ui.S(150);
                RunsList.SetBounds(pad, contentTop, width - pad * 2, listHeight);
                int logTop = contentTop + listHeight + Ui.S(Ui.Space3);
                int logHeight = Math.Max(Ui.S(90), height - logTop - pad);
                LogView.SetBounds(pad, logTop, width - pad * 2, logHeight);
            }
            RunsList.ItemHeight = Math.Max(Ui.S(18), UiFonts.Small.Height + Ui.S(4));
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
            Gfx.StrokeRound(graphics, listWell, Ui.S(Ui.RadiusSm), Theme.BorderControl, 1f);
            Gfx.StrokeRound(graphics, logWell, Ui.S(Ui.RadiusSm), Theme.BorderControl, 1f);
        }

        private void DrawRunItem(object sender, DrawItemEventArgs e)
        {
            if (e.Index < 0) { return; }
            bool selected = (e.State & DrawItemState.Selected) == DrawItemState.Selected;
            Color background = selected ? Theme.SurfaceHi : Theme.SurfaceLo;
            using (SolidBrush brush = new SolidBrush(background))
            {
                e.Graphics.FillRectangle(brush, e.Bounds);
            }
            if (selected)
            {
                Gfx.FillRound(e.Graphics, new Rectangle(e.Bounds.X + Ui.S(2), e.Bounds.Y + Ui.S(3), Ui.S(2),
                    Math.Max(Ui.S(6), e.Bounds.Height - Ui.S(6))), 1, Theme.Blue);
            }
            string text = RunsList.Items[e.Index] as string;
            Gfx.Ellipsis(e.Graphics, text, UiFonts.Small,
                new Rectangle(e.Bounds.X + Ui.S(10), e.Bounds.Y, e.Bounds.Width - Ui.S(14), e.Bounds.Height),
                selected ? Theme.Text : Theme.TextSoft);
        }
    }

    /// <summary>
    /// Bottom activity panel: live status line, auto-save countdown and the
    /// scrollable activity log. The log band can be collapsed to give the page
    /// more room on short windows.
    /// </summary>
    internal sealed class ActivityFooter : Panel
    {
        public readonly RichTextBox Log;
        public readonly SlimProgress Progress;

        private readonly Dot _dot;
        private readonly Label _status;
        private readonly Label _detail;
        private readonly Label _countdown;
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
            BackColor = Theme.BgDeep;
            Padding = new Padding(0);

            _dot = new Dot();
            _dot.Size = new Size(Ui.S(8), Ui.S(8));
            _dot.BackColor = Theme.BgDeep;

            _status = new Label();
            _status.Text = "Ready";
            _status.Font = UiFonts.H2;
            _status.ForeColor = Theme.Text;
            _status.BackColor = Theme.BgDeep;
            _status.AutoSize = false;
            _status.AutoEllipsis = true;

            _detail = new Label();
            _detail.Text = string.Empty;
            _detail.Font = UiFonts.Small;
            _detail.ForeColor = Theme.TextMuted;
            _detail.BackColor = Theme.BgDeep;
            _detail.AutoSize = false;
            _detail.AutoEllipsis = true;

            _countdown = new Label();
            _countdown.Text = "Auto-save in --:--";
            _countdown.Font = UiFonts.Small;
            _countdown.ForeColor = Theme.TextSoft;
            _countdown.BackColor = Theme.BgDeep;
            _countdown.AutoSize = false;
            _countdown.TextAlign = ContentAlignment.MiddleRight;

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
            _logCaption.Text = "ACTIVITY";
            _logCaption.Font = UiFonts.Micro;
            _logCaption.ForeColor = Theme.TextMuted;
            _logCaption.BackColor = Theme.BgDeep;
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
            Log.BackColor = Theme.BgDeep;
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
            Controls.Add(_countdown);
            Controls.Add(_toggle);
            Controls.Add(_logCaption);
            Controls.Add(_copy);
            Controls.Add(_clear);
            Controls.Add(Log);
            Controls.Add(Progress);
        }

        public bool Collapsed { get { return _collapsed; } }
        public int StatusBandHeight { get { return Ui.S(52); } }
        public int LogBandHeight { get { return Ui.S(26) + _logBoxHeight + Ui.S(8); } }
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

        public void SetCountdown(string text)
        {
            _countdown.Text = text ?? string.Empty;
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
        }        protected override void OnLayout(LayoutEventArgs e)
        {
            base.OnLayout(e);
            int width = ClientSize.Width;
            int statusBand = StatusBandHeight;
            int left = Ui.S(Ui.Space5);

            int toggleSize = Ui.S(28);
            _toggle.SetBounds(width - left - toggleSize, (statusBand - toggleSize) / 2, toggleSize, toggleSize);

            // Measure against the longest countdown string so the label never clips.
            Size countdownSize = TextRenderer.MeasureText("Auto-save in 00:00", _countdown.Font);
            int countdownWidth = Math.Max(Ui.S(96), countdownSize.Width + Ui.S(4));
            int countdownRight = _toggle.Left - Ui.S(Ui.Space2);
            _countdown.SetBounds(Math.Max(left, countdownRight - countdownWidth), Ui.S(8), countdownWidth, Ui.S(20));
            Progress.SetBounds(0, statusBand - Progress.Height, width, Progress.Height);

            int statusLeft = left + Ui.S(16);
            int statusWidth = Math.Max(Ui.S(80), _countdown.Left - statusLeft - Ui.S(Ui.Space4));
            _dot.SetBounds(left, statusBand / 2 - _dot.Height / 2, _dot.Width, _dot.Height);
            _status.SetBounds(statusLeft, Ui.S(8), statusWidth, Ui.S(20));
            _detail.SetBounds(statusLeft, Ui.S(29), Math.Max(Ui.S(80), statusWidth + Ui.S(0)), Ui.S(16));
            _detail.Visible = width > Ui.S(760);

            if (!_collapsed)
            {
                int logTop = statusBand;
                int captionHeight = Ui.S(26);
                _logCaption.SetBounds(left, logTop, Ui.S(120), captionHeight);

                int clearWidth = _clear.Width;
                int copyWidth = _copy.Width;
                _clear.SetBounds(width - left - clearWidth, logTop + (captionHeight - _clear.Height) / 2, clearWidth, _clear.Height);
                _copy.SetBounds(_clear.Left - Ui.S(Ui.Space1) - copyWidth, logTop + (captionHeight - _copy.Height) / 2, copyWidth, _copy.Height);

                Log.SetBounds(left, logTop + captionHeight, Math.Max(Ui.S(120), width - left * 2),
                    Math.Max(Ui.S(40), ClientSize.Height - logTop - captionHeight - Ui.S(8)));
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            using (Pen pen = new Pen(Theme.ChromeLine))
            {
                e.Graphics.DrawLine(pen, 0, 0, Width, 0);
            }
        }
    }

    /// <summary>Page title block that keeps the same content column as PageView.</summary>
    internal sealed class PageHeader : Panel
    {
        private readonly Label _title;
        private readonly Label _subtitle;

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

            _subtitle = new Label();
            _subtitle.Text = string.Empty;
            _subtitle.Font = UiFonts.Body;
            _subtitle.ForeColor = Theme.TextMuted;
            _subtitle.BackColor = Theme.Bg;
            _subtitle.AutoSize = false;
            _subtitle.AutoEllipsis = true;

            Controls.Add(_title);
            Controls.Add(_subtitle);
        }

        public void SetPage(string title, string subtitle)
        {
            _title.Text = title ?? string.Empty;
            _subtitle.Text = subtitle ?? string.Empty;
            AccessibleName = _title.Text;
            AccessibleDescription = _subtitle.Text;
            Invalidate();
        }

        protected override void OnLayout(LayoutEventArgs e)
        {
            base.OnLayout(e);
            int left;
            int width;
            PageMetrics.ContentBounds(ClientSize.Width, UiConstants.PagePadding, UiConstants.ContentMaxWidth, out left, out width);
            _title.SetBounds(left, Ui.S(8), width, Ui.S(30));
            _subtitle.SetBounds(left, Ui.S(40), width, Ui.S(18));
        }
    }

    /// <summary>Shared horizontal metrics so the header, page and footer line up.</summary>
    internal static class PageMetrics
    {
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
        public const int PagePadding = Ui.Space5;
        public const int ContentMaxWidth = 1440;
        public const int SidebarWidth = 232;
        public const int SidebarRailWidth = 76;
    }

    /// <summary>
    /// Left navigation. Expands to a labelled sidebar on wide windows and
    /// collapses to an icon rail on narrow ones; the last-save summary is only
    /// shown when the labels fit.
    /// </summary>
    internal sealed class SidebarPanel : Panel
    {
        public readonly NavItem[] Items = new NavItem[3];

        private readonly SurfacePanel _saveCard;
        private readonly Label _saveCaption;
        private readonly Label _saveValue;
        private readonly Label _saveMeta;
        private readonly Label _version;
        private bool _rail;

        public event EventHandler PageSelected;

        public SidebarPanel()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.BgDeep;

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

            _saveCard = new SurfacePanel();
            _saveCard.SurfaceColor = Theme.SurfaceLo;
            _saveCard.BorderColor = Theme.ChromeLine;
            _saveCard.Radius = Ui.RadiusMd;
            _saveCard.BackColor = Theme.BgDeep;

            _saveCaption = MakeCardLabel("LAST CLOUD SAVE", UiFonts.Micro, Theme.TextMuted);
            _saveValue = MakeCardLabel("--:--", UiFonts.Value, Theme.Text);
            _saveMeta = MakeCardLabel("No snapshot yet", UiFonts.Small, Theme.TextMuted);
            _saveCard.Controls.Add(_saveCaption);
            _saveCard.Controls.Add(_saveValue);
            _saveCard.Controls.Add(_saveMeta);
            Controls.Add(_saveCard);

            _version = new Label();
            _version.Text = "Dashboard 2.0";
            _version.Font = UiFonts.Small;
            _version.ForeColor = Theme.TextMuted;
            _version.BackColor = Theme.BgDeep;
            _version.AutoSize = false;
            _version.TextAlign = ContentAlignment.MiddleLeft;
            Controls.Add(_version);

            UpdateMode();
        }

        private Label MakeCardLabel(string text, Font font, Color color)
        {
            Label label = new Label();
            label.Text = text;
            label.Font = font;
            label.ForeColor = color;
            label.BackColor = Theme.SurfaceLo;
            label.AutoSize = false;
            label.AutoEllipsis = true;
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

        public void SetLastSave(string value, string meta)
        {
            _saveValue.Text = value ?? string.Empty;
            _saveMeta.Text = meta ?? string.Empty;
            _saveCaption.AccessibleName = "Last cloud save " + (value ?? string.Empty) + ", " + (meta ?? string.Empty);
        }

        public bool Rail { get { return _rail; } }

        private void UpdateMode()
        {
            if (_saveCard == null || _version == null) { return; }
            _rail = Width < Ui.S(160);
            foreach (NavItem item in Items)
            {
                item.Rail = _rail;
                item.Height = Ui.S(_rail ? 48 : Ui.NavHeight);
            }
            _saveCard.Visible = !_rail;
            _version.Visible = !_rail;
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
            if (_saveCard == null || _version == null) { return; }
            int padding = Ui.S(Ui.Space3);
            int width = ClientSize.Width;
            int height = ClientSize.Height;

            int itemWidth = _rail ? Math.Max(Ui.S(40), Math.Min(Ui.S(56), width - padding)) : Math.Max(Ui.S(120), width - padding * 2);
            int itemLeft = _rail ? (width - itemWidth) / 2 : padding;
            int y = Ui.S(Ui.Space4);
            int gap = Ui.S(_rail ? Ui.Space2 : 6);
            foreach (NavItem item in Items)
            {
                item.SetBounds(itemLeft, y, itemWidth, item.Height);
                y += item.Height + gap;
            }

            if (!_rail)
            {
                int cardHeight = Ui.S(112);
                int versionHeight = Ui.S(18);
                int cardBottom = height - padding - versionHeight - Ui.S(Ui.Space2);
                _saveCard.SetBounds(padding, cardBottom - cardHeight, Math.Max(Ui.S(80), width - padding * 2), cardHeight);
                int innerPad = Ui.S(Ui.Space3);
                _saveCaption.SetBounds(innerPad, Ui.S(12), _saveCard.Width - innerPad * 2, Ui.S(13));
                _saveValue.SetBounds(innerPad, Ui.S(28), _saveCard.Width - innerPad * 2, Ui.S(26));
                _saveMeta.SetBounds(innerPad, Ui.S(58), _saveCard.Width - innerPad * 2, Ui.S(16));
                _version.SetBounds(padding, height - padding - versionHeight, Math.Max(Ui.S(80), width - padding * 2), versionHeight);
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            using (Pen pen = new Pen(Theme.ChromeLine))
            {
                e.Graphics.DrawLine(pen, Width - 1, 0, Width - 1, Height);
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

    /// <summary>Top application chrome: brand on the left, live status chips on the right.</summary>
    internal sealed class AppHeader : Panel
    {
        private readonly LogoMark _logo;
        private readonly Label _brand;
        private readonly Label _brandSub;
        private readonly Chip _cloud;
        private readonly Chip _user;
        private bool _showUser = true;

        public AppHeader()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.BgDeep;
            Margin = new Padding(0);

            _logo = new LogoMark();
            _logo.BackColor = Theme.BgDeep;

            _brand = new Label();
            _brand.Text = "Sailuo";
            _brand.Font = UiFonts.Brand;
            _brand.ForeColor = Theme.Text;
            _brand.BackColor = Theme.BgDeep;
            _brand.AutoSize = false;
            _brand.UseMnemonic = false;

            _brandSub = new Label();
            _brandSub.Text = "Control Center";
            _brandSub.Font = UiFonts.BrandSub;
            _brandSub.ForeColor = Theme.TextMuted;
            _brandSub.BackColor = Theme.BgDeep;
            _brandSub.AutoSize = false;
            _brandSub.UseMnemonic = false;

            _cloud = new Chip("Cloud idle", Theme.Amber);
            _cloud.BackColor = Theme.BgDeep;

            _user = new Chip("User: " + Environment.UserName, Theme.Slate);
            _user.BackColor = Theme.BgDeep;

            Controls.Add(_logo);
            Controls.Add(_brand);
            Controls.Add(_brandSub);
            Controls.Add(_cloud);
            Controls.Add(_user);
        }

        public void SetCloud(string text, Color color)
        {
            _cloud.SetLabel(text);
            _cloud.DotColor = color;
            _cloud.Invalidate();
            PerformLayout();
        }

        public void SetUser(string name)
        {
            _user.SetLabel("User: " + name);
            _user.AccessibleDescription = "Signed in as " + name;
            PerformLayout();
        }

        public void SetCompact(bool compact) { _showUser = !compact; PerformLayout(); }

        protected override void OnLayout(LayoutEventArgs e)
        {
            base.OnLayout(e);
            int pad = Ui.S(Ui.Space5);
            int width = ClientSize.Width;
            int height = ClientSize.Height;

            int logoSize = Ui.S(32);
            _logo.SetBounds(pad, (height - logoSize) / 2, logoSize, logoSize);

            int brandLeft = pad + logoSize + Ui.S(Ui.Space3);
            int brandHeight = UiFonts.Brand.Height;
            int subHeight = UiFonts.BrandSub.Height;
            int blockHeight = brandHeight + subHeight;
            int brandTop = (height - blockHeight) / 2 + Ui.S(1);
            int brandWidth = Math.Max(Ui.S(60), TextRenderer.MeasureText("Sailuo", UiFonts.Brand).Width + Ui.S(4));
            _brand.SetBounds(brandLeft, brandTop, brandWidth, brandHeight);
            _brandSub.SetBounds(brandLeft, brandTop + brandHeight, Math.Max(Ui.S(80), width / 3), subHeight);

            int gap = Ui.S(Ui.Space2);
            int right = width - pad;
            _user.Visible = _showUser;
            if (_showUser)
            {
                _user.SetBounds(right - _user.Width, (height - _user.Height) / 2, _user.Width, _user.Height);
                right = _user.Left - gap;
            }
            _cloud.SetBounds(right - _cloud.Width, (height - _cloud.Height) / 2, _cloud.Width, _cloud.Height);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            using (Pen pen = new Pen(Theme.ChromeLine))
            {
                e.Graphics.DrawLine(pen, 0, Height - 1, Width, Height - 1);
            }
        }
    }

    // ========================================================================
    //  MainForm
    // ========================================================================
    public class MainForm : Form
    {
        private const int AutoSaveMinutes = 4;
        private const string CloudStatusPath = @"C:\Persist\System\last-cloud-save.json";
        private const string SyncLockPath = @"C:\Persist\System\sync.lock";

        // Chrome
        private TableLayoutPanel _root;
        private TableLayoutPanel _body;
        private TableLayoutPanel _content;
        private AppHeader _header;
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
        private DateTime _lastSaveUtc = DateTime.MinValue;
        private DateTime _lastCheckUtc = DateTime.MinValue;
        private DateTime _nextCheckUtc;
        private int _lastSaveFiles;
        private double _lastSaveMb;
        private bool _running;
        private bool _syncBusy;
        private bool _backgroundStatus;
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

            RefreshCloudStatus(false);
            RefreshSystemInfo();
            SetStatus("Ready", Theme.Green, "Choose an action below to get started.");
            AppendLog("Dashboard started. Sign-in data is backed up automatically every " + AutoSaveMinutes + " minutes.", LogKind.Muted);

            KeyDown += OnFormKeyDown;
            _nextCheckUtc = DateTime.UtcNow.AddSeconds(15);
            _clock = new System.Windows.Forms.Timer();
            _clock.Interval = 1000;
            _clock.Tick += OnClock;
            _clock.Start();
            UpdateCountdown();

            ShowPage(_initialPage, false);
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            _loadedShown = true;
            ThreadPool.QueueUserWorkItem(delegate { EnsureSyncTask(); });
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

            int width = Math.Min(Ui.S(1120), Math.Max(Ui.S(860), work.Width - Ui.S(100)));
            int height = Math.Min(Ui.S(760), Math.Max(Ui.S(560), work.Height - Ui.S(40)));
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
            _root.ColumnCount = 1;
            _root.RowCount = 3;
            _root.BackColor = Theme.Bg;
            _root.Margin = new Padding(0);
            _root.Padding = new Padding(0);
            _root.RowStyles.Add(new RowStyle(SizeType.Absolute, Ui.S(Ui.HeaderHeight)));
            _root.RowStyles.Add(new RowStyle(SizeType.Percent, 100f));
            _root.RowStyles.Add(new RowStyle(SizeType.Absolute, Ui.S(160)));
            Controls.Add(_root);

            _header = new AppHeader();
            _header.Dock = DockStyle.Fill;
            _root.Controls.Add(_header, 0, 0);

            _body = new TableLayoutPanel();
            _body.Dock = DockStyle.Fill;
            _body.ColumnCount = 2;
            _body.RowCount = 1;
            _body.BackColor = Theme.Bg;
            _body.Margin = new Padding(0);
            _body.Padding = new Padding(0);
            _body.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, Ui.S(UiConstants.SidebarWidth)));
            _body.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
            _root.Controls.Add(_body, 0, 1);

            _sidebar = new SidebarPanel();
            _sidebar.Dock = DockStyle.Fill;
            _sidebar.PageSelected += delegate(object sender, EventArgs e)
            {
                PageEventArgs args = e as PageEventArgs;
                if (args != null) { ShowPage(args.Index, false); }
            };
            _body.Controls.Add(_sidebar, 0, 0);

            _content = new TableLayoutPanel();
            _content.Dock = DockStyle.Fill;
            _content.ColumnCount = 1;
            _content.RowCount = 2;
            _content.BackColor = Theme.Bg;
            _content.Margin = new Padding(0);
            _content.Padding = new Padding(0);
            _content.RowStyles.Add(new RowStyle(SizeType.Absolute, Ui.S(Ui.PageHeader)));
            _content.RowStyles.Add(new RowStyle(SizeType.Percent, 100f));
            _body.Controls.Add(_content, 1, 0);

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
            _root.Controls.Add(_footer, 0, 2);

            _tips.SetToolTip(_hero.SaveButton, "Create a cloud checkpoint now (Ctrl+S)");
            _tips.SetToolTip(_hero.RestoreButton, "Replace this session with the latest snapshot (Ctrl+R)");
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
            _hero.SetScope("Browsers \u00B7 Desktop \u00B7 Documents \u00B7 Downloads \u00B7 C:\\Persist");
            _hero.SaveButton.Click += delegate { StartCheckpoint(true); };
            _hero.RestoreButton.Click += delegate { ConfirmRestore(); };
            page.Controls.Add(_hero);

            _stats = new StatStrip();
            _stats.SetTile(0, "STORAGE", "-- GB free", "Checking the C: drive...", -1f);
            _stats.SetTile(1, "SYSTEM UPTIME", "--", "Waiting for the session clock", -1f);
            _stats.SetTile(2, "LAST SNAPSHOT", "--:--", "No snapshot yet", -1f);
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

            CardGroup quick = new CardGroup("Quick actions", "Everyday shortcuts", Theme.Blue);
            quick.AddCard(Card("Open permanent folder", "Persistent files included in every cloud backup.",
                "\uE8B7", Theme.Blue, delegate
                {
                    Directory.CreateDirectory(@"C:\Persist");
                    Process.Start("explorer.exe", @"C:\Persist");
                    AppendLog("Opened C:\\Persist.", LogKind.Info);
                }));
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
                        "Clear now", Theme.Amber, CleanTemporaryFiles);
                }));
            quick.AddCard(Card("Open Downloads", "Open the Downloads folder included in your backup.",
                "\uE838", Theme.Cyan, delegate
                {
                    string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
                    Directory.CreateDirectory(path);
                    Process.Start("explorer.exe", path);
                    AppendLog("Opened the Downloads folder.", LogKind.Info);
                }));
            page.Controls.Add(quick);
            page.Controls.Add(_github);

            return page;
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
                "\uE774", Theme.Blue, delegate
                {
                    RunTask("Installing Google Chrome...", @"
                        & winget install --id Google.Chrome --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
                        Write-Host 'Google Chrome is ready to use.'
                    ");
                }));
            essentials.AddCard(Card("Discord, VLC and 7-Zip", "Communication, media playback and archive tools in one step.",
                "\uE714", Theme.Violet, delegate
                {
                    RunTask("Installing Discord, VLC and 7-Zip...", @"
                        & winget install --id Discord.Discord --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
                        & winget install --id VideoLAN.VLC --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
                        & winget install --id 7zip.7zip --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
                        Write-Host 'Discord, VLC and 7-Zip are ready to use.'
                    ");
                }));
            page.Controls.Add(essentials);

            CardGroup personalize = new CardGroup("Personalization", "Look and feel", Theme.Cyan);
            personalize.AddCard(Card("Change desktop wallpaper", "Pick an image; it is applied now and restored with your next session.",
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

            CardGroup automation = new CardGroup("Automation", "Scheduling and sync", Theme.Green);
            automation.AddCard(Card("Repair auto-save schedule", "Re-register the 4-minute cloud save task if it is missing or disabled.",
                "\uE90F", Theme.Green, delegate
                {
                    RunTask("Repairing the auto-save schedule...", @"
                        & 'C:\Sailuo\scripts\install-state-sync.ps1'
                    ", delegate { ThreadPool.QueueUserWorkItem(delegate { EnsureSyncTask(); }); });
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
            ActionCard card = new ActionCard();
            card.CardTitle = title;
            card.CardDescription = description;
            card.Glyph = glyph;
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

            bool rail = width < Ui.S(1040);
            int sidebarWidth = Ui.S(rail ? UiConstants.SidebarRailWidth : UiConstants.SidebarWidth);
            _body.ColumnStyles[0].Width = sidebarWidth;
            _appliedSidebarWidth = sidebarWidth;

            int pageHeaderHeight = Ui.S(Ui.PageHeader);
            if (pageHeaderHeight != _appliedPageHeaderHeight)
            {
                _content.RowStyles[0].Height = pageHeaderHeight;
                _appliedPageHeaderHeight = pageHeaderHeight;
            }

            // On short windows the activity log starts collapsed so the actions
            // stay above the fold; the reader can expand it at any time.
            if (!_autoCollapseDone)
            {
                _autoCollapseDone = true;
                if (height < Ui.S(690) && !_footer.Collapsed) { _footer.SetCollapsed(true); }
            }

            int logLines = height >= Ui.S(880) ? 8 : (height >= Ui.S(720) ? 6 : 4);
            if (height < Ui.S(640)) { logLines = 3; }
            int logBoxHeight = logLines * (UiFonts.Mono.Height + Ui.S(2)) + Ui.S(6);
            _footer.LogBoxHeight = logBoxHeight;
            int footerHeight = _footer.PreferredHeight;
            int footerCap = Math.Max(Ui.S(120), height / 3);
            if (footerHeight > footerCap) { footerHeight = footerCap; }
            if (footerHeight != _appliedFooterHeight)
            {
                _root.RowStyles[2].Height = footerHeight;
                _appliedFooterHeight = footerHeight;
            }

            _header.SetCompact(width < Ui.S(820));
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
                _pageHeader.SetPage("Overview", "Cloud backup, workspace shortcuts and quick maintenance.");
            }
            else if (index == 1)
            {
                _pageHeader.SetPage("Applications", "Install the essentials, refresh the wallpaper or update the engine.");
            }
            else
            {
                _pageHeader.SetPage("System", "Display tuning, scheduling repair and diagnostics.");
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
            else if (e.Control && e.KeyCode == Keys.S) { StartCheckpoint(true); e.SuppressKeyPress = true; }
            else if (e.Control && e.KeyCode == Keys.R) { ConfirmRestore(); e.SuppressKeyPress = true; }
            else if (e.Control && e.KeyCode == Keys.D1) { ShowPage(0, true); e.SuppressKeyPress = true; }
            else if (e.Control && e.KeyCode == Keys.D2) { ShowPage(1, true); e.SuppressKeyPress = true; }
            else if (e.Control && e.KeyCode == Keys.D3) { ShowPage(2, true); e.SuppressKeyPress = true; }
            else if (e.KeyCode == Keys.F5) { RefreshCloudStatus(true); RefreshSystemInfo(); if (_currentPage == 0) { LoadGitHubRunsOnce(); } e.SuppressKeyPress = true; }
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
            _hero.SaveButton.Enabled = !busy;
            _footer.Progress.Visible = busy;
            _footer.Progress.Active = busy;
        }

        // ------------------------------------------------------------------
        //  Clock / cloud status
        // ------------------------------------------------------------------
        private void OnClock(object sender, EventArgs e)
        {
            _ticks++;
            bool wasBusy = _syncBusy;
            _syncBusy = SyncInProgress();
            UpdateCountdown();
            if (_syncBusy != wasBusy || _ticks % 15 == 0) { RefreshCloudStatus(false); }
            if (_ticks % 30 == 0) { RefreshSystemInfo(); }

            if (_syncBusy != wasBusy && !_running)
            {
                if (_syncBusy)
                {
                    SetStatus("Saving", Theme.Blue, "A background cloud save is in progress.");
                    _backgroundStatus = true;
                }
                else if (_backgroundStatus)
                {
                    _backgroundStatus = false;
                    SetStatus("Ready", Theme.Green, "Choose an action below to get started.");
                }
            }

            if (!_running && !_syncBusy && DateTime.UtcNow >= _nextCheckUtc)
            {
                _nextCheckUtc = DateTime.UtcNow.AddSeconds(30);
                DateTime freshUtc = _lastSaveUtc > _lastCheckUtc ? _lastSaveUtc : _lastCheckUtc;
                bool stale = freshUtc == DateTime.MinValue ||
                             (DateTime.UtcNow - freshUtc).TotalMinutes >= (AutoSaveMinutes + 1.5);
                if (stale) { StartCheckpoint(false); }
            }
        }

        private bool SyncInProgress()
        {
            try
            {
                if (!File.Exists(SyncLockPath)) { return false; }
                string raw = File.ReadAllText(SyncLockPath);

                Match started = Regex.Match(raw, "\"started_utc\"\\s*:\\s*\"([^\"]+)\"");
                DateTime startedUtc;
                if (started.Success && DateTime.TryParse(started.Groups[1].Value, CultureInfo.InvariantCulture,
                        DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out startedUtc))
                {
                    if ((DateTime.UtcNow - startedUtc).TotalMinutes > 10) { return false; }
                }

                Match pidMatch = Regex.Match(raw, "\"pid\"\\s*:\\s*(\\d+)");
                if (pidMatch.Success)
                {
                    int pid;
                    if (int.TryParse(pidMatch.Groups[1].Value, out pid))
                    {
                        try
                        {
                            using (Process process = Process.GetProcessById(pid)) { return !process.HasExited; }
                        }
                        catch { return false; }
                    }
                }
                return true;
            }
            catch { return false; }
        }

        private void UpdateCountdown()
        {
            if (_running)
            {
                _footer.SetCountdown("Working...");
                return;
            }
            if (_syncBusy)
            {
                _footer.SetCountdown("Saving session...");
                return;
            }
            DateTime freshUtc = _lastSaveUtc > _lastCheckUtc ? _lastSaveUtc : _lastCheckUtc;
            if (freshUtc == DateTime.MinValue)
            {
                _footer.SetCountdown("Auto-save pending");
                return;
            }
            TimeSpan left = freshUtc.AddMinutes(AutoSaveMinutes) - DateTime.UtcNow;
            if (left < TimeSpan.Zero) { left = TimeSpan.Zero; }
            _footer.SetCountdown(left.TotalSeconds < 1
                ? "Auto-save due"
                : string.Format("Auto-save in {0:00}:{1:00}", (int)left.TotalMinutes, left.Seconds));
        }

        private void RefreshCloudStatus(bool announce)
        {
            if (!File.Exists(CloudStatusPath))
            {
                _lastSaveUtc = DateTime.MinValue;
                _lastCheckUtc = DateTime.MinValue;
                _sidebar.SetLastSave("--:--", "No snapshot yet");
                _hero.SetState("No snapshot yet", Theme.Amber);
                _hero.SetMeta("Save once to create the first cloud snapshot for this account.");
                _stats.SetTile(2, "LAST SNAPSHOT", "--:--", "No snapshot yet", -1f);
                _header.SetCloud("Cloud idle", Theme.Amber);
                return;
            }

            try
            {
                string json = File.ReadAllText(CloudStatusPath);
                Match mTime = Regex.Match(json, "\"last_saved_utc\"\\s*:\\s*\"([^\"]+)\"");
                Match mCheck = Regex.Match(json, "\"last_check_utc\"\\s*:\\s*\"([^\"]+)\"");
                Match mCount = Regex.Match(json, "\"file_count\"\\s*:\\s*(\\d+)");
                Match mSize = Regex.Match(json, "\"size_mb\"\\s*:\\s*([0-9.]+)");

                DateTime saved;
                if (mTime.Success && DateTime.TryParse(mTime.Groups[1].Value, CultureInfo.InvariantCulture,
                        DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out saved))
                {
                    _lastSaveUtc = saved;
                }
                DateTime checkedUtc;
                _lastCheckUtc = DateTime.MinValue;
                if (mCheck.Success && DateTime.TryParse(mCheck.Groups[1].Value, CultureInfo.InvariantCulture,
                        DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out checkedUtc))
                {
                    _lastCheckUtc = checkedUtc;
                }
                if (mCount.Success) { _lastSaveFiles = int.Parse(mCount.Groups[1].Value, CultureInfo.InvariantCulture); }
                if (mSize.Success) { _lastSaveMb = double.Parse(mSize.Groups[1].Value, CultureInfo.InvariantCulture); }

                DateTime local = _lastSaveUtc == DateTime.MinValue ? DateTime.Now : _lastSaveUtc.ToLocalTime();
                string timeText = _lastSaveUtc == DateTime.MinValue ? "--:--" : local.ToString("HH:mm");
                string sizeText = string.Format("{0} files \u00B7 {1:0.#} MB", _lastSaveFiles, _lastSaveMb);
                _sidebar.SetLastSave(timeText, sizeText);
                _stats.SetTile(2, "LAST SNAPSHOT", timeText, sizeText, -1f);

                DateTime freshUtc = _lastSaveUtc > _lastCheckUtc ? _lastSaveUtc : _lastCheckUtc;
                TimeSpan age = freshUtc == DateTime.MinValue ? TimeSpan.MaxValue : DateTime.UtcNow - freshUtc;
                string ago = age == TimeSpan.MaxValue ? "unknown"
                    : age.TotalMinutes < 1 ? "just now"
                    : age.TotalMinutes < 60 ? string.Format("{0} min ago", (int)age.TotalMinutes)
                    : age.TotalHours < 24 ? string.Format("{0} h ago", (int)age.TotalHours)
                    : local.ToString("d MMM");

                bool fresh = age.TotalMinutes <= 6;
                _hero.SetState(fresh ? "Up to date" : "Snapshot is " + ago, fresh ? Theme.Green : Theme.Amber);
                _hero.SetMeta(_lastSaveUtc == DateTime.MinValue
                    ? "No snapshot yet. Save once to start the 4-minute backup cycle."
                    : string.Format("Last save {0} \u00B7 {1}", local.ToString("HH:mm"), ago));

                bool busy = SyncInProgress();
                _header.SetCloud(busy ? "Saving..." : (fresh ? "Cloud up to date" : "Cloud stale"),
                    busy ? Theme.Blue : (fresh ? Theme.Green : Theme.Amber));

                if (announce)
                {
                    AppendLog(string.Format("Cloud snapshot: {0} \u00B7 {1} files \u00B7 {2:0.#} MB.",
                        local.ToString("HH:mm"), _lastSaveFiles, _lastSaveMb), LogKind.Muted);
                }
            }
            catch (Exception ex)
            {
                AppendLog("Could not read the cloud status file: " + ex.Message, LogKind.Warn);
            }
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
            }
            catch { }
        }

        [DllImport("kernel32.dll")]
        private static extern ulong GetTickCount64();

        // ------------------------------------------------------------------
        //  Actions
        // ------------------------------------------------------------------
        private void StartCheckpoint(bool manual)
        {
            if (_running)
            {
                if (manual)
                {
                    AppendLog("A task is already running. Wait for it to finish, then save again.", LogKind.Warn);
                    SetStatus("Busy", Theme.Amber, _runningLabel + " is still running.");
                }
                return;
            }
            _nextCheckUtc = DateTime.UtcNow.AddMinutes(1);
            if (_syncBusy)
            {
                if (manual)
                {
                    AppendLog("A cloud save is already running in the background - it will finish in a moment.", LogKind.Info);
                    SetStatus("Saving", Theme.Blue, "A background save is already running.");
                }
                return;
            }
            RunTask(manual ? "Saving session to the cloud..." : "Auto-saving session to the cloud...",
                @"& 'C:\Sailuo\scripts\persist-state.ps1' -Checkpoint",
                delegate { RefreshCloudStatus(false); });
        }

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

        private void ConfirmRestore()
        {
            ConfirmAction(
                "Restore the latest cloud save?",
                "Browser logins, Desktop, Documents, Downloads and C:\\Persist will be replaced with the newest snapshot. Files created after that snapshot are not kept.",
                "Restore now", Theme.Violet,
                delegate
                {
                    RunTask("Restoring the latest cloud save...", @"& 'C:\Sailuo\scripts\restore-state.ps1'",
                        delegate { RefreshCloudStatus(true); });
                });
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

        private void EnsureSyncTask()
        {
            try
            {
                ProcessStartInfo query = new ProcessStartInfo("schtasks.exe", "/Query /TN \"Sailuo Cloud Save\"");
                query.UseShellExecute = false;
                query.CreateNoWindow = true;
                query.RedirectStandardOutput = true;
                query.RedirectStandardError = true;
                using (Process process = Process.Start(query))
                {
                    process.StandardOutput.ReadToEnd();
                    process.WaitForExit();
                    if (process.ExitCode == 0)
                    {
                        AppendLog("Cloud auto-save task is active (every 4 minutes).", LogKind.Muted);
                        return;
                    }
                }

                ProcessStartInfo install = new ProcessStartInfo("powershell.exe",
                    "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"C:\\Sailuo\\scripts\\install-state-sync.ps1\" -Quiet");
                install.UseShellExecute = false;
                install.CreateNoWindow = true;
                install.RedirectStandardOutput = true;
                install.RedirectStandardError = true;
                using (Process process = Process.Start(install))
                {
                    process.StandardOutput.ReadToEnd();
                    process.StandardError.ReadToEnd();
                    process.WaitForExit();
                    if (process.ExitCode == 0)
                    {
                        AppendLog("Cloud auto-save task registered (every 4 minutes).", LogKind.Ok);
                    }
                    else
                    {
                        AppendLog("Could not register the auto-save task. Use System > Repair auto-save schedule.", LogKind.Warn);
                    }
                }
            }
            catch (Exception ex)
            {
                AppendLog("Auto-save task check skipped: " + ex.Message, LogKind.Warn);
            }
        }

        // ------------------------------------------------------------------
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
            UpdateCountdown();

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
                            UpdateCountdown();
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
      '/r:System.IO.Compression.dll', '/r:System.IO.Compression.FileSystem.dll')
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
      -ReferencedAssemblies @('System.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll', 'System.IO.Compression.dll', 'System.IO.Compression.FileSystem.dll') `
      -OutputAssembly $exePath `
      -OutputType WindowsApplication `
      -ErrorAction Stop
  }
  if (-not (Test-Path $exePath)) { throw 'SailuoDashboard.exe was not produced by the build step.' }

  if (Test-Path $exePath) {
    Copy-Item -LiteralPath $exePath -Destination $legacyExePath -Force -ErrorAction SilentlyContinue
    Log "SailuoDashboard.exe compiled successfully at $exePath"

    # Keep exactly one clean, uniquely branded shortcut per desktop.
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
        $lnk.Description = 'Sailuo Dashboard - cloud save, applications and system tools'
        $lnk.IconLocation = "$exePath,0"
        $lnk.Save()
      } catch {}
    }

    # Open the dashboard automatically on the first RDP desktop sign-in.
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
      Log 'Sailuo Dashboard registered for auto-start on the next desktop sign-in.'
    } catch {}

    Update-Status @{ tools_hub = @{ installed = $true; exe = $exePath; auto_start = $true } } | Out-Null
  }
} catch {
  Log "SailuoDashboard.exe compile warning: $($_.Exception.Message)"
}

# Register (or repair) the 4-minute cloud auto-save task. Done even when the
# dashboard compile fails, because the save script is independent of the GUI.
$syncInstaller = Join-Path $PSScriptRoot 'install-state-sync.ps1'
if (Test-Path $syncInstaller) {
  try {
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $syncInstaller | Out-Null
    if ($LASTEXITCODE -eq 0) {
      Log 'Cloud auto-save task is ready (every 4 minutes).'
    } else {
      Log "Cloud auto-save task could not be registered (exit $LASTEXITCODE)."
    }
  } catch {
    Log "Cloud auto-save task warning: $($_.Exception.Message)"
  }
} else {
  Log 'install-state-sync.ps1 not found - the 4-minute cloud save task was not registered.'
}
exit 0
