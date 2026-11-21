#requires -Version 5.1
# The outer guard also catches argument-binding errors before the core starts.
$entryArguments = @($args)
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$script:SetupExitCode = 1
$skipFinalPrompt = ($env:LATEX_SETUP_NO_PAUSE -eq '1') -or ($env:LATEX_SETUP_BAT_OWNER -eq '1') -or ($entryArguments -contains '-NoPause')
$setupCore = {
# BEGIN SETUP CORE
#requires -Version 5.1
<#
 Portable LaTeX diagnostics / builder for Windows PowerShell 5.1+.
 No administrator rights, external modules, fixed TeX Live year, or main.tex required.
 See README.md for examples and exit codes.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][Alias('File','MainFile')][string]$TexFile,
    [string]$ProjectRoot,
    [string]$TeXBin,
    [switch]$DiagnoseOnly,
    [switch]$NoSettings,
    [switch]$NoPause,
    [switch]$ConfigureOnly,
    [switch]$CleanOnly,
    [switch]$ProjectOnly,
    [switch]$Elevate,
    [ValidateSet('build','clean','clean-all')][string]$Mode = 'build'
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
    if ((Test-Path -LiteralPath $script:ReportDir) -and ((Get-Item -LiteralPath $script:ReportDir -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'build must not be a symbolic link or junction.'
    }
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
        elseif ($name -eq 'xdvipdfmx') { throw 'Required tool missing: xdvipdfmx. Install the dvipdfmx component in your TeX distribution.' }
        elseif ($name -eq 'perl') { Add-Log 'No standalone Perl on PATH; TeX Live may use its bundled Perl. The real health check verifies latexmk.' }
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

# ProcessStartInfo uses literal paths, hides native children and reads both pipes concurrently.
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
        WindowStyle = 'Hidden'
        ErrorAction = 'Stop'
    }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Exe
    $info.Arguments = $quoted -join ' '
    $info.WorkingDirectory = $WorkingDir
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    [IO.File]::WriteAllText($outFile, $outTask.Result, $script:Encoding)
    [IO.File]::WriteAllText($errFile, $errTask.Result, $script:Encoding)
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
        try {
            $resolvedTemp = [IO.Path]::GetFullPath($temp)
            if (-not $resolvedTemp.StartsWith($script:ReportDir.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe temporary cleanup path' }
            for ($retry=0; ; $retry++) {
                try { [IO.Directory]::Delete($resolvedTemp,$true); break }
                catch { if ($retry -ge 4) { throw }; Start-Sleep -Milliseconds 200 }
            }
        }
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
    $main = Join-Path $script:Workspace 'main.tex'
    if ($candidates -contains $main) { return $main }
    if ($candidates.Count -eq 1) { return $candidates[0] }
    if ($candidates.Count -eq 0) {
        Add-Fix 'No .tex file found. Put your .tex document in the project directory, use -ProjectRoot, or specify -TexFile with its full path.'
        throw 'No .tex source file was found in the project (scanned up to four directory levels).'
    }
    Add-Log ('Found ' + $candidates.Count + ' possible root files:')
    for ($i=0; $i -lt $candidates.Count; $i++) { Add-Log ('  [' + ($i+1) + '] ' + $candidates[$i]) }
    if (-not $script:NoInteraction) {
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
[CmdletBinding()]
param(
    [Alias('TexFile','File')][string]$MainFile,
    [string]$ProjectRoot,
    [string]$TeXBin,
    [ValidateSet('build','clean','clean-all')][string]$Mode = 'build',
    [ValidateRange(1,600)][int]$LockTimeout = 120
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
$root = ''; $build = ''; $lock = $null; $proc = $null; $exitCode = 1; $ownsLock = $false; $processStarted = $false
$script:Workspace = ''
function Add-Log([string]$Text) { Write-Host $Text }
function Get-AbsPath([string]$PathText, [string]$Base) {
    if ([IO.Path]::IsPathRooted($PathText)) { return [IO.Path]::GetFullPath($PathText) }
    return [IO.Path]::GetFullPath((Join-Path $Base $PathText))
}
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

function Assert-LocalDirectory([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Unsafe output/configuration directory (file or junction/symlink): $Path"
        }
    } else { [void][IO.Directory]::CreateDirectory($Path) }
}
function Get-SafeFiles([string]$Directory) {
    foreach ($item in @(Get-ChildItem -LiteralPath $Directory -Force)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ($item.PSIsContainer) {
            if ($item.Name -notmatch '^(build|legacy|settings-backups|\.vscode|\.git|node_modules|\.venv)$') { Get-SafeFiles $item.FullName }
        } else { $item }
    }
}
function Archive-Legacy {
    $folder = Join-Path $build ('legacy/' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    foreach ($file in @(Get-SafeFiles $root)) {
        # .log/.out/.ps/.ist can be user data; only migrate those with a matching TeX source.
        $match = [regex]::Match($file.Name, '^(.*)\.(aux|log|out|toc|synctex(?:\.gz)?|fls|fdb_latexmk|xdv|bbl|bcf|blg|run\.xml|lof|lot|nav|snm|vrb|idx|ind|ilg)$', 'IgnoreCase')
        if (-not $match.Success) { continue }
        if ($match.Groups[2].Value -match '^(log|out)$' -and -not (Test-Path -LiteralPath (Join-Path $file.DirectoryName ($match.Groups[1].Value + '.tex')))) { continue }
        $rel = $file.FullName.Substring($root.TrimEnd('\').Length + 1)
        $destination = Join-Path $folder $rel
        try {
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
            [IO.File]::Move($file.FullName, $destination)
        } catch { Write-Warning ("Cannot archive $($file.FullName): " + $_.Exception.Message) }
    }
}
function Invoke-Latexmk([string]$Executable, [string[]]$Arguments) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    # Every argument is quoted. Backslashes before a closing quote follow the Windows CRT rules.
    $info.Arguments = (($Arguments | ForEach-Object { '"' + [regex]::Replace($_, '(\\*)"', '$1$1\"').TrimEnd('\') + ('\' * (2 * ($_.Length - $_.TrimEnd('\').Length))) + '"' }) -join ' ')
    $info.WorkingDirectory = $root
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $script:proc = New-Object Diagnostics.Process
    $script:proc.StartInfo = $info
    [void]$script:proc.Start()
    $script:processStarted = $true
    $outTask = $script:proc.StandardOutput.ReadToEndAsync()
    $errTask = $script:proc.StandardError.ReadToEndAsync()
    $script:proc.WaitForExit()
    [IO.File]::WriteAllText((Join-Path $build 'latexmk.stdout.log'), $outTask.Result, $utf8)
    [IO.File]::WriteAllText((Join-Path $build 'latexmk.stderr.log'), $errTask.Result, $utf8)
    return $script:proc.ExitCode
}
try {
    if (-not $ProjectRoot) { $ProjectRoot = [IO.Directory]::GetParent($PSScriptRoot).FullName }
    $root = [IO.Path]::GetFullPath($ProjectRoot)
    $configPath = Join-Path $root '.vscode/latex-project.json'
    if (Test-Path -LiteralPath $configPath) {
        $config = [IO.File]::ReadAllText($configPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if (-not $MainFile) { $MainFile = $config.mainFile }
        if (-not $TeXBin) { $TeXBin = $config.texBin }
    }
    if (-not $MainFile) { $MainFile = 'main.tex' }
    if (-not $MainFile.EndsWith('.tex',[StringComparison]::OrdinalIgnoreCase)) { $MainFile += '.tex' }
    $source = Get-AbsPath $MainFile $root
    if ($Mode -eq 'build' -and -not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing TeX source: $source" }
    if ([IO.Path]::GetDirectoryName($source) -ine $root) { throw 'MainFile must be in ProjectRoot; initialize the root document directory.' }
    $script:Workspace = $root
    $build = Join-Path $root 'build'
    Assert-LocalDirectory (Join-Path $root '.vscode')
    # Lock outside build/: deleting build/ cannot change the lock identity.
    $lockPath = Join-Path $root '.vscode/.latex-operation.lock'
    if ((Test-Path -LiteralPath $lockPath) -and ((Get-Item -LiteralPath $lockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Lock file must not be a symlink.' }
    $deadline = [DateTime]::UtcNow.AddSeconds($LockTimeout)
    do {
        try { $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
        catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { $exitCode = 75; throw 'Another build/setup/clean is running (lock timeout).' }
            Start-Sleep -Milliseconds 150
        }
    } until ($null -ne $lock)
    $ownsLock = $true
    Assert-LocalDirectory $build
    # Exercise create/read/modify/delete, rather than trusting read-only directory attributes.
    $probe = Join-Path $build ('.permission-' + [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($probe, 'write', $utf8)
    [IO.File]::AppendAllText($probe, 'modify', $utf8)
    [void][IO.File]::ReadAllText($probe)
    [IO.File]::Delete($probe)
    Archive-Legacy
    $stem = [IO.Path]::GetFileNameWithoutExtension($source)
    if ($Mode -ne 'build') {
        $failed = $false
        foreach ($file in @(Get-SafeFiles $build)) {
            if ($file.Name -match '^(setup-|latexmk\.|last-build-status|last-clean-status|latex-diagnostic)' -or $file.Name -like '*.tex' -or $file.Name -like '*.bib') { continue }
            $known = $file.Name -match '\.(aux|out|toc|synctex(?:\.gz)?|fls|fdb_latexmk|xdv|dvi|bbl|bcf|blg|run\.xml|lof|lot|lol|nav|snm|vrb|idx|ind|ilg|acn|acr|alg|glg|glo|gls|nlo|nls|thm|maf|mtc\d*|spl|brf)$'
            if ($Mode -eq 'clean-all' -and $file.Name -match '\.(pdf|log)$') { $known = $true }
            if ($known) {
                try { [IO.File]::Delete($file.FullName) }
                catch { $failed = $true; Write-Warning ("Cannot clean $($file.FullName): " + $_.Exception.Message) }
            }
        }
        if ($failed) { throw 'Some generated files are locked or access was denied. Close readers and retry.' }
        [IO.File]::WriteAllText((Join-Path $build 'last-clean-status.txt'), "SUCCESS $Mode $(Get-Date -Format s)", $utf8)
        $exitCode = 0
    } else {
        $directories = New-Object 'System.Collections.Generic.Stack[string]'
        $directories.Push($build)
        while ($directories.Count -gt 0) {
            foreach ($item in @(Get-ChildItem -LiteralPath $directories.Pop() -Force)) {
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw ('Output tree contains a symlink/junction: ' + $item.FullName) }
                if ($item.PSIsContainer) { $directories.Push($item.FullName) }
            }
        }
        $bins = @(Find-TeXBins $TeXBin)
        $bin = $bins | Where-Object {
            (Test-Path -LiteralPath (Join-Path $_ 'latexmk.exe')) -and
            (Test-Path -LiteralPath (Join-Path $_ 'xelatex.exe')) -and
            (Test-Path -LiteralPath (Join-Path $_ 'xdvipdfmx.exe'))
        } | Select-Object -First 1
        if (-not $bin) { throw 'Need latexmk, xelatex and xdvipdfmx. Install TeX Live or specify -TeXBin. No system changes were made.' }
        $env:Path = $bin + ';' + $env:Path
        # Mirror directories for auxiliary files written by \include{chapters/part}.
        foreach ($file in @(Get-SafeFiles $root | Where-Object Extension -eq '.tex')) {
            $rel = $file.DirectoryName.Substring($root.Length).TrimStart('\','/')
            if ($rel) { Assert-LocalDirectory (Join-Path $build $rel) }
        }
        $arguments = @('-norc','-pdfxe','-synctex=1','-interaction=nonstopmode','-halt-on-error','-file-line-error','-outdir=build','-auxdir=build', ('./' + [IO.Path]::GetFileName($source)))
        $code = Invoke-Latexmk (Join-Path $bin 'latexmk.exe') $arguments
        if ($code -ne 0) { $exitCode = $code; throw "latexmk failed (exit $code). See build/latexmk.stdout.log and stderr.log." }
        $built = Join-Path $build ($stem + '.pdf')
        if (-not (Test-Path -LiteralPath $built) -or (Get-Item -LiteralPath $built).Length -lt 5) { throw "Missing/empty PDF: $built" }
        # Stage in build/ and atomically replace the published PDF on the same volume.
        $destination = Join-Path $root ($stem + '.pdf')
        $stage = Join-Path $build ('.publish-' + [guid]::NewGuid().ToString('N') + '.pdf')
        try {
            [IO.File]::Copy($built, $stage)
            for ($attempt = 0; ; $attempt++) {
                try {
                    if (Test-Path -LiteralPath $destination) { [IO.File]::Replace($stage, $destination, [System.Management.Automation.Language.NullString]::Value) }
                    else { [IO.File]::Move($stage, $destination) }
                    break
                } catch [IO.IOException] { if ($attempt -ge 4) { throw }; Start-Sleep -Milliseconds 200 }
            }
        } finally { if (Test-Path -LiteralPath $stage) { [IO.File]::Delete($stage) } }
        $exitCode = 0
        [IO.File]::WriteAllText((Join-Path $build 'last-build-status.txt'), "SUCCESS $(Get-Date -Format s)`nPDF: $destination", $utf8)
        Write-Host "PDF: $destination"
    }
} catch {
    $message = $_.Exception.Message
    if ($exitCode -eq 0) { $exitCode = 1 }
    if ($ownsLock -and [IO.Directory]::Exists($build)) {
        try {
            $statusName = if ($Mode -eq 'build') { 'last-build-status.txt' } else { 'last-clean-status.txt' }
            [IO.File]::WriteAllText((Join-Path $build $statusName), "FAILED exit=$exitCode $(Get-Date -Format s)`n$message", $utf8)
        } catch { }
    }
    Write-Host "ERROR: $message"
} finally {
    if ($null -ne $proc) {
        if ($processStarted -and -not $proc.HasExited) {
            # Stop only this runner's child tree before releasing the project lock.
            $killInfo = New-Object Diagnostics.ProcessStartInfo
            $killInfo.FileName = Join-Path $env:SystemRoot 'System32/taskkill.exe'
            $killInfo.Arguments = '/PID ' + $proc.Id + ' /T /F'
            $killInfo.UseShellExecute = $false; $killInfo.CreateNoWindow = $true
            $killer = [Diagnostics.Process]::Start($killInfo); $killer.WaitForExit(); $killer.Dispose()
        }
        $proc.Dispose()
    }
    if ($null -ne $lock) { $lock.Dispose() }
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

function Install-HiddenExecutable {
    $source = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
internal static class HiddenLatexLauncher {
    private static string Quote(string value) {
        StringBuilder result = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in value) {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') { result.Append('\\', slashes * 2 + 1).Append(c); }
            else { result.Append('\\', slashes).Append(c); }
            slashes = 0;
        }
        return result.Append('\\', slashes * 2).Append('"').ToString();
    }
    [STAThread]
    private static int Main(string[] args) {
        string root = Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, ".."));
        try {
            if (args.Length > 1) root = Path.GetFullPath(args[1]);
            string script = Path.Combine(root, ".vscode", "build-latex.ps1");
            string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
            string command = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(script) + " -ProjectRoot " + Quote(root);
            if (args.Length > 0 && args[0].Length != 0) command += " -MainFile " + Quote(args[0]);
            if (args.Length > 2 && args[2].Length != 0) command += " -TeXBin " + Quote(args[2]);
            if (args.Length > 3) command += " -Mode " + Quote(args[3]);
            ProcessStartInfo info = new ProcessStartInfo(ps, command);
            info.WorkingDirectory = root;
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.WindowStyle = ProcessWindowStyle.Hidden;
            using (Process process = Process.Start(info)) {
                process.WaitForExit();
                return process.ExitCode;
            }
        } catch (Exception error) {
            try {
                string build = Path.Combine(root, "build");
                Directory.CreateDirectory(build);
                File.AppendAllText(Path.Combine(build, "launcher-error.log"), DateTime.Now.ToString("s") + " " + error + Environment.NewLine);
            } catch { }
            return 1;
        }
    }
}
'@
    $exe = Join-Path $script:Workspace '.vscode/build-latex.exe'
    $sourcePath = Join-Path $script:Workspace '.vscode/hidden-launcher.cs'
    if ((Test-Path -LiteralPath $exe) -and (Test-Path -LiteralPath $sourcePath) -and [IO.File]::ReadAllText($sourcePath) -eq $source) { return }
    $tempExe = Join-Path $script:ReportDir ('launcher-' + [guid]::NewGuid().ToString('N') + '.exe')
    try {
        $compiler = Join-Path $env:SystemRoot 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
        if (-not (Test-Path -LiteralPath $compiler)) { $compiler = Join-Path $env:SystemRoot 'Microsoft.NET/Framework/v4.0.30319/csc.exe' }
        $tempSource = Join-Path $script:ReportDir ('launcher-' + [guid]::NewGuid().ToString('N') + '.cs')
        [IO.File]::WriteAllText($tempSource, $source, $script:Encoding)
        $rc = Invoke-CommandLogged $compiler @('/nologo','/target:winexe',('/out:' + $tempExe),$tempSource) $script:Workspace 'setup-launcher'
            if ($rc -ne 0 -or -not (Test-Path -LiteralPath $tempExe)) { throw 'Could not compile the hidden .NET launcher. See build/setup-launcher.stderr.log.' }
        [IO.File]::Copy($tempExe, $exe, $true)
        [IO.File]::WriteAllText($sourcePath, $source, $script:Encoding)
    } finally {
        if (Test-Path -LiteralPath $tempExe) { [IO.File]::Delete($tempExe) }
        if ($tempSource -and (Test-Path -LiteralPath $tempSource)) { [IO.File]::Delete($tempSource) }
    }
}
function Install-PersistentBuildRunner([string]$RootDir) {
    $vsDir = Join-Path $RootDir '.vscode'
    [void][IO.Directory]::CreateDirectory($vsDir)
    Install-HiddenExecutable
    $runnerPath = Join-Path $vsDir 'build-latex.ps1'
    $text = (Get-PersistentBuildRunnerContent).TrimStart("`r", "`n")
    if (-not $text.EndsWith("`n")) { $text += "`n" }
    $text = $text.Replace("`r`n", "`n")
    $existing = if (Test-Path -LiteralPath $runnerPath -PathType Leaf) { [IO.File]::ReadAllText($runnerPath, [Text.Encoding]::UTF8) } else { $null }
    # Always check all components even when the PS1 is already current.
    if ($null -ne $existing -and $existing -ne $text) {
        $archive = Join-Path $script:ReportDir 'settings-backups'
        [void][IO.Directory]::CreateDirectory($archive)
        $bak = New-UniqueBackup (Join-Path $archive 'build-latex.ps1')
        [IO.File]::Copy($runnerPath, $bak)
    }
    $temp = Join-Path $script:ReportDir ('runner-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        # UTF-8 BOM ensures Windows PowerShell 5.1 handles future Chinese comments or paths.
        $enc = New-Object System.Text.UTF8Encoding($true)
        [IO.File]::WriteAllText($temp, $text, $enc)
        if ($existing -ne $text) { [IO.File]::Copy($temp, $runnerPath, $true) }
    } finally { if (Test-Path -LiteralPath $temp) { [IO.File]::Delete($temp) } }
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
            [IO.File]::Copy($vbsPath, $backupVbs)
        }
        # ASCII-only VBS avoids Windows Script Host encoding ambiguity.
        $tempVbs = Join-Path $script:ReportDir ('launcher-' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [IO.File]::WriteAllText($tempVbs, $vbsText, [Text.Encoding]::ASCII)
            [IO.File]::Copy($tempVbs, $vbsPath, $true)
        } finally {
            if (Test-Path -LiteralPath $tempVbs -PathType Leaf) { [IO.File]::Delete($tempVbs) }
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
    # The GUI-subsystem .exe starts the permanent .ps1 without a console and waits for its exit code.
    # %DIR% denotes the actual root .tex directory even if a parent workspace is opened.
    $tool = [ordered]@{
        name = 'permanent-silent-xelatex'
        command = './.vscode/build-latex.exe'
        args = @('%DOC_EXT%', '%DIR%')
        cwd = '%DIR%'
    }
    $settings['latex-workshop.latex.tools'] = @($tool)
    $settings['latex-workshop.latex.recipes'] = @([ordered]@{
        name='XeLaTeX | silent build + root PDF'; tools=@('permanent-silent-xelatex')
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
            [IO.File]::Copy($path, $backup)
            Add-Log ('VS Code settings backup: ' + $backup)
        }
        $tmpPath = Join-Path $script:ReportDir ('settings-' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [IO.File]::WriteAllText($tmpPath, $json, $script:Encoding)
            [IO.File]::Copy($tmpPath, $path, $true)
        } finally { if (Test-Path -LiteralPath $tmpPath) { [IO.File]::Delete($tmpPath) } }
    }
    Add-Log ('Configured permanent VS Code recipe: ' + $path)
    $extensionPath = Join-Path $vsDir 'extensions.json'
    try {
        $extensions = [ordered]@{}
        if (Test-Path -LiteralPath $extensionPath) {
            $parsedExtensions = ConvertFrom-JsonC ([IO.File]::ReadAllText($extensionPath))
            if ($parsedExtensions -isnot [pscustomobject]) { throw 'extensions.json must contain an object' }
            foreach ($property in $parsedExtensions.PSObject.Properties) { $extensions[$property.Name] = $property.Value }
        }
        $recommendations = @()
        if ($extensions.Contains('recommendations')) { $recommendations = @($extensions['recommendations']) }
        if ($recommendations -notcontains 'James-Yu.latex-workshop') {
            $extensions['recommendations'] = @($recommendations) + @('James-Yu.latex-workshop')
            if (Test-Path -LiteralPath $extensionPath) {
                $backupDir = Join-Path $script:ReportDir 'settings-backups'
                [void][IO.Directory]::CreateDirectory($backupDir)
                [IO.File]::Copy($extensionPath,(New-UniqueBackup (Join-Path $backupDir 'extensions.json')))
            }
            [IO.File]::WriteAllText($extensionPath,(ConvertTo-Json $extensions -Depth 30),$script:Encoding)
        }
    } catch { Add-Warning ('Extension recommendations kept unchanged: ' + $_.Exception.Message) }
    $editor = Get-Command code -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($editor) { Add-Log ('Editor CLI: ' + $editor.Source) }
    else { Add-Warning 'VS Code CLI is not on PATH. Open the project folder in VS Code and enable LaTeX Workshop (see Extensions recommendations).' }
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
    # The entry wrapper (or BAT) owns the final Enter prompt, including binding errors.
    Write-Host $script:Outcome
}

function Test-ProjectPermissions {
    foreach ($directory in @($script:Workspace, (Join-Path $script:Workspace '.vscode'), $script:ReportDir)) {
        if (Test-Path -LiteralPath $directory) {
            $item = Get-Item -LiteralPath $directory -Force
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Output/config path is a file or link: $directory" }
        } else { [void][IO.Directory]::CreateDirectory($directory) }
        $probe = Join-Path $directory ('.latex-permission-' + [guid]::NewGuid().ToString('N'))
        try {
            [IO.File]::WriteAllText($probe, 'write', $script:Encoding)
            [IO.File]::AppendAllText($probe, 'modify', $script:Encoding)
            [void][IO.File]::ReadAllText($probe)
            [IO.File]::Delete($probe)
        } catch {
            throw ("Project permission check failed: $directory. Close programs holding files, move to a writable folder, or rerun with -Elevate for a standard UAC request. " + $_.Exception.Message)
        }
    }
}

$exitCode = 1
$setupLock = $null
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
    $script:BuildDir = $script:ReportDir
    Test-ProjectPermissions
    $lockPath = Join-Path $script:Workspace '.vscode/.latex-operation.lock'
    if ((Test-Path -LiteralPath $lockPath) -and ((Get-Item -LiteralPath $lockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Lock file must not be a symlink.' }
    $deadline = [DateTime]::UtcNow.AddSeconds(120)
    do {
        try { $setupLock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
        catch [IO.IOException] {
            if ([DateTime]::UtcNow -gt $deadline) { throw 'Another build/setup/clean is running (lock timeout).' }
            Start-Sleep -Milliseconds 150
        }
    } until ($null -ne $setupLock)
    if ($Elevate) {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Use the elevation entry point before permission checks.' }
    }
    if (-not $ConfigureOnly -and -not $CleanOnly -and $Mode -eq 'build') {
        $script:Stage = 'scanning and diagnosing TeX installation'
        Resolve-TeXTools $TeXBin
        $script:Stage = 'testing isolated XeLaTeX document'
        Test-MinimalXeLaTeX
    }
    if ($DiagnoseOnly) {
        $script:Stage = 'diagnostic complete'
        $script:ReportOK = $true
        $script:Outcome = '环境诊断通过：独立 XeLaTeX 测试成功（未编译实际文档）。'
        $exitCode = 0
    } else {
        $script:Stage = 'installing permanent build runner'
        Install-PersistentBuildRunner $script:Workspace
        $projectConfig = [ordered]@{ mainFile = [IO.Path]::GetFileName($script:SourceFile); texBin = $script:DetectedBin }
        if (-not $script:DetectedBin -and $TeXBin) { $projectConfig.texBin = $TeXBin }
        $configPath = Join-Path $script:Workspace '.vscode/latex-project.json'
        if (-not $projectConfig.texBin -and (Test-Path -LiteralPath $configPath)) {
            try { $old = [IO.File]::ReadAllText($configPath) | ConvertFrom-Json; $projectConfig.texBin = $old.texBin } catch { }
        }
        [IO.File]::WriteAllText($configPath, (ConvertTo-Json $projectConfig), $script:Encoding)
        if (-not $NoSettings -and -not $CleanOnly -and $Mode -eq 'build') {
            $script:Stage = 'configuring workspace VS Code'
            try {
                Update-VSCodeConfig $script:Workspace
                # If the parent directory is already a VS Code workspace,
                # its settings override child settings when opened as the workspace.
                # Only adjust an existing parent .vscode, never create it unsolicited.
                $parent = [IO.Directory]::GetParent($script:Workspace)
                if (-not $ProjectOnly -and $null -ne $parent -and
                    $parent.FullName -ne [IO.Path]::GetPathRoot($script:Workspace) -and
                    (Test-Path -LiteralPath (Join-Path $parent.FullName '.vscode') -PathType Container)) {
                    Update-VSCodeConfig $parent.FullName
                }
            } catch {
                Add-Fix 'Repair project or parent .vscode/settings.json and rerun the initializer.'
                throw ('Failed to install permanent VS Code settings: ' + $_.Exception.Message)
            }
        }
        $setupLock.Dispose(); $setupLock = $null
        $script:Stage = 'building source document'
        if ($ConfigureOnly -or $CleanOnly -or $Mode -ne 'build') {
            $operation = if ($CleanOnly -or $ConfigureOnly) { 'clean' } else { $Mode }
            $runner = Join-Path $script:Workspace '.vscode/build-latex.ps1'
            $ps = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
            $rc = Invoke-CommandLogged $ps @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$runner,'-ProjectRoot',$script:Workspace,'-Mode',$operation) $script:Workspace 'setup-compile'
            if ($rc -ne 0) { throw "Operation $operation failed (exit $rc). See build/setup-compile.stdout.log." }
        } else { Invoke-ProjectCompile }
        $script:Stage = 'finished'
        $script:ReportOK = $true
        $script:Outcome = '操作成功：永久静默编译器已保存在 .vscode。模式：' + $(if ($ConfigureOnly) { 'configure-only' } else { $Mode }) + '。PDF：' + $script:PdfPath
        $exitCode = 0
    }
} catch {
    $script:Outcome = $_.Exception.Message
    Write-Host $_.ScriptStackTrace
    if ($script:StatusLog) { Add-Log $_.ScriptStackTrace }
    Write-Host ('[ERROR] ' + $script:Stage + ': ' + $script:Outcome)
    if ($script:StatusLog) { Add-Log ('[ERROR] ' + $script:Stage + ': ' + $script:Outcome) }
} finally {
    if ($null -ne $setupLock) { $setupLock.Dispose() }
    if ($script:StatusLog) {
        try { Save-FinalReport $script:ReportOK $script:Outcome }
        catch { Write-Host ('Could not write diagnostic report: ' + $_.Exception.Message) }
    }
    Write-Host ('Result: ' + $(if ($script:ReportOK) { 'SUCCESS' } else { 'FAILED' }))
    if ($script:StatusLog) { Write-Host ('Full log: ' + $script:StatusLog) }
    Show-Completion $script:ReportOK
}
$script:SetupExitCode = $exitCode
# END SETUP CORE
}
try {
    if ($entryArguments -contains '-Elevate') {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            $elevatedArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath) + $entryArguments
            if ($entryArguments -notcontains '-ProjectRoot') {
                $elevationRoot = if ($env:LATEX_SETUP_PROJECT_ROOT) { $env:LATEX_SETUP_PROJECT_ROOT } else { $PSScriptRoot }
                $elevatedArgs += @('-ProjectRoot', $elevationRoot)
            }
            if ($entryArguments -notcontains '-NoPause') { $elevatedArgs += '-NoPause' }
            $line = (($elevatedArgs | ForEach-Object { '"' + [regex]::Replace($_, '(\\*)"', '$1$1\"').TrimEnd('\') + ('\' * (2 * ($_.Length - $_.TrimEnd('\').Length))) + '"' }) -join ' ')
            $child = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -ArgumentList $line -Verb RunAs -Wait -PassThru
            $script:SetupExitCode = $child.ExitCode
        } else { & $setupCore @entryArguments }
    } else { & $setupCore @entryArguments }
} catch {
    Write-Host ('ERROR: ' + $_.Exception.Message)
    $script:SetupExitCode = 1
} finally {
    if (-not $skipFinalPrompt) {
        try { Write-Host 'Press Enter to close this window / 鎸?Enter 鍏抽棴绐楀彛'; [void][Console]::ReadLine() }
        catch { Write-Host 'Interactive input unavailable. Use an interactive terminal or explicit -NoPause for automation.' }
    }
}
exit $script:SetupExitCode