# Brand icon sources

The Applications catalogue uses authentic, full-colour brand marks. They are
rasterised into `brand-icons.png` and embedded in the dashboard as base64 so the
app still ships as one self-contained executable and works offline.

The original SVGs are kept in `svg/` for provenance. Rebuild the sheet with:

```powershell
.\build-icons.ps1
```

The script writes `brand-icons.png` and `brand-icons.base64.txt`. To ship an
updated sheet, replace the `SheetBase64` literal in
`C:\Sailuo\tools\SailuoDashboard.cs` with the new base64 text and re-sync the
copy inside `scripts/setup-tools-hub.ps1`.

| Application | SVG | Source |
| --- | --- | --- |
| Google Chrome | `svg/chrome.svg` | [gilbarbara/logos](https://github.com/gilbarbara/logos) |
| Discord | `svg/discord.svg` | [gilbarbara/logos](https://github.com/gilbarbara/logos) |
| Facebook | `svg/facebook.svg` | [gilbarbara/logos](https://github.com/gilbarbara/logos) |
| Instagram | `svg/instagram-gradient.svg` | [Wikimedia Commons: Instagram logo 2016](https://commons.wikimedia.org/wiki/File:Instagram_logo_2016.svg) |
| Apple Music | `svg/apple-music.svg` | [Wikimedia Commons: Apple Music icon](https://commons.wikimedia.org/wiki/File:Apple_Music_icon.svg) |
| Spotify | `svg/spotify.svg` | [gilbarbara/logos](https://github.com/gilbarbara/logos) |
| Visual Studio Code | `svg/vscode.svg` | [gilbarbara/logos](https://github.com/gilbarbara/logos) |
| Antigravity IDE | `svg/antigravity.svg` | [gilbarbara/logos](https://github.com/gilbarbara/logos) |
| OpenCode Desktop | `svg/opencode-app-clean.svg` | [opencode.ai favicon](https://opencode.ai/favicon.svg) |
| Telegram Web | `svg/telegram.svg` | [gilbarbara/logos](https://github.com/gilbarbara/logos) |
| TikTok Web | `svg/tiktok.svg` | [gilbarbara/logos](https://github.com/gilbarbara/logos) |

`svg/vscode-streamline.svg` is the Streamline SVG supplied as the visual
reference. The build uses the flatter official mark instead because it stays
crisper at the 30 DIP size used by the cards.

All product names and logos are trademarks of their respective owners.
