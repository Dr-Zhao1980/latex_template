@echo off
setlocal EnableExtensions DisableDelayedExpansion
rem The complete PS1 payload is embedded below. No adjacent files are needed.
set "LATEX_BAT_SELF=%~f0"
set "LATEX_SETUP_PROJECT_ROOT=%~dp0"
set "LATEX_SETUP_BAT_OWNER=1"
set "LATEX_EXIT_CODE=1"
set "LATEX_BAT_PAYLOAD=%TEMP%\latex-setup-%RANDOM%-%RANDOM%-%RANDOM%.ps1"
set "LATEX_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%LATEX_POWERSHELL%" goto :missingpowershell
"%LATEX_POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop';try{$s=[IO.File]::ReadAllText($env:LATEX_BAT_SELF,[Text.Encoding]::UTF8);$m=('### POWERSHELL PAYLOAD '+'START ###');$i=$s.IndexOf($m,[StringComparison]::Ordinal);if($i -lt 0){throw 'Embedded payload is missing'};[IO.File]::WriteAllText($env:LATEX_BAT_PAYLOAD,$s.Substring($i+$m.Length),[Text.UTF8Encoding]::new($true))}catch{Write-Host $_;exit 3}"
if errorlevel 1 goto :unpackfailed
"%LATEX_POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%LATEX_BAT_PAYLOAD%" %*
set "LATEX_EXIT_CODE=%ERRORLEVEL%"
goto :finish
:missingpowershell
echo ERROR: Windows PowerShell 5.1 is missing or blocked.
set "LATEX_EXIT_CODE=2"
goto :finish
:unpackfailed
echo ERROR: Cannot unpack embedded code. Check TEMP permissions and security software.
set "LATEX_EXIT_CODE=3"
:finish
if exist "%LATEX_BAT_PAYLOAD%" del /q "%LATEX_BAT_PAYLOAD%" >nul 2>nul
echo.
echo Setup exit code: %LATEX_EXIT_CODE%
rem Only explicit unattended mode skips this final Enter prompt.
if "%LATEX_SETUP_NO_PAUSE%"=="1" goto :done
for %%A in (%*) do if /i "%%~A"=="-NoPause" goto :done
set /p "LATEX_CLOSE=Press Enter to close this window..."
:done
exit /b %LATEX_EXIT_CODE%
