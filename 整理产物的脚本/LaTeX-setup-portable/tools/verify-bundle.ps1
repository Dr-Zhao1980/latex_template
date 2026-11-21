$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$ps1=[IO.File]::ReadAllText((Join-Path $root 'setup-latex.ps1')).Replace("`r`n","`n")
$bat=[IO.File]::ReadAllText((Join-Path $root 'setup-latex.bat')).Replace("`r`n","`n")
$marker='### POWERSHELL PAYLOAD START ###'
$payload=$bat.Substring($bat.IndexOf($marker)+$marker.Length).TrimStart("`n")
if($payload -ne $ps1){throw 'BAT payload differs from standalone PS1'}
foreach($file in @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -Recurse)){
 $errors=$null; $tokens=$null
 [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
 if($errors.Count){throw ($file.FullName+': '+($errors -join '; '))}
}
$sh=[IO.File]::ReadAllText((Join-Path $root 'setup-latex.sh'))
if($sh.Contains("`r")){throw 'SH contains CRLF line endings'}
$marker="  cat > `"`$tmp`" <<'PERMANENT_RUNNER'"
$start=$sh.IndexOf($marker)+$marker.Length+1
$end=$sh.IndexOf("`nPERMANENT_RUNNER",$start)
$source=[IO.File]::ReadAllText((Join-Path $root 'src/build-latex.sh')).Replace("`r`n","`n").TrimEnd()
if($sh.Substring($start,$end-$start) -ne $source){throw 'Bash embedded runner differs from source'}
$bytes=[IO.File]::ReadAllBytes((Join-Path $root 'setup-latex.ps1'))
if($bytes[0] -ne 239 -or $bytes[1] -ne 187 -or $bytes[2] -ne 191){throw 'PS1 missing UTF-8 BOM for PowerShell 5.1'}
Write-Host 'PASS: all PowerShell syntax; identical BAT/PS1 payload; identical SH embedded runner; PS1 BOM and SH LF'
