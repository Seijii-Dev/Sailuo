# Builds the brand-icon sprite sheet used by SailuoDashboard.cs.
# Source SVGs live next to this script; the generated sheet is embedded in
# the C# source as base64 so the dashboard remains a single offline exe.
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$svgDir = Join-Path $root 'svg'
$magick = 'C:\Program Files\ImageMagick-7.1.2-Q16-HDRI\magick.exe'
if (-not (Test-Path $magick)) { throw "ImageMagick not found: $magick" }

$icons = @(
    @{ Name = 'chrome';      File = 'chrome.svg';            Target = 92; Trim = $true  },
    @{ Name = 'discord';     File = 'discord.svg';           Target = 92; Trim = $true  },
    @{ Name = 'facebook';    File = 'facebook.svg';          Target = 92; Trim = $true  },
    @{ Name = 'instagram';   File = 'instagram-gradient.svg';Target = 86; Trim = $true  },
    @{ Name = 'apple-music'; File = 'apple-music.svg';       Target = 86; Trim = $true  },
    @{ Name = 'spotify';     File = 'spotify.svg';           Target = 92; Trim = $true  },
    @{ Name = 'vscode';      File = 'vscode.svg';            Target = 88; Trim = $true  },
    @{ Name = 'antigravity'; File = 'antigravity.svg';       Target = 88; Trim = $true  },
    @{ Name = 'opencode';    File = 'opencode-app-clean.svg';Target = 84; Trim = $false },
    @{ Name = 'telegram';    File = 'telegram.svg';          Target = 92; Trim = $true  },
    @{ Name = 'tiktok';      File = 'tiktok.svg';            Target = 88; Trim = $true  }
)

$cell = 96
$work = Join-Path $env:TEMP 'sailuo-brand-icons'
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path $work | Out-Null

$cells = @()
foreach ($icon in $icons) {
    $src = Join-Path $svgDir $icon.File
    if (-not (Test-Path $src)) { throw "Missing SVG: $src" }
    $out = Join-Path $work ($icon.Name + '.png')
    $magickArgs = @('-background', 'none')
    if ($icon.Name -eq 'vscode-streamline') { $magickArgs += @('-density', '2400') }
    $magickArgs += $src
    if ($icon.Trim) { $magickArgs += @('-trim', '+repage') }
    $magickArgs += @('-resize', "$($icon.Target)x$($icon.Target)", '-gravity', 'center',
                     '-background', 'none', '-extent', "${cell}x${cell}", "PNG32:$out")
    & $magick @magickArgs
    if ($LASTEXITCODE -ne 0) { throw "Failed to render $($icon.Name)" }
    $cells += $out
}

$sheet = Join-Path $root 'brand-icons.png'
& $magick montage @cells -tile 6x2 -geometry "${cell}x${cell}+0+0" -background none "PNG32:$sheet"
if ($LASTEXITCODE -ne 0) { throw 'Failed to build sprite sheet.' }

$base64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($sheet))
[IO.File]::WriteAllText((Join-Path $root 'brand-icons.base64.txt'), $base64, (New-Object Text.UTF8Encoding($false)))

# Human-readable preview on a light card-like background.
$preview = Join-Path $work 'preview.png'
& $magick $sheet -background '#ffffff' -alpha remove -alpha off -resize 300% $preview
Get-Item $sheet, (Join-Path $root 'brand-icons.base64.txt'), $preview |
    Select-Object Name, Length, FullName
