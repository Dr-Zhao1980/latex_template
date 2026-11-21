# Extra real-runtime checks for toolchain hints, moved projects and permission errors.
param([switch]$KeepFixtures)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixture=Join-Path $temp ('latex-edge-tests-'+[guid]::NewGuid().ToString('N'))
$ps=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$enc=New-Object Text.UTF8Encoding($false)
function Check([bool]$ok,[string]$message) { if(-not $ok){throw $message} }
function Run([string]$file,[string[]]$arguments) {
 $i=New-Object Diagnostics.ProcessStartInfo
 $i.FileName=$ps; $i.Arguments=(@('-NoProfile','-ExecutionPolicy','Bypass','-File',$file)+$arguments|ForEach-Object{'"'+$_+'"'}) -join ' '
 $i.UseShellExecute=$false; $i.CreateNoWindow=$true; $i.RedirectStandardOutput=$true; $i.RedirectStandardError=$true
 $p=[Diagnostics.Process]::Start($i); $o=$p.StandardOutput.ReadToEndAsync(); $e=$p.StandardError.ReadToEndAsync(); $p.WaitForExit()
 $r=@{Code=$p.ExitCode;Output=$o.Result+$e.Result}; $p.Dispose(); return $r
}
try {
 $project=Join-Path $fixture 'original'; [void][IO.Directory]::CreateDirectory($project)
 $doc='\documentclass{article}\begin{document}Default root\end{document}'
 [IO.File]::WriteAllText((Join-Path $project 'main.tex'),$doc,$enc)
 [IO.File]::WriteAllText((Join-Path $project 'another.tex'),$doc,$enc)
 $setup=Join-Path $repo 'setup-latex.ps1'
 $r=Run $setup @('-ProjectRoot',$project,'-ConfigureOnly','-ProjectOnly','-NoPause')
 Check ($r.Code -eq 0) $r.Output
 $config=[IO.File]::ReadAllText((Join-Path $project '.vscode/latex-project.json'))|ConvertFrom-Json
 Check ($config.mainFile -eq 'main.tex') 'main.tex not preferred over other roots'
 Write-Host 'PASS: default main.tex selected among multiple roots without interaction'
 $moved=Join-Path $fixture 'moved project (portable)'
 $resolved=[IO.Path]::GetFullPath($project)
 Check ($resolved.StartsWith($fixture+'\',[StringComparison]::OrdinalIgnoreCase)) 'Unsafe test move'
 Move-Item -LiteralPath $resolved -Destination $moved
 $config.texBin='Z:\nonexistent-old-machine\bin\windows'
 [IO.File]::WriteAllText((Join-Path $moved '.vscode/latex-project.json'),(ConvertTo-Json $config),$enc)
 $runner=Join-Path $moved '.vscode/build-latex.ps1'
 $r=Run $runner @()
 Check ($r.Code -eq 0) $r.Output
 Check (Test-Path -LiteralPath (Join-Path $moved 'main.pdf')) 'Moved project not rebuilt'
 Write-Host 'PASS: moved project rebuilds; stale toolchain hint falls back to current PATH'
 $bin=[IO.Path]::GetDirectoryName((Get-Command latexmk.exe).Source)
 $savedPath=$env:Path
 try {
  $env:Path=$env:SystemRoot+'\System32'
  $r=Run $runner @('-TeXBin',$bin)
 } finally { $env:Path=$savedPath }
 Check ($r.Code -eq 0) $r.Output
 Write-Host 'PASS: explicit TeXBin works with a minimal PATH, without changing system variables'
 $settings=Join-Path $moved '.vscode/settings.json'
 [IO.File]::SetAttributes($settings,[IO.FileAttributes]::ReadOnly)
 # Force a settings change, then confirm read-only configuration is not destroyed.
 $settingsHash=(Get-FileHash -LiteralPath $settings).Hash
 $configFile=Join-Path $moved '.vscode/hidden-launcher.cs'
 [IO.File]::WriteAllText($configFile,'force component repair',$enc)
 try {
  # An exclusive settings lock simulates a real application holding the file.
  $held=[IO.File]::Open($settings,'Open','Read','None')
  try { $r=Run $setup @('-ProjectRoot',$moved,'-ConfigureOnly','-ProjectOnly','-NoPause') } finally { $held.Dispose() }
  Check ($r.Code -ne 0) 'Locked settings returned success'
  Check ((Get-FileHash -LiteralPath $settings).Hash -eq $settingsHash) 'Locked settings changed'
 } finally { [IO.File]::SetAttributes($settings,[IO.FileAttributes]::Normal) }
 Write-Host 'PASS: locked/read-only settings fail with diagnostics and preserve original bytes'
 $empty=Join-Path $fixture 'blocked'; [void][IO.Directory]::CreateDirectory($empty)
 [IO.File]::WriteAllText((Join-Path $empty 'main.tex'),$doc,$enc)
 [IO.File]::WriteAllText((Join-Path $empty 'build'),'user data',$enc)
 $r=Run $setup @('-ProjectRoot',$empty,'-ConfigureOnly','-NoPause')
 Check ($r.Code -ne 0 -and $r.Output -match 'not a directory') 'build-as-file was not diagnosed'
 Check ([IO.File]::ReadAllText((Join-Path $empty 'build')) -eq 'user data') 'Blocking file destroyed'
 Write-Host 'PASS: build-as-file is diagnosed and preserved'
 Write-Host 'ALL PASSED: 5 portability/permission groups'
} finally {
 if($KeepFixtures){Write-Host "Fixtures: $fixture"}
 elseif(Test-Path -LiteralPath $fixture){
  $target=(Resolve-Path -LiteralPath $fixture).Path
  if(-not $target.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($target) -notmatch '^latex-edge-tests-[a-f0-9]{32}$'){throw 'Unsafe test cleanup'}
  Remove-Item -LiteralPath $target -Force -Recurse
 }
}
