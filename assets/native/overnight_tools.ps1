param(
 [ValidateSet('SleepSounds','Support','DisplaysOff','LockScreen','Guard')][string]$Action,
 [int]$ProfileId=1,
 [string]$Url='https://sleep.millitop.net',
 [int]$ParentPid=0,
 [string]$GuardPath
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class MillitopNightPower {
 [DllImport("kernel32.dll", SetLastError=true)] public static extern uint SetThreadExecutionState(uint flags);
 [DllImport("user32.dll", SetLastError=true)] public static extern bool PostMessage(IntPtr hwnd,uint msg,IntPtr w,IntPtr l);
 [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll", SetLastError=true)] public static extern bool LockWorkStation();
 [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr h,int command);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
'@
if($Action -eq 'Guard'){
 if($ParentPid -lt 1 -or -not (Test-Path -LiteralPath $GuardPath -PathType Leaf)){throw 'Invalid overnight lifetime guard.'}
 $parent=Get-Process -Id $ParentPid -ErrorAction Stop
 $birth=$parent.StartTime.Ticks
 try{
  if([MillitopNightPower]::SetThreadExecutionState([uint32]2147483649) -eq 0){throw 'Windows could not enable overnight keep-awake.'}
  [Console]::Out.WriteLine('GUARD_READY')
  while(Test-Path -LiteralPath $GuardPath -PathType Leaf){
   $current=Get-Process -Id $ParentPid -ErrorAction SilentlyContinue
   if(-not $current -or $current.StartTime.Ticks -ne $birth){break}
   Start-Sleep -Seconds 1
  }
 }finally{[void][MillitopNightPower]::SetThreadExecutionState([uint32]2147483648)}
 exit 0
}
if($Action -eq 'DisplaysOff'){
 # Clear any prior "keep-awake" display requirement before monitor power-off.
 [void][MillitopNightPower]::SetThreadExecutionState([uint32]2147483648)
 $requested=$false
 for($i=0;$i -lt 3;$i++){
  try{
   # WM_SYSCOMMAND / SC_MONITORPOWER / 2 => power display off.
   if([MillitopNightPower]::PostMessage([IntPtr]65535,[uint32]274,[IntPtr]61808,[IntPtr]2)){$requested=$true}
  }catch{}
  try{
   $foreground=[MillitopNightPower]::GetForegroundWindow()
   if($foreground -ne [IntPtr]::Zero){
    if([MillitopNightPower]::PostMessage($foreground,[uint32]274,[IntPtr]61808,[IntPtr]2)){$requested=$true}
   }
  }catch{}
  Start-Sleep -Milliseconds 250
 }
 if(-not $requested){throw 'Windows did not accept the display-off request.'}
 Write-Output 'Display-off request sent; physical monitor behavior must be verified.'
 exit 0
}
if($Action -eq 'LockScreen'){
 if(-not [MillitopNightPower]::LockWorkStation()){
  throw 'Windows did not confirm the lock-screen request.'
 }
 Write-Output 'Lock screen requested.'
 exit 0
}
if($ProfileId -lt 1){throw 'Invalid profile.'}
if($Action -eq 'Support'){$Url='https://join.zoho.com'}
$uri=[Uri]$Url
if(-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or $Url -match '[\x00-\x20"\\]'){throw 'Use a safe HTTPS website address.'}
$candidates=@()
foreach($base in @(${env:ProgramFiles(x86)},$env:ProgramFiles,$env:LOCALAPPDATA)){
 if($base){$candidates+=Join-Path $base 'Microsoft\Edge\Application\msedge.exe'}
}
$exe=$null
foreach($candidate in $candidates){
 if(Test-Path -LiteralPath $candidate -PathType Leaf){
  $signature=Get-AuthenticodeSignature -LiteralPath $candidate
  if($signature.Status -eq 'Valid' -and $signature.SignerCertificate.Subject -match '(?:O|CN)=Microsoft Corporation(?:,|$)'){$exe=(Get-Item -LiteralPath $candidate).FullName;break}
 }
}
if(-not $exe){throw 'Microsoft Edge is unavailable or could not be verified. Contact support; your default browser was not changed.'}
$purpose=if($Action -eq 'Support'){'support'}else{'sleep'}
$profile=Join-Path $env:LOCALAPPDATA ('MILLITOPTV\edge-'+$purpose+'-'+$ProfileId)
# Reuse this dedicated profile only. Never close or take over a personal browser.
$existing=@(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object {
 $_.ExecutablePath -ieq $exe -and $_.CommandLine -and $_.CommandLine.IndexOf($profile,[StringComparison]::OrdinalIgnoreCase) -ge 0
})
foreach($item in $existing){
 $p=Get-Process -Id $item.ProcessId -ErrorAction SilentlyContinue
 if($p -and $p.MainWindowHandle -ne 0){
  [void][MillitopNightPower]::ShowWindowAsync($p.MainWindowHandle,9)
  [void][MillitopNightPower]::SetForegroundWindow($p.MainWindowHandle)
  Write-Output 'Existing dedicated window selected.';exit 0
 }
}
New-Item -ItemType Directory -Path $profile -Force | Out-Null
$arguments='--user-data-dir="'+$profile+'" --no-first-run --app="'+$uri.AbsoluteUri+'"'
Start-Process -FilePath $exe -ArgumentList $arguments | Out-Null
Write-Output 'Dedicated browser requested. Use the website controls to start audio or join support.'
