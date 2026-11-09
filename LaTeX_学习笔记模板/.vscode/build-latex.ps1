#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [string]$MainFile,
    [string]$Latexmk = 'latexmk'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Resolve-Source {
    $root = if ($ProjectRoot) { [IO.Path]::GetFullPath($ProjectRoot) } else {
        Split-Path -Parent $PSScriptRoot
    }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw ('Project root not found: ' + $root)
    }
    if ($MainFile) {
        $source = if ([IO.Path]::IsPathRooted($MainFile)) { $MainFile } else {
            Join-Path $root $MainFile
        }
        # LaTeX Workshop's %DOC% can omit the .tex extension.
        if (-not (Test-Path -LiteralPath $source -PathType Leaf) -and
            (Test-Path -LiteralPath ($source + '.tex') -PathType Leaf)) {
            $source += '.tex'
        }
    } else {
        $candidates = @(Get-ChildItem -LiteralPath $root -Filter '*.tex' -File | Where-Object {
            $code = [regex]::Replace([IO.File]::ReadAllText($_.FullName), '(?m)(?<!\\)%.*$', '')
            $code -match '(?m)^\s*\\documentclass\s*(?:\[[^\]]*\]\s*)?\{(?!subfiles\})[^}]+\}'
        })
        if ($candidates.Count -ne 1) {
            throw 'Specify -MainFile when there is not exactly one root document beside .vscode/.'
        }
        $source = $candidates[0].FullName
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    while ($true) {
        $source = [IO.Path]::GetFullPath($source)
        if (-not $seen.Add($source)) { throw 'Circular % !TeX root declarations.' }
        if ([IO.Path]::GetExtension($source) -ine '.tex' -or
            -not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw ('LaTeX source not found: ' + $source)
        }
        $hint = [regex]::Match([IO.File]::ReadAllText($source),
            '(?im)^\s*%\s*!TeX\s+root\s*=\s*(.+?)\s*$')
        if (-not $hint.Success) { return $source }
        $value = $hint.Groups[1].Value.Trim().Trim('"').Trim("'")
        $next = if ([IO.Path]::IsPathRooted($value)) { $value } else {
            Join-Path ([IO.Path]::GetDirectoryName($source)) $value
        }
        $next = [IO.Path]::GetFullPath($next)
        if ($next -ieq $source) { return $source }
        if (-not (Test-Path -LiteralPath $next -PathType Leaf)) { return $source }
        $source = $next
    }
}

function Prepare-BuildFolders([string]$root) {
    # \include{chapters/name} may need build/chapters/ before the first run.
    $build = Join-Path $root 'build'
    [void][IO.Directory]::CreateDirectory($build)
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($root)
    while ($stack.Count) {
        foreach ($folder in @(Get-ChildItem -LiteralPath ($stack.Pop()) -Directory -Force)) {
            if ($folder.Name -in @('build', '.git', '.vscode', '.venv', 'node_modules',
                    'backup', 'backups', 'archive', 'archives') -or
                ($folder.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $relative = $folder.FullName.Substring($root.TrimEnd('\','/').Length).TrimStart('\','/')
            [void][IO.Directory]::CreateDirectory((Join-Path $build $relative))
            $stack.Push($folder.FullName)
        }
    }
}

function Invoke-Latexmk([string[]]$Arguments) {
    $previous = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 exposes native stderr as error records. A TeX
        # failure must return its exit code, rather than interrupting recovery.
        $ErrorActionPreference = 'Continue'
        & $script:latexmkCommand @Arguments 2>&1 | ForEach-Object { Write-Host ([string]$_) }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    # Send engine output to the host; return only the integer exit code.
    return [int]$code
}

$pushed = $false
try {
    $source = Resolve-Source
    $root = [IO.Path]::GetDirectoryName($source)
    $name = [IO.Path]::GetFileName($source)
    $jobName = [IO.Path]::GetFileNameWithoutExtension($source)
    $tool = Get-Command -Name $Latexmk -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $script:latexmkCommand = $tool.Source
    Push-Location -LiteralPath $root
    $pushed = $true
    Prepare-BuildFolders $root
    $buildArgs = @(
        '-pdfxe', '-outdir=build', '-out2dir=.', '-synctex=1',
        '-interaction=nonstopmode', '-file-line-error', '-halt-on-error', ('./' + $name)
    )

    Write-Host '[LaTeX] Incremental build...' -ForegroundColor Cyan
    $code = Invoke-Latexmk $buildArgs
    if ($code -eq 0) {
        Write-Host '[LaTeX] Build succeeded; cache retained.' -ForegroundColor Green
        exit 0
    }

    Write-Host ('[LaTeX] Build failed (exit ' + $code + '). Cleaning auxiliary files once...') -ForegroundColor Yellow
    $cleanCode = Invoke-Latexmk @('-c', '-outdir=build', '-out2dir=.', ('./' + $name))
    if ($cleanCode -ne 0) {
        Write-Host ('[LaTeX] Cleanup reported exit ' + $cleanCode + '; retrying once.') -ForegroundColor Yellow
    }
    Prepare-BuildFolders $root
    Write-Host '[LaTeX] Retrying once...' -ForegroundColor Yellow
    $code = Invoke-Latexmk $buildArgs
    if ($code -eq 0) {
        Write-Host '[LaTeX] Recovery succeeded.' -ForegroundColor Green
        exit 0
    }
    Write-Host ('[LaTeX] Retry failed (exit ' + $code + '). See build/' + $jobName + '.log.') -ForegroundColor Red
    exit $code
} catch {
    [Console]::Error.WriteLine('[LaTeX] ' + $_.Exception.Message)
    exit 1
} finally {
    if ($pushed) { Pop-Location }
}
