@echo off
rem double-click to put back Stremio's official files (add -RemoveConfig to also delete the config)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0restore.ps1" %*
pause
