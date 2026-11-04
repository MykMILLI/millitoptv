$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'release-core.ps1')
$count=0
function Check([bool]$Condition,[string]$Name){if(-not $Condition){throw "SELF_TEST_FAILED: $Name"};$script:count++}
function Check-Throws([scriptblock]$Action,[string]$Name){$thrown=$false;try{& $Action|Out-Null}catch{$thrown=$true};Check $thrown $Name}
Check ((Get-ReleaseOrigin 'https://tvadmin.millitop.net/') -ceq 'https://tvadmin.millitop.net') 'HTTPS origin normalization'
Check-Throws {Get-ReleaseOrigin 'http://example.invalid'} 'Reject plaintext HTTP'
Check-Throws {Get-ReleaseOrigin 'https://example.invalid/downloads'} 'Reject URL paths'
Check-Throws {Get-ReleaseOrigin 'https://user:secret@example.invalid'} 'Reject URL credentials'
Check ((Get-NextReleaseBuild @() @() 13) -eq 13) 'First build floor'
Check ((Get-NextReleaseBuild @([pscustomobject]@{build=12}) @([pscustomobject]@{build=15}) 13) -eq 16) 'Failed/reserved local builds not reused'
Check ((Get-NextReleaseBuild @([pscustomobject]@{build=21}) @() 13) -eq 22) 'Registry build high-water mark'
Check-Throws {Get-NextReleaseBuild @([pscustomobject]@{build=2147483647}) @() 13} 'Reject build overflow'
Check ((Compare-ReleaseVersion '1.2.2' '1.2.1') -eq 1) 'Newer version'
Check ((Compare-ReleaseVersion '1.2.2' '1.2.2') -eq 0) 'Same version'
Check ((Compare-ReleaseVersion '1.2.1' '1.2.2') -eq -1) 'Older version'
Assert-ReleaseApiRoute 'GET' '/api/admin/releases'
Assert-ReleaseApiRoute 'POST' '/api/admin/releases'
Assert-ReleaseApiRoute 'POST' '/api/login'
Check-Throws {Assert-ReleaseApiRoute 'POST' '/api/admin/releases/example/assign'} 'No assignment route permitted'
Check-Throws {Assert-ReleaseApiRoute 'POST' '/api/admin/releases/example/enabled'} 'No enable/disable route permitted'
Check-Throws {Assert-ReleaseApiRoute 'DELETE' '/api/admin/releases'} 'No delete route permitted'
$metadata=[pscustomobject]@{version='1.2.2';build=13;sha256=('a'*64);sizeBytes=123;installerUrl='https://example.invalid/file.exe';notes='Test notes'}
$row=[pscustomobject]@{id='11111111-1111-4111-8111-111111111111';version='1.2.2';build=13;sha256=('a'*64);size_bytes=123;installer_url='https://example.invalid/file.exe';notes='Test notes';enabled=$false}
Assert-ReleaseMatch $row $metadata
$count++
$row.sha256='b'*64
Check-Throws {Assert-ReleaseMatch $row $metadata} 'Hash mismatch is an immutable conflict'
$row.sha256='a'*64;$row.size_bytes=124
Check-Throws {Assert-ReleaseMatch $row $metadata} 'Size mismatch is an immutable conflict'
$row.size_bytes=123;$row.installer_url='https://example.invalid/other.exe'
Check-Throws {Assert-ReleaseMatch $row $metadata} 'URL mismatch is an immutable conflict'
$row.installer_url='https://example.invalid/file.exe';$row.notes='Changed notes'
Check-Throws {Assert-ReleaseMatch $row $metadata} 'Notes mismatch is an immutable conflict'
$root=Join-Path ([IO.Path]::GetTempPath()) ('Millitop-pipeline-tests-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root|Out-Null
try{
 $file=Join-Path $root 'state.json'
 Save-ReleaseJson $file @{build=13;stage='reserved'}
 Check ((Read-ReleaseJson $file).stage -ceq 'reserved') 'Atomic initial state'
 Save-ReleaseJson $file @{build=13;stage='signed'}
 Check ((Read-ReleaseJson $file).stage -ceq 'signed') 'Atomic state replacement'
 Check (@(Get-ChildItem -LiteralPath $root -Filter '*.tmp-*').Count -eq 0) 'No temporary state remains'
}finally{Remove-Item -LiteralPath $root -Recurse -Force}
Write-Host "PIPELINE_SELF_TESTS_PASSED ($count assertions; no network, credentials or production key access)" -ForegroundColor Green
