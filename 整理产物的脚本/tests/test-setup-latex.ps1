param([switch]$KeepFixtures)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$setup = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../setup-latex.ps1'))
$launcher = [IO.Path]::ChangeExtension($setup, '.bat')
$powershell = Join-Path $PSHOME 'powershell.exe'
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixture = Join-Path $tempRoot ('latex-setup-tests-' + [guid]::NewGuid().ToString('N'))
$utf8 = New-Object Text.UTF8Encoding($false)
$document = "\documentclass{article}`n\begin{document}Minimal notes.\end{document}`n"

function Put([string]$relative, [string]$text) {
    $path = Join-Path $fixture $relative
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    [IO.File]::WriteAllText($path, $text, $utf8)
    return $path
}

function Check([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
}

function Run([string[]]$arguments, [string]$program = $setup, [bool]$batch = $false) {
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        if ($batch) {
            $output = & $program @arguments -NoDialog 2>&1 | Out-String
        } else {
            $output = & $powershell -NoProfile -ExecutionPolicy Bypass -File $program @arguments -NoDialog 2>&1 | Out-String
        }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    return @{ Code = $code; Output = $output }
}

try {
    [void][IO.Directory]::CreateDirectory($fixture)

    # Standard entry; clean stray files while preserving sources and PDF figures.
    $main = Put 'standard/main.tex' $document
    $sourceHash = (Get-FileHash -LiteralPath $main).Hash
    [void](Put 'standard/chapter.tex' "% !TeX root = main.tex`nSome text.")
    [void](Put 'standard/example.tex' '% \documentclass{article}')
    [void](Put 'standard/backup/ignored.tex' $document)
    [void](Put 'standard/old.log' 'old log')
    $figure = Put 'standard/figure.pdf' 'PDF figure sentinel'
    $result = Run @('-ProjectRoot', (Join-Path $fixture 'standard'))
    Check ($result.Code -eq 0) $result.Output
    Check (Test-Path -LiteralPath (Join-Path $fixture 'standard/build/main.pdf')) 'main.pdf missing'
    Check (-not (Test-Path -LiteralPath (Join-Path $fixture 'standard/old.log'))) 'Old log was not archived'
    Check ((Get-FileHash -LiteralPath $main).Hash -eq $sourceHash) 'Source changed'
    Check ([IO.File]::ReadAllText($figure) -eq 'PDF figure sentinel') 'PDF figure changed'
    $settings = Get-Content -LiteralPath (Join-Path $fixture 'standard/.vscode/settings.json') -Raw | ConvertFrom-Json
    $recipeArgs = $settings.'latex-workshop.latex.tools'[0].args
    Check ($recipeArgs -contains '%DOC%' -and $recipeArgs -notcontains 'main.tex') 'Recipe hard-codes a source name'
    Write-Host 'PASS: main.tex discovery, cleanup, PDF preservation and portable recipe'

    # Nested project and a filename containing Chinese and spaces through .bat.
    $nested = Put 'nested/notes/课程 笔记.tex' $document
    [void](Put 'nested/notes/chapters/part.tex' "% !TeX root = ../课程 笔记.tex`nSome text.")
    $result = Run @((Join-Path $fixture 'nested')) $launcher $true
    Check ($result.Code -eq 0) $result.Output
    Check (Test-Path -LiteralPath (Join-Path $fixture 'nested/notes/build/课程 笔记.pdf')) 'Named PDF missing'
    Check (Test-Path -LiteralPath (Join-Path $fixture 'nested/notes/build/课程 笔记.synctex.gz')) 'Named SyncTeX missing'
    Write-Host 'PASS: batch folder argument, nested discovery, Chinese and space-containing filename'

    # Dragging a chapter file follows its root comment to the real entry.
    [void](Put 'nested/notes/legacy.aux' 'old auxiliary file')
    $result = Run @((Join-Path $fixture 'nested/notes/chapters/part.tex'), '-CleanOnly') $launcher $true
    Check ($result.Code -eq 0) $result.Output
    Check (-not (Test-Path -LiteralPath (Join-Path $fixture 'nested/notes/legacy.aux'))) 'Root hint cleanup failed'
    Check (-not (Test-Path -LiteralPath (Join-Path $fixture 'nested/notes/chapters/build'))) 'Child was mistaken for root'
    Write-Host 'PASS: batch file argument and root-comment resolution'

    # Ambiguity must fail before changing a project, then explicit selection works.
    [void](Put 'multiple/main.tex' $document)
    [void](Put 'multiple/other.tex' $document)
    $oldAux = Put 'multiple/old.aux' 'keep until a root is chosen'
    $result = Run @('-ProjectRoot', (Join-Path $fixture 'multiple'), '-CleanOnly')
    Check ($result.Code -ne 0 -and $result.Output -match 'Multiple LaTeX root') 'Ambiguous entry was silently selected'
    Check (-not (Test-Path -LiteralPath (Join-Path $fixture 'multiple/build'))) 'Ambiguity modified the project'
    Check (Test-Path -LiteralPath $oldAux) 'Ambiguity moved a file'
    $savedPath = $env:Path
    try {
        $env:Path = $PSHOME
        $result = Run @('-ProjectRoot', (Join-Path $fixture 'multiple'), '-MainFile', 'other.tex', '-CleanOnly')
    } finally { $env:Path = $savedPath }
    Check ($result.Code -eq 0) $result.Output
    Check (-not (Test-Path -LiteralPath (Join-Path $fixture 'multiple/.vscode'))) 'Clean-only changed VS Code configuration'
    Check (-not (Test-Path -LiteralPath $oldAux)) 'Explicit clean-only did not archive auxiliary files'
    $result = Run @('-ProjectRoot', (Join-Path $fixture 'multiple'), '-MainFile', 'other.tex')
    Check ($result.Code -eq 0) $result.Output
    Check (Test-Path -LiteralPath (Join-Path $fixture 'multiple/build/other.pdf')) 'Explicit entry was not compiled'
    Check (-not (Test-Path -LiteralPath (Join-Path $fixture 'multiple/build/main.pdf'))) 'Wrong entry was compiled'
    Write-Host 'PASS: ambiguity detection, explicit compilation and clean-only without TeX on PATH'

    # Scripts in a tools subfolder work without a project argument.
    [void](Put 'portable/renamed.tex' $document)
    $portableSetup = Join-Path $fixture 'portable/tools/setup-latex.ps1'
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($portableSetup))
    Copy-Item -LiteralPath $setup -Destination $portableSetup
    [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'empty'))
    Push-Location (Join-Path $fixture 'empty')
    try { $result = Run @() $portableSetup } finally { Pop-Location }
    Check ($result.Code -eq 0) $result.Output
    Check (Test-Path -LiteralPath (Join-Path $fixture 'portable/build/renamed.pdf')) 'Parent-directory discovery failed'
    Write-Host 'PASS: no-argument discovery from a tools subfolder'

    # Missing roots fail before writing configuration or moving files.
    $result = Run @('-ProjectRoot', (Join-Path $fixture 'empty'), '-CleanOnly')
    Check ($result.Code -ne 0) 'Empty folder was accepted as a project'
    Check (-not (Test-Path -LiteralPath (Join-Path $fixture 'empty/build'))) 'Empty-folder failure created output'
    Write-Host 'PASS: missing-entry handling'
    Write-Host 'All regression checks passed.'
} finally {
    if ($KeepFixtures) {
        Write-Host ('Fixtures: ' + $fixture)
    } elseif (Test-Path -LiteralPath $fixture) {
        $resolved = (Resolve-Path -LiteralPath $fixture).Path
        if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolved) -notmatch '^latex-setup-tests-[a-f0-9]{32}$') {
            throw 'Unexpected temporary cleanup target'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
