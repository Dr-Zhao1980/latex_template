param([switch]$KeepFixtures)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixture=Join-Path $temp ('latex-portable-tests-'+[guid]::NewGuid().ToString('N'))
$ps=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$utf8=New-Object Text.UTF8Encoding($false)
$env:LATEX_SETUP_NO_PAUSE='1'
$count=0
function Check([bool]$ok,[string]$message) { if (-not $ok) { throw $message } }
function Pass([string]$message) { $script:count++; Write-Host "PASS: $message" }
function Put([string]$path,[string]$text) {
 [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)); [IO.File]::WriteAllText($path,$text,$utf8)
}
function Run([string]$exe,[string[]]$arguments,[string]$cwd=$fixture) {
 $info=New-Object Diagnostics.ProcessStartInfo
 $info.FileName=$exe; $info.Arguments=(($arguments|ForEach-Object{'"'+$_.Replace('"','\"')+'"'}) -join ' ')
 $info.WorkingDirectory=$cwd; $info.UseShellExecute=$false; $info.CreateNoWindow=$true
 $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
 $p=[Diagnostics.Process]::Start($info); $o=$p.StandardOutput.ReadToEndAsync(); $e=$p.StandardError.ReadToEndAsync()
 if (-not $p.WaitForExit(180000)) { $p.Kill(); throw "Timeout: $exe" }
 $r=@{Code=$p.ExitCode;Output=$o.Result+$e.Result}; $p.Dispose(); return $r
}
function Setup([string]$program,[string[]]$extra) {
 if ($program.EndsWith('.bat')) {
  $line='""'+$program+'" -ProjectOnly -NoPause '+(($extra|ForEach-Object{'"'+$_+'"'}) -join ' ')+'"'
  $info=New-Object Diagnostics.ProcessStartInfo
  $info.FileName=$env:ComSpec; $info.Arguments='/d /s /c '+$line
  $info.WorkingDirectory=$fixture; $info.UseShellExecute=$false; $info.CreateNoWindow=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
  $p=[Diagnostics.Process]::Start($info); $o=$p.StandardOutput.ReadToEndAsync(); $e=$p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit(180000)) { $p.Kill(); throw 'BAT timeout' }
  $r=@{Code=$p.ExitCode;Output=$o.Result+$e.Result}; $p.Dispose(); return $r
 }
 return Run $ps (@('-NoProfile','-ExecutionPolicy','Bypass','-File',$program,'-ProjectOnly','-NoPause')+$extra)
}
function Build([string]$project,[string[]]$extra) {
 return Run $ps (@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $project '.vscode/build-latex.ps1'),'-ProjectRoot',$project)+$extra)
}
$document=@'
\documentclass{article}
\begin{document}
\tableofcontents
\include{chapters/part}
\bibliographystyle{unsrt}
\bibliography{references}
\end{document}
'@
try {
 foreach ($kind in @('ps1','bat')) {
  $project=Join-Path $fixture ("$kind/项目 空格(甲) & [b] !")
  $source=Join-Path $project '课程 笔记.v2.tex'; Put $source $document
  Put (Join-Path $project 'chapters/part.tex') '\section{Portable}\label{demo}Hello \cite{demo}. See \ref{demo}.'
  Put (Join-Path $project 'references.bib') '@book{demo,author={Example Author},title={Example Reference},publisher={Example Publisher},year={2026}}'
  Put (Join-Path $project 'old.aux') 'historical'; Put (Join-Path $project 'chapters/old.aux') 'historical'
  Put (Join-Path $project 'user.log') 'user data'; Put (Join-Path $project 'figure.pdf') 'PDF source image'
  Put (Join-Path $project 'build/notes.txt') 'user data'
  Put (Join-Path $project '.vscode/settings.json') "{`n// JSONC`n`"editor.wordWrap`":`"on`",`n`"custom.url`":`"https://example.test/a//b,}`",`n`"latex-workshop.latex.external.build.command`":`"broken`",`n}"
  $program=Join-Path $project ("setup-latex.$kind")
  Copy-Item -LiteralPath (Join-Path $repo ("setup-latex.$kind")) -Destination $program
  $hash=(Get-FileHash -LiteralPath $source).Hash
  $result=Setup $program @(); Check ($result.Code -eq 0) $result.Output
  $pdf=Join-Path $project '课程 笔记.v2.pdf'; $cache=Join-Path $project 'build/课程 笔记.v2.pdf'
  Check (Test-Path -LiteralPath $pdf) 'No root PDF'
  foreach ($leaf in @('课程 笔记.v2.bbl','课程 笔记.v2.synctex.gz','chapters/part.aux','latexmk.stdout.log','latexmk.stderr.log','last-build-status.txt')) {
   Check (Test-Path -LiteralPath (Join-Path $project ('build/'+$leaf))) "Missing $leaf"
  }
  Check ((Get-FileHash -LiteralPath $source).Hash -eq $hash) 'Source changed'
  Check (-not (Test-Path -LiteralPath (Join-Path $project 'old.aux'))) 'Legacy not moved'
  Check (@(Get-ChildItem -LiteralPath (Join-Path $project 'build/legacy') -Recurse -File).Count -eq 2) 'Legacy incomplete'
  Check (Test-Path -LiteralPath (Join-Path $project 'user.log')) 'Unrelated data moved'
  $settingsPath=Join-Path $project '.vscode/settings.json'
  $settings=[IO.File]::ReadAllText($settingsPath)|ConvertFrom-Json
  Check ($settings.'editor.wordWrap' -eq 'on' -and $settings.'custom.url' -eq 'https://example.test/a//b,}') 'JSONC settings lost'
  Check (-not $settings.PSObject.Properties['latex-workshop.latex.external.build.command']) 'Old build remains'
  Pass "$kind standalone; real XeLaTeX/BibTeX/include/SyncTeX; JSONC and legacy preservation"
  $time=(Get-Item -LiteralPath $cache).LastWriteTimeUtc.Ticks
  $result=Build $project @(); Check ($result.Code -eq 0) $result.Output
  Check ((Get-Item -LiteralPath $cache).LastWriteTimeUtc.Ticks -eq $time) 'Incremental cache regenerated'
  Pass "$kind incremental build reuses PDF timestamp and publishes by atomic replacement"
  $settingsHash=(Get-FileHash -LiteralPath $settingsPath).Hash
  [IO.File]::Delete((Join-Path $project '.vscode/build-latex.vbs')); [IO.File]::Delete((Join-Path $project '.vscode/build-latex.exe'))
  $result=Setup $program @('-ConfigureOnly'); Check ($result.Code -eq 0) $result.Output
  Check (Test-Path -LiteralPath (Join-Path $project '.vscode/build-latex.vbs')) 'VBS not repaired'
  Check (Test-Path -LiteralPath (Join-Path $project '.vscode/build-latex.exe')) 'EXE not repaired'
  Check ((Get-FileHash -LiteralPath $settingsPath).Hash -eq $settingsHash) 'Settings not idempotent'
  Check (Test-Path -LiteralPath (Join-Path $project 'build/notes.txt')) 'Cleanup deleted user data'
  Pass "$kind repeat initialization repairs deleted components and preserves settings/user data"
  [IO.File]::Delete($program)
  $target=[IO.Path]::GetFullPath((Join-Path $project 'build'))
  Check ($target.StartsWith($fixture+'\',[StringComparison]::OrdinalIgnoreCase)) 'Unsafe test target'
  Remove-Item -LiteralPath $target -Recurse -Force; [IO.File]::Delete($pdf)
  $launcher=Join-Path $project '.vscode/build-latex.exe'
  $result=Run $launcher @($source,$project); Check ($result.Code -eq 0) $result.Output
  Check (Test-Path -LiteralPath $pdf) 'Rebuild after deleting installer/build failed'
  Check (@(Get-ChildItem -LiteralPath $project -File|Where-Object Name -match '\.(aux|toc|blg|bbl|fls|synctex\.gz)$').Count -eq 0) 'Root output leak'
  Pass "$kind permanent GUI launcher rebuilds without installers/build; root stays clean"
  $lastGood=(Get-FileHash -LiteralPath $pdf).Hash
  Put $source ($document.Replace('\end{document}','\UndefinedPortableCommand\end{document}'))
  $result=Run $launcher @($source,$project); Check ($result.Code -ne 0) 'GUI returned success for bad TeX'
  Check ((Get-FileHash -LiteralPath $pdf).Hash -eq $lastGood) 'Failed build overwrote good PDF'
  Check ([IO.File]::ReadAllText((Join-Path $project 'build/last-build-status.txt')) -match 'FAILED exit=') 'Missing failure status'
  Pass "$kind real TeX failure reaches GUI exit code and preserves last good PDF"
  Put $source ($document+"`n% revised`n"); $result=Build $project @(); Check ($result.Code -eq 0) $result.Output
  $locked=[IO.File]::Open($pdf,'Open','Read','None')
  try { $result=Build $project @(); Check ($result.Code -ne 0) 'Locked PDF returned success' } finally { $locked.Dispose() }
  Check ((Get-FileHash -LiteralPath $pdf).Hash -eq (Get-FileHash -LiteralPath $cache).Hash) 'Locked publication damaged PDF'
  Pass "$kind Windows PDF lock handled without damaging previous output"
  $lock=[IO.File]::Open((Join-Path $project '.vscode/.latex-operation.lock'),'OpenOrCreate','ReadWrite','None')
  try { $result=Build $project @('-Mode','clean-all','-LockTimeout','1'); Check ($result.Code -eq 75) 'Shared lock not enforced' } finally { $lock.Dispose() }
  $result=Build $project @('-Mode','clean'); Check ($result.Code -eq 0) $result.Output
  Check (Test-Path -LiteralPath $cache) 'clean removed cached PDF'
  $result=Build $project @('-Mode','clean-all'); Check ($result.Code -eq 0) $result.Output
  Check (-not (Test-Path -LiteralPath $cache)) 'Deep clean left cached PDF'
  Check (Test-Path -LiteralPath $pdf) 'Deep clean removed published PDF'
  Check (Test-Path -LiteralPath (Join-Path $project 'build/latexmk.stdout.log')) 'Deep clean discarded diagnostics'
  $result=Build $project @(); Check ($result.Code -eq 0) $result.Output
  Pass "$kind clean/build mutual exclusion; both clean modes and rebuild after deep clean"
 }
 Write-Host "ALL PASSED: $count integration groups"
} finally {
 $env:LATEX_SETUP_NO_PAUSE=$null
 if ($KeepFixtures) { Write-Host "Fixtures: $fixture" }
 elseif (Test-Path -LiteralPath $fixture) {
  $resolved=(Resolve-Path -LiteralPath $fixture).Path
  if (-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^latex-portable-tests-[a-f0-9]{32}$') { throw 'Unsafe test cleanup path' }
  Remove-Item -LiteralPath $resolved -Recurse -Force
 }
}
