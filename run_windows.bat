@echo off
cd /d "%~dp0"
title Auto-Provisioner (com.gadgets.auto)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0provision.ps1"
echo.
pause
