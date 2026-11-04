param([Parameter(Mandatory=$true)][string]$RequestPath)
$ErrorActionPreference='Stop'
$state=''
function Write-BootLog([string]$Message){
 try{
  $line=(Get-Date).ToUniversalTime().ToString('o')+' '+$Message+[Environment]::NewLine
  [IO.File]::AppendAllText((Join-Path $state 'bootstrap.log'),$line,[Text.Encoding]::UTF8)
 }catch{}
}
try{
 $root=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'MILLITOPTV\updates'))+'\'
 $requestFull=[IO.Path]::GetFullPath($RequestPath)
 $state=[IO.Path]::GetDirectoryName($requestFull)
 if(-not ($state+'\').StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){$state='';throw 'Invalid request directory.'}
 if(-not (Test-Path -LiteralPath $state -PathType Container)){$state='';throw 'Request directory missing.'}
 Write-BootLog ('Bootstrap entered before reading request. PID '+$PID)
 $r=Get-Content -LiteralPath $requestFull -Raw|ConvertFrom-Json
 if([IO.Path]::GetFullPath([string]$r.stateDirectory) -ine $state){throw 'Request/state directory mismatch.'}
 Write-BootLog ('Windows user: '+[Security.Principal.WindowsIdentity]::GetCurrent().Name)
 $expectedWorker=Join-Path $root 'update_worker.ps1'
 if([IO.Path]::GetFullPath([string]$r.worker) -ine [IO.Path]::GetFullPath($expectedWorker)){throw 'Unexpected worker path.'}
 $parameters=@{
  Action='Install';EnvelopePath=[string]$r.envelopePath;
  ExpectedVersion=[string]$r.version;ExpectedBuild=[int]$r.build;
  ExpectedHash=[string]$r.sha256;ExpectedBytes=[long]$r.sizeBytes;
  InstallerPath=[string]$r.installerPath;AppPid=[int]$r.appPid;
  AppExe=[string]$r.appExe;StateDirectory=$state
 }
 Write-BootLog ('Invoking worker with typed parameters; target PID '+$parameters.AppPid)
 & $expectedWorker @parameters
 $code=$LASTEXITCODE
 Write-BootLog ('Worker returned '+$code)
 if($code -ne 0 -and -not (Test-Path (Join-Path $state 'result.json'))){throw "Worker exited with code $code before writing a result."}
 exit $code
}catch{
 $message=$_.Exception.Message
 Write-BootLog ('ERROR: '+$message)
 if($state -and (Test-Path -LiteralPath $state -PathType Container)){
  try{
   $result=Join-Path $state 'result.json'
   if(-not (Test-Path -LiteralPath $result)){
    $json=@{installerExitCode=-1;error=$message;stage='bootstrap'}|ConvertTo-Json -Compress
    [IO.File]::WriteAllText($result,$json,(New-Object Text.UTF8Encoding($false)))
   }
  }catch{}
 }
 try{[Console]::Error.WriteLine($message)}catch{}
 exit 1
}
