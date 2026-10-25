# Sailuo Dashboard — UI architecture and design system

The dashboard (`tools/SailuoDashboard.exe`) is a single-file WinForms application
compiled by `scripts/setup-tools-hub.ps1` with the .NET Framework 4.x
`csc.exe` bundled with Windows. It renders every surface itself (no designer
files, no NuGet packages), so the layout engine, tokens and states are defined
in `SailuoDashboard.cs` and documented here.

## Source of truth

| Artifact | Purpose |
|---|---|
| `tools/SailuoDashboard.cs` (generated) | Written by `setup-tools-hub.ps1` before compiling. |
| `$csharpSource` here-string in `scripts/setup-tools-hub.ps1` | Canonical source shipped in the repository. |
| `build/SailuoDashboard.cs` | Working copy used while iterating; `build/sync-embedded.ps1` re-embeds it into the installer and `build/build.ps1` compiles it. |

Build command (must include the compression reference used by the GitHub
run-log viewer):

```
csc.exe /nologo /target:winexe /out:SailuoDashboard.exe
        /r:System.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll
        /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll
        /win32icon:C:\Sailuo\icons\sailuo-dashboard.ico SailuoDashboard.cs
```

The build step fails loudly on a compiler error so a stale executable can never
be mistaken for a fresh one.

## Design tokens

* **Spacing** — 4 / 8 / 12 / 16 / 24 / 32 DIP. All margins, paddings and gaps use
  this scale; nothing is hand-positioned.
* **Radii** — 8 (controls), 12 (cards/panels), 16 (hero).
* **Type** — Segoe UI Variable Text / Segoe UI with fallback probing:
  hero 21 pt, page title 17.5 pt, section 11 pt, card title 10.5 pt,
  body 9.5 pt, small 8.5 pt, micro 8 pt semibold, mono 8.75 pt.
* **Colour** — dark canvas `#0B0F14`, chrome `#080B0F`, surfaces
  `#0E151D` / `#121A23` / `#18222E`. Text `#E8EEF6` (14.6:1),
  `#A7B4C4` (7.9:1), `#7D8B9C` (5.1:1) on Surface. Accents (blue, green,
  violet, amber, cyan, red, slate) all clear 4.5:1 on both surfaces.
  Interactive boundaries use `#5C7086` (≈3.4:1) so controls are identifiable
  (WCAG 1.4.11); decorative hairlines stay subtle.

## Layout and responsive rules

The window is a three-band shell: header (64 DIP), body, activity footer.

| Region | Behaviour |
|---|---|
| Sidebar | 232 DIP with labels at ≥1040 px client width, otherwise a 76 DIP icon rail. Nav items are 44 DIP tall, keyboard-navigable with arrows, Enter/Space activates. |
| Page header | 76 DIP; title and subtitle share the page content column. |
| Page body | `PageView` measures and arranges section blocks. Content is capped at 1440 DIP and centred on wider monitors; the scrollbar gutter is always reserved so a scrollbar appearing never reflows the grid. |
| Cards | `CardGrid` fits 1–4 equal columns from a 300 DIP minimum card width, caps cards at 460 DIP and balances rows (4 cards become 2×2 rather than 3+1 when only 3 columns fit). Cards are 92 DIP tall with a two-line description. |
| Stat tiles | 3 / 2 / 1 columns at ≥760 / ≥440 / below. |
| GitHub panel | List and log side by side at ≥740 DIP, stacked below it. |
| Activity footer | Status band 52 DIP plus a log band sized from the window height (3–8 lines). Collapsed automatically below 690 px client height; `Ctrl+Shift+L` or the chevron toggles it. |
| Dialogs | Width 500 DIP, height measured from the message; Enter accepts, Escape cancels, focus starts on the accept button. |

## High-DPI

The process opts into Per-Monitor-V2 awareness before the first window
(`SetProcessDpiAwarenessContext`, falling back to per-monitor and then system
awareness). Every pixel constant is expressed in DIP and converted with
`Ui.S()`; fonts are point-based and scale natively. `WM_DPICHANGED` resizes the
window to the suggested rectangle, recalculates the minimum window size against
the current monitor's work area, and re-runs the layout. The minimum size is
clamped to the work area so the window can always be shown on small or scaled
displays (an unclamped 880×600 DIP minimum at 150 % would not fit a 768 px
panel).

`SAILUO_DASH_DPI=144` (or `--dpi=144`) is a diagnostic override used by the
verification harness to render the full layout at a simulated scale; it has no
effect in normal use.

## Interaction states

Hover, pressed, focus and disabled are shared through one 60 fps ticker and are
skipped when Windows animations are disabled
(`SPI_GETCLIENTAREAANIMATION`). Focus rings are 2 px accent outlines, visible on
every surface. Background work disables action cards and the save/restore
buttons, shows an indeterminate progress bar under the status band and reports
completion in the activity log.

## Accessibility

* Every interactive element has an `AccessibleName` (and description where the
  action has consequences); the log is a named read-only RichTextBox.
* Page tabs expose role and selection; the GitHub run list has a keyboard route
  to its log (`Enter`/double-click) and to the browser (`Shift+Enter`).
* Errors are shown in the warning colour, not muted grey.
* Text contrast meets WCAG AA (worst text pair 5.05:1); control boundaries meet
  3:1; all text-bearing colours were measured, not estimated.
* Known limitation: Windows High Contrast themes are not specially handled yet;
  the dark palette is fixed.

## Verification

The UI is validated by `out/ux/harness` tooling (not shipped): a headless
`layout-check` walks the live control tree at 9 window sizes × 3 pages and
reports clipped/overlapping controls, and a capture matrix renders the real
window at multiple sizes and pages, including a DPI-emulation pass.
