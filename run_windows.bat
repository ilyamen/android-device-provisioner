@echo off
cd /d "%~dp0"
title Автоматическая настройка телефонов (Provisioner)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0provision.ps1"
if %ERRORLEVEL% NEQ 0 pause
