$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release-core.ps1')
Add-Type -AssemblyName System.IO.Compression
$root = Join-Path ([IO.Path]::GetTempPath()) ('Millitop-source-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    foreach ($path in @('lib\main.dart', 'third_party\engine\lib\engine.dart', 'android\app\build.gradle.kts', 'android\key.properties', 'android\.gradle\cache', 'lib\.env', 'pubspec.yaml', 'pubspec.lock', 'LICENSE', 'README.md')) {
        $full = Join-Path $root $path
        New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
        [IO.File]::WriteAllText($full, 'Test fixture')
    }
    $config = @{ vcRedist = (Join-Path $root 'LICENSE'); webView2Installer = (Join-Path $root 'LICENSE'); sqliteDll = (Join-Path $root 'LICENSE') }
    $initial = Get-ReleaseFingerprint $root $config 'test-toolchain'
    [IO.File]::WriteAllText((Join-Path $root 'third_party\engine\lib\engine.dart'), 'Engine change')
    $engine = Get-ReleaseFingerprint $root $config 'test-toolchain'
    if ($initial -ceq $engine) { throw 'Engine source is missing from release fingerprint.' }
    [IO.File]::WriteAllText((Join-Path $root 'android\app\build.gradle.kts'), 'Android change')
    $android = Get-ReleaseFingerprint $root $config 'test-toolchain'
    if ($engine -ceq $android) { throw 'Android source is missing from release fingerprint.' }
    [IO.File]::WriteAllText((Join-Path $root 'android\.gradle\cache'), 'Cache change')
    if ($android -cne (Get-ReleaseFingerprint $root $config 'test-toolchain')) { throw 'Generated Android cache changed the fingerprint.' }
    $first = & (Join-Path $PSScriptRoot 'package-release-source.ps1') -Version 2.1.0 -Build 30 -Project $root
    $second = & (Join-Path $PSScriptRoot 'package-release-source.ps1') -Version 2.1.0 -Build 30 -Project $root
    if ($first.sha256 -cne $second.sha256) { throw 'Source packaging is not repeatable.' }
    $stream = [IO.File]::OpenRead($first.path)
    $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Read)
    try {
        foreach ($required in @('lib/main.dart', 'third_party/engine/lib/engine.dart', 'android/app/build.gradle.kts', 'SOURCE-MANIFEST.json', 'LICENSE')) {
            if (-not $archive.GetEntry($required)) { throw "Missing source archive entry: $required" }
        }
        foreach ($excluded in @('android/key.properties', 'android/.gradle/cache', 'lib/.env')) {
            if ($archive.GetEntry($excluded)) { throw "Excluded local file leaked into source archive: $excluded" }
        }
    } finally { $archive.Dispose(); $stream.Dispose() }
    [IO.File]::WriteAllText((Join-Path $root 'lib\main.dart'), 'Different source')
    $rejected = $false
    try { & (Join-Path $PSScriptRoot 'package-release-source.ps1') -Version 2.1.0 -Build 30 -Project $root | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Immutable source archive was overwritten.' }
    Write-Host 'SOURCE_PACKAGE_TESTS_PASSED (source coverage, cache exclusion, local-secret exclusion, repeatability and immutability)'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
