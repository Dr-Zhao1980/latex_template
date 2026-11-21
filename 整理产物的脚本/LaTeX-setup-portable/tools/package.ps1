$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$items=@('setup-latex.bat','setup-latex.ps1','setup-latex.sh','README.md','TEST-RESULTS.md','src','tools','tests')|ForEach-Object{Join-Path $root $_}
$zip=Join-Path $root 'LaTeX-setup-portable.zip'
Compress-Archive -LiteralPath $items -DestinationPath $zip -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive=[IO.Compression.ZipFile]::OpenRead($zip)
try {
 foreach($entry in $archive.Entries){
  if($entry.FullName -match '(^|[/\\])(\.git|node_modules)([/\\]|$)'){throw 'Unexpected package content'}
 }
 foreach($name in @('setup-latex.bat','setup-latex.ps1','setup-latex.sh','README.md','TEST-RESULTS.md')){
  if(-not $archive.GetEntry($name)){throw "Package missing $name"}
 }
 Write-Host ("Verified ZIP: $($archive.Entries.Count) entries")
} finally {$archive.Dispose()}
Get-Item -LiteralPath $zip | Select-Object Name,Length
