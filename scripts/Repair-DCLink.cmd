@echo off
REM Run repair now (Administrator). For autostart use Install-Repair-DCLink.ps1
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Repair-DCLink.ps1"
echo ExitCode=%ERRORLEVEL%
pause
