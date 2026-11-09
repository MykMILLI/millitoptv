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
 $dock=$null
 if($r.dock -and $r.action -eq 'launch' -and $r.purpose -ne 'payments'){
  $dock=$r.dock
  if([int]$dock.hostPid -lt 1){throw 'Docked browser needs the app process.'}
 }
 # Docked sessions hide Firefox's own tabs and toolbars; MILLITOP's top bar
 # provides Back, the sleep timer and pop-out. Normal sessions keep them.
 $chromeDir=Join-Path $profile 'chrome'
 $userChrome=Join-Path $chromeDir 'userChrome.css'
 $marker='/* MILLITOPTV docked */'
 if($dock){
  $text=[IO.File]::ReadAllText($prefs)
  if($text -notmatch 'legacyUserProfileCustomizations'){
   [IO.File]::AppendAllText($prefs,"user_pref(`"toolkit.legacyUserProfileCustomizations.stylesheets`", true);`n",(New-Object Text.UTF8Encoding($false)))
  }
  New-Item -ItemType Directory -Path $chromeDir -Force|Out-Null
  [IO.File]::WriteAllText($userChrome,"$marker`n#navigator-toolbox{visibility:collapse !important;}`n#titlebar{display:none !important;}`n",(New-Object Text.UTF8Encoding($false)))
 }elseif((Test-Path -LiteralPath $userChrome) -and ([IO.File]::ReadAllText($userChrome)).StartsWith($marker)){
  Remove-Item -LiteralPath $userChrome -Force -ErrorAction SilentlyContinue
 }
 Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class MillitopFirefoxWindows {
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr h,int command);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd,uint msg,UIntPtr wParam,IntPtr lParam);
 [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
 [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
 delegate bool EnumProc(IntPtr h, IntPtr l);
 [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
 [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
 [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
 [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
 [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT p);
 [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
 [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
 [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] static extern IntPtr GetLongPtr(IntPtr h, int i);
 [DllImport("user32.dll", EntryPoint="SetWindowLongPtrW")] static extern IntPtr SetLongPtr(IntPtr h, int i, IntPtr v);
 public static IntPtr FindHost(int pid) {
  IntPtr found = IntPtr.Zero;
  EnumWindows((h, l) => {
   uint owner; GetWindowThreadProcessId(h, out owner);
   if (owner != (uint)pid) return true;
   var name = new System.Text.StringBuilder(64);
   GetClassName(h, name, 64);
   if (name.ToString() == "FLUTTER_RUNNER_WIN32_WINDOW") { found = h; return false; }
   return true;
  }, IntPtr.Zero);
  return found;
 }
 // Makes the Firefox window an owned, borderless child-like window of the app.
 public static void Dock(IntPtr ff, IntPtr host) {
  SetLongPtr(ff, -8, host);
  long style = GetLongPtr(ff, -16).ToInt64();
  style &= ~(0x00C00000L | 0x00040000L | 0x01000000L);
  SetLongPtr(ff, -16, new IntPtr(style));
  long ex = GetLongPtr(ff, -20).ToInt64();
  ex &= ~0x00040000L;
  SetLongPtr(ff, -20, new IntPtr(ex));
  ShowWindow(ff, 9);
  SetWindowPos(ff, IntPtr.Zero, 0, 0, 0, 0, 0x0027);
 }
 public static void Undock(IntPtr ff) {
  SetLongPtr(ff, -8, IntPtr.Zero);
  long style = GetLongPtr(ff, -16).ToInt64();
  style |= 0x00C00000L | 0x00040000L;
  SetLongPtr(ff, -16, new IntPtr(style));
  long ex = GetLongPtr(ff, -20).ToInt64();
  ex |= 0x00040000L;
  SetLongPtr(ff, -20, new IntPtr(ex));
  SetWindowPos(ff, IntPtr.Zero, 0, 0, 0, 0, 0x0027);
  ShowWindow(ff, 3);
 }
 // Keeps the Firefox window over the app's client area below the top bar.
 // Returns false when the app window is gone.
 public static bool Follow(IntPtr ff, IntPtr host, double topInset) {
  if (!IsWindow(host)) return false;
  if (IsIconic(host)) return true;
  RECT c; if (!GetClientRect(host, out c)) return false;
  POINT o = new POINT(); ClientToScreen(host, ref o);
  double scale = Math.Max(1.0, GetDpiForWindow(host) / 96.0);
  int top = (int)Math.Round(topInset * scale);
  RECT want; want.Left = o.X; want.Top = o.Y + top; want.Right = o.X + c.Right; want.Bottom = o.Y + c.Bottom;
  RECT now; GetWindowRect(ff, out now);
  if (now.Left == want.Left && now.Top == want.Top && now.Right == want.Right && now.Bottom == want.Bottom) return true;
  SetWindowPos(ff, IntPtr.Zero, want.Left, want.Top, Math.Max(1, want.Right - want.Left), Math.Max(1, want.Bottom - want.Top), 0x0014);
  return true;
 }
 }
'@
 $before=@(Get-Process -Name firefox -ErrorAction SilentlyContinue|ForEach-Object{$_.Id})
 $fullscreenApp=($r.appFullscreen -eq $true -and $r.action -eq 'launch')
 if($dock){
  $arguments='-no-remote -profile "'+$profile+'" -new-window "'+$url+'"'
 }elseif($fullscreenApp){
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
 $dockHandle=[IntPtr]::Zero;$hostHandle=[IntPtr]::Zero;$dockHidden=$false;$dockTop=0.0;$dockFile=$null
 if($dock){
  $hostHandle=[MillitopFirefoxWindows]::FindHost([int]$dock.hostPid)
  if($hostHandle -eq [IntPtr]::Zero){throw 'The MILLITOP TV window was not found for docking.'}
  $dockHandle=$windows[0].MainWindowHandle
  $dockTop=[double]$dock.topInset
  $dockFile=Join-Path (Split-Path -Parent $RequestPath) 'dock.json'
  [MillitopFirefoxWindows]::Dock($dockHandle,$hostHandle)
  [void][MillitopFirefoxWindows]::Follow($dockHandle,$hostHandle,$dockTop)
 }else{
  [void][MillitopFirefoxWindows]::ShowWindowAsync($windows[0].MainWindowHandle,3)
 }
 [void][MillitopFirefoxWindows]::SetForegroundWindow($windows[0].MainWindowHandle)
 [Console]::Out.WriteLine((@{type='ready';pid=$windows[0].Id;docked=($dock -ne $null)}|ConvertTo-Json -Compress))
 $dockStamp=$null
 function Update-Dock {
  if($dockHandle -eq [IntPtr]::Zero){return}
  if(-not [MillitopFirefoxWindows]::IsWindow($dockHandle)){$script:dockHandle=[IntPtr]::Zero;return}
  if(Test-Path -LiteralPath $dockFile -PathType Leaf){
   $stamp=(Get-Item -LiteralPath $dockFile).LastWriteTimeUtc.Ticks
   if($stamp -ne $script:dockStamp){
    $script:dockStamp=$stamp
    try{
     $state=Get-Content -LiteralPath $dockFile -Raw -Encoding UTF8|ConvertFrom-Json
     if($state.popOut -eq $true){
      [MillitopFirefoxWindows]::Undock($dockHandle)
      [void][MillitopFirefoxWindows]::SetForegroundWindow($dockHandle)
      $script:dockHandle=[IntPtr]::Zero;$script:dockHidden=$false
      [Console]::Out.WriteLine('{"type":"undocked"}')
      return
     }
     if($null -ne $state.topInset){$script:dockTop=[double]$state.topInset}
     $hide=($state.hidden -eq $true)
     if($hide -ne $script:dockHidden){
      $script:dockHidden=$hide
      [void][MillitopFirefoxWindows]::ShowWindow($dockHandle,$(if($hide){0}else{4}))
      if(-not $hide){[void][MillitopFirefoxWindows]::SetForegroundWindow($dockHandle)}
     }
    }catch{}
   }
  }
  if(-not $script:dockHidden){
   if(-not [MillitopFirefoxWindows]::Follow($dockHandle,$hostHandle,$script:dockTop)){
    # The app window is gone: hand Firefox back as a normal window.
    [MillitopFirefoxWindows]::Undock($dockHandle);$script:dockHandle=[IntPtr]::Zero
   }
  }
 }
 $missing=0
 $stopSignal=Join-Path (Split-Path -Parent $RequestPath) 'close-viewing.signal'
 $closingRequested=$false
 $closeDeadline=$null
 while($missing -lt 4){
  if($dockHandle -ne [IntPtr]::Zero){
   for($tick=0;$tick -lt 8;$tick++){Update-Dock;if($dockHandle -eq [IntPtr]::Zero){break};Start-Sleep -Milliseconds 60}
  }else{Start-Sleep -Milliseconds 500}
  $visible=@(Get-OwnedWindows)
  if($visible.Count -eq 0 -and $dockHandle -ne [IntPtr]::Zero -and [MillitopFirefoxWindows]::IsWindow($dockHandle)){
   # Owned (docked) or deliberately hidden windows are not reported as a
   # process main window, so track the docked handle directly.
   $visible=@(Get-Process -Id $windows[0].Id -ErrorAction SilentlyContinue)
  }
  if((Test-Path -LiteralPath $stopSignal -PathType Leaf) -and -not $closingRequested){
   $closingRequested=$true;$closeDeadline=(Get-Date).AddSeconds(15)
   if($dockHandle -ne [IntPtr]::Zero){
    if($dockHidden){[void][MillitopFirefoxWindows]::ShowWindow($dockHandle,4);$dockHidden=$false}
    [void][MillitopFirefoxWindows]::PostMessage($dockHandle,[uint32]16,[UIntPtr]::Zero,[IntPtr]::Zero)
   }
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
