param([Parameter(Mandatory=$true)][string]$ProjectRoot)
$ErrorActionPreference='Stop'
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class LatexWindowCheck {
 public delegate bool Callback(IntPtr h, IntPtr p);
 [DllImport("user32.dll")] static extern bool EnumWindows(Callback fn, IntPtr p);
 [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
 public static Dictionary<long,int> Visible() {
  var windows=new Dictionary<long,int>();
  EnumWindows(delegate(IntPtr h,IntPtr p) { uint pid; GetWindowThreadProcessId(h,out pid); if(IsWindowVisible(h))windows[h.ToInt64()]=(int)pid; return true; },IntPtr.Zero);
  return windows;
 }
}
'@
$exe=Join-Path $ProjectRoot '.vscode/build-latex.exe'
$bytes=[IO.File]::ReadAllBytes($exe)
$pe=[BitConverter]::ToInt32($bytes,0x3c)
if ([BitConverter]::ToUInt16($bytes,$pe+24+68) -ne 2) { throw 'Launcher is not a GUI-subsystem executable' }
$baseline=[LatexWindowCheck]::Visible()
$info=New-Object Diagnostics.ProcessStartInfo
$info.FileName=$exe; $info.WorkingDirectory=$ProjectRoot
$info.UseShellExecute=$false; $info.CreateNoWindow=$true
$p=[Diagnostics.Process]::Start($info)
$samples=0
try {
 do {
  foreach($entry in [LatexWindowCheck]::Visible().GetEnumerator()) {
   if ($baseline.ContainsKey($entry.Key)) { continue }
   $owner=Get-Process -Id $entry.Value -ErrorAction SilentlyContinue
   if($owner -and $owner.ProcessName -match '^(powershell|pwsh|cmd|conhost|latexmk|xelatex|xdvipdfmx|bibtex|build-latex)$') { throw ('Visible build window: '+$owner.ProcessName) }
  }
  $samples++; Start-Sleep -Milliseconds 20
 } until($p.HasExited)
 if($p.ExitCode -ne 0) { throw "Hidden build exited $($p.ExitCode)" }
 Write-Host "PASS: GUI PE subsystem; $samples visible-window samples found no new build/Shell window"
} finally { if(-not $p.HasExited) { $p.Kill() }; $p.Dispose() }
