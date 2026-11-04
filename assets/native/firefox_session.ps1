param([Parameter(Mandatory=$true)][string]$RequestPath)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
$started=$false
try{
 $r=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8|ConvertFrom-Json
 $candidates=New-Object 'System.Collections.Generic.List[string]'
 if($r.executable){$candidates.Add([string]$r.executable)}
 foreach($base in @($env:ProgramFiles,${env:ProgramFiles(x86)},$env:LOCALAPPDATA)){
  if($base){$candidates.Add((Join-Path $base 'Mozilla Firefox\firefox.exe'));$candidates.Add((Join-Path $base 'Programs\Mozilla Firefox\firefox.exe'))}
 }
 foreach($reg in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\firefox.exe','HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\firefox.exe')){
  if(Test-Path $reg){$value=(Get-Item $reg).GetValue('');if($value){$candidates.Add([string]$value)}}
 }
 if($r.managedOnly){
  if(-not $r.executable){throw 'Managed browser executable was not prepared.'}
  $candidates=@([string]$r.executable)
 }
 $exe=$null
 foreach($candidate in $candidates){
  if(-not(Test-Path -LiteralPath $candidate -PathType Leaf)){continue}
  $file=Get-Item -LiteralPath $candidate
  if($file.Name -ine 'firefox.exe' -or $file.VersionInfo.ProductName -notmatch 'Firefox'){continue}
  $signature=Get-AuthenticodeSignature -LiteralPath $file.FullName
  if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)(?:O|CN)=Mozilla Corporation(?:,|$)'){continue}
  $exe=$file.FullName;break
 }
 if($r.action -eq 'detect'){
  [Console]::Out.WriteLine((@{type='detected';executable=$exe}|ConvertTo-Json -Compress));exit 0
 }
 if(-not $exe){throw 'Install desktop Firefox from Mozilla, or select its signed firefox.exe in Settings.'}
 [int]$profileId=$r.profileId
 if($profileId -lt 1){throw 'Invalid household profile.'}
 $url=[string]$r.url
 if($r.action -eq 'addons'){$url='about:addons'}elseif($r.action -ne 'launch'){throw 'Unsupported Firefox action.'}
 if($r.action -eq 'launch'){
  $uri=[Uri]$url
  if(-not $uri.IsAbsoluteUri -or $uri.Scheme -notin @('https','http') -or $uri.UserInfo -or $url -match '[\x00-\x20"\\]'){throw 'Unsafe browser URL.'}
  $url=$uri.AbsoluteUri
 }
 $profile=Join-Path $env:LOCALAPPDATA ($(if($r.purpose -eq 'payments'){'MILLITOPTV\firefox\payments-profile-'}else{'MILLITOPTV\firefox\profile-'})+$profileId)
 New-Item -ItemType Directory -Path $profile -Force|Out-Null
 $prefs=Join-Path $profile 'user.js'
 if(-not(Test-Path -LiteralPath $prefs)){
  [IO.File]::WriteAllText($prefs,"user_pref(`"browser.shell.checkDefaultBrowser`", false);`nuser_pref(`"browser.startup.page`", 0);`n",(New-Object Text.UTF8Encoding($false)))
 }
 Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class MillitopFirefoxWindows {
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr h,int command);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd,uint msg,UIntPtr wParam,IntPtr lParam);
 }
 '@
 $before=@(Get-Process -Name firefox -ErrorAction SilentlyContinue|ForEach-Object{$_.Id})
 $fullscreenApp=($r.appFullscreen -eq $true -and $r.action -eq 'launch')
 if($fullscreenApp){
  $arguments='-no-remote -profile "'+$profile+'" -kiosk "'+$url+'"'
 }else{
  $arguments='-no-remote -profile "'+$profile+'" -new-window "'+$url+'"'
 }
 $initial=Start-Process -FilePath $exe -ArgumentList $arguments -PassThru
 $started=$true
 $owned=New-Object 'System.Collections.Generic.HashSet[int]'
 [void]$owned.Add($initial.Id)
 $births=@{};$births[$initial.Id]=$initial.StartTime.Ticks
 function Get-OwnedWindows {
  $all=@(Get-CimInstance Win32_Process -Filter "Name='firefox.exe'")
  for($pass=0;$pass -lt 6;$pass++){
   foreach($p in $all){
    if($owned.Contains([int]$p.ParentProcessId) -and $births.ContainsKey([int]$p.ParentProcessId) -and [int]$p.ProcessId -notin $before){
     $parent=Get-Process -Id $p.ParentProcessId -ErrorAction SilentlyContinue
     $candidateProcess=Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
     if($parent -and $parent.StartTime.Ticks -eq $births[[int]$p.ParentProcessId] -and $candidateProcess -and $candidateProcess.Path -ieq $exe -and $candidateProcess.StartTime -ge $initial.StartTime){
      [void]$owned.Add([int]$p.ProcessId)
      if(-not $births.ContainsKey([int]$p.ProcessId)){$births[[int]$p.ProcessId]=$candidateProcess.StartTime.Ticks}
     }
    }
   }
  }
  foreach($id in @($owned)){
   $p=Get-Process -Id $id -ErrorAction SilentlyContinue
   if($p -and $births.ContainsKey([int]$id) -and $p.StartTime.Ticks -eq $births[[int]$id] -and $p.Path -ieq $exe -and $p.MainWindowHandle -ne 0 -and [MillitopFirefoxWindows]::IsWindowVisible($p.MainWindowHandle)){$p}
  }
 }
 $deadline=(Get-Date).AddSeconds(45)
 $windows=@()
 do{Start-Sleep -Milliseconds 400;$windows=@(Get-OwnedWindows)}while($windows.Count -eq 0 -and (Get-Date) -lt $deadline)
 if($windows.Count -eq 0){throw 'Firefox started but its window was not confirmed. Close that Firefox window before retrying.'}
 [void][MillitopFirefoxWindows]::ShowWindowAsync($windows[0].MainWindowHandle,3)
 [void][MillitopFirefoxWindows]::SetForegroundWindow($windows[0].MainWindowHandle)
 [Console]::Out.WriteLine((@{type='ready';pid=$windows[0].Id}|ConvertTo-Json -Compress))
 $missing=0
 $stopSignal=Join-Path (Split-Path -Parent $RequestPath) 'close-viewing.signal'
 $closingRequested=$false
 $closeDeadline=$null
 while($missing -lt 4){
  Start-Sleep -Milliseconds 500
  $visible=@(Get-OwnedWindows)
  if((Test-Path -LiteralPath $stopSignal -PathType Leaf) -and -not $closingRequested){
   $closingRequested=$true;$closeDeadline=(Get-Date).AddSeconds(15)
   foreach($window in $visible){
    # Only the Firefox windows already owned by this helper are requested to close.
    if($window.Path -ieq $exe -and $window.StartTime -ge $initial.StartTime){
     [void][MillitopFirefoxWindows]::PostMessage($window.MainWindowHandle,[uint32]16,[UIntPtr]::Zero,[IntPtr]::Zero)
     [void]$window.CloseMainWindow()
    }
   }
  }
  if($visible.Count -eq 0){$missing++}else{$missing=0}
  if($closingRequested -and (Get-Date) -gt $closeDeadline -and $missing -eq 0){
   foreach($window in $visible){
    if($window.Path -ieq $exe -and $window.StartTime -ge $initial.StartTime){
     try{Stop-Process -Id $window.Id -Force -ErrorAction Stop}catch{}
    }
   }
   Start-Sleep -Milliseconds 1200
   $visible=@(Get-OwnedWindows)
   if($visible.Count -gt 0){throw 'Firefox did not accept the viewing-timer close request. No unrelated browser was terminated.'}
   $missing=4
  }
 }
 [Console]::Out.WriteLine('{"type":"closed"}')
 exit 0
}catch{
 [Console]::Out.WriteLine((@{type='error';started=$started;message=$_.Exception.Message}|ConvertTo-Json -Compress))
 exit 1
}
