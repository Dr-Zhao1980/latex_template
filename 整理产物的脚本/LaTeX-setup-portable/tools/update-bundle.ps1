# Rebuild standalone payloads from their editable sources. No TeX is needed.
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$path = Join-Path $root 'setup-latex.ps1'
$text = [IO.File]::ReadAllText($path).Replace("`r`n", "`n")
if ($text.Contains('# BEGIN SETUP CORE')) {
    $text = $text.Substring($text.IndexOf('# BEGIN SETUP CORE') + '# BEGIN SETUP CORE'.Length)
    $text = $text.Substring(0, $text.IndexOf('# END SETUP CORE')).Trim()
}
$start = $text.IndexOf('function Find-TeXBins(')
$end = $text.IndexOf('function Resolve-TeXTools(', $start)
$discovery = $text.Substring($start, $end - $start).Trim()
$runner = [IO.File]::ReadAllText((Join-Path $root 'src/build-latex.ps1')).Replace("`r`n", "`n").Replace('__TOOL_DISCOVERY__', $discovery).Trim()
$start = $text.IndexOf('function Get-PersistentBuildRunnerContent {')
$end = $text.IndexOf('function Get-HiddenBuildLauncherContent {', $start)
$text = $text.Substring(0,$start) + "function Get-PersistentBuildRunnerContent {`n    return @'`n" + $runner + "`n'@`n}`n`n" + $text.Substring($end)
$launcher = [IO.File]::ReadAllText((Join-Path $root 'src/HiddenLauncher.cs')).Replace("`r`n", "`n").Trim()
$start = $text.IndexOf('function Install-HiddenExecutable {')
if ($start -ge 0) {
    $end = $text.IndexOf('function Install-PersistentBuildRunner(', $start)
    $text = $text.Remove($start,$end-$start)
}
$start = $text.IndexOf('function Install-PersistentBuildRunner(')
$installer = @'
function Install-HiddenExecutable {
    $source = @'
__CS__
'MARKER
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

'@
$installer = $installer.Replace('__CS__',$launcher).Replace("'MARKER", "'@")
$text = $text.Insert($start, $installer)
$lastExit = $text.LastIndexOf('exit $exitCode')
if ($lastExit -ge $text.LastIndexOf('function Show-Completion')) {
    $text = $text.Substring(0,$lastExit) + '$script:SetupExitCode = $exitCode' + $text.Substring($lastExit + 'exit $exitCode'.Length)
}
$wrapper = @'
#requires -Version 5.1
# The outer guard also catches argument-binding errors before the core starts.
$entryArguments = @($args)
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$script:SetupExitCode = 1
$skipFinalPrompt = ($env:LATEX_SETUP_NO_PAUSE -eq '1') -or ($env:LATEX_SETUP_BAT_OWNER -eq '1') -or ($entryArguments -contains '-NoPause')
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
        } else { & { __CORE__ } @entryArguments }
    } else { & { __CORE__ } @entryArguments }
} catch {
    Write-Host ('ERROR: ' + $_.Exception.Message)
    $script:SetupExitCode = 1
} finally {
    if (-not $skipFinalPrompt) {
        try { Write-Host 'Press Enter to close this window / 按 Enter 关闭窗口'; [void][Console]::ReadLine() }
        catch { Write-Host 'Interactive input unavailable. Use an interactive terminal or explicit -NoPause for automation.' }
    }
}
exit $script:SetupExitCode
'@
# Only embed the core once; invocation uses a reusable script block.
$coreStart = $wrapper.IndexOf('try {')
$wrapper = $wrapper.Insert($coreStart, ('$setupCore = {' + "`n# BEGIN SETUP CORE`n" + $text + "`n# END SETUP CORE`n}`n"))
$wrapper = $wrapper.Replace('& { __CORE__ }', '& $setupCore')
$text = $wrapper
[IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($true)))
$header = [IO.File]::ReadAllText((Join-Path $root 'src/setup-header.bat')).Replace("`r`n", "`n").TrimEnd()
[IO.File]::WriteAllText((Join-Path $root 'setup-latex.bat'), ($header + "`n`n### POWERSHELL PAYLOAD START ###`n" + $text).Replace("`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
Write-Host 'Updated independent PS1 and BAT payloads.'
$shPath = Join-Path $root 'setup-latex.sh'
$sh = [IO.File]::ReadAllText($shPath).Replace("`r`n", "`n")
$marker = "  cat > `"`$tmp`" <<'PERMANENT_RUNNER'"
$start = $sh.IndexOf($marker)
$end = $sh.IndexOf("`nPERMANENT_RUNNER", $start + $marker.Length)
$shRunner = [IO.File]::ReadAllText((Join-Path $root 'src/build-latex.sh')).Replace("`r`n", "`n").TrimEnd()
$sh = $sh.Substring(0,$start) + $marker + "`n" + $shRunner + $sh.Substring($end)
[IO.File]::WriteAllText($shPath,$sh,(New-Object Text.UTF8Encoding($false)))
