@echo off
REM GPO / startup script helper. Copies into C:\Scripts on first boot then runs.
if not exist C:\Scripts mkdir C:\Scripts
if exist "%~dp0Repair-DCLink.ps1" copy /Y "%~dp0Repair-DCLink.ps1" C:\Scripts\Repair-DCLink.ps1 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Repair-DCLink.ps1
exit /b %ERRORLEVEL%
