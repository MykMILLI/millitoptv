param(
 [Parameter(Mandatory=$true)][ValidateSet('Metadata','Verify','Install')][string]$Action,
 [Parameter(Mandatory=$true)][string]$EnvelopePath,
 [Parameter(Mandatory=$true)][string]$ExpectedVersion,
 [Parameter(Mandatory=$true)][int]$ExpectedBuild,
 [Parameter(Mandatory=$true)][string]$ExpectedHash,
 [Parameter(Mandatory=$true)][long]$ExpectedBytes,
 [string]$InstallerPath='', [int]$AppPid=0, [string]$AppExe='', [string]$StateDirectory=''
)
$ErrorActionPreference='Stop'
$publicBase64='RUNTMSAAAABgiAV0QhnP+2qR5ioMPBYx6wYocoErxme4XVV5fI9+hJKOu60FrHawjEwSkGzRmRmSQywkb6zcMgaXDg6kM11W'
function Save-State([string]$Name,$Value) {
 $utf8=New-Object Text.UTF8Encoding($false)
 $target=Join-Path $StateDirectory $Name
 [IO.File]::WriteAllText("$target.tmp",($Value|ConvertTo-Json -Compress),$utf8)
 Move-Item -LiteralPath "$target.tmp" -Destination $target -Force
}
$ready=$false
try {
 if((Get-Item -LiteralPath $EnvelopePath).Length -gt 65536){throw 'Release envelope is too large.'}
 $envelope=Get-Content -LiteralPath $EnvelopePath -Raw|ConvertFrom-Json
 if($envelope.protocol -ne 1){throw 'Unsupported signature envelope.'}
 $payload=[Convert]::FromBase64String($envelope.payload)
 $signature=[Convert]::FromBase64String($envelope.signature)
 if($signature.Length -ne 64){throw 'Invalid update signature size.'}
 $key=[Security.Cryptography.CngKey]::Import([Convert]::FromBase64String($publicBase64),[Security.Cryptography.CngKeyBlobFormat]::EccPublicBlob)
 $verifier=[Security.Cryptography.ECDsaCng]::new($key)
 try {
  $verifier.HashAlgorithm=[Security.Cryptography.CngAlgorithm]::Sha256
  if(-not $verifier.VerifyData($payload,$signature)){throw 'Update signature verification failed.'}
 }finally{$verifier.Dispose();$key.Dispose()}
 $meta=[Text.Encoding]::UTF8.GetString($payload)|ConvertFrom-Json
 if($meta.product -ne 'MillitopTV' -or $meta.platform -ne 'windows-x64' -or
    $meta.version -cne $ExpectedVersion -or [int]$meta.build -ne $ExpectedBuild -or
    $meta.sha256 -cne $ExpectedHash -or [long]$meta.sizeBytes -ne $ExpectedBytes){throw 'Signed release does not match the assignment.'}
 if($ExpectedHash -notmatch '^[a-f0-9]{64}$' -or $ExpectedBytes -lt 1 -or $ExpectedBytes -gt 1073741824){throw 'Invalid installer bounds.'}
 if($Action -eq 'Metadata') { Write-Output '{"verified":true}'; exit 0 }
 $file=Get-Item -LiteralPath $InstallerPath
 if($file.Extension -ine '.exe' -or $file.Length -ne $ExpectedBytes -or
    ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Invalid update installer file.'}
 if((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExpectedHash){throw 'Update installer hash mismatch.'}
 if($Action -eq 'Verify') {Write-Output '{"verified":true}';exit 0}
 $allowedRoot=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'MILLITOPTV\updates'))+'\'
 $state=[IO.Path]::GetFullPath($StateDirectory)+'\'
 if(-not $state.StartsWith($allowedRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected updater state directory.'}
 if([IO.Path]::GetFileName($AppExe) -ine 'millitop_tv.exe'){throw 'Unexpected app executable.'}
 $app=Get-Process -Id $AppPid -ErrorAction Stop
 if([IO.Path]::GetFullPath($app.Path) -ine [IO.Path]::GetFullPath($AppExe)){throw 'Running app path differs from handoff.'}
 Save-State 'ready.json' @{ready=$true}
 $ready=$true
 if(-not $app.WaitForExit(90000)){throw 'Millitop did not close. Installer was not started.'}
 # Recheck the payload immediately before executing it.
 if((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExpectedHash){throw 'Installer changed after handoff.'}
 $log=Join-Path $StateDirectory 'installer.log'
 $args='/SP- /SILENT /NORESTART /LOG="'+$log+'"'
 try{
  $setup=Start-Process -FilePath $file.FullName -Verb RunAs -ArgumentList $args -PassThru -Wait
  $code=$setup.ExitCode
 }catch{
  if($_.Exception.NativeErrorCode -eq 1223){$code=1223}else{throw}
 }
 Save-State 'result.json' @{installerExitCode=$code;completed=(Get-Date).ToUniversalTime().ToString('o')}
 if(Test-Path -LiteralPath $AppExe){Start-Process -FilePath $AppExe -WorkingDirectory (Split-Path $AppExe)|Out-Null}
 exit 0
}catch{
 if($StateDirectory -and (Test-Path -LiteralPath $StateDirectory)){
  Save-State 'result.json' @{installerExitCode=-1;error=$_.Exception.Message}
 }
 try { [Console]::Error.WriteLine($_.Exception.Message) } catch {}
 if($ready -and $AppExe -and (Test-Path -LiteralPath $AppExe)){
  $stillRunning=Get-Process -Id $AppPid -ErrorAction SilentlyContinue
  if(-not $stillRunning){Start-Process -FilePath $AppExe -WorkingDirectory (Split-Path $AppExe)|Out-Null}
 }
 exit 1
}
