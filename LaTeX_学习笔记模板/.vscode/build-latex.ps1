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
