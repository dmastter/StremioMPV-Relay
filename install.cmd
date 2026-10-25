@echo off
rem double-click to install or re-apply the patch (also after every Stremio update)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
pause
