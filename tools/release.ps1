param(
 [string]$Version='',
 [string]$Notes='',
 [switch]$Resume,
 [switch]$NewRelease,
 [switch]$ConfigureDashboardCredential,
 [switch]$ForgetDashboardCredential,
 [switch]$SelfTest,
 [pscredential]$DashboardCredential
)
$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT'){throw 'Run this pipeline on the Windows development PC.'}
. (Join-Path $PSScriptRoot 'release-core.ps1')
$project=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent)).TrimEnd('\')
$config=Read-ReleaseJson (Join-Path $PSScriptRoot 'release.config.json')
$origin=Get-ReleaseOrigin $config.publicOrigin
$credentialPath=Get-ReleaseCredentialPath $origin
if($ForgetDashboardCredential){
 if(Test-Path -LiteralPath $credentialPath){Remove-Item -LiteralPath $credentialPath}
 Write-Host 'Saved dashboard credential removed. The signing key was not changed.'
 return
}
if($ConfigureDashboardCredential){
 Write-Host 'This optionally stores your dashboard login encrypted for this Windows user and computer, outside the project.'
 Write-Host 'It does not store the password in plaintext or save an access token in the project.'
 $credential=Get-Credential -Message "Dashboard administrator for $origin"
 if($null -eq $credential){throw 'Credential setup cancelled.'}
 $session=Connect-ReleaseDashboard $origin $credential
 $consent=Read-Host 'Store this dashboard credential with Windows DPAPI for unattended future release commands? Type SAVE'
 if($consent -cne 'SAVE'){Write-Host 'Login validated; credential was not stored.';return}
 Protect-CredentialDirectory (Split-Path $credentialPath -Parent)
 $credential|Export-Clixml -LiteralPath $credentialPath -Force
 $credential=$null;$session=$null
 Write-Host 'DASHBOARD_CREDENTIAL_CONFIGURED' -ForegroundColor Green
 return
}
if($SelfTest){& (Join-Path $PSScriptRoot 'test-release-pipeline.ps1');return}
if($Resume -and $NewRelease){throw 'Choose -Resume or -NewRelease, not both.'}
if($null -eq $DashboardCredential -and -not(Test-Path -LiteralPath $credentialPath)){throw 'One-time setup required: .\release.cmd -ConfigureDashboardCredential, or pass -DashboardCredential directly to tools/release.ps1. No build or upload started.'}
foreach($entry in (Read-ReleaseJson (Join-Path $PSScriptRoot 'release-helpers\manifest.json')).PSObject.Properties){
 $path=Join-Path $PSScriptRoot ('release-helpers\'+$entry.Name)
 if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine [string]$entry.Value){throw "Bundled helper changed: $($entry.Name). Review/reinstall the pipeline before publishing."}
}
foreach($field in @('innoCompiler','vcRedist','webView2Installer','sqliteDll')){
 $value=[Environment]::ExpandEnvironmentVariables([string]$config.$field)
 if(-not [IO.Path]::IsPathRooted($value)){$value=Join-Path $project $value}
 $config.$field=[IO.Path]::GetFullPath($value)
 if(-not(Test-Path -LiteralPath $config.$field -PathType Leaf)){throw "Configured prerequisite/tool missing: $field"}
}
if([string]$config.serverAlias -notmatch '^[a-zA-Z0-9._-]+$'){throw 'Invalid SSH alias.'}
$stateRoot=Join-Path $project '.release'
$runs=Join-Path $stateRoot 'runs'
New-Item -ItemType Directory -Path $runs -Force|Out-Null
$lock=$null;$run=$null;$state=$null;$candidateState=$null
try{
 try{$lock=[IO.File]::Open((Join-Path $stateRoot 'pipeline.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{throw 'Release lock unavailable. Another run may be active; check project permissions before retrying.'}
 Set-Location -LiteralPath $project
 if($null -ne $DashboardCredential){$credential=$DashboardCredential}else{$credential=Import-Clixml -LiteralPath $credentialPath}
 if($credential -isnot [pscredential]){throw 'Invalid encrypted credential. Reconfigure the dashboard credential.'}
 $session=Connect-ReleaseDashboard $origin $credential
 $rows=@(Get-RegisteredReleases $origin $session.Token)
 foreach($row in $rows){
  $null=Get-RowValue $row 'sha256' 'sha256'
  $null=Get-RowValue $row 'size_bytes' 'sizeBytes'
  $null=Get-RowValue $row 'installer_url' 'installerUrl'
  if($row.enabled -isnot [bool]){throw 'Release API schema lacks Boolean enabled state. Nothing built.'}
 }
 Assert-PublisherKeyAccess
 & ssh -oBatchMode=yes -oStrictHostKeyChecking=yes ([string]$config.serverAlias) 'test -d millitop-tv-dashboard/releases && command -v flock >/dev/null'
 if($LASTEXITCODE -ne 0){throw 'Noninteractive SSH, known host verification, release directory, or server flock support unavailable. Nothing built.'}
 & flutter pub get
 if($LASTEXITCODE -ne 0){throw 'flutter pub get failed.'}
 $toolchainText=@(& flutter --version --machine)
 if($LASTEXITCODE -ne 0){throw 'Could not identify Flutter toolchain.'}
 $toolchain=($toolchainText -join "`n")|ConvertFrom-Json
 $toolchainIdentity=([string]$toolchain.frameworkRevision)+'|'+([string]$toolchain.engineRevision)+'|'+([string]$toolchain.dartSdkVersion)
 $fingerprint=Get-ReleaseFingerprint $project $config $toolchainIdentity
 $activePath=Join-Path $stateRoot 'active.json'
 if(Test-Path -LiteralPath $activePath){
  $active=Read-ReleaseJson $activePath
  if([string]$active.run -notmatch '^[0-9TZ-]+-[0-9a-f]{32}$'){throw 'Invalid active-run pointer.'}
  $candidate=Join-Path $runs ([string]$active.run)
  $candidateState=Read-ReleaseJson (Join-Path $candidate 'state.json')
  if($Resume -or (-not $NewRelease -and -not $candidateState.completed)){
   if(-not $Resume -and $candidateState.fingerprint -cne $fingerprint){throw 'An unfinished release exists, but source/toolchain changed. Use -Resume to finish its existing artifact or -NewRelease to reserve a new build.'}
   if($Version -and $Version -cne [string]$candidateState.version){throw 'Pending release version differs. Use -NewRelease or resume without -Version.'}
   if($Notes -and $Notes.Trim() -cne [string]$candidateState.notes){throw 'Pending release notes are immutable. Use -NewRelease for different notes.'}
   $run=$candidate;$state=$candidateState
   if($state.completed){
    $existing=@($rows|Where-Object{$_.version -ceq $state.version -and [int]$_.build -eq [int]$state.build})
    if($existing.Count -ne 1){throw 'Previously completed release is missing or duplicated in registry. Stop for review.'}
    Assert-ReleaseMatch $existing[0] $state.metadata
    Write-Host "ALREADY_REGISTERED: $($state.version)+$($state.build), ID $($existing[0].id). Existing enabled state unchanged." -ForegroundColor Green
    return
   }
  }
 }elseif($Resume){throw 'No previous pipeline run exists to resume.'}
 if($null -eq $state){
  if(-not $Version){$Version=[string]$config.version}
  if($Version -notmatch '^\d+\.\d+\.\d+$'){throw 'Expected a version such as 1.2.2.'}
  if(-not $Notes){$Notes=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'release-notes.md')).Trim()}
  $Notes=$Notes.Replace("`r`n","`n").Trim()
  if(-not $Notes -or $Notes.Length -gt 12000 -or [Text.Encoding]::UTF8.GetByteCount($Notes) -gt 24000){throw 'Provide nonempty release notes within the API size limit.'}
  foreach($row in $rows){if((Compare-ReleaseVersion $Version ([string]$row.version)) -lt 0){throw 'Requested version is older than a registered release. Set -Version or edit tools/release.config.json.'}}
  if(-not $NewRelease -and $candidateState -and $candidateState.completed -and $candidateState.fingerprint -ceq $fingerprint -and $candidateState.version -ceq $Version -and $candidateState.notes -ceq $Notes){
   $existing=@($rows|Where-Object{$_.version -ceq $Version -and [int]$_.build -eq [int]$candidateState.build})
   if($existing.Count -ne 1){throw 'Completed release missing or duplicated in registry. Stop for review.'}
   Assert-ReleaseMatch $existing[0] $candidateState.metadata
   Write-Host "ALREADY_REGISTERED: $Version+$($candidateState.build), ID $($existing[0].id). No rebuild, re-sign or upload performed." -ForegroundColor Green
   return
  }
  $localStates=@()
  foreach($directory in Get-ChildItem -LiteralPath $runs -Directory){
   $path=Join-Path $directory.FullName 'state.json'
   if(Test-Path -LiteralPath $path){$localStates+=Read-ReleaseJson $path}
  }
  $build=Get-NextReleaseBuild $rows $localStates ([int]$config.minimumBuild)
  $runName=(Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')+'-'+[Guid]::NewGuid().ToString('N')
  $run=Join-Path $runs $runName
  New-Item -ItemType Directory -Path $run|Out-Null
  $state=[pscustomobject]@{version=$Version;build=$build;notes=$Notes;fingerprint=$fingerprint;toolchain=$toolchainIdentity;built=$false;signed=$false;published=$false;completed=$false;installer='';builtSha256='';builtBytes=0;metadata=$null;releaseId='';stage='reserved';error='';createdUtc=[DateTime]::UtcNow.ToString('o')}
  Save-ReleaseJson (Join-Path $run 'state.json') $state
  Save-ReleaseJson $activePath @{run=$runName}
 }
 $statePath=Join-Path $run 'state.json'
 Write-Host "RELEASE: $($state.version)+$($state.build)" -ForegroundColor Cyan
 Write-Host "Journal/logs: $run"
 $buildResult=Join-Path $run 'build-result.json'
 if(-not $state.built){
  if(Test-Path -LiteralPath $buildResult){
   $result=Read-ReleaseJson $buildResult
   if($result.version -cne $state.version -or [int]$result.build -ne [int]$state.build -or -not(Test-Path -LiteralPath $result.installer)){throw 'Incomplete or mismatched build receipt.'}
   if($state.fingerprint -cne (Get-ReleaseFingerprint $project $config $state.toolchain)){throw 'Source changed since the reserved build. Use -NewRelease instead of rebuilding this version/build.'}
   $state.installer=[string]$result.installer;$state.built=$true
  }else{
   if($state.fingerprint -cne (Get-ReleaseFingerprint $project $config $state.toolchain)){throw 'Source changed before build. Use -NewRelease.'}
   if($state.toolchain -cne $toolchainIdentity){throw 'Toolchain changed before build. Use -NewRelease.'}
   $state.stage='building';Save-ReleaseJson $statePath $state
   Invoke-ReleaseHelper $project (Join-Path $PSScriptRoot 'release-helpers\build.ps1') @{
    Project=$project;VcRedist=$config.vcRedist;WebView2Installer=$config.webView2Installer;
    SqliteDll=$config.sqliteDll;InnoCompiler=$config.innoCompiler;Version=$state.version;Build=[int]$state.build;ResultFile=$buildResult
   } $run 'build'
   $result=Read-ReleaseJson $buildResult
   if($result.version -cne $state.version -or [int]$result.build -ne [int]$state.build -or -not(Test-Path -LiteralPath $result.installer)){throw 'Build receipt missing/mismatched.'}
   if($state.fingerprint -cne (Get-ReleaseFingerprint $project $config $state.toolchain)){throw 'Source changed during build. Installer will not be signed or published. Use -NewRelease.'}
   $state.installer=[string]$result.installer;$state.built=$true
  }
  $buildMeta=Read-ReleaseJson ([string]$result.metadata)
  if($buildMeta.version -cne $state.version -or [int]$buildMeta.build -ne [int]$state.build -or
     (Get-Item -LiteralPath $state.installer).Length -ne [long]$buildMeta.sizeBytes -or
     (Get-FileHash -LiteralPath $state.installer -Algorithm SHA256).Hash -ine [string]$buildMeta.sha256){throw 'Build output differs from the compiler receipt. Nothing signed.'}
  $state.builtSha256=[string]$buildMeta.sha256;$state.builtBytes=[long]$buildMeta.sizeBytes
  $state.stage='built';Save-ReleaseJson $statePath $state
 }
 if(-not $state.builtSha256 -or (Get-Item -LiteralPath $state.installer).Length -ne [long]$state.builtBytes -or
    (Get-FileHash -LiteralPath $state.installer -Algorithm SHA256).Hash -ine [string]$state.builtSha256){throw 'Built installer was modified. Nothing will be signed or published.'}
 if(-not $state.signed -and -not(Test-Path -LiteralPath ($state.installer+'.release.json'))){
  $state.stage='signing';Save-ReleaseJson $statePath $state
  Invoke-ReleaseHelper $project (Join-Path $PSScriptRoot 'release-helpers\sign.ps1') @{
   Installer=$state.installer;Version=$state.version;Build=[int]$state.build
  } $run 'sign'
 }
 $signed=Get-VerifiedEnvelope $state.installer $state.version ([int]$state.build)
 $state.signed=$true;$state.stage='signed';Save-ReleaseJson $statePath $state
 # Verify again on resume; the publisher detects an existing identical remote pair.
 $state.stage='publishing';Save-ReleaseJson $statePath $state
 Invoke-ReleaseHelper $project (Join-Path $PSScriptRoot 'release-helpers\publish.ps1') @{
  Installer=$state.installer;PublicOrigin=$origin;ServerAlias=$config.serverAlias;Notes=$state.notes
 } $run 'publish'
 $metadata=Read-ReleaseJson (Join-Path (Split-Path $state.installer -Parent) 'dashboard-release-metadata.json')
 $expectedUrl=$origin+'/downloads/Millitop-TV-'+$state.version+'-build-'+$state.build+'-'+([string]$signed.sha256).Substring(0,12)+'-windows-x64.exe'
 if($metadata.version -cne $state.version -or [int]$metadata.build -ne [int]$state.build -or $metadata.sha256 -cne $signed.sha256 -or [long]$metadata.sizeBytes -ne [long]$signed.sizeBytes -or $metadata.installerUrl -cne $expectedUrl -or $metadata.notes -cne $state.notes){throw 'Published metadata differs from the signed release plan.'}
 $state.metadata=$metadata;$state.published=$true;$state.stage='registering';Save-ReleaseJson $statePath $state
 if([long]$session.ExpiresAt -le ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+60)){$session=Connect-ReleaseDashboard $origin $credential}
 $rows=@(Get-RegisteredReleases $origin $session.Token)
 $matching=@($rows|Where-Object{$_.version -ceq $state.version -and [int]$_.build -eq [int]$state.build})
 $created=$false
 if($matching.Count -gt 1){throw 'Duplicate release rows. Stop for review.'}
 if($matching.Count -eq 0){
  try{
   $null=Invoke-ReleaseApi $origin 'POST' '/api/admin/releases' $session.Token $metadata
   $created=$true
  }catch{
   # A timeout/409 may mean the first request committed; never blindly insert twice.
   $original=$_.Exception.Message
   $rows=@(Get-RegisteredReleases $origin $session.Token)
   $matching=@($rows|Where-Object{$_.version -ceq $state.version -and [int]$_.build -eq [int]$state.build})
   if($matching.Count -ne 1){throw $original}
  }
  $rows=@(Get-RegisteredReleases $origin $session.Token)
  $matching=@($rows|Where-Object{$_.version -ceq $state.version -and [int]$_.build -eq [int]$state.build})
 }
 if($matching.Count -ne 1){throw 'Registration could not be confirmed by a fresh registry read.'}
 $registered=$matching[0]
 Assert-ReleaseMatch $registered $metadata
 if($created -and $registered.enabled){throw 'New release unexpectedly enabled. Stop and pause it in the dashboard; the pipeline has assigned no devices.'}
 $state.releaseId=[string]$registered.id;$state.completed=$true;$state.stage='registered';$state.error=''
 Save-ReleaseJson $statePath $state
 $receipt=[ordered]@{version=$state.version;build=$state.build;releaseId=$state.releaseId;enabled=$registered.enabled;installerUrl=$metadata.installerUrl;sha256=$metadata.sha256;sizeBytes=$metadata.sizeBytes;notes=$metadata.notes;pipelineCreatedAssignments=$false;journal=$run}
 Save-ReleaseJson (Join-Path $stateRoot 'latest-release.json') $receipt
 Write-Host ''
 if(-not $registered.enabled){Write-Host 'RELEASE_READY_FOR_ASSIGNMENT' -ForegroundColor Green}else{Write-Host 'RELEASE_ALREADY_REGISTERED_AND_ENABLED: Existing deployment state left unchanged.' -ForegroundColor Yellow}
 $receipt|ConvertTo-Json -Depth 5
 Write-Host 'No devices were assigned and no enable/disable request was sent. Assign and enable only your chosen pilot in the dashboard.'
}catch{
 $safe=$_.Exception.Message
 if($null -ne $state -and $null -ne $run -and -not $state.completed){
  $state.error=$safe
  try{Save-ReleaseJson (Join-Path $run 'state.json') $state}catch{}
 }
 Write-Host ('RELEASE_PIPELINE_STOPPED: '+$safe) -ForegroundColor Red
 Write-Host 'Completed artifacts are retained. Rerun release.cmd to resume unchanged inputs, or use -Resume explicitly for the existing artifact. Do not overwrite files manually.'
 exit 1
}finally{
 if($lock){$lock.Dispose()}
 $credential=$null;$session=$null
}
