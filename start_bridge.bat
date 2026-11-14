@echo off
setlocal
title Metrolist Now Playing Bridge
cd /d "%~dp0"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0bridge_metrolist.ps1" %*
if errorlevel 1 pause

endlocal
