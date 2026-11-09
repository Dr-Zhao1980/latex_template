@echo off
setlocal EnableExtensions DisableDelayedExpansion
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-latex.ps1" %*
exit /b %ERRORLEVEL%
