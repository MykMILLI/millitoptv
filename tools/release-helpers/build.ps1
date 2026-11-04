param(
    [string]$Project = "C:\clones\MILLITOPTV",
    [string]$VcRedist = "$HOME\Downloads\VC_redist.x64.exe",
    [string]$WebView2Installer = "$HOME\Downloads\MicrosoftEdgeWebView2RuntimeInstallerX64.exe",
    [string]$SqliteDll = "",
    [string]$InnoCompiler = "",
    [string]$Version = "1.0.1",
    [int]$Build = 2,
    [string]$ResultFile = ""
)
$ErrorActionPreference = "Stop"
function Assert-MicrosoftInstaller([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing prerequisite installer: $Path. Download it from Microsoft's official site."
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or
        $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') {
        throw "Microsoft signature verification failed for $Path. Do not use this file."
    }
}
function Assert-X64Dll([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 256 -or $bytes[0] -ne 77 -or $bytes[1] -ne 90) {
        throw "Not a valid Windows DLL: $Path"
    }
    $offset = [BitConverter]::ToInt32($bytes, 60)
    if ($offset -lt 0 -or ($offset + 24) -gt $bytes.Length -or
        [BitConverter]::ToUInt32($bytes, $offset) -ne 17744 -or
        [BitConverter]::ToUInt16($bytes, $offset + 4) -ne 34404 -or
        ([BitConverter]::ToUInt16($bytes, $offset + 22) -band 8192) -eq 0) {
        throw "Expected an x64 PE DLL: $Path"
    }
}
if ($Version -notmatch '^\d+\.\d+\.\d+$' -or $Build -lt 1) { throw 'Invalid version or build.' }
if (-not (Test-Path (Join-Path $Project 'pubspec.yaml'))) { throw 'Flutter project not found.' }
Assert-MicrosoftInstaller $VcRedist
Assert-MicrosoftInstaller $WebView2Installer
if (-not $InnoCompiler) {
    foreach ($candidate in @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
    )) {
        if (Test-Path -LiteralPath $candidate) { $InnoCompiler = $candidate; break }
    }
}
if (-not $InnoCompiler -or -not (Test-Path -LiteralPath $InnoCompiler)) {
    throw 'Inno Setup compiler not found. Install Inno Setup 6 or supply -InnoCompiler with its ISCC.exe path.'
}
Set-Location -LiteralPath $Project
flutter analyze
if ($LASTEXITCODE -ne 0) { throw 'Flutter analysis failed. Stop and send the diagnostics.' }
flutter test
if ($LASTEXITCODE -ne 0) { throw 'Flutter tests failed. Stop and send the test output.' }
flutter build windows --release --build-name=$Version --build-number=$Build
if ($LASTEXITCODE -ne 0) { throw 'Flutter release build failed.' }
$release = Join-Path $Project 'build\windows\x64\runner\Release'
if (-not (Test-Path (Join-Path $release 'millitop_tv.exe'))) {
    throw "Expected x64 executable missing: $release\millitop_tv.exe"
}
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$work = Join-Path $Project "installer\build-$Version-$Build-$stamp"
$bundle = Join-Path $work 'bundle'
$prereq = Join-Path $work 'prerequisites'
$output = Join-Path $work 'output'
New-Item -ItemType Directory -Force -Path $bundle,$prereq,$output | Out-Null
Copy-Item -Path (Join-Path $release '*') -Destination $bundle -Recurse -Force
if ($SqliteDll) {
    Assert-X64Dll $SqliteDll
    Copy-Item -LiteralPath $SqliteDll -Destination (Join-Path $bundle 'sqlite3.dll') -Force
}
$sqlite = Join-Path $bundle 'sqlite3.dll'
if (-not (Test-Path -LiteralPath $sqlite)) {
    throw 'SQLite runtime missing from release bundle. No installer compiled. Supply -SqliteDll with a trusted x64 sqlite3.dll; do not download a random DLL.'
}
Assert-X64Dll $sqlite
foreach ($file in @('flutter_windows.dll','data\icudtl.dat','data\app.so')) {
    if (-not (Test-Path (Join-Path $bundle $file))) { throw "Release bundle incomplete: $file" }
}
Copy-Item -LiteralPath $VcRedist -Destination (Join-Path $prereq 'VC_redist.x64.exe')
Copy-Item -LiteralPath $WebView2Installer -Destination (Join-Path $prereq 'MicrosoftEdgeWebView2RuntimeInstallerX64.exe')
$iss = Join-Path $work 'millitop-tv.iss'
$utf8 = New-Object System.Text.UTF8Encoding($true)
$template = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('I2lmbmRlZiBCdW5kbGVEaXIKI2Vycm9yIEJ1bmRsZURpciBpcyByZXF1aXJlZAojZW5kaWYKI2lmbmRlZiBQcmVyZXFEaXIKI2Vycm9yIFByZXJlcURpciBpcyByZXF1aXJlZAojZW5kaWYKI2lmbmRlZiBSZWxlYXNlVmVyc2lvbgojZXJyb3IgUmVsZWFzZVZlcnNpb24gaXMgcmVxdWlyZWQKI2VuZGlmCiNpZm5kZWYgUmVsZWFzZUJ1aWxkCiNlcnJvciBSZWxlYXNlQnVpbGQgaXMgcmVxdWlyZWQKI2VuZGlmCiNpZm5kZWYgT3V0cHV0Rm9sZGVyCiNlcnJvciBPdXRwdXRGb2xkZXIgaXMgcmVxdWlyZWQKI2VuZGlmCltTZXR1cF0KQXBwSWQ9e3s3N0MzNkQzMC1DNjg1LTQ4NTctQkFBNC1FNjc1MDIwQUJGMTh9CkFwcE5hbWU9TWlsbGl0b3AgVFYKQXBwVmVyc2lvbj17I1JlbGVhc2VWZXJzaW9ufQpBcHBWZXJOYW1lPU1pbGxpdG9wIFRWIHsjUmVsZWFzZVZlcnNpb259K3sjUmVsZWFzZUJ1aWxkfQpBcHBQdWJsaXNoZXI9TWlsbGl0b3AKRGVmYXVsdERpck5hbWU9e2F1dG9wZn1cTWlsbGl0b3AgVFYKRGVmYXVsdEdyb3VwTmFtZT1NaWxsaXRvcCBUVgpQcml2aWxlZ2VzUmVxdWlyZWQ9YWRtaW4KQXJjaGl0ZWN0dXJlc0FsbG93ZWQ9eDY0Y29tcGF0aWJsZQpBcmNoaXRlY3R1cmVzSW5zdGFsbEluNjRCaXRNb2RlPXg2NGNvbXBhdGlibGUKTWluVmVyc2lvbj0xMC4wLjE3NzYzCk91dHB1dERpcj17I091dHB1dEZvbGRlcn0KT3V0cHV0QmFzZUZpbGVuYW1lPU1pbGxpdG9wLVRWLXsjUmVsZWFzZVZlcnNpb259LWJ1aWxkLXsjUmVsZWFzZUJ1aWxkfS13aW5kb3dzLXg2NApDb21wcmVzc2lvbj1sem1hMgpTb2xpZENvbXByZXNzaW9uPXllcwpXaXphcmRTdHlsZT1tb2Rlcm4KQ2xvc2VBcHBsaWNhdGlvbnM9eWVzClJlc3RhcnRBcHBsaWNhdGlvbnM9bm8KVW5pbnN0YWxsRGlzcGxheUljb249e2FwcH1cbWlsbGl0b3BfdHYuZXhlClNldHVwTG9nZ2luZz15ZXMKRGlzYWJsZVByb2dyYW1Hcm91cFBhZ2U9eWVzCltGaWxlc10KU291cmNlOiAieyNCdW5kbGVEaXJ9XCoiOyBEZXN0RGlyOiAie2FwcH0iOyBGbGFnczogaWdub3JldmVyc2lvbiByZWN1cnNlc3ViZGlycyBjcmVhdGVhbGxzdWJkaXJzClNvdXJjZTogInsjUHJlcmVxRGlyfVxWQ19yZWRpc3QueDY0LmV4ZSI7IEZsYWdzOiBkb250Y29weQpTb3VyY2U6ICJ7I1ByZXJlcURpcn1cTWljcm9zb2Z0RWRnZVdlYlZpZXcyUnVudGltZUluc3RhbGxlclg2NC5leGUiOyBGbGFnczogZG9udGNvcHkKW0ljb25zXQpOYW1lOiAie2F1dG9wcm9ncmFtc31cTWlsbGl0b3AgVFYiOyBGaWxlbmFtZTogInthcHB9XG1pbGxpdG9wX3R2LmV4ZSIKTmFtZTogInthdXRvZGVza3RvcH1cTWlsbGl0b3AgVFYiOyBGaWxlbmFtZTogInthcHB9XG1pbGxpdG9wX3R2LmV4ZSI7IFRhc2tzOiBkZXNrdG9waWNvbgpbVGFza3NdCk5hbWU6IGRlc2t0b3BpY29uOyBEZXNjcmlwdGlvbjogIkNyZWF0ZSBhIGRlc2t0b3Agc2hvcnRjdXQiOyBGbGFnczogdW5jaGVja2VkCltSdW5dCkZpbGVuYW1lOiAie2FwcH1cbWlsbGl0b3BfdHYuZXhlIjsgRGVzY3JpcHRpb246ICJPcGVuIE1pbGxpdG9wIFRWIjsgRmxhZ3M6IG5vd2FpdCBwb3N0aW5zdGFsbCBza2lwaWZzaWxlbnQgcnVuYXNvcmlnaW5hbHVzZXIKW0NvZGVdCnZhcgogIERlcGVuZGVuY3lQYWdlOiBUT3V0cHV0TWFycXVlZVByb2dyZXNzV2l6YXJkUGFnZTsKCmZ1bmN0aW9uIE1hY2hpbmVXZWJWaWV3Mkluc3RhbGxlZDogQm9vbGVhbjsKdmFyCiAgVmVyc2lvbjogU3RyaW5nOwpiZWdpbgogIFJlc3VsdCA6PSBSZWdRdWVyeVN0cmluZ1ZhbHVlKEhLTE0zMiwKICAgICdTT0ZUV0FSRVxNaWNyb3NvZnRcRWRnZVVwZGF0ZVxDbGllbnRzXHtGMzAxNzIyNi1GRTJBLTQyOTUtOEJERi0wMEMzQTlBN0U0QzV9JywKICAgICdwdicsIFZlcnNpb24pOwogIGlmIFJlc3VsdCB0aGVuCiAgICBSZXN1bHQgOj0gKFRyaW0oVmVyc2lvbikgPD4gJycpIGFuZCAoVmVyc2lvbiA8PiAnMC4wLjAuMCcpOwplbmQ7CgpmdW5jdGlvbiBJbnN0YWxsUHJlcmVxdWlzaXRlKGNvbnN0IE5hbWUsIEFyZ3VtZW50cywgU3RhZ2U6IFN0cmluZzsKICBBbGxvd05ld2VyOiBCb29sZWFuKTogU3RyaW5nOwp2YXIKICBDb2RlOiBJbnRlZ2VyOwogIEluc3RhbGxlZDogQ2FyZGluYWw7CmJlZ2luCiAgUmVzdWx0IDo9ICcnOwogIERlcGVuZGVuY3lQYWdlLlNldFRleHQoU3RhZ2UsCiAgICAnV2luZG93cyBpcyBwcmVwYXJpbmcgYSByZXF1aXJlZCBjb21wb25lbnQuIFRoaXMgbWF5IHRha2Ugc2V2ZXJhbCBtaW51dGVzLicpOwogIERlcGVuZGVuY3lQYWdlLlNob3c7CiAgRGVwZW5kZW5jeVBhZ2UuQW5pbWF0ZTsKICB0cnkKICAgIExvZygnUHJlcmVxdWlzaXRlIHN0YXJ0ZWQ6ICcgKyBOYW1lKTsKICAgIEV4dHJhY3RUZW1wb3JhcnlGaWxlKE5hbWUpOwogICAgaWYgbm90IEV4ZWMoRXhwYW5kQ29uc3RhbnQoJ3t0bXB9XCcpICsgTmFtZSwgQXJndW1lbnRzLCAnJywgU1dfSElERSwKICAgICAgZXdXYWl0VW50aWxUZXJtaW5hdGVkLCBDb2RlKSB0aGVuCiAgICBiZWdpbgogICAgICBSZXN1bHQgOj0gJ0NvdWxkIG5vdCBzdGFydCBwcmVyZXF1aXNpdGUgJyArIE5hbWUgKyAnLiBXaW5kb3dzIGVycm9yICcgKyBJbnRUb1N0cihDb2RlKSArICcuJzsKICAgICAgRXhpdDsKICAgIGVuZDsKICAgIExvZygnUHJlcmVxdWlzaXRlIGNvbXBsZXRlZDogJyArIE5hbWUgKyAnOyBleGl0IGNvZGUgJyArIEludFRvU3RyKENvZGUpKTsKICAgIGlmIENvZGUgPSAwIHRoZW4gRXhpdDsKICAgIGlmIChDb2RlID0gMTYzOCkgYW5kIEFsbG93TmV3ZXIgdGhlbgogICAgYmVnaW4KICAgICAgaWYgUmVnUXVlcnlEV29yZFZhbHVlKEhLTE02NCwKICAgICAgICAnU09GVFdBUkVcTWljcm9zb2Z0XFZpc3VhbFN0dWRpb1wxNC4wXFZDXFJ1bnRpbWVzXHg2NCcsCiAgICAgICAgJ0luc3RhbGxlZCcsIEluc3RhbGxlZCkgdGhlbgogICAgICAgIGlmIEluc3RhbGxlZCA9IDEgdGhlbiBFeGl0OwogICAgZW5kOwogICAgaWYgQ29kZSA9IDMwMTAgdGhlbgogICAgICBSZXN1bHQgOj0gJ0EgcHJlcmVxdWlzaXRlIHJlcXVpcmVzIGEgV2luZG93cyByZXN0YXJ0LiBSZXN0YXJ0IFdpbmRvd3MgYW5kIHJ1biB0aGlzIGluc3RhbGxlciBhZ2Fpbi4nCiAgICBlbHNlCiAgICAgIFJlc3VsdCA6PSAnUHJlcmVxdWlzaXRlICcgKyBOYW1lICsgJyBmYWlsZWQgd2l0aCBleGl0IGNvZGUgJyArIEludFRvU3RyKENvZGUpICsgJy4gQXBwIGluc3RhbGxhdGlvbiBzdG9wcGVkLic7CiAgZmluYWxseQogICAgRGVwZW5kZW5jeVBhZ2UuSGlkZTsKICBlbmQ7CmVuZDsKCmZ1bmN0aW9uIFByZXBhcmVUb0luc3RhbGwodmFyIE5lZWRzUmVzdGFydDogQm9vbGVhbik6IFN0cmluZzsKYmVnaW4KICBpZiBEZXBlbmRlbmN5UGFnZSA9IG5pbCB0aGVuCiAgICBEZXBlbmRlbmN5UGFnZSA6PSBDcmVhdGVPdXRwdXRNYXJxdWVlUHJvZ3Jlc3NQYWdlKAogICAgICAnUHJlcGFyaW5nIE1pbGxpdG9wIFRWJywgJ0luc3RhbGxpbmcgcmVxdWlyZWQgV2luZG93cyBjb21wb25lbnRzJyk7CiAgUmVzdWx0IDo9IEluc3RhbGxQcmVyZXF1aXNpdGUoJ1ZDX3JlZGlzdC54NjQuZXhlJywKICAgICcvaW5zdGFsbCAvcXVpZXQgL25vcmVzdGFydCcsCiAgICAnU3RlcCAxIG9mIDM6IFByZXBhcmluZyBNaWNyb3NvZnQgVmlzdWFsIEMrKyBSdW50aW1lJywgVHJ1ZSk7CiAgaWYgUmVzdWx0IDw+ICcnIHRoZW4gRXhpdDsKICBpZiBNYWNoaW5lV2ViVmlldzJJbnN0YWxsZWQgdGhlbgogIGJlZ2luCiAgICBMb2coJ1dlYlZpZXcyIHNraXBwZWQ6IG1hY2hpbmUtd2lkZSBFdmVyZ3JlZW4gUnVudGltZSBpcyByZWdpc3RlcmVkLicpOwogICAgUmVzdWx0IDo9ICcnOwogIGVuZAogIGVsc2UKICAgIFJlc3VsdCA6PSBJbnN0YWxsUHJlcmVxdWlzaXRlKCdNaWNyb3NvZnRFZGdlV2ViVmlldzJSdW50aW1lSW5zdGFsbGVyWDY0LmV4ZScsCiAgICAgICcvc2lsZW50IC9pbnN0YWxsJywKICAgICAgJ1N0ZXAgMiBvZiAzOiBJbnN0YWxsaW5nIE1pY3Jvc29mdCBFZGdlIFdlYlZpZXcyIFJ1bnRpbWUnLCBGYWxzZSk7CmVuZDsKCnByb2NlZHVyZSBDdXJTdGVwQ2hhbmdlZChDdXJTdGVwOiBUU2V0dXBTdGVwKTsKYmVnaW4KICBpZiBDdXJTdGVwID0gc3NJbnN0YWxsIHRoZW4KICAgIFdpemFyZEZvcm0uU3RhdHVzTGFiZWwuQ2FwdGlvbiA6PSAnU3RlcCAzIG9mIDM6IEluc3RhbGxpbmcgTWlsbGl0b3AgVFYgYXBwbGljYXRpb24gZmlsZXMuLi4nOwplbmQ7Cg=='))
[System.IO.File]::WriteAllText($iss,$template,$utf8)
& $InnoCompiler "/DBundleDir=$bundle" "/DPrereqDir=$prereq" "/DOutputFolder=$output" "/DReleaseVersion=$Version" "/DReleaseBuild=$Build" $iss
if ($LASTEXITCODE -ne 0) { throw 'Inno Setup compilation failed. Send the compiler output.' }
$exe = Join-Path $output "Millitop-TV-$Version-build-$Build-windows-x64.exe"
if (-not (Test-Path -LiteralPath $exe)) { throw 'Expected installer was not produced.' }
$metadata = [ordered]@{
    version=$Version; build=$Build; sha256=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant();
    sizeBytes=(Get-Item -LiteralPath $exe).Length; notes=''; installerUrl='';
    signingStatus=(Get-AuthenticodeSignature -LiteralPath $exe).Status.ToString()
}
$metadata | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'release-metadata.json') -Encoding UTF8
Write-Host "`nINSTALLER_BUILD_COMPLETE" -ForegroundColor Green
Write-Host "Installer: $exe"
Write-Host "Metadata: $(Join-Path $output 'release-metadata.json')"
Write-Warning 'Development installer only. Not code-signed or clean-machine tested. Do not publish or enable a release yet.'

if ($ResultFile) {
    $result = [ordered]@{installer=$exe;version=$Version;build=$Build;metadata=(Join-Path $output 'release-metadata.json')}
    [IO.File]::WriteAllText($ResultFile,($result|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
}
