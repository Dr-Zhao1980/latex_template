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

function Native([string]$program, [string[]]$arguments) {
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $program @arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    return @{ Code = $code; Output = $output }
}

try {
    [void][IO.Directory]::CreateDirectory($fixture)
    $batchText = [IO.File]::ReadAllText($launcher, [Text.Encoding]::UTF8)
    $marker = '# POWERSHELL_PAYLOAD_BEGIN'
    $payload = $batchText.Substring($batchText.LastIndexOf($marker) + $marker.Length).TrimStart([char]13,[char]10)
    $psText = [IO.File]::ReadAllText($setup, [Text.Encoding]::UTF8)
    Check ($payload.Replace("`r`n", "`n") -eq $psText.Replace("`r`n", "`n")) 'Embedded batch implementation differs from standalone PowerShell'

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

    # A standalone script beside the source ignores an unrelated working folder.
    [void](Put 'portable/renamed.tex' $document)
    $portableSetup = Join-Path $fixture 'portable/setup-latex.ps1'
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($portableSetup))
    Copy-Item -LiteralPath $setup -Destination $portableSetup
    [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'empty'))
    Push-Location (Join-Path $fixture 'empty')
    try { $result = Run @() $portableSetup } finally { Pop-Location }
    Check ($result.Code -eq 0) $result.Output
    Check (Test-Path -LiteralPath (Join-Path $fixture 'portable/build/renamed.pdf')) 'Script-directory discovery failed'
    Write-Host 'PASS: no-argument discovery beside the root document'

    # Missing roots fail before writing configuration or moving files.
    $result = Run @('-ProjectRoot', (Join-Path $fixture 'empty'), '-CleanOnly')
    Check ($result.Code -ne 0) 'Empty folder was accepted as a project'
    Check (-not (Test-Path -LiteralPath (Join-Path $fixture 'empty/build'))) 'Empty-folder failure created output'
    Write-Host 'PASS: missing-entry handling'

    foreach ($kind in @('bat', 'ps1')) {
        $workspace = 'standalone-' + $kind
        $relative = $workspace + '/project with spaces'
        $project = Join-Path $fixture $relative
        $entry = Put ($relative + '/课程 笔记.tex') $document
        $sourceHash = (Get-FileHash -LiteralPath $entry).Hash
        $program = Join-Path $project ('setup-latex.' + $kind)
        Copy-Item -LiteralPath $(if ($kind -eq 'bat') { $launcher } else { $setup }) -Destination $program
        $other = if ($kind -eq 'bat') { 'ps1' } else { 'bat' }
        Check (-not (Test-Path -LiteralPath (Join-Path $project ('setup-latex.' + $other)))) 'Standalone fixture contains a companion script'
        [void](Put ($relative + '/.vscode/settings.json') '{ broken JSON')
        [void](Put ($workspace + '/.vscode/settings.json') '{"editor.wordWrap":"on","latex-workshop.latex.outDir":"%DIR%","latex-workshop.latex.external.build.command":"obsolete"}')
        $rc = Put ($relative + '/latexmkrc') "# user comment`n`$out_dir = '.';`n"
        $dotRc = Put ($relative + '/.latexmkrc') "# dotfile preference`n`$aux_dir = '.';`n"
        [void](Put ($relative + '/old.aux') 'old root cache')
        [void](Put ($relative + '/build/old.log') 'old build cache')
        [void](Put ($relative + '/chapters/old.aux') 'old chapter cache')
        $archiveSentinel = Put ($relative + '/build/legacy/keep.aux') 'existing archive'
        $pdfFigure = Put ($relative + '/figure.pdf') 'PDF figure sentinel'
        [void](Put 'unrelated/other.tex' $document)
        $unrelated = Put 'unrelated/keep.aux' 'outside selected project'
        Push-Location (Join-Path $fixture 'unrelated')
        try { $result = Run @() $program ($kind -eq 'bat') } finally { Pop-Location }
        Check ($result.Code -eq 0) $result.Output
        Check ((Get-FileHash -LiteralPath $entry).Hash -eq $sourceHash) 'Standalone script changed source'
        Check (Test-Path -LiteralPath $unrelated) 'Caller working directory was cleaned'
        Check (Test-Path -LiteralPath (Join-Path $project '课程 笔记.pdf')) 'Standalone root PDF missing'
        Check (Test-Path -LiteralPath (Join-Path $project 'build/课程 笔记.synctex.gz')) 'Standalone SyncTeX missing'
        foreach ($old in @('old.aux', 'chapters/old.aux')) {
            Check (-not (Test-Path -LiteralPath (Join-Path $project $old))) ('Old output remains: ' + $old)
        }
        $archived = @(Get-ChildItem -LiteralPath (Join-Path $project 'build/legacy') -File -Recurse)
        Check ($archived.Count -eq 3) 'Stray outputs were not archived completely'
        Check (Test-Path -LiteralPath (Join-Path $project 'build/old.log')) 'Normal setup discarded build cache before compiling'
        Check ([IO.File]::ReadAllText($archiveSentinel) -eq 'existing archive') 'Existing archive was moved'
        Check ([IO.File]::ReadAllText($pdfFigure) -eq 'PDF figure sentinel') 'PDF figure was changed'
        foreach ($path in @((Join-Path $project '.vscode/settings.json'), (Join-Path $fixture ($workspace + '/.vscode/settings.json')))) {
            $config = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            Check ($config.'latex-workshop.latex.outDir' -eq '%DIR%/build') 'Wrong output directory in VS Code'
            Check (-not $config.PSObject.Properties['latex-workshop.latex.external.build.command']) 'Stale external build overrides repair'
            Check ($config.'latex-workshop.latex.tools'[0].args -contains '%DOC%') 'VS Code root is hard-coded'
            Check (-not $config.'latex-workshop.latex.build.enableMagicComments') 'Magic build command can bypass repaired recipe'
        }
        $parentConfig = Get-Content -LiteralPath (Join-Path $fixture ($workspace + '/.vscode/settings.json')) -Raw | ConvertFrom-Json
        Check ($parentConfig.'editor.wordWrap' -eq 'on') 'Unrelated parent settings were lost'
        Check (@(Get-ChildItem -LiteralPath (Join-Path $project '.vscode') -Filter 'settings.json.backup-*').Count -eq 1) 'Broken settings were not backed up'
        foreach ($path in @($rc, $dotRc)) {
            $text = [IO.File]::ReadAllText($path)
            Check ($text.Contains('课程 笔记.tex') -and $text.Contains("`$out_dir = 'build';")) 'latexmk configuration was not repaired'
            Check (@(Get-ChildItem -LiteralPath $project -Filter ([IO.Path]::GetFileName($path) + '.backup-*')).Count -eq 1) 'latexmk configuration was not backed up'
        }
        $settingsPath = Join-Path $project '.vscode/settings.json'
        $settingsHash = (Get-FileHash -LiteralPath $settingsPath).Hash
        $rcHash = (Get-FileHash -LiteralPath $rc).Hash
        $pdf = Join-Path $project '课程 笔记.pdf'
        $pdfHash = (Get-FileHash -LiteralPath $pdf).Hash
        [void](Put ($relative + '/new.aux') 'new stale output')
        $savedPath = $env:Path
        try {
            $env:Path = $PSHOME + ';' + (Join-Path $env:SystemRoot 'System32')
            $result = Run @('-ConfigureOnly') $program ($kind -eq 'bat')
        } finally { $env:Path = $savedPath }
        Check ($result.Code -eq 0) $result.Output
        Check (-not (Test-Path -LiteralPath (Join-Path $project 'new.aux'))) 'Configure-only did not clean outputs'
        Check (-not (Test-Path -LiteralPath (Join-Path $project 'build/课程 笔记.aux'))) 'Configure-only left active build cache'
        Check (-not (Test-Path -LiteralPath (Join-Path $project 'build/old.log'))) 'Explicit cleanup left stale build output'
        Check ((Get-FileHash -LiteralPath $settingsPath).Hash -eq $settingsHash) 'Repeated settings repair is not idempotent'
        Check ((Get-FileHash -LiteralPath $rc).Hash -eq $rcHash) 'Repeated latexmk repair is not idempotent'
        Check ((Get-FileHash -LiteralPath $pdf).Hash -eq $pdfHash) 'Configure-only compiled or removed the PDF'

        # Execute the repaired command-line configuration, without -norc or
        # explicit engine/output/source arguments.
        Push-Location $project
        try { $result = Native 'latexmk' @('-g') } finally { Pop-Location }
        Check ($result.Code -eq 0) $result.Output
        Check (Test-Path -LiteralPath (Join-Path $project 'build/课程 笔记.synctex.gz')) 'Repaired latexmkrc was not used'
        Check (-not (Test-Path -LiteralPath (Join-Path $project '课程 笔记.synctex.gz'))) 'SyncTeX leaked out of build/'

        # Execute the exact generated VS Code tool as well.
        [void](Put ($relative + '/课程 笔记.tex') ($document + "% VS Code rebuild`n"))
        $config = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        $tool = $config.'latex-workshop.latex.tools'[0]
        $toolArgs = @($tool.args | ForEach-Object { $_.Replace('%DOC%', $entry).Replace('%DIR%', $project) })
        Push-Location $project
        try { $result = Native $tool.command $toolArgs } finally { Pop-Location }
        Check ($result.Code -eq 0) $result.Output
        Check ($tool.command -eq 'powershell.exe') 'VS Code bypasses the recovery runner'
        Check (Test-Path -LiteralPath (Join-Path $project '.vscode/build-latex.ps1')) 'Build runner was not generated'
        $lastGoodPdf = (Get-FileHash -LiteralPath $pdf).Hash

        # Cleanup and settings must not be skipped when compilation fails.
        [void](Put ($relative + '/课程 笔记.tex') "\documentclass{article}`n\begin{document}\DefinitelyUndefinedCommand\end{document}")
        [void](Put ($relative + '/failure.aux') 'cleanup before compilation failure')
        [void](Put ($relative + '/.vscode/settings.json') '{"latex-workshop.latex.outDir":"wrong"}')
        $result = Run @() $program ($kind -eq 'bat')
        Check ($result.Code -ne 0) 'Invalid TeX was reported as compiled successfully'
        Check (-not (Test-Path -LiteralPath (Join-Path $project 'failure.aux'))) 'Compilation failure prevented cleanup'
        $config = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        Check ($config.'latex-workshop.latex.outDir' -eq '%DIR%/build') 'Compilation failure prevented configuration repair'
        Check ((Get-FileHash -LiteralPath $pdf).Hash -eq $lastGoodPdf) 'Failed recovery removed the last successful PDF'
        $parentPath = Put ($workspace + '/.vscode/settings.json') '{ parent deliberately untouched'
        $parentHash = (Get-FileHash -LiteralPath $parentPath).Hash
        $result = Run @('-ProjectOnly', '-ConfigureOnly') $program ($kind -eq 'bat')
        Check ($result.Code -eq 0) $result.Output
        Check ((Get-FileHash -LiteralPath $parentPath).Hash -eq $parentHash) '-ProjectOnly changed parent settings'
        Write-Host ('PASS: ' + $kind + ' alone; root/build cleanup, project/parent/latexmk repair, repaired CLI/VS Code commands, no-TeX configuration and compile-failure recovery')
    }
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
