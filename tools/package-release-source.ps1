param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][int]$Build,
    [string]$Project = (Split-Path $PSScriptRoot -Parent),
    [string]$OutputDirectory = ""
)
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+$' -or $Build -lt 1) { throw 'Invalid release version/build.' }
$Project = [IO.Path]::GetFullPath($Project)
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $Project '.release\source' }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$destination = Join-Path $OutputDirectory "Millitop-TV-$Version-build-$Build-source.zip"
$temporary = $destination + '.tmp-' + [Guid]::NewGuid().ToString('N')
$files = New-Object 'System.Collections.Generic.List[string]'
foreach ($top in @('lib', 'assets', 'android', 'windows', 'linux', 'macos', 'ios', 'web', 'third_party', 'test', 'tools')) {
    $start = Join-Path $Project $top
    if (-not (Test-Path -LiteralPath $start -PathType Container)) { continue }
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($start)
    while ($stack.Count -gt 0) {
        foreach ($entry in Get-ChildItem -LiteralPath $stack.Pop() -Force) {
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Symlinked source requires review before packaging.' }
            if ($entry.PSIsContainer) {
                if ($entry.Name -notin @('build', 'ephemeral', '.git', '.gradle', '.kotlin', '.cxx', '.dart_tool', 'Pods', '.symlinks')) { $stack.Push($entry.FullName) }
            } elseif ($entry.Name -notmatch '^\.env(?:\.|$)|^(local|key)\.properties$|\.(jks|keystore|p12|pem|dpapi)$') {
                $files.Add($entry.FullName)
            }
        }
    }
}
foreach ($name in @('pubspec.yaml', 'pubspec.lock', 'analysis_options.yaml', 'README.md', 'LICENSE', '.metadata', '.gitignore')) {
    $path = Join-Path $Project $name
    if (Test-Path -LiteralPath $path -PathType Leaf) { $files.Add($path) }
}
foreach ($required in @('pubspec.yaml', 'pubspec.lock', 'LICENSE', 'README.md')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Project $required))) { throw "Missing required source file: $required" }
}
Add-Type -AssemblyName System.IO.Compression
$archive = $null
$stream = $null
$hash = [Security.Cryptography.SHA256]::Create()
$records = @()
try {
    $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew)
    $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
    foreach ($path in ($files | Sort-Object -Unique)) {
        $relative = $path.Substring($Project.Length + 1).Replace('\', '/')
        $bytes = [IO.File]::ReadAllBytes($path)
        $sha256 = [BitConverter]::ToString($hash.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
        $records += [ordered]@{ path = $relative; sha256 = $sha256; sizeBytes = $bytes.Length }
        $entry = $archive.CreateEntry($relative, [IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
        $output = $entry.Open()
        try { $output.Write($bytes, 0, $bytes.Length) } finally { $output.Dispose() }
    }
    $manifest = [ordered]@{ version = $Version; build = $Build; files = $records }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($manifest | ConvertTo-Json -Depth 6))
    $entry = $archive.CreateEntry('SOURCE-MANIFEST.json')
    $entry.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
    $output = $entry.Open()
    try { $output.Write($bytes, 0, $bytes.Length) } finally { $output.Dispose() }
    $archive.Dispose()
    $archive = $null
    $stream = $null
    if (Test-Path -LiteralPath $destination) {
        if ((Get-FileHash $temporary).Hash -cne (Get-FileHash $destination).Hash) { throw 'Immutable source archive already exists with different contents. Reserve a new build.' }
    } else {
        Move-Item -LiteralPath $temporary -Destination $destination
    }
    [pscustomobject]@{ path = $destination; sha256 = (Get-FileHash $destination).Hash.ToLowerInvariant(); sizeBytes = (Get-Item $destination).Length; files = $records.Count }
} finally {
    if ($archive) { $archive.Dispose() }
    if ($stream) { $stream.Dispose() }
    $hash.Dispose()
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
}
