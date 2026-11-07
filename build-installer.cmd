@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tool\build_windows_installer.ps1" %*
set "RESULT=%ERRORLEVEL%"
if not defined CI pause
exit /b %RESULT%
