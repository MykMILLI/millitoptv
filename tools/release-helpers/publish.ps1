param(
 [Parameter(Mandatory=$true)][string]$Installer,
 [Parameter(Mandatory=$true)][string]$PublicOrigin,
 [string]$ServerAlias='millitop-host',
 [string]$Notes=''
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$origin=[Uri]$PublicOrigin
if(-not $origin.IsAbsoluteUri -or $origin.Scheme -ne 'https' -or $origin.UserInfo -or $origin.Query -or $origin.Fragment -or $origin.AbsolutePath -notin @('','/')){throw 'Expected an HTTPS origin only.'}
if($ServerAlias -notmatch '^[a-zA-Z0-9._-]+$'){throw 'Unexpected SSH alias.'}
$file=Get-Item -LiteralPath $Installer
$sidecar=$file.FullName+'.release.json'
$envelope=Get-Content -LiteralPath $sidecar -Raw|ConvertFrom-Json
if($envelope.protocol -ne 1){throw 'Unsupported envelope.'}
$payload=[Convert]::FromBase64String($envelope.payload)
$signature=[Convert]::FromBase64String($envelope.signature)
$key=[Security.Cryptography.CngKey]::Import([Convert]::FromBase64String('RUNTMSAAAABgiAV0QhnP+2qR5ioMPBYx6wYocoErxme4XVV5fI9+hJKOu60FrHawjEwSkGzRmRmSQywkb6zcMgaXDg6kM11W'),[Security.Cryptography.CngKeyBlobFormat]::EccPublicBlob)
$verifier=[Security.Cryptography.ECDsaCng]::new($key)
try{$verifier.HashAlgorithm=[Security.Cryptography.CngAlgorithm]::Sha256;if(-not $verifier.VerifyData($payload,$signature)){throw 'Signature failed.'}}finally{$verifier.Dispose();$key.Dispose()}
$meta=[Text.Encoding]::UTF8.GetString($payload)|ConvertFrom-Json
if($meta.product -cne 'MillitopTV' -or $meta.platform -cne 'windows-x64' -or $meta.version -notmatch '^\d+\.\d+\.\d+$' -or [int]$meta.build -lt 1){throw 'Unexpected signed metadata.'}
$hash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
$sideHash=(Get-FileHash -LiteralPath $sidecar -Algorithm SHA256).Hash.ToLowerInvariant()
if($hash -cne $meta.sha256 -or $file.Length -ne [long]$meta.sizeBytes){throw 'Installer differs from signed release.'}
$name="Millitop-TV-$($meta.version)-build-$($meta.build)-$($hash.Substring(0,12))-windows-x64.exe"
function Invoke-PublishRemote([string]$Script){
 $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Script.Replace("`r",'')))
 $lines=@(& ssh -oBatchMode=yes -oStrictHostKeyChecking=yes $ServerAlias "printf %s $encoded | base64 --decode | bash")
 $code=$LASTEXITCODE
 if($code -ne 0){throw "Remote artifact verification failed (SSH exit $code). Existing published files were not intentionally overwritten."}
 return ($lines -join "`n")
}
$probe=@'
set -euo pipefail
cd "$HOME/millitop-tv-dashboard/releases"
if [ -e '__NAME__' ] || [ -e '__NAME__.release.json' ]; then
 test -f '__NAME__' && test ! -L '__NAME__'
 test -f '__NAME__.release.json' && test ! -L '__NAME__.release.json'
 printf '%s  %s\n' '__HASH__' '__NAME__' | sha256sum --check --status -
 printf '%s  %s\n' '__SIDEHASH__' '__NAME__.release.json' | sha256sum --check --status -
 printf '\nARTIFACT_PAIR_EXISTS_AND_MATCHES\n'
else
 command -v flock >/dev/null
 printf '\nARTIFACT_PAIR_ABSENT\n'
fi
'@
$probe=$probe.Replace('__NAME__',$name).Replace('__HASH__',$hash).Replace('__SIDEHASH__',$sideHash)
$result=Invoke-PublishRemote $probe
if($result -match '(?m)^ARTIFACT_PAIR_ABSENT\r?$'){
 $upload='.upload-'+[Guid]::NewGuid().ToString('N')
 $remote="millitop-tv-dashboard/releases/$upload"
 & ssh -oBatchMode=yes -oStrictHostKeyChecking=yes $ServerAlias "mkdir $remote"
 if($LASTEXITCODE -ne 0){throw 'Could not create unique staging directory.'}
 & scp -q -oBatchMode=yes -oStrictHostKeyChecking=yes $file.FullName "${ServerAlias}:$remote/update.exe"
 if($LASTEXITCODE -ne 0){throw 'Installer upload failed; release not registered.'}
 & scp -q -oBatchMode=yes -oStrictHostKeyChecking=yes $sidecar "${ServerAlias}:$remote/release.json"
 if($LASTEXITCODE -ne 0){throw 'Envelope upload failed; release not registered.'}
 $finalize=@'
set -euo pipefail
cd "$HOME/millitop-tv-dashboard/releases"
exec 9> '.publish-__NAME__.lock'
flock -w 30 9
printf '%s  %s\n' '__HASH__' '__UPLOAD__/update.exe' | sha256sum --check --status -
printf '%s  %s\n' '__SIDEHASH__' '__UPLOAD__/release.json' | sha256sum --check --status -
if [ -e '__NAME__' ] || [ -e '__NAME__.release.json' ]; then
 test -f '__NAME__' && test ! -L '__NAME__'
 test -f '__NAME__.release.json' && test ! -L '__NAME__.release.json'
 printf '%s  %s\n' '__HASH__' '__NAME__' | sha256sum --check --status -
 printf '%s  %s\n' '__SIDEHASH__' '__NAME__.release.json' | sha256sum --check --status -
 rm -- '__UPLOAD__/update.exe' '__UPLOAD__/release.json'
else
 mv -- '__UPLOAD__/update.exe' '__NAME__'
 mv -- '__UPLOAD__/release.json' '__NAME__.release.json'
 chmod 644 '__NAME__' '__NAME__.release.json'
fi
rmdir -- '__UPLOAD__'
printf '\nARTIFACT_PAIR_FINALIZED\n'
'@
 $finalize=$finalize.Replace('__NAME__',$name).Replace('__HASH__',$hash).Replace('__SIDEHASH__',$sideHash).Replace('__UPLOAD__',$upload)
 $null=Invoke-PublishRemote $finalize
}elseif($result -notmatch '(?m)^ARTIFACT_PAIR_EXISTS_AND_MATCHES\r?$'){throw 'Unexpected remote artifact response.'}
$url=$PublicOrigin.TrimEnd('/')+'/downloads/'+$name
$temp=Join-Path $file.DirectoryName ('.https-check-'+[Guid]::NewGuid().ToString('N'))
try{
 $null=Invoke-WebRequest -UseBasicParsing -Uri ($url+'.release.json') -OutFile ($temp+'.json') -TimeoutSec 60 -MaximumRedirection 0
 if((Get-FileHash -LiteralPath ($temp+'.json') -Algorithm SHA256).Hash -ine $sideHash){throw 'Public HTTPS envelope bytes differ from the signed envelope.'}
 Write-Host 'Verifying complete installer download over public HTTPS...'
 $null=Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile ($temp+'.exe') -TimeoutSec 600 -MaximumRedirection 0
 if((Get-Item -LiteralPath ($temp+'.exe')).Length -ne $file.Length -or
    (Get-FileHash -LiteralPath ($temp+'.exe') -Algorithm SHA256).Hash -ine $hash){throw 'Public HTTPS installer bytes differ from the signed installer.'}
}finally{
 foreach($path in @($temp+'.json',$temp+'.exe')){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}}
}
$ready=[ordered]@{version=$meta.version;build=[int]$meta.build;notes=$Notes;installerUrl=$url;sha256=$hash;sizeBytes=$file.Length}
$output=Join-Path $file.DirectoryName 'dashboard-release-metadata.json'
[IO.File]::WriteAllText($output,($ready|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
Write-Host 'SIGNED_RELEASE_PUBLISHED_AND_HTTPS_HASH_VERIFIED' -ForegroundColor Green
$ready|ConvertTo-Json
Write-Host "Metadata: $output"
