$script:ReleasePublicKey='RUNTMSAAAABgiAV0QhnP+2qR5ioMPBYx6wYocoErxme4XVV5fI9+hJKOu60FrHawjEwSkGzRmRmSQywkb6zcMgaXDg6kM11W'
function Save-ReleaseJson([string]$Path,$Value){
 if([string]::IsNullOrWhiteSpace($Path)){throw 'JSON journal path is empty.'}
 $target=[IO.Path]::GetFullPath($Path)
 $parent=[IO.Path]::GetDirectoryName($target)
 if(-not [IO.Directory]::Exists($parent)){throw "JSON journal directory missing: $parent"}
 $id=[Guid]::NewGuid().ToString('N')
 $temp=$target+'.tmp-'+$id
 $backup=$target+'.previous-'+$id
 $bytes=[Text.Encoding]::UTF8.GetBytes(($Value|ConvertTo-Json -Depth 20))
 $stream=$null
 try{
  $stream=[IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  $stream.Write($bytes,0,$bytes.Length)
  $stream.Flush($true)
 }finally{if($null -ne $stream){$stream.Dispose()}}
 for($attempt=0;$attempt -lt 12;$attempt++){
  try{
   if([IO.File]::Exists($target)){
    [IO.File]::Replace($temp,$target,$backup)
   }else{
    [IO.File]::Move($temp,$target)
   }
   return
  }catch{
   $cause=$_.Exception.GetBaseException()
   $native=([int]$cause.HResult -band 65535)
   $retryable=$native -in @(32,33,1175)
   if($retryable -and $attempt -lt 11 -and [IO.File]::Exists($temp)){
    Start-Sleep -Milliseconds ([Math]::Min(1500,150+150*$attempt))
    continue
   }
   throw [IO.IOException]::new(
    "Journal save failed at '$target' (Windows code $native). No delete/copy fallback was used. Recovery files, if present: '$temp' and '$backup'. Original error: $($cause.Message)",
    $cause)
  }
 }
}
function Read-ReleaseJson([string]$Path){return (Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json)}
function Get-TextHash([string]$Text){
 $sha=[Security.Cryptography.SHA256]::Create()
 try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant()}
 finally{$sha.Dispose()}
}
function Get-ReleaseOrigin([string]$Value){
 $uri=[Uri]$Value
 if(-not $uri.IsAbsoluteUri -or $uri.Scheme -cne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -notin @('','/')){throw 'Configure an HTTPS origin without a path, credentials, query or fragment.'}
 return $uri.GetLeftPart([UriPartial]::Authority).TrimEnd('/')
}
function Assert-ReleaseApiRoute([string]$Method,[string]$Route){
 if(($Method -ceq 'POST' -and $Route -cin @('/api/login','/api/admin/releases')) -or ($Method -ceq 'GET' -and $Route -ceq '/api/admin/releases')){return}
 throw 'This pipeline may only sign in, list releases, and register releases. Assignment and enable/disable routes are prohibited.'
}
function Invoke-ReleaseApi([string]$Origin,[string]$Method,[string]$Route,[string]$Token='',$Body=$null){
 Assert-ReleaseApiRoute $Method $Route
 $headers=@{Origin=$Origin;Accept='application/json'}
 if($Token){$headers.Authorization='Bearer '+$Token}
 $args=@{Uri=($Origin+$Route);Method=$Method;Headers=$headers;UseBasicParsing=$true;TimeoutSec=30;MaximumRedirection=0;ErrorAction='Stop'}
 $bytes=$null
 if($null -ne $Body){$bytes=[Text.Encoding]::UTF8.GetBytes(($Body|ConvertTo-Json -Compress -Depth 10));$args.Body=$bytes;$args.ContentType='application/json; charset=utf-8'}
 try{
  $response=Invoke-WebRequest @args
  if($response.StatusCode -lt 200 -or $response.StatusCode -ge 300){throw 'Unexpected HTTP result.'}
  $parsed=ConvertFrom-Json -InputObject $response.Content
  return [pscustomobject]@{Status=[int]$response.StatusCode;Data=$parsed;Content=$response.Content}
 }catch{
  $status=0
  if($_.Exception.Response){try{$status=[int]$_.Exception.Response.StatusCode}catch{}}
  $safe=[System.InvalidOperationException]::new("Dashboard $Method $Route failed (HTTP $status). Credentials and response bodies are not logged.")
  $safe.Data['HttpStatus']=$status
  throw $safe
 }finally{if($null -ne $bytes){[Array]::Clear($bytes,0,$bytes.Length)};$args=$null;$Body=$null}
}
function Get-ReleaseCredentialPath([string]$Origin){
 return Join-Path $env:LOCALAPPDATA ('MillitopReleasePipeline\credentials\'+(Get-TextHash $Origin)+'.clixml')
}
function Protect-CredentialDirectory([string]$Path){
 New-Item -ItemType Directory -Path $Path -Force|Out-Null
 $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
 $acl=New-Object Security.AccessControl.DirectorySecurity
 $acl.SetOwner($sid);$acl.SetAccessRuleProtection($true,$false)
 foreach($identity in @($sid,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'))){
  $rule=[Security.AccessControl.FileSystemAccessRule]::new($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
  $acl.AddAccessRule($rule)
 }
 Set-Acl -LiteralPath $Path -AclObject $acl
}
function Connect-ReleaseDashboard([string]$Origin,[pscredential]$Credential){
 $password=$null;$body=$null
 try{
  $password=$Credential.GetNetworkCredential().Password
  $body=@{email=$Credential.UserName;password=$password}
  $r=Invoke-ReleaseApi $Origin 'POST' '/api/login' '' $body
  if($r.Data.accessToken -isnot [string] -or [string]::IsNullOrWhiteSpace($r.Data.accessToken)){throw 'Dashboard login did not return an access token.'}
  $session=[pscustomobject]@{Token=[string]$r.Data.accessToken;ExpiresAt=[long]$r.Data.expiresAt}
  $check=Invoke-ReleaseApi $Origin 'GET' '/api/admin/releases' $session.Token
  if(-not $check.Content.TrimStart().StartsWith('[')){throw 'Unexpected release-list response. No release was created.'}
  return $session
 }finally{$password=$null;$body=$null}
}
function Get-RegisteredReleases([string]$Origin,[string]$Token){
 $r=Invoke-ReleaseApi $Origin 'GET' '/api/admin/releases' $Token
 if(-not $r.Content.TrimStart().StartsWith('[')){throw 'Unexpected release-list schema.'}
 return @($r.Data|Where-Object{$null -ne $_})
}
function Get-NextReleaseBuild($Rows,$LocalStates,[int]$Minimum){
 [long]$maximum=[Math]::Max(0,$Minimum-1)
 foreach($row in @($Rows)+@($LocalStates)){
  if($null -eq $row){continue}
  [long]$n=0
  if(-not [long]::TryParse([string]$row.build,[ref]$n) -or $n -lt 1 -or $n -gt 2147483647){throw 'Invalid build number in registry or local journal.'}
  if($n -gt $maximum){$maximum=$n}
 }
 if($maximum -ge 2147483647){throw 'Build number range exhausted.'}
 return [int]($maximum+1)
}
function Compare-ReleaseVersion([string]$A,[string]$B){
 if($A -notmatch '^\d+\.\d+\.\d+$' -or $B -notmatch '^\d+\.\d+\.\d+$'){throw 'Expected three-part release versions.'}
 $ap=$A.Split('.');$bp=$B.Split('.')
 for($i=0;$i -lt 3;$i++){
  $left=[long]$ap[$i];$right=[long]$bp[$i]
  if($left -gt $right){return 1};if($left -lt $right){return -1}
 }
 return 0
}
function Get-RowValue($Row,[string]$Snake,[string]$Camel){
 if($Row.PSObject.Properties[$Snake]){return $Row.$Snake}
 if($Row.PSObject.Properties[$Camel]){return $Row.$Camel}
 throw "Release-list response lacks $Snake/$Camel. No existing release was edited."
}
function Assert-ReleaseMatch($Row,$Metadata){
 if([string]$Row.version -cne [string]$Metadata.version -or [int]$Row.build -ne [int]$Metadata.build -or
    [string](Get-RowValue $Row 'sha256' 'sha256') -ine [string]$Metadata.sha256 -or
    [long](Get-RowValue $Row 'size_bytes' 'sizeBytes') -ne [long]$Metadata.sizeBytes -or
    [string](Get-RowValue $Row 'installer_url' 'installerUrl') -cne [string]$Metadata.installerUrl -or
    [string]$Row.notes -cne [string]$Metadata.notes){throw 'Immutable release conflict. Existing metadata will not be overwritten.'}
 if([string]$Row.id -notmatch '^[0-9a-fA-F-]{36}$'){throw 'Invalid registered release ID.'}
 if($Row.enabled -isnot [bool]){throw 'Release-list response lacks a Boolean enabled state.'}
}
function Get-VerifiedEnvelope([string]$Installer,[string]$Version,[int]$Build){
 $file=Get-Item -LiteralPath $Installer
 $side=$Installer+'.release.json'
 if($file.Extension -ine '.exe' -or (Get-Item -LiteralPath $side).Length -gt 65536){throw 'Invalid local release files.'}
 $envelope=Read-ReleaseJson $side
 if($envelope.protocol -ne 1){throw 'Unsupported envelope.'}
 $payload=[Convert]::FromBase64String($envelope.payload)
 $signature=[Convert]::FromBase64String($envelope.signature)
 $key=[Security.Cryptography.CngKey]::Import([Convert]::FromBase64String($script:ReleasePublicKey),[Security.Cryptography.CngKeyBlobFormat]::EccPublicBlob)
 $verify=[Security.Cryptography.ECDsaCng]::new($key)
 try{
  $verify.HashAlgorithm=[Security.Cryptography.CngAlgorithm]::Sha256
  if(-not $verify.VerifyData($payload,$signature)){throw 'Signed envelope verification failed.'}
  $tampered=[byte[]]$payload.Clone();$tampered[0]=$tampered[0] -bxor 1
  if($verify.VerifyData($tampered,$signature)){throw 'Tamper test failed.'}
 }finally{$verify.Dispose();$key.Dispose()}
 $meta=[Text.Encoding]::UTF8.GetString($payload)|ConvertFrom-Json
 if($meta.product -cne 'MillitopTV' -or $meta.platform -cne 'windows-x64' -or $meta.version -cne $Version -or [int]$meta.build -ne $Build -or
    $meta.sha256 -notmatch '^[a-f0-9]{64}$' -or [long]$meta.sizeBytes -lt 1 -or [long]$meta.sizeBytes -gt 1073741824){throw 'Signed metadata differs from the planned release.'}
 if((Get-FileHash -LiteralPath $Installer -Algorithm SHA256).Hash -ine $meta.sha256 -or $file.Length -ne [long]$meta.sizeBytes){throw 'Installer bytes do not match the signature.'}
 return $meta
}
function Assert-PublisherKeyAccess {
 Add-Type -AssemblyName System.Security
 $path=Join-Path $env:APPDATA 'Millitop-Publisher-Keys\updates-p256-private.dpapi'
 if(-not(Test-Path -LiteralPath $path)){throw 'Existing publisher key unavailable. Run as its original Windows user; do not regenerate the key.'}
 $raw=$null;$key=$null
 try{
  $raw=[Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($path),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
  $key=[Security.Cryptography.CngKey]::Import($raw,[Security.Cryptography.CngKeyBlobFormat]::EccPrivateBlob)
  if([Convert]::ToBase64String($key.Export([Security.Cryptography.CngKeyBlobFormat]::EccPublicBlob)) -cne $script:ReleasePublicKey){throw 'Signing key does not match the installed clients.'}
 }finally{if($raw){[Array]::Clear($raw,0,$raw.Length)};if($key){$key.Dispose()}}
}
function Get-ReleaseFingerprint([string]$Project,$Config,[string]$Toolchain){
 $records=New-Object 'System.Collections.Generic.List[string]'
 $paths=New-Object 'System.Collections.Generic.List[string]'
 foreach($top in @('lib','assets','windows','android','third_party','test','tools')){
  $start=Join-Path $Project $top
  if(-not(Test-Path -LiteralPath $start)){continue}
  $stack=New-Object 'System.Collections.Generic.Stack[string]';$stack.Push($start)
  while($stack.Count -gt 0){
   $directory=$stack.Pop()
   foreach($entry in Get-ChildItem -LiteralPath $directory -Force){
    if(($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Symlinked source detected outside generated directories. Extend/review the fingerprint before releasing.'}
    if($entry.PSIsContainer){
     if($entry.Name -notin @('ephemeral','.dart_tool','.gradle','.kotlin','.cxx','.git','build','backups','.release')){$stack.Push($entry.FullName)}
    }elseif($entry.Name -ne 'local.properties' -and $entry.FullName -notmatch '[\\/]windows[\\/]flutter[\\/]generated_(plugin_registrant\.(cc|h)|plugins\.cmake)$'){$paths.Add($entry.FullName)}
   }
  }
 }
 foreach($name in @('pubspec.yaml','pubspec.lock','analysis_options.yaml','LICENSE')){if(Test-Path -LiteralPath (Join-Path $Project $name)){$paths.Add((Join-Path $Project $name))}}
 foreach($field in @('vcRedist','webView2Installer','sqliteDll')){$paths.Add([string]$Config.$field)}
 foreach($path in ($paths|Sort-Object -Unique)){
  $relative=$path
  if($path.StartsWith($Project+'\',[StringComparison]::OrdinalIgnoreCase)){$relative=$path.Substring($Project.Length+1)}
  $records.Add($relative.Replace('\','/')+' '+(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash)
 }
 $records.Add('toolchain '+$Toolchain)
 return Get-TextHash ($records -join "`n")
}
function Invoke-ReleaseHelper([string]$Project,[string]$Helper,[hashtable]$Parameters,[string]$RunDirectory,[string]$Stage){
 $request=Join-Path $RunDirectory ($Stage+'-request.json')
 $log=Join-Path $RunDirectory ($Stage+'.log')
 Save-ReleaseJson $request @{helper=$Helper;parameters=$Parameters;log=$log;project=$Project}
 $powershell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
 & $powershell -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File (Join-Path $Project 'tools\release-helper-runner.ps1') -RequestPath $request
 $code=$LASTEXITCODE
 if($code -ne 0){throw "$Stage failed (exit $code). Log: $log. Rerun release.cmd to resume; do not manually overwrite artifacts."}
}
