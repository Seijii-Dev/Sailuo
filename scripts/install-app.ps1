# install-app.ps1 - Install one Sailuo app at a time and add a desktop shortcut
# with the application's own icon.
# Called by the Sailuo Dashboard "Apps" cards so every app installs on its own
# instead of a single one-tap bundle. Safe to run more than once.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('facebook', 'instagram', 'apple-music', 'spotify', 'vscode', 'antigravity', 'opencode', 'discord', 'chrome', 'telegram', 'tiktok')]
  [string]$App,

  # Used by validation runs so a shortcut can be tested without opening a window.
  [switch]$NoLaunch
)

$ErrorActionPreference = 'Continue'

$iconsDir = 'C:\Sailuo\icons'
if (-not (Test-Path -LiteralPath $iconsDir)) {
  New-Item -ItemType Directory -Path $iconsDir -Force -ErrorAction SilentlyContinue | Out-Null
}

function Write-Step([string]$Message) {
  Write-Output "[$App] $Message"
}

function Test-Admin {
  try {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
      [Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch {
    return $false
  }
}

function Invoke-Elevated {
  if (Test-Admin) { return $true }
  try {
    $logPath = Join-Path $env:TEMP ('sailuo-install-' + $App + '.log')
    $wrapperPath = Join-Path $env:TEMP ('sailuo-install-wrapper-' + $App + '.ps1')
    Remove-Item -LiteralPath $logPath, $wrapperPath -Force -ErrorAction SilentlyContinue
    $wrapperContent = @"
`$ErrorActionPreference = 'Continue'
& '$PSCommandPath' -App '$App' 2>&1 | Tee-Object -FilePath '$logPath'
exit `$LASTEXITCODE
"@
    if ($NoLaunch) {
      $wrapperContent = $wrapperContent -replace "-App '$App'", "-App '$App' -NoLaunch"
    }
    Set-Content -LiteralPath $wrapperPath -Value $wrapperContent -Encoding UTF8
    Write-Step 'Requesting administrator rights...'
    $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapperPath)
    $waited = 0
    while (-not $process.HasExited -and $waited -lt 30) {
      Start-Sleep -Seconds 2
      $waited += 2
    }
    if (-not $process.HasExited) {
      try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
      Write-Step 'Elevation timed out.'
      Remove-Item -LiteralPath $wrapperPath, $logPath -Force -ErrorAction SilentlyContinue
      return $false
    }
    if (Test-Path -LiteralPath $logPath) {
      Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue | ForEach-Object { Write-Output $_ }
    }
    Remove-Item -LiteralPath $wrapperPath, $logPath -Force -ErrorAction SilentlyContinue
    exit $process.ExitCode
  } catch {
    Write-Step "Could not elevate: $($_.Exception.Message)"
    Write-Step 'Continuing without administrator rights.'
    return $false
  }
}

function Install-WingetApp([string]$Id, [string]$Name) {
  Write-Step "Installing $Name with winget..."
  & winget install --id $Id --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
  $code = $LASTEXITCODE
  if ($code -eq 0) {
    Write-Step "$Name is ready to use."
  } else {
    Write-Step "winget exited with code $code. If $Name is already installed this is harmless."
  }
}

function Find-Executable([string[]]$Patterns) {
  $searchRoots = @(
    $env:ProgramFiles,
    ${env:ProgramFiles(x86)},
    (Join-Path $env:LOCALAPPDATA 'Programs'),
    $env:LOCALAPPDATA,
    'C:\Program Files\WindowsApps'
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

  foreach ($root in $searchRoots) {
    foreach ($pattern in $Patterns) {
      try {
        $match = Get-ChildItem -LiteralPath $root -Recurse -Filter $pattern -ErrorAction SilentlyContinue -Depth 5 |
          Select-Object -First 1
        if ($match) { return $match.FullName }
      } catch {}
    }
  }
  return $null
}

function Convert-PngToIco([string]$PngPath, [string]$IcoPath) {
  if (-not (Test-Path -LiteralPath $PngPath)) { return $false }
  try {
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $bitmap = [System.Drawing.Bitmap]::new($PngPath)
    $hIcon = $bitmap.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hIcon)
    $stream = [System.IO.File]::Create($IcoPath)
    $icon.Save($stream)
    $stream.Close()
    $icon.Dispose()
    $bitmap.Dispose()
    return (Test-Path -LiteralPath $IcoPath)
  } catch {
    Write-Step "Could not convert icon: $($_.Exception.Message)"
    return $false
  }
}

function Ensure-WebIcon([string]$Name, [string]$Url) {
  $icoPath = Join-Path $iconsDir ($Name.ToLower() + '.ico')
  if (Test-Path -LiteralPath $icoPath) {
    # Some sites serve a PNG from favicon.ico. Windows needs a real ICO file
    # for shortcut icons, so convert the PNG payload when we detect one.
    try {
      $bytes = [IO.File]::ReadAllBytes($icoPath)
      if ($bytes.Length -gt 8 -and $bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50 -and
          $bytes[2] -eq 0x4E -and $bytes[3] -eq 0x47) {
        $pngPath = [IO.Path]::ChangeExtension($icoPath, '.png')
        Copy-Item -LiteralPath $icoPath -Destination $pngPath -Force
        if (Convert-PngToIco $pngPath $icoPath) {
          Remove-Item -LiteralPath $pngPath -Force -ErrorAction SilentlyContinue
        }
      }
    } catch {
      Write-Step "Could not normalise $Name icon: $($_.Exception.Message)"
    }
    return $icoPath
  }
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $client = New-Object System.Net.WebClient
    $client.DownloadFile($Url, $icoPath)
    if (Test-Path -LiteralPath $icoPath) {
      $bytes = [IO.File]::ReadAllBytes($icoPath)
      if ($bytes.Length -gt 8 -and $bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50 -and
          $bytes[2] -eq 0x4E -and $bytes[3] -eq 0x47) {
        $pngPath = [IO.Path]::ChangeExtension($icoPath, '.png')
        Copy-Item -LiteralPath $icoPath -Destination $pngPath -Force
        if (Convert-PngToIco $pngPath $icoPath) {
          Remove-Item -LiteralPath $pngPath -Force -ErrorAction SilentlyContinue
        }
      }
      return $icoPath
    }
  } catch {
    Write-Step "Could not download $Name icon: $($_.Exception.Message)"
  }
  return $null
}

function New-DesktopShortcut([string]$Name, [string]$TargetPath, [string]$Arguments, [string]$IconLocation) {
  $desktop = [Environment]::GetFolderPath('Desktop')
  if (-not $desktop -or -not (Test-Path -LiteralPath $desktop)) { return }
  try {
    $wsh = New-Object -ComObject WScript.Shell
    $shortcutPath = Join-Path $desktop ($Name + '.lnk')
    if (Test-Path -LiteralPath $shortcutPath) {
      Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction SilentlyContinue
    }
    $shortcut = $wsh.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $TargetPath
    if ($Arguments) { $shortcut.Arguments = $Arguments }
    $shortcut.WorkingDirectory = (Split-Path -Parent $TargetPath)
    $shortcut.Description = "$Name"
    if ($IconLocation) { $shortcut.IconLocation = $IconLocation }
    $shortcut.Save()
    Write-Step "Desktop shortcut created: $shortcutPath"
  } catch {
    Write-Step "Could not create desktop shortcut: $($_.Exception.Message)"
  }
}

function New-StoreShortcut([string]$Name, [string]$Aumid, [string]$IconSource) {
  $target = 'C:\Windows\explorer.exe'
  $arguments = "shell:AppsFolder\$Aumid"
  $iconLocation = $null
  if ($IconSource -and (Test-Path -LiteralPath $IconSource)) {
    $iconLocation = "$IconSource,0"
  }
  New-DesktopShortcut $Name $target $arguments $iconLocation
}

function New-WingetShortcut([string]$Name, [string[]]$ExePatterns) {
  $exe = Find-Executable $ExePatterns
  if ($exe) {
    New-DesktopShortcut $Name $exe '' "$exe,0"
  } else {
    Write-Step "Could not locate the $Name executable for a desktop shortcut."
  }
}

function New-WebAppShortcut([string]$Name, [string]$Url, [string]$IconUrl) {
  $candidates = @(
    'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
    (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe')
  )
  $browser = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  if (-not $browser) {
    throw "No Microsoft Edge or Google Chrome installation was found. Install Google Chrome first."
  }

  $icoPath = $null
  if ($IconUrl) {
    $icoPath = Ensure-WebIcon $Name $IconUrl
  }

  $desktop = [Environment]::GetFolderPath('Desktop')
  $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
  $wsh = New-Object -ComObject WScript.Shell

  foreach ($directory in @($desktop, $startMenu)) {
    if (-not $directory) { continue }
    if (-not (Test-Path -LiteralPath $directory)) {
      New-Item -ItemType Directory -Path $directory -Force -ErrorAction SilentlyContinue | Out-Null
    }
    try {
      $shortcutPath = Join-Path $directory ($Name + '.lnk')
      $shortcut = $wsh.CreateShortcut($shortcutPath)
      $shortcut.TargetPath = $browser
      $shortcut.Arguments = "--app=$Url"
      $shortcut.WorkingDirectory = Split-Path -Parent $browser
      $shortcut.Description = "$Name web app"
      if ($icoPath) { $shortcut.IconLocation = "$icoPath,0" } else { $shortcut.IconLocation = "$browser,0" }
      $shortcut.Save()
      Write-Step "Shortcut created: $shortcutPath"
    } catch {
      Write-Step "Could not create shortcut in $directory : $($_.Exception.Message)"
    }
  }

  if (-not $NoLaunch) {
    try {
      Start-Process -FilePath $browser -ArgumentList "--app=$Url"
      Write-Step "$Name opened. It will also start from its desktop and Start menu shortcut."
    } catch {
      Write-Step "$Name was installed. Start it from its desktop shortcut."
    }
  } else {
    Write-Step "$Name shortcut installed."
  }
}

function Install-StoreApp([string]$Id, [string]$Name, [string]$WebUrl, [string]$Aumid, [string]$IconPngPattern) {
  Write-Step "Installing $Name from the Microsoft Store..."
  & winget install --id $Id --exact --source msstore --accept-package-agreements --accept-source-agreements --disable-interactivity
  $wingetCode = $LASTEXITCODE

  # winget returns a non-zero "no applicable update" code when the Store app
  # is already installed, so also check the installed package list.
  $packageFamily = ($Aumid -replace '!.*', '')
  $alreadyInstalled = $false
  try {
    $pkgCheck = Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.PackageFamilyName -eq $packageFamily }
    if ($pkgCheck) { $alreadyInstalled = $true }
  } catch {}

  if ($wingetCode -eq 0 -or $alreadyInstalled) {
    Write-Step "$Name is ready to use."
  } else {
    Write-Step "The Store package could not be installed (winget exit code $wingetCode)."
    Write-Step "Installing $Name as a web app instead..."
    $iconUrl = $null
    if ($Name -eq 'Instagram') { $iconUrl = 'https://static.cdninstagram.com/rsrc.php/v3/yI/r/VsNE-OHk_8a.png' }
    if ($Name -eq 'Apple Music') { $iconUrl = 'https://music.apple.com/favicon.ico' }
    New-WebAppShortcut $Name $WebUrl $iconUrl
    return
  }

  # Create a desktop shortcut with the app's own icon for the Store install.
  $pkg = $null
  try { $pkg = Get-AppxPackage -Name "*$($Name -replace ' ','')*" -ErrorAction SilentlyContinue | Select-Object -First 1 } catch {}
  # Fallback: search by family name prefix.
  if (-not $pkg) {
    try { $pkg = Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $Name.Split(' ')[0] } | Select-Object -First 1 } catch {}
  }

  $iconSource = $null
  if ($pkg -and $pkg.InstallLocation -and (Test-Path -LiteralPath $pkg.InstallLocation)) {
    if ($IconPngPattern) {
      $png = Get-ChildItem -LiteralPath $pkg.InstallLocation -Recurse -Filter $IconPngPattern -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($png) {
        $safeName = $Name.ToLower() -replace '[^a-z0-9]', ''
        $icoPath = Join-Path $iconsDir ($safeName + '.ico')
        if (Convert-PngToIco $png.FullName $icoPath) { $iconSource = $icoPath }
      }
    }
    # Try to find an exe with an embedded icon (prefer a known main executable).
    if (-not $iconSource) {
      $preferred = @()
      if ($Name -eq 'Apple Music') { $preferred = @('AppleMusic.exe') }
      $exe = $null
      foreach ($pe in $preferred) {
        $exe = Get-ChildItem -LiteralPath $pkg.InstallLocation -Recurse -Filter $pe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($exe) { break }
      }
      if (-not $exe) {
        $exe = Get-ChildItem -LiteralPath $pkg.InstallLocation -Recurse -Filter '*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
      }
      if ($exe) { $iconSource = $exe.FullName }
    }
  }

  if ($Aumid) {
    if ($iconSource -and $iconSource -notmatch '\.ico$') {
      # Use the exe as the icon source.
      New-StoreShortcut $Name $Aumid $iconSource
    } elseif ($iconSource) {
      # Convert the provided icon into an exe-less shortcut by pointing IconLocation at the ico.
      $target = 'C:\Windows\explorer.exe'
      $arguments = "shell:AppsFolder\$Aumid"
      New-DesktopShortcut $Name $target $arguments "$iconSource,0"
    } else {
      New-StoreShortcut $Name $Aumid $null
    }
  }
}

# Elevate for machine-scope installs.
switch ($App) {
  'chrome'      { Invoke-Elevated | Out-Null }
  'discord'     { Invoke-Elevated | Out-Null }
  'spotify'     { Invoke-Elevated | Out-Null }
  'vscode'      { Invoke-Elevated | Out-Null }
  'antigravity' { Invoke-Elevated | Out-Null }
  'opencode'    { Invoke-Elevated | Out-Null }
}

switch ($App) {
  'chrome' {
    Install-WingetApp 'Google.Chrome' 'Google Chrome'
    New-WingetShortcut 'Google Chrome' @('chrome.exe')
  }
  'discord' {
    Install-WingetApp 'Discord.Discord' 'Discord'
    New-WingetShortcut 'Discord' @('Discord.exe')
  }
  'spotify' {
    Install-WingetApp 'Spotify.Spotify' 'Spotify'
    New-WingetShortcut 'Spotify' @('Spotify.exe')
  }
  'vscode' {
    Install-WingetApp 'Microsoft.VisualStudioCode' 'Visual Studio Code'
    New-WingetShortcut 'Visual Studio Code' @('Code.exe')
  }
  'antigravity' {
    Install-WingetApp 'Google.AntigravityIDE' 'Antigravity IDE'
    New-WingetShortcut 'Antigravity IDE' @('Antigravity.exe', '*Antigravity*.exe')
  }
  'opencode' {
    Install-WingetApp 'SST.OpenCodeDesktop' 'OpenCode Desktop'
    New-WingetShortcut 'OpenCode Desktop' @('OpenCode.exe', '*OpenCode*.exe')
  }
  'facebook' {
    Write-Step 'Installing the Facebook web app...'
    $iconUrl = 'https://www.facebook.com/favicon.ico'
    New-WebAppShortcut 'Facebook' 'https://www.facebook.com/' $iconUrl
  }
  'instagram' {
    Install-StoreApp '9NBLGGH5L9XT' 'Instagram' 'https://www.instagram.com/' 'Facebook.InstagramBeta_8xx8rvfyw5nnt!App' 'LargeTile.scale-200.png'
  }
  'apple-music' {
    Install-StoreApp '9PFHDD62MXS1' 'Apple Music' 'https://music.apple.com/' 'AppleInc.AppleMusicWin_nzyj5cx40ttqa!App' $null
  }
  'telegram' {
    Write-Step 'Installing the Telegram Web app...'
    $iconUrl = 'https://web.telegram.org/favicon.ico'
    New-WebAppShortcut 'Telegram Web' 'https://web.telegram.org/' $iconUrl
  }
  'tiktok' {
    Write-Step 'Installing the TikTok Web app...'
    $iconUrl = 'https://www.tiktok.com/favicon.ico'
    New-WebAppShortcut 'TikTok Web' 'https://www.tiktok.com/' $iconUrl
  }
}

Write-Step 'Done.'
exit 0

