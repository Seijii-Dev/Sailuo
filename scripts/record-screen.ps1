[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('Start', 'Stop', 'TestMicrophone', 'Worker')]
  [string]$Action,
  [switch]$IncludeMicrophone,
  [int]$OwnerPid = 0,
  [string]$AudioDevice = '',
  [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
$script:RecorderRoot = Join-Path $env:LOCALAPPDATA 'Sailuo\Recorder'
$script:StatePath = Join-Path $script:RecorderRoot 'state.json'
$script:StopPath = Join-Path $script:RecorderRoot 'stop.request'
$script:RecordingsPath = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::MyVideos)) 'SailuoRecordings'
$script:FfmpegPath = 'C:\Sailuo\tools\ffmpeg\ffmpeg.exe'
$script:WorkerLogPath = Join-Path $script:RecorderRoot 'ffmpeg.log'

function Write-RecorderState {
  param([Parameter(Mandatory = $true)][hashtable]$State)
  New-Item -ItemType Directory -Path $script:RecorderRoot -Force | Out-Null
  $temporaryPath = $script:StatePath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
  $json = $State | ConvertTo-Json -Depth 5
  [IO.File]::WriteAllText($temporaryPath, $json, (New-Object System.Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $temporaryPath -Destination $script:StatePath -Force
}

function Read-RecorderState {
  if (-not (Test-Path -LiteralPath $script:StatePath)) { return $null }
  try { return (Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json) }
  catch { return $null }
}

function ConvertTo-PowerShellLiteral {
  param([string]$Value)
  return "'" + $Value.Replace("'", "''") + "'"
}

function ConvertTo-WindowsArgument {
  param([Parameter(Mandatory = $true)][string]$Value)
  $builder = New-Object System.Text.StringBuilder
  [void]$builder.Append([char]34)
  $backslashes = 0
  foreach ($character in $Value.ToCharArray()) {
    if ($character -eq [char]92) {
      $backslashes++
      continue
    }
    if ($character -eq [char]34) {
      if ($backslashes -gt 0) { [void]$builder.Append([char]92, (2 * $backslashes + 1)) }
      else { [void]$builder.Append([char]92) }
      [void]$builder.Append([char]34)
      $backslashes = 0
      continue
    }
    if ($backslashes -gt 0) { [void]$builder.Append([char]92, $backslashes) }
    [void]$builder.Append($character)
    $backslashes = 0
  }
  if ($backslashes -gt 0) { [void]$builder.Append([char]92, (2 * $backslashes)) }
  [void]$builder.Append([char]34)
  return $builder.ToString()
}

function Install-RecorderFfmpeg {
  if (Test-Path -LiteralPath $script:FfmpegPath) { return $script:FfmpegPath }

  $version = '9.0.2'
  $uri = "https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-$version-essentials_build.zip"
  $expectedHash = '60f467265b1e312373dbcd92200c2618a74850f98d3d078e94296bb3fa2047ba'
  $downloadPath = Join-Path $env:TEMP "sailuo-ffmpeg-$version.zip"
  $extractPath = Join-Path $env:TEMP ('sailuo-ffmpeg-' + [Guid]::NewGuid().ToString('N') + '.exe')
  $ffmpegDirectory = Split-Path -Parent $script:FfmpegPath

  New-Item -ItemType Directory -Path $ffmpegDirectory -Force | Out-Null
  Write-Host "FFmpeg is not installed. Downloading the $version essentials build for first-time recording setup..."
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $uri -OutFile $downloadPath -UseBasicParsing -TimeoutSec 300
    $actualHash = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
      throw "FFmpeg archive checksum mismatch. Expected $expectedHash; received $actualHash."
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($downloadPath)
    try {
      $entry = $archive.Entries | Where-Object { $_.FullName -match '(^|/)bin/ffmpeg\.exe$' } | Select-Object -First 1
      if ($null -eq $entry) { throw 'The verified FFmpeg archive did not contain bin/ffmpeg.exe.' }
      [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $extractPath, $true)
    }
    finally { $archive.Dispose() }

    if (-not (Test-Path -LiteralPath $extractPath) -or (Get-Item -LiteralPath $extractPath).Length -lt 1000000) {
      throw 'FFmpeg extraction did not produce a valid executable.'
    }
    Move-Item -LiteralPath $extractPath -Destination $script:FfmpegPath -Force
    Write-Host "FFmpeg $version installed at $script:FfmpegPath (archive SHA-256 verified)."
    return $script:FfmpegPath
  }
  finally {
    Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $extractPath -Force -ErrorAction SilentlyContinue
  }
}

function Get-DirectShowAudioDevices {
  param([Parameter(Mandatory = $true)][string]$Ffmpeg)
  $previousErrorActionPreference = $ErrorActionPreference
  try {
    # FFmpeg reports DirectShow devices on stderr and may exit nonzero after listing them.
    # Keep that diagnostic output parseable even though the rest of this script uses Stop.
    $ErrorActionPreference = 'Continue'
    $lines = @(& $Ffmpeg -hide_banner -list_devices true -f dshow -i dummy 2>&1 | ForEach-Object { $_.ToString() })
  }
  finally { $ErrorActionPreference = $previousErrorActionPreference }
  $text = $lines -join [Environment]::NewLine
  $marker = $text.IndexOf('DirectShow audio devices', [StringComparison]::OrdinalIgnoreCase)
  if ($marker -lt 0) { return @() }
  $audioText = $text.Substring($marker)
  $nextSection = $audioText.IndexOf('DirectShow ', 15, [StringComparison]::OrdinalIgnoreCase)
  if ($nextSection -gt 0) { $audioText = $audioText.Substring(0, $nextSection) }
  $devices = @()
  foreach ($match in [regex]::Matches($audioText, '\]\s+"([^"]+)"')) { $devices += $match.Groups[1].Value }
  return $devices
}

function Get-RemoteMicrophone {
  param([Parameter(Mandatory = $true)][string]$Ffmpeg)
  $devices = @(Get-DirectShowAudioDevices -Ffmpeg $Ffmpeg)
  $remote = $devices | Where-Object { $_ -match '(?i)remote audio' } | Select-Object -First 1
  if ($remote) { return [string]$remote }

  $listed = if ($devices.Count -gt 0) { $devices -join ', ' } else { '(no DirectShow audio inputs were found)' }
  throw "The RDP microphone is not visible to Windows. Audio inputs found: $listed. Reconnect with microphone/input redirection enabled in the RDP client, allow the Android microphone permission, and try again."
}

function Test-OwnerProcess {
  param([int]$ProcessId)
  if ($ProcessId -le 0) { return $false }
  try { $null = Get-Process -Id $ProcessId -ErrorAction Stop; return $true }
  catch { return $false }
}

function Invoke-RecorderWorker {
  param(
    [string]$Ffmpeg,
    [string]$Device,
    [string]$Destination,
    [int]$DashboardPid,
    [bool]$WithMicrophone
  )

  $process = $null
  try {
    if (-not (Test-OwnerProcess -ProcessId $DashboardPid)) {
      throw 'The Sailuo Dashboard closed before recording started.'
    }
    $driveRoot = [IO.Path]::GetPathRoot($Destination)
    $driveInfo = New-Object System.IO.DriveInfo($driveRoot)
    if ($driveInfo.AvailableFreeSpace -lt 2GB) { throw 'At least 2 GB of free VM disk space is required to start recording.' }

    $arguments = @('-hide_banner', '-nostats', '-loglevel', 'warning', '-y',
      '-thread_queue_size', '256', '-f', 'gdigrab', '-framerate', '15', '-draw_mouse', '1', '-i', 'desktop')
    if ($WithMicrophone) {
      $arguments += @('-thread_queue_size', '256', '-f', 'dshow', '-i', ('audio="' + $Device + '"'))
    }
    $arguments += @('-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '27', '-pix_fmt', 'yuv420p')
    if ($WithMicrophone) { $arguments += @('-c:a', 'aac', '-b:a', '96k', '-ac', '1') }
    $arguments += @('-movflags', '+faststart', '-f', 'mp4', $Destination)

    $quotedArguments = @($arguments | ForEach-Object { ConvertTo-WindowsArgument -Value ([string]$_) })
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Ffmpeg
    $startInfo.Arguments = $quotedArguments -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardOutput = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $logPath = $script:WorkerLogPath
    $eventHandler = [System.Diagnostics.DataReceivedEventHandler]{
      param($sender, $eventArgs)
      if ($eventArgs.Data) {
        try { [IO.File]::AppendAllText($logPath, $eventArgs.Data + [Environment]::NewLine) } catch {}
      }
    }
    $process.add_ErrorDataReceived($eventHandler)
    $process.add_OutputDataReceived($eventHandler)
    if (-not $process.Start()) { throw 'FFmpeg did not start.' }
    $process.BeginErrorReadLine()
    $process.BeginOutputReadLine()

    Write-RecorderState @{ state = 'recording'; mode = $(if ($WithMicrophone) { 'screen+microphone' } else { 'screen' }); outputPath = $Destination; audioDevice = $Device; startedAt = [DateTime]::UtcNow.ToString('o'); workerPid = $PID; ffmpegPid = $process.Id; ownerPid = $DashboardPid; logPath = $logPath; message = 'Recording is active.' }

    $stopReason = ''
    $lastDiskCheck = Get-Date
    while (-not $process.WaitForExit(1000)) {
      if (Test-Path -LiteralPath $script:StopPath) {
        Remove-Item -LiteralPath $script:StopPath -Force -ErrorAction SilentlyContinue
        $stopReason = 'Stopped by the user from the Dashboard.'
        break
      }
      if (-not (Test-OwnerProcess -ProcessId $DashboardPid)) {
        $stopReason = 'Stopped because the Dashboard closed.'
        break
      }
      if (((Get-Date) - $lastDiskCheck).TotalSeconds -ge 30) {
        $driveInfo = New-Object System.IO.DriveInfo($driveRoot)
        if ($driveInfo.AvailableFreeSpace -lt 2GB) {
          $stopReason = 'Stopped automatically to preserve at least 2 GB of free space on the VM disk.'
          break
        }
        $lastDiskCheck = Get-Date
      }
    }

    if ($stopReason) {
      Write-RecorderState @{ state = 'stopping'; mode = $(if ($WithMicrophone) { 'screen+microphone' } else { 'screen' }); outputPath = $Destination; audioDevice = $Device; startedAt = [DateTime]::UtcNow.ToString('o'); workerPid = $PID; ffmpegPid = $process.Id; ownerPid = $DashboardPid; logPath = $logPath; message = $stopReason }
      try { $process.StandardInput.WriteLine('q'); $process.StandardInput.Flush() } catch {}
      if (-not $process.WaitForExit(45000)) {
        try { $process.Kill(); $process.WaitForExit() } catch {}
        throw 'FFmpeg did not stop cleanly within 45 seconds; the current MP4 may be incomplete.'
      }
    }
    $process.WaitForExit()
    $exitCode = $process.ExitCode
    if ($exitCode -eq 0) {
      $message = if ($stopReason) { $stopReason } else { 'FFmpeg ended normally.' }
      Write-RecorderState @{ state = 'stopped'; mode = $(if ($WithMicrophone) { 'screen+microphone' } else { 'screen' }); outputPath = $Destination; audioDevice = $Device; stoppedAt = [DateTime]::UtcNow.ToString('o'); workerPid = $PID; ownerPid = $DashboardPid; logPath = $logPath; message = $message }
    }
    else {
      throw "FFmpeg exited with code $exitCode. Check the recorder log at $logPath."
    }
  }
  catch {
    Write-RecorderState @{ state = 'failed'; mode = $(if ($WithMicrophone) { 'screen+microphone' } else { 'screen' }); outputPath = $Destination; audioDevice = $Device; stoppedAt = [DateTime]::UtcNow.ToString('o'); workerPid = $PID; ownerPid = $DashboardPid; logPath = $script:WorkerLogPath; message = $_.Exception.Message }
    try { [IO.File]::AppendAllText($script:WorkerLogPath, $_.Exception.ToString() + [Environment]::NewLine) } catch {}
  }
  finally {
    if ($process) { $process.Dispose() }
    Remove-Item -LiteralPath $script:StopPath -Force -ErrorAction SilentlyContinue
  }
}

switch ($Action) {
  'TestMicrophone' {
    $ffmpeg = Install-RecorderFfmpeg
    $devices = @(Get-DirectShowAudioDevices -Ffmpeg $ffmpeg)
    if ($devices.Count -gt 0) { Write-Host ('Windows audio inputs: ' + ($devices -join ', ')) }
    $remote = $devices | Where-Object { $_ -match '(?i)remote audio' } | Select-Object -First 1
    if (-not $remote) { throw 'No Remote Audio microphone input was found. Reconnect with microphone redirection and grant the client microphone permission.' }
    Write-Host "RDP microphone input is ready: $remote"
  }
  'Start' {
    if ($OwnerPid -le 0 -or -not (Test-OwnerProcess -ProcessId $OwnerPid)) {
      throw 'Start recording from the Sailuo Dashboard so the recording ends when the Dashboard closes.'
    }
    $existing = Read-RecorderState
    if ($existing -and $existing.state -in @('starting', 'recording', 'stopping') -and (Test-OwnerProcess -ProcessId ([int]$existing.workerPid))) {
      throw "A recording is already $($existing.state). Stop it from the Dashboard before starting another."
    }
    $ffmpeg = Install-RecorderFfmpeg
    $device = ''
    if ($IncludeMicrophone) { $device = Get-RemoteMicrophone -Ffmpeg $ffmpeg }
    New-Item -ItemType Directory -Path $script:RecordingsPath -Force | Out-Null
    New-Item -ItemType Directory -Path $script:RecorderRoot -Force | Out-Null
    Remove-Item -LiteralPath $script:StopPath -Force -ErrorAction SilentlyContinue
    $modeName = if ($IncludeMicrophone) { 'ScreenAndMic' } else { 'Screen' }
    $destination = Join-Path $script:RecordingsPath ('Sailuo-' + $modeName + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.mp4')
    $workerCommand = '& ' + (ConvertTo-PowerShellLiteral -Value $PSCommandPath) + ' -Action Worker -OwnerPid ' + $OwnerPid + ' -OutputPath ' + (ConvertTo-PowerShellLiteral -Value $destination) + ' -AudioDevice ' + (ConvertTo-PowerShellLiteral -Value $device)
    if ($IncludeMicrophone) { $workerCommand += ' -IncludeMicrophone' }
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($workerCommand))
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $worker = Start-Process -FilePath $powershell -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedCommand) -PassThru -WindowStyle Hidden

    $deadline = (Get-Date).AddSeconds(20)
    do {
      Start-Sleep -Milliseconds 400
      $state = Read-RecorderState
      if ($state -and $state.state -eq 'recording') {
        Write-Host "Recording started: $destination"
        if ($IncludeMicrophone) { Write-Host "Microphone: $device" }
        Write-Host 'The recording is stored on this VM only and is not uploaded.'
        return
      }
      if ($state -and $state.state -eq 'failed') { throw $state.message }
      if ($worker.HasExited -and -not $state) { throw 'The recorder worker did not start.' }
    } while ((Get-Date) -lt $deadline)
    Write-Host "Recorder startup requested. Check Dashboard status; output target: $destination"
  }
  'Stop' {
    $state = Read-RecorderState
    if (-not $state -or $state.state -notin @('starting', 'recording', 'stopping')) {
      Write-Host 'No active recording was found.'
      return
    }
    if (-not (Test-OwnerProcess -ProcessId ([int]$state.workerPid))) {
      throw 'The recorder worker is no longer running. The state file may be stale; check the local MP4 and recorder log.'
    }
    New-Item -ItemType Directory -Path $script:RecorderRoot -Force | Out-Null
    [IO.File]::WriteAllText($script:StopPath, [DateTime]::UtcNow.ToString('o'), (New-Object System.Text.UTF8Encoding($false)))
    $deadline = (Get-Date).AddSeconds(50)
    do {
      Start-Sleep -Milliseconds 500
      $state = Read-RecorderState
      if ($state -and $state.state -in @('stopped', 'failed')) {
        if ($state.state -eq 'failed') { throw $state.message }
        if ($state.outputPath -and (Test-Path -LiteralPath $state.outputPath)) {
          Write-Host "Recording saved: $($state.outputPath)"
        }
        if ($state.message) { Write-Host $state.message }
        Write-Host 'The MP4 was finalized and remains local to this VM.'
        return
      }
    } while ((Get-Date) -lt $deadline)
    throw 'Timed out waiting for the recording to finalize. Check the Dashboard status and recorder log.'
  }
  'Worker' {
    if (-not $OutputPath) { throw 'Worker requires an output path.' }
    if ($IncludeMicrophone -and -not $AudioDevice) { throw 'Worker requires the redirected microphone device.' }
    Invoke-RecorderWorker -Ffmpeg $script:FfmpegPath -Device $AudioDevice -Destination $OutputPath -DashboardPid $OwnerPid -WithMicrophone ([bool]$IncludeMicrophone)
  }
}
