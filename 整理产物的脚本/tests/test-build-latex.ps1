param([switch]$KeepFixtures)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$runner = Join-Path $repository 'LaTeX_学习笔记模板/.vscode/build-latex.ps1'
$setup = Join-Path $repository '整理产物的脚本/setup-latex.ps1'
$powershell = Join-Path $PSHOME 'powershell.exe'
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixture = Join-Path $tempBase ('latex-build-tests-' + [guid]::NewGuid().ToString('N'))
$utf8 = New-Object Text.UTF8Encoding($false)

function Check([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
}
function Put([string]$relative, [string]$text) {
    $path = Join-Path $fixture $relative
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    [IO.File]::WriteAllText($path, $text, $utf8)
    return $path
}
function Run([string]$script, [string[]]$arguments) {
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $powershell -NoProfile -ExecutionPolicy Bypass -File $script @arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    return @{ Code = $code; Output = $output }
}

try {
    $fakeEngine = @'
$ErrorActionPreference = 'Stop'
$received = @($args)
$plan = Get-Content -LiteralPath 'plan.json' -Raw -Encoding UTF8 | ConvertFrom-Json
$history = if (Test-Path -LiteralPath 'calls.json') { Get-Content -LiteralPath 'calls.json' -Raw -Encoding UTF8 | ConvertFrom-Json } else { @() }
$history = @($history)
$count = @($history | Where-Object { $_.Mode -eq 'build' }).Count
$mode = if ($received -ccontains '-c') { 'clean' } else { 'build' }
$history += [pscustomobject]@{ Mode = $mode; Arguments = $received }
[IO.File]::WriteAllText((Join-Path (Get-Location).Path 'calls.json'), (ConvertTo-Json -InputObject @($history) -Depth 8))
if ($mode -eq 'clean') {
    [Console]::Out.WriteLine('ENGINE CLEAN')
    if (Test-Path -LiteralPath 'build/cache.aux') { [IO.File]::Delete((Join-Path (Get-Location).Path 'build/cache.aux')) }
    exit ([int]$plan.CleanCode)
}
$code = [int]$plan.BuildCodes[[Math]::Min($count, $plan.BuildCodes.Count-1)]
[Console]::Out.WriteLine('ENGINE STDOUT BUILD ' + ($count+1))
[Console]::Error.WriteLine('ENGINE STDERR BUILD ' + ($count+1))
if ($code -ne 0) {
    [Console]::Error.WriteLine('REAL BUILD ERROR ' + $code)
    [IO.File]::WriteAllText((Join-Path (Get-Location).Path 'build/课程 笔记.v2.log'), 'REAL BUILD ERROR ' + $code)
}
exit $code
'@
    $launcher = "@echo off`r`n`"$powershell`" -NoProfile -ExecutionPolicy Bypass -File `"%~dp0fake-engine.ps1`" %*`r`nexit /b %ERRORLEVEL%`r`n"
    $cases = @(
        @{ Name = 'first-success'; BuildCodes = @(0); CleanCode = 0; Expected = 0; Modes = 'build' },
        @{ Name = 'recovered'; BuildCodes = @(7,0); CleanCode = 0; Expected = 0; Modes = 'build,clean,build' },
        @{ Name = 'retry-failed'; BuildCodes = @(7,19); CleanCode = 0; Expected = 19; Modes = 'build,clean,build' },
        @{ Name = 'cleanup-failed'; BuildCodes = @(7,19); CleanCode = 13; Expected = 19; Modes = 'build,clean,build' }
    )
    foreach ($case in $cases) {
        $folder = 'fake/' + $case.Name
        $project = Join-Path $fixture $folder
        [void](Put ($folder + '/课程 笔记.v2.tex') "% !TeX root = missing-old-name.tex`n\documentclass{article}`n\begin{document}Example.\end{document}")
        [void](Put ($folder + '/fake-engine.ps1') $fakeEngine)
        $fake = Put ($folder + '/latexmk.cmd') $launcher
        [void](Put ($folder + '/plan.json') (ConvertTo-Json -InputObject $case -Depth 5))
        $cache = Put ($folder + '/build/cache.aux') 'existing incremental cache'
        $pdf = Put ($folder + '/build/课程 笔记.v2.pdf') 'last successful PDF'
        $pdfHash = (Get-FileHash -LiteralPath $pdf).Hash
        $result = Run $runner @('-ProjectRoot', $project, '-MainFile', '课程 笔记.v2', '-Latexmk', $fake)
        Check ($result.Code -eq $case.Expected) ($case.Name + ': wrong exit code. ' + $result.Output)
        $history = Get-Content -LiteralPath (Join-Path $project 'calls.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $history = @($history)
        Check (($history.Mode -join ',') -eq $case.Modes) ($case.Name + ': incorrect retry sequence')
        foreach ($call in $history) {
            Check ($call.Arguments -cnotcontains '-C') 'Recovery deletes PDF output'
            Check ($call.Arguments -notcontains '-g' -and $call.Arguments -notcontains '-norc') 'Normal build forces recompilation or skips configuration'
            Check ($call.Arguments -contains './课程 笔记.v2.tex') 'Renamed source was not resolved'
        }
        Check ((Get-FileHash -LiteralPath $pdf).Hash -eq $pdfHash) 'Last PDF was changed by recovery'
        Check ($result.Output -match 'ENGINE STDOUT BUILD 1' -and $result.Output -match 'ENGINE STDERR BUILD 1') 'Engine output was swallowed'
        if ($case.Name -eq 'first-success') {
            Check (Test-Path -LiteralPath $cache) 'Successful build discarded its cache'
        } else {
            Check (@($history | Where-Object Mode -eq 'build').Count -eq 2) 'Recovery built more than twice'
            Check (@($history | Where-Object Mode -eq 'clean').Count -eq 1) 'Recovery cleaned more than once'
        }
        if ($case.Expected -ne 0) { Check ($result.Output -match 'REAL BUILD ERROR 19') 'Final engine error was hidden' }
        Write-Host ('PASS: ' + $case.Name + ', native output, bounded retry and PDF preservation')
    }

    # Real TeX/BibTeX: the second unchanged save must reuse the first build.
    $document = @'
\documentclass{article}
\begin{document}
\input{chapters/part}
\bibliographystyle{unsrt}
\bibliography{references}
\end{document}
'@
    $source = Put 'real/课程 笔记.tex' $document
    [void](Put 'real/chapters/part.tex' 'A short note \cite{demo}.')
    [void](Put 'real/references.bib' '@book{demo,author={Example Author},title={Example Reference},publisher={Example Publisher},year={2026}}')
    $project = Join-Path $fixture 'real'
    $result = Run $setup @('-ProjectRoot', $project, '-ConfigureOnly', '-ProjectOnly', '-NoDialog')
    Check ($result.Code -eq 0) $result.Output
    $generated = Join-Path $project '.vscode/build-latex.ps1'
    Check ([IO.File]::ReadAllText($generated).Replace("`r`n","`n") -eq [IO.File]::ReadAllText($runner).Replace("`r`n","`n")) 'Generated runner differs from shipped runner'
    $result = Run $generated @('-MainFile', '课程 笔记.tex')
    Check ($result.Code -eq 0) $result.Output
    $snapshot = @{}
    foreach ($extension in @('aux','bbl','pdf')) {
        $path = Join-Path $project ('build/课程 笔记.' + $extension)
        Check (Test-Path -LiteralPath $path) ('Missing real build output: ' + $extension)
        $snapshot[$path] = (Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks
    }
    $result = Run $generated @('-MainFile', '课程 笔记')
    Check ($result.Code -eq 0) $result.Output
    Check ($result.Output -notmatch 'Cleaning auxiliary|Retrying once') 'Unchanged successful build triggered recovery'
    foreach ($path in $snapshot.Keys) {
        Check ((Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks -eq $snapshot[$path]) 'Unchanged save regenerated cached TeX/BibTeX/PDF output'
    }
    Write-Host 'PASS: real unchanged TeX/BibTeX build preserves auxiliary, bibliography and PDF timestamps'

    $pdf = Join-Path $project 'build/课程 笔记.pdf'
    $hash = (Get-FileHash -LiteralPath $pdf).Hash
    [IO.File]::WriteAllText($source, $document.Replace('\end{document}', '\DefinitelyUndefinedCommand\end{document}'), $utf8)
    $result = Run $generated @('-MainFile', '课程 笔记.tex')
    Check ($result.Code -ne 0) 'Real TeX error returned success'
    Check (@([regex]::Matches($result.Output, 'Retrying once')).Count -eq 1) 'Real TeX error did not stop after one retry'
    Check ($result.Output -match 'DefinitelyUndefinedCommand|Undefined control sequence') 'Real TeX error was not reported'
    Check ((Get-FileHash -LiteralPath $pdf).Hash -eq $hash) 'Real failed build removed the previous PDF'
    Check (Test-Path -LiteralPath (Join-Path $project 'build/课程 笔记.log')) 'Final real error log is missing'
    Write-Host 'PASS: real TeX failure retries once, reports diagnostics and keeps the previous PDF'
    Write-Host 'All incremental-build checks passed.'
} finally {
    if ($KeepFixtures) { Write-Host ('Fixtures: ' + $fixture) }
    elseif (Test-Path -LiteralPath $fixture) {
        $resolved = (Resolve-Path -LiteralPath $fixture).Path
        if (-not $resolved.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolved) -notmatch '^latex-build-tests-[a-f0-9]{32}$') {
            throw 'Unexpected test cleanup target'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
