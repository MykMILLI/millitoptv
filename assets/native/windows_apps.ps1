param(
    [ValidateSet("Detect", "Launch")]
    [string]$Action = "Detect",

    [ValidateSet("vlc", "iptvnator")]
    [string]$AppKey,

    [string]$ExePath,

    [string]$MediaPath,

    [string]$CloseSignalPath
)

$ErrorActionPreference = "Stop"

$expected = if ($AppKey -eq "vlc") { "vlc.exe" } else { "IPTVnator.exe" }
$displayPattern = if ($AppKey -eq "vlc") { "^VLC media player" } else { "IPTVnator" }
$packageId = if ($AppKey -eq "vlc") { "VideoLAN.VLC" } else { "4gray.iptvnator" }

function Test-AppExecutable([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return (
        (Test-Path -LiteralPath $Path -PathType Leaf) -and
        ([System.IO.Path]::GetFileName($Path) -ieq $expected)
    )
}

if ($Action -eq "Launch") {
    if (!(Test-AppExecutable $ExePath)) {
        throw "The selected executable is missing or has an unexpected filename."
    }

    $resolved = (Resolve-Path -LiteralPath $ExePath).Path
    $processName = [System.IO.Path]::GetFileNameWithoutExtension($resolved)
    if (![string]::IsNullOrWhiteSpace($MediaPath)) {
        if ($AppKey -ne 'vlc') { throw 'Recordings must open in VLC.' }
        if ($MediaPath.Contains('"') -or $MediaPath.Contains("`r") -or $MediaPath.Contains("`n")) {
            throw 'The recording path contains unsupported characters.'
        }
        if (![System.IO.Path]::IsPathRooted($MediaPath) -or !(Test-Path -LiteralPath $MediaPath -PathType Leaf)) {
            throw 'The recording is no longer available. Refresh recordings and try again.'
        }
        $media = (Get-Item -LiteralPath $MediaPath -Force).FullName
        # A dedicated VLC process keeps playback tracking independent of an
        # already-open VLC window. Quote the filename as one Windows argument.
        $vlcArguments = @('--no-one-instance', '--play-and-exit', '--', ('"' + $media + '"'))
        $player = Start-Process -FilePath $resolved -WorkingDirectory (Split-Path $resolved) -ArgumentList $vlcArguments -PassThru
        $closeRequested=$false
        $closeDeadline=$null
        while(-not $player.HasExited){
            if($CloseSignalPath -and (Test-Path -LiteralPath $CloseSignalPath -PathType Leaf) -and -not $closeRequested){
                $closeRequested=$true;$closeDeadline=(Get-Date).AddSeconds(12)
                [void]$player.CloseMainWindow()
            }
            if($closeRequested -and (Get-Date) -gt $closeDeadline){throw 'VLC did not accept the timer close request. Close that recording manually.'}
            Start-Sleep -Milliseconds 400
            $player.Refresh()
        }
        $player.WaitForExit()
        if ($player.ExitCode -ne 0) { throw 'VLC could not finish playing this recording. It may still be recording or use an unsupported format.' }
        Write-Output 'Recording playback finished.'
        exit 0
    }


    Start-Process -FilePath $resolved -WorkingDirectory (Split-Path $resolved) | Out-Null

    function Get-AppWindows {
        @(
            Get-Process -Name $processName -ErrorAction SilentlyContinue |
                Where-Object {
                    try {
                        $_.Path -ieq $resolved -and $_.MainWindowHandle -ne 0
                    }
                    catch {
                        $false
                    }
                }
        )
    }

    $deadline = (Get-Date).AddSeconds(45)
    $found = $false

    do {
        Start-Sleep -Milliseconds 500
        if (@(Get-AppWindows).Count -gt 0) {
            $found = $true
            break
        }
    } while ((Get-Date) -lt $deadline)

    if (!$found) {
        throw "The app was started, but its window could not be tracked. It may still be running."
    }

    $missingChecks = 0

    while ($missingChecks -lt 3) {
        Start-Sleep -Milliseconds 750

        if (@(Get-AppWindows).Count -eq 0) {
            $missingChecks++
        }
        else {
            $missingChecks = 0
        }
    }

    Write-Output "Application window closed."
    exit 0
}

$candidates = [System.Collections.Generic.List[string]]::new()
$evidence = $false

if ($AppKey -eq "vlc") {
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($root) {
            $candidates.Add((Join-Path $root "VideoLAN\VLC\vlc.exe"))
        }
    }
}
else {
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($root) {
            $candidates.Add((Join-Path $root "IPTVnator\IPTVnator.exe"))
            $candidates.Add((Join-Path $root "iptvnator\iptvnator.exe"))
        }
    }

    if ($env:LOCALAPPDATA) {
        $candidates.Add((Join-Path $env:LOCALAPPDATA "Programs\iptvnator\IPTVnator.exe"))
        $candidates.Add((Join-Path $env:LOCALAPPDATA "Programs\IPTVnator\IPTVnator.exe"))
    }
}

foreach ($registryRoot in @(
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)) {
    foreach ($entry in @(Get-ItemProperty $registryRoot -ErrorAction SilentlyContinue)) {
        if ($entry.DisplayName -match $displayPattern) {
            $evidence = $true

            if ($entry.InstallLocation) {
                $candidates.Add((Join-Path $entry.InstallLocation $expected))
            }

            if ($entry.DisplayIcon) {
                $iconPath = ([string]$entry.DisplayIcon -replace ',\s*-?\d+$', '').Trim('"')
                if ($iconPath -match '\.exe$') {
                    $candidates.Add($iconPath)
                }
            }
        }
    }
}

$shell = New-Object -ComObject WScript.Shell

foreach ($folder in @(
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs",
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs"
)) {
    if (!(Test-Path -LiteralPath $folder)) { continue }

    Get-ChildItem -LiteralPath $folder -Filter "*.lnk" -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            if ($AppKey -eq "vlc") {
                $_.Name -match "VLC"
            }
            else {
                $_.Name -match "IPTVnator"
            }
        } |
        ForEach-Object {
            $target = $shell.CreateShortcut($_.FullName).TargetPath
            if (Test-AppExecutable $target) {
                $candidates.Add($target)
                $evidence = $true
            }
        }
}

$located = $candidates |
    Where-Object { Test-AppExecutable $_ } |
    Select-Object -First 1

$winget = Get-Command winget.exe -ErrorAction SilentlyContinue

[pscustomobject]@{
    path = if ($located) { [string]$located } else { $null }
    installedEvidence = [bool]($evidence -or $located)
    wingetAvailable = [bool]$winget
} | ConvertTo-Json -Compress

