param(
 [Parameter(Mandatory=$true)][string]$Installer,
 [Parameter(Mandatory=$true)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
 [Parameter(Mandatory=$true)][ValidateRange(1,2147483647)][int]$Build
)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Security
$file=Get-Item -LiteralPath $Installer
if($file.Extension -ine '.exe'){throw 'Expected the compiled Inno Setup EXE.'}
$privatePath=Join-Path $env:APPDATA 'Millitop-Publisher-Keys\updates-p256-private.dpapi'
$raw=[Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($privatePath),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
$key=[Security.Cryptography.CngKey]::Import($raw,[Security.Cryptography.CngKeyBlobFormat]::EccPrivateBlob)
$signer=[Security.Cryptography.ECDsaCng]::new($key)
try{
 $public=[Convert]::ToBase64String($signer.Key.Export([Security.Cryptography.CngKeyBlobFormat]::EccPublicBlob))
 if($public -cne 'RUNTMSAAAABgiAV0QhnP+2qR5ioMPBYx6wYocoErxme4XVV5fI9+hJKOu60FrHawjEwSkGzRmRmSQywkb6zcMgaXDg6kM11W'){throw 'Private signing key does not match the installed-client public key.'}
 $hash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
 $meta=[ordered]@{product='MillitopTV';platform='windows-x64';version=$Version;build=$Build;sha256=$hash;sizeBytes=$file.Length}
 $payload=[Text.Encoding]::UTF8.GetBytes(($meta|ConvertTo-Json -Compress))
 $signer.HashAlgorithm=[Security.Cryptography.CngAlgorithm]::Sha256
 $signature=$signer.SignData($payload)
 if(-not $signer.VerifyData($payload,$signature)){throw 'Signature self-test failed.'}
 $tampered=[byte[]]$payload.Clone();$tampered[0]=$tampered[0] -bxor 1
 if($signer.VerifyData($tampered,$signature)){throw 'Tampered release unexpectedly verified.'}
 $envelope=[ordered]@{protocol=1;payload=[Convert]::ToBase64String($payload);signature=[Convert]::ToBase64String($signature)}
 $sidecar=$file.FullName+'.release.json'
 if(Test-Path -LiteralPath $sidecar){throw 'Signed sidecar already exists. Do not overwrite published artifacts.'}
 $utf8=New-Object Text.UTF8Encoding($false)
 [IO.File]::WriteAllText($sidecar,($envelope|ConvertTo-Json -Compress),$utf8)
 Write-Host 'RELEASE_SIGNED_AND_TAMPER_TEST_PASSED' -ForegroundColor Green
 $meta|ConvertTo-Json
 Write-Host "Publish these two files unchanged at adjacent HTTPS URLs:"
 Write-Host $file.FullName
 Write-Host $sidecar
 Write-Warning 'This is application-level update signing, not Windows Authenticode signing.'
}finally{
 [Array]::Clear($raw,0,$raw.Length);$signer.Dispose();$key.Dispose()
}