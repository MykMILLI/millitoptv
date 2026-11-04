param(
 [Parameter(Mandatory=$true)][ValidateSet('vlc','iptvnator')][string]$AppKey,
 [Parameter(Mandatory=$true)][string]$Installer,
 [Parameter(Mandatory=$true)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedHash
)
$ErrorActionPreference='Stop'
try {
 $file=Get-Item -LiteralPath $Installer
 if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {throw 'Installer link rejected.'}
 $expectedExtension=if($AppKey -eq 'vlc'){'.msi'}else{'.exe'}
 if($file.Extension -ine $expectedExtension){throw 'Unexpected installer type.'}
 if((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ine $ExpectedHash){throw 'Installer hash changed. Nothing executed.'}
 if($AppKey -eq 'vlc'){
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class MillitopElevation {
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
 public struct Info {
  public int cbSize; public uint fMask; public IntPtr hwnd;
  [MarshalAs(UnmanagedType.LPWStr)] public string lpVerb;
  [MarshalAs(UnmanagedType.LPWStr)] public string lpFile;
  [MarshalAs(UnmanagedType.LPWStr)] public string lpParameters;
  [MarshalAs(UnmanagedType.LPWStr)] public string lpDirectory;
  public int nShow; public IntPtr hInstApp; public IntPtr lpIDList;
  [MarshalAs(UnmanagedType.LPWStr)] public string lpClass;
  public IntPtr hkeyClass; public uint dwHotKey; public IntPtr hIcon; public IntPtr hProcess;
 }
 [DllImport("shell32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
 [return:MarshalAs(UnmanagedType.Bool)] public static extern bool ShellExecuteEx(ref Info info);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr h,uint ms);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool GetExitCodeProcess(IntPtr h,out uint code);
 [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
}
'@
  $info=New-Object MillitopElevation+Info
  $info.cbSize=[Runtime.InteropServices.Marshal]::SizeOf($info)
  $info.fMask=0x40
  $info.hwnd=[MillitopElevation]::GetForegroundWindow()
  $info.lpVerb='runas'
  $info.lpFile=Join-Path $env:SystemRoot 'System32\msiexec.exe'
  $info.lpParameters='/i "'+$file.FullName+'" /passive /norestart'
  $info.lpDirectory=$file.DirectoryName
  $info.nShow=1
  if(-not [MillitopElevation]::ShellExecuteEx([ref]$info)){
   $err=[Runtime.InteropServices.Marshal]::GetLastWin32Error()
   if($err -eq 1223){[pscustomobject]@{code=1223;cancelled=$true;pending=$false}|ConvertTo-Json -Compress;exit 0}
   throw "Windows approval could not start (error $err)."
  }
  if($info.hProcess -eq [IntPtr]::Zero){throw 'Windows did not provide an installer process handle.'}
  try{
   $wait=[MillitopElevation]::WaitForSingleObject($info.hProcess,600000)
   if($wait -eq 258){[pscustomobject]@{code=258;pending=$true;cancelled=$false}|ConvertTo-Json -Compress;exit 0}
   if($wait -ne 0){throw 'Could not monitor the Windows installer.'}
   [uint32]$code=0
   if(-not [MillitopElevation]::GetExitCodeProcess($info.hProcess,[ref]$code)){throw 'Could not read installer result.'}
  }finally{[void][MillitopElevation]::CloseHandle($info.hProcess)}
 }else{
  # Curated Electron NSIS package: current-user installation only, no elevation.
  $process=Start-Process -FilePath $file.FullName -ArgumentList '/S' -PassThru
  if(-not $process.WaitForExit(600000)){
   [pscustomobject]@{code=258;pending=$true;cancelled=$false}|ConvertTo-Json -Compress;exit 0
  }
  $code=$process.ExitCode
 }
 [pscustomobject]@{code=[long]$code;pending=$false;cancelled=$false}|ConvertTo-Json -Compress
}catch{
 [Console]::Error.WriteLine($_.Exception.Message)
 exit 1
}
