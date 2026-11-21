# Failure/Enter-prompt contract tests; no TeX installation is required.
param([switch]$KeepFixtures)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixture=Join-Path $temp ('latex-entry-tests-'+[guid]::NewGuid().ToString('N'))
$ps=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
function Check([bool]$ok,[string]$message) { if (-not $ok) { throw $message } }
function Test-Enter([string]$kind,[string]$name,[string[]]$extra,[bool]$success,[string]$missingPart='') {
 $folder=Join-Path $fixture ($kind+'-'+$name); [void][IO.Directory]::CreateDirectory($folder)
 $program=Join-Path $folder ('setup-latex.'+$kind)
 [IO.File]::Copy((Join-Path $repo ('setup-latex.'+$kind)),$program)
 if ($success) { [IO.File]::WriteAllText((Join-Path $folder 'main.tex'),'\documentclass{article}\begin{document}Hello\end{document}') }
 $info=New-Object Diagnostics.ProcessStartInfo
 if ($kind -eq 'ps1') {
  $info.FileName=$ps
  $info.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$program+'" '+($extra -join ' ')
 } else {
  $info.FileName=$env:ComSpec
  $info.Arguments='/d /s /c ""'+$program+'" '+($extra -join ' ')+'"'
 }
 $info.UseShellExecute=$false; $info.CreateNoWindow=$true
 $info.RedirectStandardInput=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
 $info.EnvironmentVariables['LATEX_SETUP_NO_PAUSE']='0'
 $info.EnvironmentVariables['LATEX_SETUP_BAT_OWNER']=''
 if ($missingPart -eq 'powershell') { $info.EnvironmentVariables['SystemRoot']=$folder }
 if ($missingPart -eq 'temp') { $info.EnvironmentVariables['TEMP']=Join-Path $folder 'nonexistent' }
 $p=[Diagnostics.Process]::Start($info); $o=$p.StandardOutput.ReadToEndAsync(); $e=$p.StandardError.ReadToEndAsync()
 try {
  Check (-not $p.WaitForExit(4000)) "$kind/$name exited before Enter"
  $p.StandardInput.WriteLine(''); $p.StandardInput.Flush()
  Check ($p.WaitForExit(20000)) "$kind/$name did not exit after Enter"
  $output=$o.Result+$e.Result
  Check ($output -match 'Press Enter') "$kind/$name never reached the Enter prompt: $output"
  Check (($p.ExitCode -eq 0) -eq $success) "$kind/$name wrong exit status: $output"
  Write-Host "PASS: $kind/$name stayed alive before Enter, then exited with correct status"
 } finally { if (-not $p.HasExited) { $p.Kill() }; $p.Dispose() }
}
try {
 foreach($kind in @('ps1','bat')) {
  Test-Enter $kind 'empty-project' @() $false
  Test-Enter $kind 'bad-argument' @('-UnknownOption') $false
  Test-Enter $kind 'success' @('-ConfigureOnly','-ProjectOnly') $true
 }
 Test-Enter 'bat' 'missing-powershell' @() $false 'powershell'
 Test-Enter 'bat' 'unpack-failed' @() $false 'temp'
 Write-Host 'ALL PASSED: 8 Enter/exit contract scenarios'
} finally {
 if($KeepFixtures) { Write-Host "Fixtures: $fixture" }
 elseif(Test-Path -LiteralPath $fixture) {
  $target=(Resolve-Path -LiteralPath $fixture).Path
  if(-not $target.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($target) -notmatch '^latex-entry-tests-[a-f0-9]{32}$') { throw 'Unsafe test cleanup target' }
  Remove-Item -LiteralPath $target -Recurse -Force
 }
}
