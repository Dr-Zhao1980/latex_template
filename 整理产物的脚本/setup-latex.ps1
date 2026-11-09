[CmdletBinding()]
param([string]$ProjectRoot = $PSScriptRoot)

# Windows PowerShell 5.1 compatible.  All project paths are relative to main.tex.
# The .bat launcher calls this script so there is only one implementation.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:stage = 'starting'
$script:project = $null
$script:build = $null
$script:runLog = $null
$script:latexmk = $null
$script:xelatex = $null
$script:toolCommand = 'latexmk'
$script:toolEnv = @{}
$script:archiveCount = 0
$script:recoveredCount = 0
$script:configPaths = New-Object 'System.Collections.Generic.List[string]'
$script:environmentNote = ''
$script:isWindows = ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
$script:utf8 = New-Object System.Text.UTF8Encoding($false)

function Write-Note([string]$message) {
    Write-Host $message
    if ($script:runLog) {
        Add-Content -LiteralPath $script:runLog -Encoding UTF8 -Value $message
    }
}

function Show-Result([bool]$ok, [string]$message) {
    $title = if ($ok) { 'LaTeX - Ready' } else { 'LaTeX - Failed' }
    Write-Host ($title + ': ' + $message)
    if ($env:LATEX_SETUP_NO_DIALOG -eq '1') { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $icon = if ($ok) { [System.Windows.Forms.MessageBoxIcon]::Information } else { [System.Windows.Forms.MessageBoxIcon]::Error }
        [void][System.Windows.Forms.MessageBox]::Show(
            $message, $title, [System.Windows.Forms.MessageBoxButtons]::OK, $icon
        )
    } catch {
        try {
            $shell = New-Object -ComObject WScript.Shell -ErrorAction Stop
            $flags = if ($ok) { 64 } else { 16 }
            [void]$shell.Popup($message, 0, $title, $flags)
        } catch { }
    }
}

function New-BackupName([string]$path) {
    $stem = $path + '.backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
    $candidate = $stem
    $i = 0
    while (Test-Path -LiteralPath $candidate) {
        $i++
        $candidate = $stem + '-' + $i
    }
    return $candidate
}

function Ensure-BuildDirectory {
    $script:build = Join-Path $script:project 'build'
    # Do NOT reject every ReparsePoint: cloud-sync folders can be usable
    # directories.  Only move actual symbolic links/junctions aside.
    $item = Get-Item -LiteralPath $script:build -Force -ErrorAction SilentlyContinue
    if ($null -ne $item) {
        $linkType = ''
        if ($null -ne $item.PSObject.Properties['LinkType']) {
            $linkType = [string]$item.LinkType
        }
        if ((-not $item.PSIsContainer) -or ($linkType -in @('Junction', 'SymbolicLink'))) {
            $backup = New-BackupName $script:build
            Rename-Item -LiteralPath $script:build -NewName ([IO.Path]::GetFileName($backup)) -ErrorAction Stop
            Write-Host ('Backed up incompatible build entry to ' + $backup)
        }
    }
    [void][IO.Directory]::CreateDirectory($script:build)
    if (-not [IO.Directory]::Exists($script:build)) {
        throw 'Cannot create a writable build directory.'
    }
    $script:runLog = Join-Path $script:build 'setup-latex-status.log'
    [IO.File]::WriteAllText($script:runLog,
        ('LaTeX Workshop setup' + [Environment]::NewLine + 'Root: ' + $script:project + [Environment]::NewLine), $script:utf8)
}

function Find-TeXLiveBin {
    $roots = New-Object 'System.Collections.Generic.List[string]'
    foreach ($value in @($env:TEXLIVE_ROOT, $env:TEXDIR, 'C:\texlive', 'D:\texlive',
                        'D:\APP\Texlive\texlive', 'D:\APPgallery\texlive\texlive',
                        'D:\APP\texlive\texlive')) {
        if (-not [string]::IsNullOrWhiteSpace($value)) { $roots.Add($value) }
    }
    # Scan common per-drive install locations, never traverse entire drives.
    if ($script:isWindows) {
        foreach ($drive in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            $roots.Add((Join-Path $drive.Root 'texlive'))
            $roots.Add((Join-Path $drive.Root 'APP\Texlive\texlive'))
        }
    }
    foreach ($base in $roots) {
        foreach ($bin in @($base, (Join-Path $base 'bin\windows'))) {
            if (Test-Path -LiteralPath (Join-Path $bin 'latexmk.exe') -PathType Leaf) {
                return $bin
            }
        }
        foreach ($year in @(2030,2029,2028,2027,2026,2025,2024,2023,2022)) {
            $bin = Join-Path $base ($year.ToString() + '\bin\windows')
            if (Test-Path -LiteralPath (Join-Path $bin 'latexmk.exe') -PathType Leaf) {
                return $bin
            }
        }
    }
    return $null
}

function Set-UserTeXPath([string]$texBin) {
    if (-not $script:isWindows) { return }
    try {
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if (-not $userPath) { $userPath = '' }
        $exists = $false
        foreach ($segment in $userPath.Split(';')) {
            if ($segment.Trim().TrimEnd('\') -ieq $texBin.TrimEnd('\')) { $exists = $true }
        }
        if (-not $exists) {
            $sep = if ($userPath.Trim().Length -eq 0 -or $userPath.EndsWith(';')) { '' } else { ';' }
            [Environment]::SetEnvironmentVariable('Path', $userPath + $sep + $texBin, 'User')
            Write-Note ('Repaired user PATH: ' + $texBin)
        }
    } catch {
        Write-Note ('User PATH update unavailable; VS Code recipe will have an explicit environment: ' + $_.Exception.Message)
    }
}

function Check-TeXEnvironment {
    $existing = Get-Command -Name 'latexmk.exe', 'latexmk' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $fallback = $false
    if ($null -ne $existing) {
        $script:latexmk = $existing.Source
    } else {
        $bin = Find-TeXLiveBin
        if (-not $bin) {
            throw 'Cannot find latexmk. Install TeX Live (with latexmk/XeLaTeX), or put its bin\windows folder in PATH.'
        }
        $script:latexmk = Join-Path $bin 'latexmk.exe'
        $fallback = $true
    }
    $texBin = [IO.Path]::GetDirectoryName($script:latexmk)
    if (-not (($env:Path -split [regex]::Escape([string][IO.Path]::PathSeparator)) -contains $texBin)) {
        $env:Path = $texBin + [IO.Path]::PathSeparator + $env:Path
    }
    $xe = Get-Command -Name 'xelatex.exe', 'xelatex' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $xe) {
        throw ('latexmk found, but xelatex is missing. Check TeX Live installation: ' + $texBin)
    }
    $script:xelatex = $xe.Source
    if ($fallback) {
        Set-UserTeXPath $texBin
        # This also works immediately in an already-running VS Code instance:
        # environment injection does not depend on restarting the editor.
        $script:toolCommand = $script:latexmk
        $script:toolEnv = @{ Path = $env:Path }
        $script:environmentNote = 'TeX Live was missing from PATH; patched recipe environment.'
    }
    Write-Note ('latexmk: ' + $script:latexmk)
    Write-Note ('xelatex: ' + $script:xelatex)
    # Windows PowerShell 5.1 treats native stderr as an error record.
    # A locale warning must not hide a successful version probe.
    $probePreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $versionOutput = (& $script:latexmk -v 2>$null | Out-String)
        $probeExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $probePreference
    }
    if ($probeExitCode -ne 0) {
        throw ('latexmk version check failed (exit ' + $probeExitCode + '). ' + $versionOutput.Trim())
    }
    Write-Note ('latexmk version: ' + $versionOutput.Trim())
    $versionMatch = [regex]::Match($versionOutput, 'Version\s+(\d+\.\d+)')
    if ($versionMatch.Success) {
        $v = [decimal]::Parse($versionMatch.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
        if ($v -lt [decimal]4.86) {
            throw 'latexmk is too old for -out2dir. Upgrade latexmk to version 4.86 or newer.'
        }
    } else {
        throw 'Could not verify latexmk version; setup requires latexmk 4.86 or newer.'
    }
    foreach ($name in @('bibtex', 'biber', 'makeindex')) {
        $cmd = Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($cmd) { Write-Note ($name + ': ' + $cmd.Source) }
        else { Write-Note ('Optional bibliography/index tool not found: ' + $name) }
    }
}

function ConvertFrom-JsonC([string]$inputText) {
    # VS Code settings.json permits //, /* */ comments and trailing commas.
    # Strip them while respecting quoted JSON strings; then use native JSON.
    $chars = $inputText.ToCharArray()
    $inside = $false
    $escaped = $false
    $lineComment = $false
    $blockComment = $false
    for ($i = 0; $i -lt $chars.Length; $i++) {
        $c = $chars[$i]
        $next = if ($i + 1 -lt $chars.Length) { $chars[$i+1] } else { [char]0 }
        if ($lineComment) {
            if ($c -eq "`n" -or $c -eq "`r") { $lineComment = $false }
            else { $chars[$i] = ' ' }
            continue
        }
        if ($blockComment) {
            if ($c -eq '*' -and $next -eq '/') {
                $chars[$i] = ' '; $chars[$i+1] = ' '; $i++; $blockComment = $false
            } elseif ($c -ne "`r" -and $c -ne "`n") { $chars[$i] = ' ' }
            continue
        }
        if ($inside) {
            if ($escaped) { $escaped = $false }
            elseif ($c -eq '\') { $escaped = $true }
            elseif ($c -eq '"') { $inside = $false }
            continue
        }
        if ($c -eq '"') { $inside = $true; continue }
        if ($c -eq '/' -and $next -eq '/') {
            $chars[$i] = ' '; $chars[$i+1] = ' '; $i++; $lineComment = $true; continue
        }
        if ($c -eq '/' -and $next -eq '*') {
            $chars[$i] = ' '; $chars[$i+1] = ' '; $i++; $blockComment = $true; continue
        }
    }
    $inside = $false
    $escaped = $false
    for ($i = 0; $i -lt $chars.Length; $i++) {
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
            if ($j -lt $chars.Length -and ($chars[$j] -eq '}' -or $chars[$j] -eq ']')) {
                $chars[$i] = ' '
            }
        }
    }
    $sanitized = -join $chars
    $obj = ConvertFrom-Json -InputObject $sanitized -ErrorAction Stop
    if ($obj -isnot [pscustomobject]) { throw 'settings.json must contain a top-level JSON object.' }
    return $obj
}

function New-WorkshopSettings {
    $tool = [ordered]@{
        name = 'latexmk-xelatex-main-clean'
        command = $script:toolCommand
        args = @(
            '-norc', '-pdfxe', '-e', '@out2_exts=(qw(pdf));$max_repeat=10;',
            '-outdir=build', '-out2dir=.', '-synctex=1',
            '-interaction=nonstopmode', '-file-line-error', '-halt-on-error',
            '-g', 'main.tex'
        )
        cwd = '%DIR%'
        env = $script:toolEnv
    }
    return @{
        'latex-workshop.latex.outDir' = '%DIR%/build'
        'latex-workshop.latex.auxDir' = '%DIR%/build'
        'latex-workshop.latex.recipe.default' = 'first'
        'latex-workshop.latex.recipes' = @(
            [ordered]@{ name = 'XeLaTeX | main.tex | build/'; tools = @('latexmk-xelatex-main-clean') }
        )
        'latex-workshop.latex.tools' = @($tool)
        'latex-workshop.latex.build.fromFolder' = ''
        'latex-workshop.latex.build.enableMagicComments' = $false
        'latex-workshop.latex.rootFile.useSubFile' = $false
        'latex-workshop.latex.autoBuild.run' = 'onSave'
        'latex-workshop.latex.autoClean.run' = 'never'
        'latex-workshop.latex.autoBuild.cleanAndRetry.enabled' = $false
        'latex-workshop.view.pdf.viewer' = 'tab'
    }
}

function Update-Settings([string]$folder) {
    $vscode = Join-Path $folder '.vscode'
    [void][IO.Directory]::CreateDirectory($vscode)
    $settingsPath = Join-Path $vscode 'settings.json'
    $settings = [ordered]@{}
    $previous = $null
    $invalid = $false
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        $previous = [IO.File]::ReadAllText($settingsPath, [Text.Encoding]::UTF8)
        try {
            if (-not [string]::IsNullOrWhiteSpace($previous)) {
                $parsed = ConvertFrom-JsonC $previous
                foreach ($prop in $parsed.PSObject.Properties) { $settings[$prop.Name] = $prop.Value }
            }
        } catch {
            $invalid = $true
            Write-Note ('Broken settings.json will be backed up and regenerated: ' + $settingsPath)
            $settings = [ordered]@{}
        }
    }
    # Old external scripts and stale cleanup arguments must not override the recipe.
    foreach ($key in @('latex-workshop.latex.external.build.command',
                       'latex-workshop.latex.external.build.args')) {
        if ($settings.Contains($key)) { $settings.Remove($key) }
    }
    $managed = New-WorkshopSettings
    foreach ($key in @('latex-workshop.latex.outDir', 'latex-workshop.latex.auxDir',
                       'latex-workshop.latex.recipe.default', 'latex-workshop.latex.recipes',
                       'latex-workshop.latex.tools', 'latex-workshop.latex.build.fromFolder',
                       'latex-workshop.latex.build.enableMagicComments',
                       'latex-workshop.latex.rootFile.useSubFile',
                       'latex-workshop.latex.autoBuild.run',
                       'latex-workshop.latex.autoClean.run',
                       'latex-workshop.latex.autoBuild.cleanAndRetry.enabled',
                       'latex-workshop.view.pdf.viewer')) {
        $settings[$key] = $managed[$key]
    }
    $json = (ConvertTo-Json -InputObject $settings -Depth 64) + [Environment]::NewLine
    if ($previous -ne $json) {
        if ($null -ne $previous) {
            $backup = New-BackupName $settingsPath
            Copy-Item -LiteralPath $settingsPath -Destination $backup -ErrorAction Stop
            Write-Note ('Saved original settings backup: ' + $backup)
        }
        [IO.File]::WriteAllText($settingsPath, $json, $script:utf8)
    }
    # Verify the configuration can be parsed before declaring success.
    $verify = [IO.File]::ReadAllText($settingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if (-not $verify.'latex-workshop.latex.tools') {
        throw ('Generated VS Code configuration failed verification: ' + $settingsPath)
    }
    $script:configPaths.Add($settingsPath)
    Write-Note ('Configured: ' + $settingsPath)
}

function Is-GeneratedFile([string]$name) {
    # Preserve source .tex, .bib, .sty, .cls, .ist, images and all PDFs.
    return [bool]($name -match '(?i)\.(?:aux|log|toc|lof|lot|lol|out|bbl|blg|bcf|fls|fdb_latexmk|synctex(?:\.gz)?|run\.xml|xdv|dvi|nav|snm|vrb|idx|ind|ilg|glo|gls|glg|acn|acr|alg|nlo|nls|thm|maf|mtc\d*|auxlock)$')
}

function Move-StrayOutputs([string]$groupName) {
    $files = New-Object 'System.Collections.Generic.List[string]'
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($script:project)
    while ($stack.Count -gt 0) {
        $folder = $stack.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $folder -Force -ErrorAction Stop)) {
            if ($item.PSIsContainer) {
                if ($item.Name -in @('build', '.vscode', '.git', '.svn', '.hg', 'node_modules', '.venv', '原始笔记备份')) { continue }
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                $stack.Push($item.FullName)
            } elseif (Is-GeneratedFile $item.Name) {
                $files.Add($item.FullName)
            }
        }
    }
    if ($files.Count -eq 0) { return 0 }
    $destinationRoot = Join-Path $script:build ($groupName + '\' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    $rootLen = $script:project.TrimEnd('\','/').Length
    foreach ($file in $files) {
        $rel = $file.Substring($rootLen).TrimStart('\','/')
        $destination = Join-Path $destinationRoot $rel
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
        Move-Item -LiteralPath $file -Destination $destination -ErrorAction Stop
    }
    return $files.Count
}

function Prepare-IncludeFolders {
    # A \include{chapters/ch1} emits build/chapters/ch1.aux.  Pre-create
    # directory structure because XeLaTeX itself may not do so.
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($script:project)
    $baseLen = $script:project.TrimEnd('\','/').Length
    while ($stack.Count -gt 0) {
        $folder = $stack.Pop()
        foreach ($sub in @(Get-ChildItem -LiteralPath $folder -Directory -Force -ErrorAction Stop)) {
            if ($sub.Name -in @('build', '.vscode', '.git', '.svn', '.hg', 'node_modules', '.venv', '原始笔记备份')) { continue }
            if (($sub.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $rel = $sub.FullName.Substring($baseLen).TrimStart('\','/')
            [void][IO.Directory]::CreateDirectory((Join-Path $script:build $rel))
            $stack.Push($sub.FullName)
        }
    }
}

function Invoke-InitialCompilation {
    $outputPath = Join-Path $script:build 'setup-compile.stdout.log'
    $errorPath = Join-Path $script:build 'setup-compile.stderr.log'
    $args = @(
        '-norc', '-pdfxe', '-e', '@out2_exts=(qw(pdf));$max_repeat=10;',
        '-outdir=build', '-out2dir=.', '-synctex=1',
        '-interaction=nonstopmode', '-file-line-error', '-halt-on-error',
        '-g', 'main.tex'
    )
    # Every arg is ASCII without whitespace, so Windows PowerShell 5.1
    # Start-Process argument joining cannot damage Unicode project paths.
    $launch = @{
        FilePath = $script:latexmk
        ArgumentList = ($args -join ' ')
        WorkingDirectory = $script:project
        Wait = $true
        PassThru = $true
        RedirectStandardOutput = $outputPath
        RedirectStandardError = $errorPath
        ErrorAction = 'Stop'
    }
    if ($script:isWindows) { $launch.WindowStyle = 'Hidden' }
    $process = Start-Process @launch
    Write-Note ('Initial latexmk exit code: ' + $process.ExitCode)
    if ($process.ExitCode -ne 0) {
        $tail = ''
        foreach ($f in @($errorPath, $outputPath)) {
            if ((Test-Path -LiteralPath $f -PathType Leaf) -and (Get-Item $f).Length -gt 0) {
                $tail = ((Get-Content -LiteralPath $f -Tail 12) -join [Environment]::NewLine)
                break
            }
        }
        throw ('XeLaTeX test compilation failed (exit ' + $process.ExitCode + '). ' + $tail)
    }
    foreach ($file in @('build\main.pdf', 'main.pdf', 'build\main.synctex.gz')) {
        if (-not (Test-Path -LiteralPath (Join-Path $script:project $file) -PathType Leaf)) {
            throw ('Compile finished, but expected output was missing: ' + $file)
        }
    }
    Write-Note 'Initial compile passed: main.pdf in project root; all aux/SyncTeX in build/.'
}

$ok = $false
$detail = ''
try {
    $script:stage = 'locating main.tex'
    if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { throw 'Cannot determine script directory.' }
    $script:project = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\','/')
    if (-not (Test-Path -LiteralPath (Join-Path $script:project 'main.tex') -PathType Leaf)) {
        throw ('main.tex not found next to this script: ' + $script:project)
    }
    $script:stage = 'creating or repairing build/'
    Ensure-BuildDirectory
    $script:stage = 'checking and repairing TeX Live environment'
    Check-TeXEnvironment
    $script:stage = 'moving legacy auxiliary files into build/'
    $script:archiveCount = Move-StrayOutputs 'legacy'
    Write-Note ('Archived old aux files: ' + $script:archiveCount)
    $script:stage = 'preparing include directories'
    Prepare-IncludeFolders
    $script:stage = 'repairing VS Code settings'
    Update-Settings $script:project
    # SAFETY: only write settings inside the project by default.
    # Configure the parent explicitly only with LATEX_SETUP_PARENT_CONFIG=1.
    if ($env:LATEX_SETUP_PARENT_CONFIG -eq '1') {
        $parent = [IO.Directory]::GetParent($script:project)
        if ($null -ne $parent -and $parent.FullName -ne [IO.Path]::GetPathRoot($script:project)) {
            Update-Settings $parent.FullName
        }
    }
    $script:stage = 'verifying first compile'
    Invoke-InitialCompilation
    $script:stage = 'collecting stray files'
    $script:recoveredCount = Move-StrayOutputs 'recovered'
    Write-Note ('Recovered stray aux after compile: ' + $script:recoveredCount)
    $ok = $true
    $detail = "初始化成功，已完成 XeLaTeX 编译验证。`n`n源文件目录：$script:project`nPDF：main.pdf`n辅助文件：build\`n已修复的 VS Code 配置：$($script:configPaths.Count) 处`n`n以后直接在 VS Code 中打开 main.tex，点击 LaTeX Workshop 编译，无需再次运行脚本。"
    if ($script:environmentNote) { $detail += "`n`n$script:environmentNote" }
} catch {
    $detail = "初始化或编译失败。`n阶段：$script:stage`n原因：$($_.Exception.Message)"
    if ($script:runLog) {
        try { Write-Note ('FAIL at ' + $script:stage + ': ' + $_.Exception.Message) } catch { }
        $detail += "`n`n日志：$script:runLog"
    }
} finally {
    if ($script:build -and (Test-Path -LiteralPath $script:build -PathType Container)) {
        try { $script:recoveredCount += Move-StrayOutputs 'recovered' } catch { }
    }
    Show-Result $ok $detail
}
if ($ok) { exit 0 }
exit 1
