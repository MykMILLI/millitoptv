param([Parameter(Mandatory=$true)][string]$RequestPath)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
function Emit([string]$Type,[string]$Message,[int]$Percent=-1){[Console]::Out.WriteLine((@{type=$Type;message=$Message;percent=$Percent}|ConvertTo-Json -Compress))}
function Mozilla-Signed([string]$Path){
 if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $false}
 $signature=Get-AuthenticodeSignature -LiteralPath $Path
 return $signature.Status -eq 'Valid' -and $signature.SignerCertificate.Subject -match '(?:^|,\s*)(?:O|CN)=Mozilla Corporation(?:,|$)'
}
function Write-Json([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 15),(New-Object Text.UTF8Encoding($false)))}
function Download-Firefox([string]$Path){
 [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
 $request=[Net.HttpWebRequest]::Create('https://download.mozilla.org/?product=firefox-latest-ssl&os=win64&lang=en-US')
 $request.Timeout=30000;$request.ReadWriteTimeout=30000;$request.UserAgent='MillitopTV Browser Provisioning'
 $response=$null;$inputStream=$null;$outputStream=$null
 try{
  $response=$request.GetResponse()
  if($response.ResponseUri.Scheme -ne 'https'){throw 'Firefox download did not end on HTTPS.'}
  [long]$total=$response.ContentLength
  if($total -gt 536870912){throw 'Unexpected Firefox installer size.'}
  $inputStream=$response.GetResponseStream();$outputStream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  $buffer=New-Object byte[] 131072;[long]$received=0;[long]$last=0;$clock=[Diagnostics.Stopwatch]::StartNew()
  while(($count=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0){
   $received+=$count;if($received -gt 536870912 -or $clock.Elapsed.TotalMinutes -gt 10){throw 'Browser download limit exceeded.'}
   $outputStream.Write($buffer,0,$count)
   if($received-$last -ge 1048576){$last=$received;$percent=-1;if($total -gt 0){$percent=[Math]::Min(100,[int](100*$received/$total))};Emit 'progress' 'Downloading official Firefox...' $percent}
  }
  $outputStream.Flush($true)
 }finally{if($outputStream){$outputStream.Dispose()};if($inputStream){$inputStream.Dispose()};if($response){$response.Close()}}
}
function Active-Extensions([string]$Profile,$Required){
 if($Required.Count -eq 0){return $true}
 $path=Join-Path $Profile 'extensions.json'
 try{
  if(-not(Test-Path -LiteralPath $path)){return $false}
  if((Get-Item -LiteralPath $path).Length -gt 8388608){return $false}
  $data=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
  foreach($extension in $Required){
   $found=@($data.addons|Where-Object{$_.id -ceq $extension.id -and $_.active -eq $true -and -not $_.appDisabled -and -not $_.userDisabled})
   if($found.Count -ne 1){return $false}
  }
  return $true
 }catch{return $false}
}
$lock=$null;$bootstrap=$null;$extractor=$null;$stage=$null;$browserMayBeOpen=$false
try{
 $r=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8|ConvertFrom-Json
 [int]$profileId=$r.profileId;if($profileId -lt 1){throw 'Invalid household profile.'}
 if($r.purpose -notin @('media','payments')){throw 'Unsupported browser purpose.'}
 $purpose=[string]$r.purpose
 $base=Join-Path $env:LOCALAPPDATA 'MILLITOPTV\managed-browser'
 $root=Join-Path $base $purpose;$current=Join-Path $root 'current';$exe=Join-Path $current 'firefox.exe'
 $profile=Join-Path $env:LOCALAPPDATA ('MILLITOPTV\firefox\'+$(if($purpose -eq 'payments'){'payments-profile-'}else{'profile-'})+$profileId)
 $required=@()
 if($purpose -eq 'media'){
  $manifest=Get-Content -LiteralPath $r.manifest -Raw -Encoding UTF8|ConvertFrom-Json
  $required=@($manifest.extensions)
  if($manifest.protocol -ne 1 -or $required.Count -ne 2 -or @($required|Where-Object{$_.slug -notin @('adblocker-ultimate','sponsorblock')}).Count -ne 0 -or @($required.id|Select-Object -Unique).Count -ne 2){throw 'Unexpected required-extension manifest.'}
  foreach($extension in $required){
   if(-not $extension.id -or ([string]$extension.id).Length -gt 200 -or ([string]$extension.id) -match '[\x00-\x20]'){throw 'Invalid extension ID.'}
   $uri=[Uri]$extension.installUrl
   if($uri.Scheme -ne 'https' -or $uri.Host -ne 'addons.mozilla.org' -or $uri.UserInfo){throw 'Extension source must be Mozilla Add-ons HTTPS.'}
  }
 }
 $marker=Join-Path $profile 'millitop-browser-ready.json'
 $installed=Mozilla-Signed $exe
 $existingSessions=@(Get-CimInstance Win32_Process -Filter "Name='firefox.exe'"|Where-Object{$_.ExecutablePath -and $_.ExecutablePath.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)})
 if($r.action -eq 'inspect'){
  [Console]::Out.WriteLine((@{type='inspected';installed=$installed;sessionActive=($existingSessions.Count -gt 0);executable=$(if($installed){$exe}else{$null});ready=($installed -and (Test-Path -LiteralPath $marker) -and (Active-Extensions $profile $required))}|ConvertTo-Json -Compress));exit 0
 }
 if($r.action -ne 'ensure' -or $r.consent -ne $true){throw 'Browser setup requires the user-approved first-use action.'}
 New-Item -ItemType Directory -Force -Path $base,$root,$profile|Out-Null
 try{$lock=[IO.File]::Open((Join-Path $base 'setup.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{throw 'Another Millitop browser setup is running. Wait and retry.'}
 $active=@(Get-CimInstance Win32_Process -Filter "Name='firefox.exe'"|Where-Object{$_.ExecutablePath -and $_.ExecutablePath.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)})
 if($active.Count -gt 0){$browserMayBeOpen=$true;throw 'Close the Millitop Firefox window before preparing another session. Personal Firefox is not changed.'}
 if(-not $installed){
  if(Test-Path -LiteralPath $current){throw 'Managed Firefox is incomplete or its signature failed. Preserve the directory and contact support; no personal installation was overwritten.'}
  $cache=Join-Path $base 'cache';New-Item -ItemType Directory -Force -Path $cache|Out-Null
  $cached=@(Get-ChildItem -LiteralPath $cache -File -Filter 'FirefoxSetup-*.exe'|Where-Object{$_.LastWriteTime -gt (Get-Date).AddDays(-7) -and $_.LastWriteTime -lt (Get-Date).AddMinutes(5)}|Sort-Object LastWriteTime -Descending)
  $installer=$null
  foreach($file in $cached){if(Mozilla-Signed $file.FullName){$installer=$file.FullName;break}}
  if(-not $installer){
   $installer=Join-Path $cache ('FirefoxSetup-'+[Guid]::NewGuid().ToString('N')+'.exe')
   Emit 'progress' 'Firefox is required. Downloading the official Mozilla package...'
   Download-Firefox $installer
  }
  if(-not(Mozilla-Signed $installer)){throw 'Mozilla installer signature verification failed. Nothing executed.'}
  # FIREFOX_STANDARD_INSTALL_V1: use the measured Mozilla installation path, not /ExtractDir.
  Emit 'progress' 'Verified Mozilla signature. Installing the app-owned Firefox browser...'
  $installInfo=New-Object Diagnostics.ProcessStartInfo
  $installInfo.FileName=$installer
  $installInfo.UseShellExecute=$false
  $installInfo.Arguments=@(
   '/S'
   ('/InstallDirectoryPath="'+$current+'"')
   '/DesktopShortcut=false'
   '/StartMenuShortcut=false'
   '/TaskbarShortcut=false'
   '/PrivateBrowsingShortcut=false'
   '/MaintenanceService=false'
   '/RegisterDefaultAgent=false'
  ) -join ' '
  $extractor=New-Object Diagnostics.Process
  $extractor.StartInfo=$installInfo
  if(-not $extractor.Start()){throw 'Windows did not start the verified Mozilla installer.'}
  if(-not $extractor.WaitForExit(240000)){throw ('Firefox installation is still running after four minutes. Do not start another installer. PID: '+$extractor.Id)}
  $installCode=$extractor.ExitCode
  Emit 'progress' ('Mozilla installer returned exit code '+$installCode)
  if($installCode -eq 3010){throw 'Firefox installation requested a Windows restart. Restart Windows, then open the web app again.'}
  if($installCode -ne 0){throw ('Firefox installation failed with exit code '+$installCode+'. The signed installer cache and profile data were preserved.')}
  for($wait=0;$wait -lt 30;$wait++){
   if(Test-Path -LiteralPath $exe -PathType Leaf){break}
   Start-Sleep -Milliseconds 500
  }
  if(-not(Mozilla-Signed $exe)){throw ('Firefox installation exited successfully but the expected Mozilla-signed executable is missing or invalid: '+$exe)}
  if(-not(Test-Path -LiteralPath (Join-Path $current 'xul.dll')) -or -not(Test-Path -LiteralPath (Join-Path $current 'application.ini'))){throw 'Firefox installation did not produce the complete application files. Required extensions and website launch remain blocked.'}
 }
 $settings=[ordered]@{}
 if($purpose -eq 'payments'){$settings['*']=[ordered]@{installation_mode='blocked'}}else{
  foreach($extension in $required){$settings[[string]$extension.id]=[ordered]@{installation_mode='force_installed';install_url=[string]$extension.installUrl;updates_disabled=$false}}
 }
 $policies=[ordered]@{policies=[ordered]@{ExtensionSettings=$settings}}
 $distribution=Join-Path $current 'distribution';New-Item -ItemType Directory -Force -Path $distribution|Out-Null
 $policyPath=Join-Path $distribution 'policies.json'
 $policyJson=$policies|ConvertTo-Json -Depth 15 -Compress
 [IO.File]::WriteAllText($policyPath,$policyJson,(New-Object Text.UTF8Encoding($false)))
 $hash=(Get-FileHash -LiteralPath $policyPath -Algorithm SHA256).Hash
 $version=(Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
 $ready=$false
 if(Test-Path -LiteralPath $marker){try{$saved=Get-Content -LiteralPath $marker -Raw -Encoding UTF8|ConvertFrom-Json;$ready=$saved.policyHash -ceq $hash -and $saved.version -ceq $version -and (Active-Extensions $profile $required)}catch{}}
 if(-not $ready -and $required.Count -gt 0){
  Emit 'progress' 'Preparing AdBlocker Ultimate and SponsorBlock for this profile. The selected website has not opened yet.'
  $before=@(Get-Process -Name firefox -ErrorAction SilentlyContinue|ForEach-Object{$_.Id})
  $bootstrap=Start-Process -FilePath $exe -ArgumentList ('-no-remote -profile "'+$profile+'" -new-window about:blank') -WindowStyle Minimized -PassThru
  $browserMayBeOpen=$true
  $owned=New-Object 'System.Collections.Generic.HashSet[int]';[void]$owned.Add($bootstrap.Id)
  function Owned-Processes {
   $all=@(Get-CimInstance Win32_Process -Filter "Name='firefox.exe'")
   for($pass=0;$pass -lt 6;$pass++){foreach($p in $all){if($owned.Contains([int]$p.ParentProcessId) -and [int]$p.ProcessId -notin $before){[void]$owned.Add([int]$p.ProcessId)}}}
   foreach($id in $owned){$p=Get-Process -Id $id -ErrorAction SilentlyContinue;if($p){$p}}
  }
  $clock=[Diagnostics.Stopwatch]::StartNew();$ready=$false
  while($clock.Elapsed.TotalSeconds -lt 120){
   $processes=@(Owned-Processes)
   if($processes.Count -eq 0){throw 'Firefox setup was closed before required extensions were ready.'}
   if($clock.Elapsed.TotalSeconds -ge 5 -and (Active-Extensions $profile $required)){$ready=$true;break}
   Start-Sleep -Milliseconds 700
  }
  foreach($p in @(Owned-Processes)){if($p.MainWindowHandle -ne 0){[void]$p.CloseMainWindow()}}
  $closeClock=[Diagnostics.Stopwatch]::StartNew()
  while(@(Owned-Processes).Count -gt 0 -and $closeClock.Elapsed.TotalSeconds -lt 30){Start-Sleep -Milliseconds 400}
  if(@(Owned-Processes).Count -gt 0){throw 'Close the Millitop Firefox setup window before retrying. It was not forcibly terminated.'}
  $browserMayBeOpen=$false
  if(-not $ready){throw 'Required extensions were not confirmed active. Check internet access or organizational Firefox policies. The requested website was not opened.'}
 }
 Write-Json $marker @{protocol=1;version=$version;policyHash=$hash;checkedUtc=[DateTime]::UtcNow.ToString('o')}
 [Console]::Out.WriteLine((@{type='prepared';executable=$exe;profile=$profile;purpose=$purpose;extensionsReady=$true}|ConvertTo-Json -Compress))
 exit 0
}catch{[Console]::Out.WriteLine((@{type='error';message=$_.Exception.Message;requiresRecovery=($browserMayBeOpen -or ($extractor -and -not $extractor.HasExited))}|ConvertTo-Json -Compress));exit 1}
finally{if($lock){$lock.Dispose()}}
