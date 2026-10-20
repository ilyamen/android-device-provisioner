@echo off
chcp 65001 >nul
title Автоматическая настройка телефонов (Provisioner)

cd /d "%~dp0"

echo ============================================================
echo       Автоматическая настройка телефонов (Android 14-16)
echo ============================================================
echo.

:: 1. Проверяем наличие ADB в системе или локально
where adb >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    goto :RUN_PROVISIONER
)

if exist "%~dp0platform-tools\adb.exe" (
    set "PATH=%~dp0platform-tools;%PATH%"
    goto :RUN_PROVISIONER
)

echo [*] Утилита ADB не обнаружена на компьютере.
echo [*] Скачиваю официальный пакет Google Platform-Tools (ADB)...
echo     Пожалуйста, подождите пару секунд...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; " ^
    "$url = 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip'; " ^
    "$zip = Join-Path $PWD 'platform-tools.zip'; " ^
    "Write-Host '[*] Загрузка platform-tools.zip с серверов Google...'; " ^
    "(New-Object System.Net.WebClient).DownloadFile($url, $zip); " ^
    "Write-Host '[*] Распаковка...'; " ^
    "Expand-Archive -Path $zip -DestinationPath $PWD -Force; " ^
    "Remove-Item $zip -Force; " ^
    "Write-Host '[OK] ADB успешно установлен локально!'"

if exist "%~dp0platform-tools\adb.exe" (
    set "PATH=%~dp0platform-tools;%PATH%"
    echo.
    echo [OK] Окружение полностью готово!
    echo.
) else (
    echo.
    echo [!] ОШИБКА: Не удалось автоматически скачать ADB.
    echo     Проверьте подключение к интернету и перезапустите скрипт.
    echo.
    pause
    exit /b 1
)

:RUN_PROVISIONER
:: 2. Запускаем нативный PowerShell-скрипт настройки
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0provision.ps1"

echo.
echo Нажмите любую клавишу для выхода...
pause >nul
