@echo off
setlocal EnableExtensions DisableDelayedExpansion
rem Standalone portable LaTeX build script. Does NOT require setup-latex.ps1.
rem It contains its own embedded PowerShell implementation below.
set "LATEX_BAT_SELF=%~f0"
set "LATEX_SETUP_PROJECT_ROOT=%~dp0"
if exist "%~dp0build\NUL" goto :hasbuild
if exist "%~dp0build" (
  echo ERROR: build already exists as a file, not a directory.
  pause
  exit /b 2
)
mkdir "%~dp0build" 2>nul
if errorlevel 1 (
  echo ERROR: cannot create build directory.
  pause
  exit /b 2
)
:hasbuild
where powershell.exe >nul 2>nul
if errorlevel 1 (
  echo ERROR: Windows PowerShell is required.
  pause
  exit /b 2
)
set "LATEX_BAT_PAYLOAD=%~dp0build\latex-bat-bootstrap-%RANDOM%-%RANDOM%.ps1"
rem Decode the embedded payload from this BAT file. UTF-8 BOM for PS 5.1.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText($env:LATEX_BAT_SELF,[Text.Encoding]::UTF8);$m=('### POWERSHELL PAYLOAD '+'START ###');$i=$s.IndexOf($m,[StringComparison]::Ordinal);if($i -lt 0){exit 3};$code=$s.Substring($i+$m.Length);[IO.File]::WriteAllText($env:LATEX_BAT_PAYLOAD,$code,[Text.UTF8Encoding]::new($true))"
if errorlevel 1 (
  echo ERROR: cannot unpack BAT-internal build logic.
  pause
  exit /b 3
)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%LATEX_BAT_PAYLOAD%" %*
set "LATEX_EXIT_CODE=%ERRORLEVEL%"
if exist "%LATEX_BAT_PAYLOAD%" del /f /q "%LATEX_BAT_PAYLOAD%" >nul 2>nul
if not "%LATEX_EXIT_CODE%"=="0" if not "%LATEX_SETUP_NO_PAUSE%"=="1" (
  echo.
  echo Build failed. Check build\setup-latex-status.log.
  pause
)
exit /b %LATEX_EXIT_CODE%

### POWERSHELL PAYLOAD START ###
#requires -Version 5.1
<#
 Portable LaTeX diagnostics / builder for Windows PowerShell 5.1+.
 No administrator rights, external modules, fixed TeX Live year, or main.tex required.
 See README.md for examples and exit codes.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][Alias('File')][string]$TexFile,
    [string]$ProjectRoot,
    [string]$TeXBin,
    [switch]$DiagnoseOnly,
    [switch]$NoSettings,
    [switch]$NoPause
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:NoInteraction = $NoPause.IsPresent -or ($env:LATEX_SETUP_NO_PAUSE -eq '1')
$script:Workspace = ''
$script:SourceFile = ''
$script:SourceDir = ''
$script:BuildDir = ''
$script:ReportDir = ''
$script:StatusLog = ''
$script:LastLog = ''
$script:Latexmk = ''
$script:XeLaTeX = ''
$script:Perl = ''
$script:DetectedBin = ''
$script:PdfPath = ''
$script:Stage = 'starting'
$script:Warnings = New-Object 'System.Collections.Generic.List[string]'
$script:Recommendations = New-Object 'System.Collections.Generic.List[string]'
$script:Encoding = New-Object System.Text.UTF8Encoding($false)
$script:ReportOK = $false
$script:Outcome = ''
$script:CmdResults = New-Object 'System.Collections.Generic.List[string]'

function Add-Log([string]$Text) {
    Write-Host $Text
    if ($script:StatusLog) {
        try { [IO.File]::AppendAllText($script:StatusLog, $Text + [Environment]::NewLine, $script:Encoding) }
        catch { Write-Host ('Cannot write status log: ' + $_.Exception.Message) }
    }
}
function Add-Warning([string]$Text) {
    $script:Warnings.Add($Text)
    Add-Log ('[WARN] ' + $Text)
}
function Add-Fix([string]$Text) {
    if (-not $script:Recommendations.Contains($Text)) { $script:Recommendations.Add($Text) }
    Add-Log ('[FIX] ' + $Text)
}
function Get-AbsPath([string]$PathText, [string]$Base) {
    if ([IO.Path]::IsPathRooted($PathText)) { return [IO.Path]::GetFullPath($PathText) }
    return [IO.Path]::GetFullPath((Join-Path $Base $PathText))
}
function New-UniqueBackup([string]$PathText) {
    $stem = $PathText + '.backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
    $candidate = $stem
    $i = 0
    while (Test-Path -LiteralPath $candidate) { $i++; $candidate = "$stem-$i" }
    return $candidate
}
function Initialize-Logs {
    $script:ReportDir = Join-Path $script:Workspace 'build'
    if ((Test-Path -LiteralPath $script:ReportDir) -and -not (Test-Path -LiteralPath $script:ReportDir -PathType Container)) {
        throw "build exists but is not a directory: $script:ReportDir. Rename it before running."
    }
    try { [void][IO.Directory]::CreateDirectory($script:ReportDir) }
    catch { throw ('Cannot write to project build directory: ' + $script:ReportDir + '. ' + $_.Exception.Message) }
    $script:StatusLog = Join-Path $script:ReportDir 'setup-latex-status.log'
    [IO.File]::WriteAllText($script:StatusLog,
        ('Portable LaTeX Setup - ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + [Environment]::NewLine), $script:Encoding)
    Add-Log ('Workspace: ' + $script:Workspace)
    Add-Log ('PowerShell: ' + $PSVersionTable.PSVersion.ToString())
    Add-Log ('OS: ' + [Environment]::OSVersion.VersionString)
}

# Search known TeX executable locations first, then bounded likely installation trees.
# Scan is dynamic by directory structure, NOT by hard-coded TeX Live year.
function Find-TeXBins([string]$Override) {
    $found = New-Object 'System.Collections.Generic.List[string]'
    $seen = @{}
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    $candidateSeen = @{}
    $exeNames = @('latexmk.exe', 'xelatex.exe', 'kpsewhich.exe')
    function Add-Candidate([string]$p) {
        if (-not $p -or $candidateSeen.ContainsKey($p.ToLowerInvariant())) { return }
        $candidateSeen[$p.ToLowerInvariant()] = $true
        $candidates.Add($p)
    }
    function Add-Found([string]$p) {
        if (-not $p -or -not [IO.Directory]::Exists($p)) { return }
        $k = $p.TrimEnd('\', '/').ToLowerInvariant()
        if ($seen.ContainsKey($k)) { return }
        foreach ($exe in $exeNames) {
            if (Test-Path -LiteralPath (Join-Path $p $exe) -PathType Leaf) {
                $seen[$k] = $true
                $found.Add($p)
                return
            }
        }
    }
    if ($Override) {
        $item = Get-AbsPath $Override $script:Workspace
        if ([IO.File]::Exists($item)) { $item = [IO.Path]::GetDirectoryName($item) }
        Add-Candidate $item
        Add-Found $item
    }
    foreach ($exe in $exeNames) {
        $cmd = Get-Command $exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { Add-Found ([IO.Path]::GetDirectoryName($cmd.Source)) }
    }
    $pathValues = @($env:Path, [Environment]::GetEnvironmentVariable('Path', 'User'),
                    [Environment]::GetEnvironmentVariable('Path', 'Machine'))
    foreach ($value in $pathValues) {
        if (-not $value) { continue }
        foreach ($entry in ($value -split ';')) {
            $d = [Environment]::ExpandEnvironmentVariables($entry.Trim(' ', '"'))
            if ($d) { Add-Found $d }
        }
    }
    foreach ($name in @('TEXDIR','TEXLIVE_ROOT','TEXMFROOT','MIKTEX_INSTALL')) {
        $v = [Environment]::GetEnvironmentVariable($name)
        if ($v) { Add-Candidate ([Environment]::ExpandEnvironmentVariables($v)) }
    }
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA, $env:USERPROFILE)) {
        if ($root) { Add-Candidate $root }
    }
    foreach ($drive in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if ($drive.Root) { Add-Candidate $drive.Root }
    }
    # If both executables are already found together, a deep scan is unnecessary.
    foreach ($bin in $found) {
        if ((Test-Path -LiteralPath (Join-Path $bin 'latexmk.exe') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $bin 'xelatex.exe') -PathType Leaf)) {
            Add-Log ('Found full toolchain on PATH/in an explicit directory: ' + $bin)
            return $found.ToArray()
        }
    }
    # Prioritized depth-first search prevents huge Program Files trees from
    # exhausting the budget before a nested drive install (APP/texlive/year/bin).
    $stack = New-Object 'System.Collections.Generic.Stack[object]'
    for ($i = $candidates.Count - 1; $i -ge 0; $i--) {
        $candidate = $candidates[$i]
        if ([IO.Directory]::Exists($candidate)) { $stack.Push(@{ P = $candidate; Depth = 0; Relevant = $false }) }
    }
    $visited = @{}
    $inspected = 0
    while ($stack.Count -gt 0 -and $inspected -lt 650) {
        $n = $stack.Pop()
        $dir = [string]$n.P
        $depth = [int]$n.Depth
        $related = [bool]$n.Relevant
        $key = $dir.TrimEnd('\','/').ToLowerInvariant()
        if ($visited.ContainsKey($key)) { continue }
        $visited[$key] = $true
        $inspected++
        Add-Found $dir
        foreach ($bin in $found) {
            if ((Test-Path -LiteralPath (Join-Path $bin 'latexmk.exe') -PathType Leaf) -and
                (Test-Path -LiteralPath (Join-Path $bin 'xelatex.exe') -PathType Leaf)) {
                Add-Log ('Found complete TeX toolchain in ' + $bin)
                return $found.ToArray()
            }
        }
        if ($depth -gt 8) { continue }
        $subDirs = @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue)
        # Favor likely software directories and only explore deep within them.
        $subDirs = @($subDirs | Sort-Object @{Expression={ if ($_.Name -match '(?i)tex|mik|app|soft|program|tool|portable|install|bin|^[0-9]{4}$') { 0 } else { 1 } }}, Name)
        $filteredKids = New-Object 'System.Collections.Generic.List[object]'
        foreach ($sub in $subDirs) {
            if ($filteredKids.Count -ge 110) { break }
            if (($sub.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if ($sub.Name -match '^(?i:programdata|system volume information|\$recycle.bin|node_modules|\.git|\.cache|\.venv)$') { continue }
            if ($depth -eq 0 -and $sub.Name -match '^(?i:windows|winnt|users)$') { continue }
            $looksRelevant = $sub.Name -match '(?i)tex|mik|app|soft|program|tool|portable|install|bin|^[0-9]{4}$|^x64$|^windows$'
            if (-not ($related -or $looksRelevant)) { continue }
            if ($depth -ge 8) { continue }
            $filteredKids.Add($sub)
        }
        for ($i = $filteredKids.Count - 1; $i -ge 0; $i--) {
            $sub = $filteredKids[$i]
            $stack.Push(@{ P = $sub.FullName; Depth = $depth + 1; Relevant = $true })
        }
    }
    Add-Log ("Scanned $inspected candidate directories; found $($found.Count) TeX executable directories.")
    return $found.ToArray()
}
function Resolve-TeXTools([string]$Override) {
    $bins = @(Find-TeXBins $Override)
    if ($bins.Count -eq 0) {
        Add-Fix 'No TeX executable directory found. Install TeX Live: https://tug.org/texlive/windows.html (or MiKTeX), then rerun this script.'
        Add-Fix 'If TeX Live is installed in a custom folder, use -TeXBin "<install>\bin\windows" or add that directory to PATH.'
        throw 'TeX distribution was not found in PATH or the scanned candidate paths.'
    }
    $preferred = ''
    foreach ($bin in $bins) {
        if ((Test-Path -LiteralPath (Join-Path $bin 'latexmk.exe') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $bin 'xelatex.exe') -PathType Leaf)) { $preferred = $bin; break }
    }
    if (-not $preferred) { $preferred = $bins[0] }
    $arr = New-Object 'System.Collections.Generic.List[string]'
    $arr.Add($preferred)
    foreach ($bin in $bins) { if ($bin -ine $preferred) { $arr.Add($bin) } }
    foreach ($bin in $arr) {
        if (-not $script:Latexmk) {
            $p = Join-Path $bin 'latexmk.exe'
            if (Test-Path -LiteralPath $p -PathType Leaf) { $script:Latexmk = $p }
        }
        if (-not $script:XeLaTeX) {
            $p = Join-Path $bin 'xelatex.exe'
            if (Test-Path -LiteralPath $p -PathType Leaf) { $script:XeLaTeX = $p }
        }
        if (-not $script:Perl) {
            $p = Join-Path $bin 'perl.exe'
            if (Test-Path -LiteralPath $p -PathType Leaf) { $script:Perl = $p }
        }
    }
    if (-not $script:Latexmk) {
        Add-Fix 'XeLaTeX is present, but latexmk is missing. Install the latexmk package using TeX Live Manager (tlmgr) or MiKTeX Console.'
    }
    if (-not $script:XeLaTeX) {
        Add-Fix 'latexmk is present, but XeLaTeX is missing. Install the xetex package using TeX Live Manager (tlmgr) or MiKTeX Console.'
    }
    if (-not $script:Latexmk -or -not $script:XeLaTeX) { throw 'Required compilation tools are missing (see FIX lines above).' }
    $script:DetectedBin = [IO.Path]::GetDirectoryName($script:Latexmk)
    $prepend = New-Object 'System.Collections.Generic.List[string]'
    foreach ($bin in $arr) {
        if ($bin -and -not $prepend.Contains($bin)) { $prepend.Add($bin) }
    }
    $env:Path = ($prepend.ToArray() -join ';') + ';' + $env:Path
    Add-Log ('latexmk: ' + $script:Latexmk)
    Add-Log ('xelatex: ' + $script:XeLaTeX)
    foreach ($name in @('perl','kpsewhich','biber','bibtex','makeindex','tlmgr','xdvipdfmx')) {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { Add-Log ('Tool ' + $name + ': ' + $cmd.Source) }
        elseif ($name -in @('perl','xdvipdfmx')) { Add-Warning ('A potentially required tool is not on PATH: ' + $name) }
        else { Add-Log ('Optional tool not found: ' + $name) }
    }
    $cmd = Get-Command 'kpsewhich' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) {
        foreach ($pkg in @('article.cls','fontspec.sty','ctex.sty','xeCJK.sty')) {
            try {
                $resolved = (& $cmd.Source $pkg 2>$null | Select-Object -First 1)
                if ($resolved) { Add-Log ('Package ' + $pkg + ': available') }
                else { Add-Warning ("Package $pkg was not found (needed only by documents that use it).") }
            } catch { Add-Warning ('Cannot query package ' + $pkg) }
        }
    }
}

# Start-Process redirects both pipes directly to files; avoids command-line shell
# injection, PowerShell 5.1 native redirection quirks, and output deadlocks.
function Invoke-CommandLogged([string]$Exe, [string[]]$ArgsList, [string]$WorkingDir, [string]$Prefix) {
    $outFile = Join-Path $script:ReportDir ($Prefix + '.stdout.log')
    $errFile = Join-Path $script:ReportDir ($Prefix + '.stderr.log')
    # Windows filenames cannot contain a double-quote. Escape argument whitespace.
    $quoted = foreach ($arg in $ArgsList) {
        if ($arg -match '[\s"]') { '"' + ($arg.Replace('"', '\"')) + '"' }
        else { $arg }
    }
    $start = @{
        FilePath = $Exe
        ArgumentList = ($quoted -join ' ')
        WorkingDirectory = $WorkingDir
        PassThru = $true
        Wait = $true
        RedirectStandardOutput = $outFile
        RedirectStandardError = $errFile
        ErrorAction = 'Stop'
    }
    $process = Start-Process @start
    $script:LastLog = $outFile
    $script:CmdResults.Add(("$Prefix exit code: " + $process.ExitCode))
    Add-Log ("$Prefix exit code: " + $process.ExitCode)
    return [int]$process.ExitCode
}
function Find-FirstTeXError([string[]]$Paths) {
    foreach ($p in $Paths) {
        if (-not $p -or -not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        try {
            $lines = @(Get-Content -LiteralPath $p -ErrorAction Stop)
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^\s*!\s|^.*\.tex:\d+:|^.*\.sty:\d+:|^.*\.cls:\d+:|!\s+(Emergency stop|Fatal error)|^Latexmk:\s+Missing input') {
                    $last = [Math]::Min($lines.Count - 1, $i + 3)
                    return (($lines[$i..$last]) -join [Environment]::NewLine).Trim()
                }
            }
            foreach ($line in $lines) {
                if ($line -match '(?i)(fatal error|file not found|permission denied|cannot find|could not find|not found|error:)') { return $line.Trim() }
            }
        } catch { continue }
    }
    return ''
}
function Interpret-TeXError([string]$ErrorText) {
    if (-not $ErrorText) { return 'No root LaTeX error was extracted; open the full .log and setup-compile.stdout.log.' }
    if ($ErrorText -match '(?i)\.sty.*not found|\.cls.*not found') {
        return 'A required LaTeX package/class is absent. Install it using tlmgr/MiKTeX Console, or check the local .sty/.cls path.'
    }
    if ($ErrorText -match '(?i)fontspec|font.*not found|font.*cannot be found') {
        return 'Check the font name in fontspec/xeCJK, install the required font, and refresh the font cache if needed.'
    }
    if ($ErrorText -match '(?i)undefined control sequence') { return 'Check the misspelled command, required packages, and missing macro definitions at the reported source line.' }
    if ($ErrorText -match '(?i)missing \$ inserted|extra }|runaway argument') { return 'Check math-mode delimiters, braces and command arguments near the reported source line.' }
    if ($ErrorText -match '(?i)file .*not found|cannot find file') { return 'Check referenced images, \input/\include files, relative paths, filenames and case.' }
    if ($ErrorText -match '(?i)permission denied|cannot write|access is denied') { return 'Close PDF/auxiliary-file viewers and other builds; check write permissions.' }
    return 'The source file or one of its dependencies failed to compile. Start from the first reported LaTeX error, rather than latexmk exit code 12.'
}
function Test-MinimalXeLaTeX {
    $temp = Join-Path $script:ReportDir ('healthcheck-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($temp)
    try {
        [void][IO.Directory]::CreateDirectory((Join-Path $temp 'build'))
        [IO.File]::WriteAllText((Join-Path $temp 'healthcheck.tex'),
            "\documentclass{article}`n\begin{document}`nXeLaTeX OK.`n\end{document}`n", $script:Encoding)
        $args = @('-norc', '-pdfxe', '-interaction=nonstopmode', '-halt-on-error', '-file-line-error',
                  '-outdir=build', 'healthcheck.tex')
        $rc = Invoke-CommandLogged $script:Latexmk $args $temp 'setup-env'
        $pdf = Join-Path $temp 'build\healthcheck.pdf'
        if ($rc -ne 0 -or -not (Test-Path -LiteralPath $pdf -PathType Leaf)) {
            $reason = Find-FirstTeXError @((Join-Path $temp 'build\healthcheck.log'),
                                           (Join-Path $script:ReportDir 'setup-env.stdout.log'),
                                           (Join-Path $script:ReportDir 'setup-env.stderr.log'))
            if ($reason) { Add-Log ('Environment test error: ' + $reason) }
            Add-Fix 'The minimal XeLaTeX test failed; repair missing TeX Live packages/formats/fonts or confirm latexmk, Perl, XeLaTeX and xdvipdfmx work together.'
            throw 'Minimal XeLaTeX compilation failed. Check build/setup-env.stdout.log and build/setup-env.stderr.log.'
        }
        Add-Log '[OK] Minimal XeLaTeX compilation succeeded (isolated temporary document).'
    } finally {
        try { Remove-Item -LiteralPath $temp -Force -Recurse -ErrorAction Stop }
        catch { Add-Warning ('Could not remove temporary test directory: ' + $temp) }
    }
}

function Get-TeXRootCandidates([string]$Folder) {
    $rootDocs = New-Object 'System.Collections.Generic.List[string]'
    $otherTex = New-Object 'System.Collections.Generic.List[string]'
    $stack = New-Object 'System.Collections.Generic.Stack[object]'
    $stack.Push(@{ P = $Folder; Depth = 0 })
    $filesSeen = 0
    while ($stack.Count -gt 0 -and $filesSeen -lt 2000) {
        $cur = $stack.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $cur.P -Force -ErrorAction SilentlyContinue)) {
            if ($item.PSIsContainer) {
                if ($cur.Depth -ge 4) { continue }
                if ($item.Name -match '^(?i:build|\.vscode|\.git|\.svn|\.hg|node_modules|\.venv|venv|dist|target|\.idea|_minted.*)$') { continue }
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                $stack.Push(@{ P = $item.FullName; Depth = $cur.Depth + 1 })
            } elseif ($item.Extension -ieq '.tex') {
                $filesSeen++
                try {
                    $head = (Get-Content -LiteralPath $item.FullName -TotalCount 140 -ErrorAction Stop) -join "`n"
                    if ($head -match '(?m)^\s*\\document(class|style)(\[|\{)') { $rootDocs.Add($item.FullName) }
                    else { $otherTex.Add($item.FullName) }
                } catch { $otherTex.Add($item.FullName) }
            }
        }
    }
    if ($rootDocs.Count -gt 0) { return $rootDocs.ToArray() }
    return $otherTex.ToArray()
}
function Choose-Source([string]$ExplicitFile) {
    if ($ExplicitFile) {
        $selected = Get-AbsPath $ExplicitFile $script:Workspace
        if (-not (Test-Path -LiteralPath $selected -PathType Leaf) -or [IO.Path]::GetExtension($selected) -ine '.tex') {
            throw ("The requested .tex file does not exist: " + $selected)
        }
        # Honor `% !TeX root = ../thesis.tex` when explicitly invoked on a chapter.
        $head = (Get-Content -LiteralPath $selected -TotalCount 30 -ErrorAction SilentlyContinue) -join "`n"
        if ($head -notmatch '\\documentclass' -and $head -match '(?im)^\s*%\s*!TeX\s+root\s*=\s*(.+?)\s*$') {
            $possible = Get-AbsPath $Matches[1].Trim(' ', '"', "'") ([IO.Path]::GetDirectoryName($selected))
            if (Test-Path -LiteralPath $possible -PathType Leaf) {
                Add-Log ("Magic root directive: $selected -> $possible")
                $selected = $possible
            } else { Add-Warning ('Magic root directive refers to a missing file: ' + $possible) }
        }
        return $selected
    }
    $candidates = @(Get-TeXRootCandidates $script:Workspace)
    if ($candidates.Count -eq 1) { return $candidates[0] }
    if ($candidates.Count -eq 0) {
        Add-Fix 'No .tex file found. Put your .tex document in the project directory, use -ProjectRoot, or specify -TexFile with its full path.'
        throw 'No .tex source file was found in the project (scanned up to four directory levels).'
    }
    Add-Log ('Found ' + $candidates.Count + ' possible root files:')
    for ($i=0; $i -lt $candidates.Count; $i++) { Add-Log ('  [' + ($i+1) + '] ' + $candidates[$i]) }
    if (-not $script:NoInteraction) {
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            $chooser = New-Object System.Windows.Forms.OpenFileDialog
            $chooser.Title = 'Select a LaTeX root .tex file (not a chapter)'
            $chooser.InitialDirectory = $script:Workspace
            $chooser.Filter = 'LaTeX source (*.tex)|*.tex'
            $chooser.CheckFileExists = $true
            if ($chooser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $chooser.FileName }
        } catch { Add-Warning ('Graphical file selector unavailable: ' + $_.Exception.Message) }
        while ($true) {
            $choice = Read-Host ('Choose a file [1-' + $candidates.Count + '] (Enter to cancel)')
            if (-not $choice) { break }
            $num = 0
            if ([int]::TryParse($choice, [ref]$num) -and $num -ge 1 -and $num -le $candidates.Count) {
                return $candidates[$num - 1]
            }
        }
    }
    Add-Fix 'Multiple root documents found. Run: .\setup-latex.ps1 -TexFile "your-document.tex" (or drag the .tex file onto setup-latex.bat).'
    throw 'Cannot select a root document automatically when there are multiple candidates.'
}
function Prepare-IncludeDirectories([string]$RootDir, [string]$DestDir) {
    $stack = New-Object 'System.Collections.Generic.Stack[object]'
    $stack.Push(@{ P = $RootDir; Depth = 0 })
    $count = 0
    $base = $RootDir.TrimEnd('\','/').Length
    while ($stack.Count -gt 0 -and $count -lt 1000) {
        $cur = $stack.Pop()
        if ($cur.Depth -ge 6) { continue }
        foreach ($dir in @(Get-ChildItem -LiteralPath $cur.P -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($dir.Name -match '^(?i:build|\.vscode|\.git|\.svn|\.hg|node_modules|\.venv|venv|dist|target|\.idea|_minted.*)$') { continue }
            if (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $rel = $dir.FullName.Substring($base).TrimStart('\','/')
            if ($rel) { [void][IO.Directory]::CreateDirectory((Join-Path $DestDir $rel)) }
            $stack.Push(@{ P = $dir.FullName; Depth = $cur.Depth + 1 })
            $count++
        }
    }
}

# VS Code accepts JSONC; parse its comments/trailing commas without altering strings.
function ConvertFrom-JsonC([string]$InputText) {
    $chars = $InputText.ToCharArray()
    $inside = $false; $escaped = $false; $line = $false; $block = $false
    for ($i=0; $i -lt $chars.Length; $i++) {
        $c = $chars[$i]
        $next = if ($i+1 -lt $chars.Length) { $chars[$i+1] } else { [char]0 }
        if ($line) { if ($c -eq "`n" -or $c -eq "`r") { $line = $false } else { $chars[$i] = ' ' }; continue }
        if ($block) {
            if ($c -eq '*' -and $next -eq '/') { $chars[$i]=' '; $chars[$i+1]=' '; $i++; $block=$false }
            elseif ($c -ne "`n" -and $c -ne "`r") { $chars[$i]=' ' }
            continue
        }
        if ($inside) {
            if ($escaped) { $escaped = $false }
            elseif ($c -eq '\') { $escaped = $true }
            elseif ($c -eq '"') { $inside = $false }
            continue
        }
        if ($c -eq '"') { $inside = $true; continue }
        if ($c -eq '/' -and $next -eq '/') { $chars[$i]=' '; $chars[$i+1]=' '; $i++; $line=$true; continue }
        if ($c -eq '/' -and $next -eq '*') { $chars[$i]=' '; $chars[$i+1]=' '; $i++; $block=$true; continue }
    }
    $inside = $false; $escaped = $false
    for ($i=0; $i -lt $chars.Length; $i++) {
        $c = $chars[$i]
        if ($inside) {
            if ($escaped) { $escaped = $false }
            elseif ($c -eq '\') { $escaped = $true }
            elseif ($c -eq '"') { $inside = $false }
            continue
        }
        if ($c -eq '"') { $inside = $true; continue }
        if ($c -eq ',') {
            $j = $i + 1
            while ($j -lt $chars.Length -and [char]::IsWhiteSpace($chars[$j])) { $j++ }
            if ($j -lt $chars.Length -and ($chars[$j] -eq '}' -or $chars[$j] -eq ']')) { $chars[$i]=' ' }
        }
    }
    return (ConvertFrom-Json -InputObject (-join $chars) -ErrorAction Stop)
}
function Get-PersistentBuildRunnerContent {
    return @'
#requires -Version 5.1
<#
 Permanent LaTeX Workshop runner. Keep this file inside .vscode/.
 Works after the original setup BAT/PS1 files and build/ have been deleted.
 XeLaTeX -> build/; publish only the final PDF beside the source .tex.
#>
[CmdletBinding()]
param(
    [string]$MainFile,
    [string]$ProjectRoot,
    [string]$TeXBin
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Pick-Latexmk([string]$Hint) {
    $bins = New-Object 'System.Collections.Generic.List[string]'
    if ($Hint) { $bins.Add($Hint) }
    foreach ($item in @('latexmk.exe','latexmk')) {
        $found = Get-Command -Name $item -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $bins.Add([IO.Path]::GetDirectoryName($found.Source)) }
    }
    foreach ($base in @($env:TEXLIVE_ROOT, $env:TEXDIR, 'D:\APPgallery\texlive\texlive',
                       'C:\texlive','D:\texlive','E:\texlive')) {
        if (-not $base -or -not (Test-Path -LiteralPath $base -PathType Container)) { continue }
        $bins.Add($base)
        $bins.Add((Join-Path $base 'bin\windows'))
        foreach ($y in @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^20[0-9]{2}$' } | Sort-Object Name -Descending)) {
            $bins.Add((Join-Path $y.FullName 'bin\windows'))
        }
    }
    foreach ($bin in $bins) {
        if (-not $bin) { continue }
        $exe = Join-Path $bin 'latexmk.exe'
        $xe = Join-Path $bin 'xelatex.exe'
        if ((Test-Path -LiteralPath $exe -PathType Leaf) -and (Test-Path -LiteralPath $xe -PathType Leaf)) {
            $env:Path = $bin + ';' + $env:Path
            return $exe
        }
    }
    throw 'latexmk.exe / xelatex.exe not found. Check TeX Live and the -TeXBin argument in .vscode/settings.json.'
}

function Make-IncludeFolders([string]$Root, [string]$Build) {
    $todo = New-Object 'System.Collections.Generic.Stack[object]'
    $todo.Push(@{ Path = $Root; Depth = 0 })
    $seen = 0
    $prefix = $Root.TrimEnd('\','/').Length
    while ($todo.Count -gt 0 -and $seen -lt 600) {
        $task = $todo.Pop()
        if ($task.Depth -ge 7) { continue }
        foreach ($dir in @(Get-ChildItem -LiteralPath $task.Path -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($dir.Name -match '^(?i:build|\.vscode|\.git|\.svn|\.hg|node_modules|\.venv|venv|dist|target|\.idea|_minted.*)$') { continue }
            if (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $rel = $dir.FullName.Substring($prefix).TrimStart('\','/')
            if ($rel) { [void][IO.Directory]::CreateDirectory((Join-Path $Build $rel)) }
            $todo.Push(@{ Path = $dir.FullName; Depth = $task.Depth + 1 })
            $seen++
            if ($seen -ge 600) { break }
        }
    }
}

function Archive-OldAux([string]$Root, [string]$Build, [string]$Stem) {
    $escaped = [regex]::Escape($Stem)
    $suffix = '(aux|log|out|toc|synctex\.gz|synctex|fls|fdb_latexmk|xdv|dvi|ps|bbl|bcf|blg|run\.xml|lof|lot|lol|nav|snm|vrb|idx|ind|ilg|acn|acr|alg|glg|glo|gls|ist|nlo|nls|thm|maf|mtc|mtc0|spl|brf)'
    $matcher = '^(?i:' + $escaped + ')\.' + $suffix + '$'
    $folder = Join-Path (Join-Path $Build 'legacy') (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
    foreach ($f in @(Get-ChildItem -LiteralPath $Root -File -Force -ErrorAction SilentlyContinue)) {
        if ($f.Name -notmatch $matcher) { continue }
        try {
            [void][IO.Directory]::CreateDirectory($folder)
            $target = Join-Path $folder $f.Name
            $n = 0
            while (Test-Path -LiteralPath $target) { $n++; $target = Join-Path $folder ($f.Name + '.' + $n) }
            Move-Item -LiteralPath $f.FullName -Destination $target -ErrorAction Stop
            Write-Host ('Archived old root auxiliary: ' + $f.Name)
        } catch {
            Write-Warning ('Cannot archive in-use file ' + $f.Name + ': ' + $_.Exception.Message)
        }
    }
}

$exitCode = 1
try {
    if (-not $ProjectRoot) { $ProjectRoot = [IO.Directory]::GetParent($PSScriptRoot).FullName }
    $root = [IO.Path]::GetFullPath($ProjectRoot)
    if (-not $MainFile) { $MainFile = 'main.tex' }
    $source = if ([IO.Path]::IsPathRooted($MainFile)) { [IO.Path]::GetFullPath($MainFile) } else { [IO.Path]::GetFullPath((Join-Path $root $MainFile)) }
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw ('LaTeX source missing: ' + $source) }
    # Compile in the document's own directory, regardless of the VS Code workspace.
    $root = [IO.Path]::GetDirectoryName($source)
    $stem = [IO.Path]::GetFileNameWithoutExtension($source)
    $leaf = [IO.Path]::GetFileName($source)
    $build = Join-Path $root 'build'
    if ((Test-Path -LiteralPath $build) -and -not (Test-Path -LiteralPath $build -PathType Container)) {
        throw ('A file named build blocks the output folder: ' + $build)
    }
    [void][IO.Directory]::CreateDirectory($build)
    $stdout = Join-Path $build 'latexmk.stdout.log'
    $stderr = Join-Path $build 'latexmk.stderr.log'
    $latexmk = Pick-Latexmk $TeXBin
    Make-IncludeFolders $root $build
    Archive-OldAux $root $build $stem
    $src = if ($leaf.StartsWith('-')) { '.\' + $leaf } else { $leaf }
    $arg = @('-norc','-pdfxe','-synctex=1','-interaction=nonstopmode','-file-line-error',
             '-halt-on-error','-outdir=build','-auxdir=build',$src)
    # Quote arguments only if required (PowerShell 5.1 Start-Process takes a command-line string).
    $cmdline = (($arg | ForEach-Object { if ($_ -match '[\s"]') { '"' + $_.Replace('"','\"') + '"' } else { $_ } }) -join ' ')
    Write-Host ('[CleanBuild] Compiling: ' + $source)
    Write-Host ('[CleanBuild] Working directory: ' + $root)
    $start = @{
        FilePath = $latexmk
        ArgumentList = $cmdline
        WorkingDirectory = $root
        Wait = $true
        PassThru = $true
        RedirectStandardOutput = $stdout
        RedirectStandardError = $stderr
        NoNewWindow = $true
        ErrorAction = 'Stop'
    }
    $proc = Start-Process @start
    Archive-OldAux $root $build $stem
    $builtPdf = Join-Path $build ($stem + '.pdf')
    $rootPdf = Join-Path $root ($stem + '.pdf')
    if ($proc.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $builtPdf -PathType Leaf)) {
        foreach ($logPath in @($stdout, $stderr)) {
            if (Test-Path -LiteralPath $logPath -PathType Leaf) {
                Get-Content -LiteralPath $logPath -Tail 35 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
            }
        }
        throw ('LaTeX compilation failed (' + $proc.ExitCode + '). Check ' + $stdout)
    }
    # Keep the final PDF visible at the project root; never publish auxiliary files.
    # Republish even if build/main.pdf was already up-to-date but root/main.pdf was deleted.
    [IO.File]::Copy($builtPdf, $rootPdf, $true)
    # This status file lives in build/ only. Do not generate a root-level log.
    [IO.File]::WriteAllText((Join-Path $build 'last-build-status.txt'),
        ('SUCCESS ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + [Environment]::NewLine +
         'PDF: ' + $rootPdf + [Environment]::NewLine), $utf8)
    Write-Host ('[CleanBuild] PDF: ' + $rootPdf)
    Write-Host ('[CleanBuild] Auxiliary files: ' + $build)
    $exitCode = 0
} catch {
    # Preserve the last successfully published PDF and persist the error silently.
    $message = $_.Exception.Message
    try {
        $logRoot = if ($build) { $build } elseif ($root) { Join-Path $root 'build' } else { $null }
        if ($logRoot) {
            [void][IO.Directory]::CreateDirectory($logRoot)
            [IO.File]::WriteAllText((Join-Path $logRoot 'last-build-status.txt'),
                ('FAILED ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + [Environment]::NewLine +
                 $message + [Environment]::NewLine +
                 'Inspect latexmk.stdout.log, latexmk.stderr.log, and the TeX .log file.' + [Environment]::NewLine), $utf8)
        }
    } catch { }
    Write-Host ('[CleanBuild ERROR] ' + $message)
    $exitCode = 1
}
exit $exitCode

'@
}

function Get-HiddenBuildLauncherContent {
    return @'
Option Explicit
' Permanent no-window launcher. Run with wscript.exe //B //Nologo.
' The launcher waits for compilation to finish so LaTeX Workshop gets the exit status.
On Error Resume Next
Dim shell, fs, root, mainFile, texBin, ps, runner, command, result, logFolder, logFile, message, stream
If WScript.Arguments.Count < 2 Then WScript.Quit 64
Set shell = CreateObject("WScript.Shell")
Set fs = CreateObject("Scripting.FileSystemObject")
If Err.Number <> 0 Then WScript.Quit 1
mainFile = WScript.Arguments.Item(0)
root = WScript.Arguments.Item(1)
texBin = ""
If WScript.Arguments.Count >= 3 Then texBin = WScript.Arguments.Item(2)
runner = fs.BuildPath(fs.BuildPath(root, ".vscode"), "build-latex.ps1")
If Not fs.FileExists(runner) Then WScript.Quit 2
ps = fs.BuildPath(shell.ExpandEnvironmentStrings("%SystemRoot%"), "System32\WindowsPowerShell\v1.0\powershell.exe")
If Not fs.FileExists(ps) Then ps = "powershell.exe"
command = QuoteArgument(ps) & " -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " & QuoteArgument(runner) & " -MainFile " & QuoteArgument(mainFile) & " -ProjectRoot " & QuoteArgument(root)
If Len(Trim(texBin)) > 0 Then command = command & " -TeXBin " & QuoteArgument(texBin)
Err.Clear
result = shell.Run(command, 0, True)
If Err.Number <> 0 Then
    message = "Hidden launcher could not execute PowerShell: " & CStr(Err.Number) & " " & Err.Description
    Err.Clear
    logFolder = fs.BuildPath(root, "build")
    If Not fs.FolderExists(logFolder) Then fs.CreateFolder logFolder
    If fs.FolderExists(logFolder) Then
        logFile = fs.BuildPath(logFolder, "launcher-error.log")
        Set stream = fs.OpenTextFile(logFile, 8, True)
        If Not stream Is Nothing Then
            stream.WriteLine Now & " " & message
            stream.Close
        End If
    End If
    WScript.Quit 1
End If
WScript.Quit result

Function QuoteArgument(ByVal value)
    QuoteArgument = Chr(34) & Replace(CStr(value), Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function
'@
}

function Install-PersistentBuildRunner([string]$RootDir) {
    $vsDir = Join-Path $RootDir '.vscode'
    [void][IO.Directory]::CreateDirectory($vsDir)
    $runnerPath = Join-Path $vsDir 'build-latex.ps1'
    $text = (Get-PersistentBuildRunnerContent).TrimStart("`r", "`n")
    if (-not $text.EndsWith("`n")) { $text += "`n" }
    $text = $text.Replace("`r`n", "`n")
    $existing = if (Test-Path -LiteralPath $runnerPath -PathType Leaf) { [IO.File]::ReadAllText($runnerPath, [Text.Encoding]::UTF8) } else { $null }
    if ($existing -eq $text) { Add-Log ('Permanent runner unchanged: ' + $runnerPath); return }
    if ($null -ne $existing) {
        $archive = Join-Path $script:ReportDir 'settings-backups'
        [void][IO.Directory]::CreateDirectory($archive)
        $bak = New-UniqueBackup (Join-Path $archive 'build-latex.ps1')
        Copy-Item -LiteralPath $runnerPath -Destination $bak -ErrorAction Stop
    }
    $temp = Join-Path $script:ReportDir ('runner-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        # UTF-8 BOM ensures Windows PowerShell 5.1 handles future Chinese comments or paths.
        $enc = New-Object System.Text.UTF8Encoding($true)
        [IO.File]::WriteAllText($temp, $text, $enc)
        Copy-Item -LiteralPath $temp -Destination $runnerPath -Force -ErrorAction Stop
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
    Add-Log ('Installed permanent runner: ' + $runnerPath)
    $vbsPath = Join-Path $vsDir 'build-latex.vbs'
    $vbsText = (Get-HiddenBuildLauncherContent).Replace("`r`n", "`n").Replace("`n", "`r`n")
    $existingVbs = if (Test-Path -LiteralPath $vbsPath -PathType Leaf) {
        [IO.File]::ReadAllText($vbsPath, [Text.Encoding]::ASCII)
    } else { $null }
    if ($existingVbs -ne $vbsText) {
        if ($null -ne $existingVbs) {
            $backupFolder = Join-Path $script:ReportDir 'settings-backups'
            [void][IO.Directory]::CreateDirectory($backupFolder)
            $backupVbs = New-UniqueBackup (Join-Path $backupFolder 'build-latex.vbs')
            Copy-Item -LiteralPath $vbsPath -Destination $backupVbs -ErrorAction Stop
        }
        # ASCII-only VBS avoids Windows Script Host encoding ambiguity.
        $tempVbs = Join-Path $script:ReportDir ('launcher-' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [IO.File]::WriteAllText($tempVbs, $vbsText, [Text.Encoding]::ASCII)
            Copy-Item -LiteralPath $tempVbs -Destination $vbsPath -Force -ErrorAction Stop
        } finally {
            if (Test-Path -LiteralPath $tempVbs -PathType Leaf) { Remove-Item -LiteralPath $tempVbs -Force }
        }
        Add-Log ('Installed hidden launcher: ' + $vbsPath)
    } else { Add-Log ('Hidden launcher unchanged: ' + $vbsPath) }
}

function Update-VSCodeConfig([string]$ConfigRoot) {
    if (-not $ConfigRoot) { $ConfigRoot = $script:Workspace }
    $vsDir = Join-Path $ConfigRoot '.vscode'
    [void][IO.Directory]::CreateDirectory($vsDir)
    $path = Join-Path $vsDir 'settings.json'
    $settings = [ordered]@{}
    $original = $null
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $original = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
        if ($original.Trim()) {
            try {
                $parsed = ConvertFrom-JsonC $original
                if ($parsed -isnot [pscustomobject]) { throw 'settings.json must be a JSON object.' }
                foreach ($p in $parsed.PSObject.Properties) { $settings[$p.Name] = $p.Value }
            } catch {
                throw ('Existing VS Code settings.json is invalid. Kept unchanged: ' + $path + '; ' + $_.Exception.Message)
            }
        }
    }
    # Windows Script Host (GUI subsystem) does not create a console window.
    # The permanent .vbs invokes the permanent .ps1 invisibly and waits for its exit code.
    # %DIR% denotes the actual root .tex directory even if a parent workspace is opened.
    $tool = [ordered]@{
        name = 'permanent-silent-xelatex'
        command = 'wscript.exe'
        args = @('//B','//Nologo', '%DIR%/.vscode/build-latex.vbs',
                 '%DOC_EXT%', '%DIR%', $script:DetectedBin)
        cwd = '%DIR%'
    }
    $settings['latex-workshop.latex.tools'] = @($tool)
    $settings['latex-workshop.latex.recipes'] = @([ordered]@{
        name='XeLaTeX | silent clean build + root PDF'; tools=@('permanent-silent-xelatex')
    })
    # The *published* PDF is next to main.tex, while latexmk cache stays in build/.
    # LaTeX Workshop previews build/main.pdf beside its build/main.synctex.gz.
    # A matching convenience copy main.pdf is published in the project root.
    $settings['latex-workshop.latex.outDir'] = '%DIR%/build'
    $settings['latex-workshop.latex.auxDir'] = '%DIR%/build'
    $settings['latex-workshop.latex.recipe.default'] = 'first'
    $settings['latex-workshop.latex.autoBuild.run'] = 'onSave'
    $settings['latex-workshop.latex.autoClean.run'] = 'never'
    $settings['latex-workshop.latex.build.fromFolder'] = ''
    $settings['latex-workshop.latex.build.enableMagicComments'] = $false
    $settings['latex-workshop.latex.build.forceRecipeUsage'] = $true
    $settings['latex-workshop.latex.autoBuild.cleanAndRetry.enabled'] = $false
    $settings['latex-workshop.view.pdf.viewer'] = 'tab'
    foreach ($old in @('latex-workshop.latex.external.build.command',
                       'latex-workshop.latex.external.build.args')) {
        if ($settings.Contains($old)) { $settings.Remove($old) }
    }
    $json = (ConvertTo-Json -InputObject $settings -Depth 60) + [Environment]::NewLine
    if ($json -ne $original) {
        if ($null -ne $original) {
            $backupDir = Join-Path $script:ReportDir 'settings-backups'
            [void][IO.Directory]::CreateDirectory($backupDir)
            $suffix = if ($ConfigRoot -ieq $script:Workspace) { 'project' } else { 'parent-workspace' }
            $backup = New-UniqueBackup (Join-Path $backupDir ($suffix + '-settings.json'))
            Copy-Item -LiteralPath $path -Destination $backup -ErrorAction Stop
            Add-Log ('VS Code settings backup: ' + $backup)
        }
        $tmpPath = Join-Path $script:ReportDir ('settings-' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [IO.File]::WriteAllText($tmpPath, $json, $script:Encoding)
            Copy-Item -LiteralPath $tmpPath -Destination $path -Force -ErrorAction Stop
        } finally { if (Test-Path -LiteralPath $tmpPath) { Remove-Item -LiteralPath $tmpPath -Force } }
    }
    Add-Log ('Configured permanent VS Code recipe: ' + $path)
}

# Only collect outputs belonging to a .tex root. Never touch unrelated PDFs,
# user data, .tex, .bib, .sty, images, or actively locked files.
function Move-LegacyOutputs([string]$RootDir) {
    $items = @(Get-ChildItem -LiteralPath $RootDir -File -Force -ErrorAction SilentlyContinue)
    $rootNames = @{}
    foreach ($tex in $items) {
        if ($tex.Extension -ieq '.tex') {
            $rootNames[[IO.Path]::GetFileNameWithoutExtension($tex.Name).ToLowerInvariant()] = $true
        }
    }
    if ($script:SourceFile) {
        $rootNames[[IO.Path]::GetFileNameWithoutExtension($script:SourceFile).ToLowerInvariant()] = $true
    }
    $generatedExts = @(
        'aux','log','out','toc','synctex','synctex.gz','fls','fdb_latexmk','xdv',
        'dvi','ps','bbl','bcf','blg','run.xml','lof','lot','lol','nav','snm',
        'vrb','idx','ind','ilg','acn','acr','alg','glg','glo','gls',
        'ist','nlo','nls','thm','maf','mtc','mtc0','spl','brf'
    )
    $exts = '(' + (($generatedExts | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')'
    $moved = 0
    $destDir = Join-Path (Join-Path $script:BuildDir 'legacy') (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
    foreach ($file in $items) {
        if ($file.Name -notmatch ('^(?i:(.+)\.' + $exts + ')$')) { continue }
        $rootName = $Matches[1].ToLowerInvariant()
        if (-not $rootNames.ContainsKey($rootName)) { continue }
        # Do not archive files changed since this run started by other active builds.
        try {
            [void][IO.Directory]::CreateDirectory($destDir)
            $dest = Join-Path $destDir $file.Name
            if (Test-Path -LiteralPath $dest) { $dest = New-UniqueBackup $dest }
            Move-Item -LiteralPath $file.FullName -Destination $dest -ErrorAction Stop
            Add-Log ('Archived root artifact: ' + $file.Name + ' -> ' + $dest)
            $moved++
        } catch {
            Add-Warning ('Cannot archive root file (possibly locked by another compiler): ' + $file.FullName + '; ' + $_.Exception.Message)
        }
    }
    if ($moved -gt 0) { Add-Log ('Archived root artifacts: ' + $moved) }
}

function Invoke-ProjectCompile {
    $script:SourceDir = [IO.Path]::GetDirectoryName($script:SourceFile)
    if ([IO.Path]::GetFileName($script:SourceDir) -ieq 'build') { throw 'Source .tex is inside build/. Move it outside first.' }
    $script:BuildDir = Join-Path $script:SourceDir 'build'
    if ((Test-Path -LiteralPath $script:BuildDir) -and -not (Test-Path -LiteralPath $script:BuildDir -PathType Container)) {
        throw ('Output blocked by file named build: ' + $script:BuildDir)
    }
    [void][IO.Directory]::CreateDirectory($script:BuildDir)
    Move-LegacyOutputs $script:SourceDir
    Prepare-IncludeDirectories $script:SourceDir $script:BuildDir
    $leaf = [IO.Path]::GetFileName($script:SourceFile)
    $stem = [IO.Path]::GetFileNameWithoutExtension($script:SourceFile)
    $script:PdfPath = Join-Path $script:SourceDir ($stem + '.pdf')
    $cachePdf = Join-Path $script:BuildDir ($stem + '.pdf')
    Add-Log ('Compiling source: ' + $script:SourceFile)
    Add-Log ('Published PDF: ' + $script:PdfPath)
    Add-Log ('Cache PDF: ' + $cachePdf)
    $runner = Join-Path (Join-Path $script:SourceDir '.vscode') 'build-latex.ps1'
    if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw ('Permanent runner was not installed: ' + $runner) }
    $powerShell = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $powerShell -PathType Leaf)) { $powerShell = 'powershell.exe' }
    $args = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
              '-File',$runner,'-MainFile',$script:SourceFile,'-ProjectRoot',$script:SourceDir,
              '-TeXBin',$script:DetectedBin)
    $rc = Invoke-CommandLogged $powerShell $args $script:SourceDir 'setup-compile'
    Move-LegacyOutputs $script:SourceDir
    if ($rc -ne 0 -or -not (Test-Path -LiteralPath $cachePdf -PathType Leaf) -or
        -not (Test-Path -LiteralPath $script:PdfPath -PathType Leaf)) {
        $errorText = Find-FirstTeXError @((Join-Path $script:BuildDir ($stem + '.log')),
                                           (Join-Path $script:ReportDir 'setup-compile.stdout.log'),
                                           (Join-Path $script:ReportDir 'setup-compile.stderr.log'))
        if ($errorText) { Add-Log ('[FIRST TEX ERROR] ' + $errorText) }
        Add-Fix (Interpret-TeXError $errorText)
        throw ('Compilation failed (exit ' + $rc + '). Open build/setup-compile.stdout.log or build/' + $stem + '.log.')
    }
    Add-Log ('[OK] Published only final PDF to root: ' + $script:PdfPath)
}

function Save-FinalReport([bool]$Success, [string]$Message) {
    $state = if ($Success) { 'PASS' } else { 'FAIL' }
    Add-Log ('--- FINAL RESULT: ' + $state + ' ---')
    Add-Log ('Stage: ' + $script:Stage)
    Add-Log ('Reason: ' + $Message)
    Add-Log ('Report log: ' + $script:StatusLog)
    if ($script:PdfPath) { Add-Log ('PDF location: ' + $script:PdfPath) }
    $report = Join-Path $script:ReportDir 'latex-diagnostic-report.txt'
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('Portable LaTeX diagnostic report')
    $lines.Add('Result: ' + $state)
    $lines.Add('Date: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $lines.Add('Stage: ' + $script:Stage)
    $lines.Add('Reason: ' + $Message)
    $lines.Add('Project: ' + $script:Workspace)
    $lines.Add('Source: ' + $script:SourceFile)
    $lines.Add('latexmk: ' + $script:Latexmk)
    $lines.Add('xelatex: ' + $script:XeLaTeX)
    $lines.Add('PDF: ' + $script:PdfPath)
    $lines.Add('')
    $lines.Add('Warnings:')
    foreach ($w in $script:Warnings) { $lines.Add(' - ' + $w) }
    $lines.Add('Recommended fixes:')
    foreach ($f in $script:Recommendations) { $lines.Add(' - ' + $f) }
    $lines.Add('')
    $lines.Add('Log files:')
    $lines.Add(' - ' + $script:StatusLog)
    foreach ($prefix in @('setup-env','setup-compile')) {
        foreach ($stream in @('stdout','stderr')) {
            $f = Join-Path $script:ReportDir ($prefix + '.' + $stream + '.log')
            if (Test-Path -LiteralPath $f -PathType Leaf) { $lines.Add(' - ' + $f) }
        }
    }
    if ($script:SourceFile -and $script:BuildDir) {
        $sourceLog = Join-Path $script:BuildDir (([IO.Path]::GetFileNameWithoutExtension($script:SourceFile)) + '.log')
        if (Test-Path -LiteralPath $sourceLog -PathType Leaf) { $lines.Add(' - ' + $sourceLog) }
    }
    [IO.File]::WriteAllLines($report, $lines, $script:Encoding)
    Add-Log ('Diagnostic report: ' + $report)
}
function Show-Completion([bool]$Success) {
    if ($script:NoInteraction) { return }
    $headline = if ($Success) { 'LaTeX - 编译成功' } else { 'LaTeX - 需要修复' }
    $summary = $headline + "`n" + $script:Outcome + "`n`n诊断日志：" + $script:StatusLog
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        while ($true) {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                ($summary + "`n`n点击【是】：用记事本查看日志。`n点击【否】：手动关闭窗口。"),
                $headline, [System.Windows.Forms.MessageBoxButtons]::YesNo,
                $(if ($Success) { [System.Windows.Forms.MessageBoxIcon]::Information } else { [System.Windows.Forms.MessageBoxIcon]::Warning }))
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { break }
            try { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $script:StatusLog + '"') -ErrorAction Stop }
            catch { Write-Host ('Open this log manually: ' + $script:StatusLog) }
        }
    } catch {
        Write-Host '按 L 后回车查看日志；直接回车结束。'
        try {
            while ($true) {
                $key = Read-Host 'L / Enter'
                if ($key -notin @('l','L')) { break }
                Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $script:StatusLog + '"') -ErrorAction SilentlyContinue
            }
        } catch { Write-Host 'Interactive input is unavailable; check the log path printed above.' }
    }
}

$exitCode = 1
try {
    $script:Stage = 'locating project directory'
    if (-not $ProjectRoot -and $env:LATEX_SETUP_PROJECT_ROOT) { $ProjectRoot = $env:LATEX_SETUP_PROJECT_ROOT }
    if (-not $ProjectRoot) { $ProjectRoot = $PSScriptRoot }
    if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).Path }
    $script:Workspace = Get-AbsPath $ProjectRoot (Get-Location).Path
    # Drag-and-drop an absolute .tex from another folder: use that folder as
    # the workspace so VS Code settings/logs are not written beside the launcher.
    if ($TexFile -and [IO.Path]::IsPathRooted($TexFile) -and (Test-Path -LiteralPath $TexFile -PathType Leaf)) {
        $fullFile = [IO.Path]::GetFullPath($TexFile)
        $projectPrefix = $script:Workspace.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
        if (-not $fullFile.StartsWith($projectPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $script:Workspace = [IO.Path]::GetDirectoryName($fullFile)
            Write-Host ('Using selected document directory as workspace: ' + $script:Workspace)
        }
    }
    if (-not (Test-Path -LiteralPath $script:Workspace -PathType Container)) { throw ('Project directory does not exist: ' + $script:Workspace) }
    # Choose the root before opening logs, so source/PDF/logs share one build folder.
    # Diagnostic-only mode still works when there are no .tex documents.
    if (-not $DiagnoseOnly) {
        $script:Stage = 'detecting the document root'
        $script:SourceFile = Choose-Source $TexFile
        $script:Workspace = [IO.Path]::GetDirectoryName($script:SourceFile)
    }
    $script:Stage = 'preparing report directory'
    Initialize-Logs
    $script:Stage = 'scanning and diagnosing TeX installation'
    Resolve-TeXTools $TeXBin
    $script:Stage = 'testing isolated XeLaTeX document'
    Test-MinimalXeLaTeX
    if ($DiagnoseOnly) {
        $script:Stage = 'diagnostic complete'
        $script:ReportOK = $true
        $script:Outcome = '环境诊断通过：独立 XeLaTeX 测试成功（未编译实际文档）。'
        $exitCode = 0
    } else {
        $script:Stage = 'installing permanent build runner'
        Install-PersistentBuildRunner $script:Workspace
        if (-not $NoSettings) {
            $script:Stage = 'configuring workspace VS Code'
            try {
                Update-VSCodeConfig $script:Workspace
                # If the parent directory is already a VS Code workspace,
                # its settings override child settings when opened as the workspace.
                # Only adjust an existing parent .vscode, never create it unsolicited.
                $parent = [IO.Directory]::GetParent($script:Workspace)
                if ($null -ne $parent -and
                    $parent.FullName -ne [IO.Path]::GetPathRoot($script:Workspace) -and
                    (Test-Path -LiteralPath (Join-Path $parent.FullName '.vscode') -PathType Container)) {
                    Update-VSCodeConfig $parent.FullName
                }
            } catch {
                Add-Fix 'Repair project or parent .vscode/settings.json and rerun the initializer.'
                throw ('Failed to install permanent VS Code settings: ' + $_.Exception.Message)
            }
        }
        $script:Stage = 'building source document'
        Invoke-ProjectCompile
        $script:Stage = 'finished'
        $script:ReportOK = $true
        $script:Outcome = '初始化成功：根目录只保留最终 PDF，永久静默编译器在 .vscode/build-latex.vbs + build-latex.ps1。PDF：' + $script:PdfPath
        $exitCode = 0
    }
} catch {
    $script:Outcome = $_.Exception.Message
    Write-Host ('[ERROR] ' + $script:Stage + ': ' + $script:Outcome)
    if ($script:StatusLog) { Add-Log ('[ERROR] ' + $script:Stage + ': ' + $script:Outcome) }
} finally {
    if ($script:StatusLog) {
        try { Save-FinalReport $script:ReportOK $script:Outcome }
        catch { Write-Host ('Could not write diagnostic report: ' + $_.Exception.Message) }
    }
    Write-Host ('Result: ' + $(if ($script:ReportOK) { 'SUCCESS' } else { 'FAILED' }))
    if ($script:StatusLog) { Write-Host ('Full log: ' + $script:StatusLog) }
    Show-Completion $script:ReportOK
}
exit $exitCode
