# ============================================================
#   Android Auto-Provisioner for com.gadgets.auto (Windows PS)
#   Настройка чтения банковских пушей и SMS (Android 14-16)
# ============================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$PackageName = "com.gadgets.auto"
$NotificationService = "com.gadgets.auto/com.gadgets.auto.util.network.NotificationService"
$DefaultApk = "HEAD_2026.10.08_release.apk"

$RuntimePermissions = @(
    "android.permission.READ_SMS",
    "android.permission.RECEIVE_SMS",
    "android.permission.SEND_SMS",
    "android.permission.POST_NOTIFICATIONS",
    "android.permission.READ_PHONE_STATE",
    "android.permission.READ_PHONE_NUMBERS",
    "android.permission.ACCESS_FINE_LOCATION",
    "android.permission.ACCESS_COARSE_LOCATION",
    "android.permission.READ_EXTERNAL_STORAGE",
    "android.permission.WRITE_EXTERNAL_STORAGE",
    "android.permission.CAMERA",
    "android.permission.RECEIVE_MMS",
    "android.permission.READ_MEDIA_IMAGES",
    "android.permission.READ_MEDIA_VIDEO",
    "android.permission.READ_MEDIA_AUDIO",
    "android.permission.READ_MEDIA_VISUAL_USER_SELECTED"
)

Clear-Host
Write-Host "============================================================" -ForegroundColor Green
Write-Host "      Android Auto-Provisioner for $PackageName" -ForegroundColor Green
Write-Host "      Настройка чтения банковских пушей и SMS (Android 14-16)" -ForegroundColor Green
Write-Host "============================================================`n" -ForegroundColor Green

# 1. Определение рабочей папки
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptDir) { $ScriptDir = $PSScriptRoot }
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }

# 2. Проверка и автоматическое скачивание ADB
$AdbInPath = Get-Command adb -ErrorAction SilentlyContinue
$LocalAdb = Join-Path $ScriptDir "platform-tools\adb.exe"

if (-not $AdbInPath -and -not (Test-Path $LocalAdb)) {
    Write-Host "[*] ADB не обнаружен на компьютере." -ForegroundColor Yellow
    Write-Host "[*] Скачиваю официальный пакет Google Platform-Tools (ADB)..." -ForegroundColor Cyan
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $zipPath = Join-Path $ScriptDir "platform-tools.zip"
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile("https://dl.google.com/android/repository/platform-tools-latest-windows.zip", $zipPath)
        Write-Host "[*] Распаковка архива..." -ForegroundColor Cyan
        Expand-Archive -Path $zipPath -DestinationPath $ScriptDir -Force
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        Write-Host "[OK] ADB успешно установлен локально!`n" -ForegroundColor Green
    } catch {
        Write-Host "[!] Ошибка загрузки ADB: $_" -ForegroundColor Red
        Write-Host "Проверьте подключение к интернету и перезапустите скрипт."
        Read-Host "Нажмите Enter для выхода..."
        exit 1
    }
}

if (Test-Path $LocalAdb) {
    $toolsDir = Join-Path $ScriptDir "platform-tools"
    $env:PATH = "$toolsDir;$env:PATH"
}

function Exec-Cmd ($cmd) {
    $proc = New-Object System.Diagnostics.ProcessStartInfo
    $proc.FileName = "cmd.exe"
    $proc.Arguments = "/c $cmd"
    $proc.RedirectStandardOutput = $true
    $proc.RedirectStandardError = $true
    $proc.UseShellExecute = $false
    $proc.CreateNoWindow = $true

    $p = [System.Diagnostics.Process]::Start($proc)
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return @{
        Stdout = $stdout.Trim()
        Stderr = $stderr.Trim()
        ExitCode = $p.ExitCode
    }
}

function Get-DevicesStatus {
    $res = Exec-Cmd "adb devices"
    $lines = $res.Stdout -split "`r?\n"
    $authorized = @()
    $unauthorized = @()
    $noPermissions = @()

    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split "\s+"
        if ($parts.Count -ge 2) {
            $serial = $parts[0]
            $status = $parts[1]
            if ($status -eq "device") {
                $authorized += $serial
            } elseif ($status -eq "unauthorized") {
                $unauthorized += $serial
            } elseif ($status -match "permission|no") {
                $noPermissions += $serial
            }
        }
    }
    return @{
        Authorized = $authorized
        Unauthorized = $unauthorized
        NoPermissions = $noPermissions
    }
}

function Get-DeviceProp ($serial, $prop) {
    $res = Exec-Cmd "adb -s $serial shell getprop $prop"
    return $res.Stdout
}

function Provision-Device ($serial, $apkPath) {
    Write-Host "`n============================================================" -ForegroundColor Cyan
    Write-Host "[*] НАЧИНАЮ НАСТРОЙКУ УСТРОЙСТВА: $serial" -ForegroundColor Cyan
    
    $manuf = Get-DeviceProp $serial "ro.product.manufacturer"
    $model = Get-DeviceProp $serial "ro.product.model"
    $ver = Get-DeviceProp $serial "ro.build.version.release"
    Write-Host "[*] Модель: $manuf $model | Android $ver" -ForegroundColor White
    Write-Host "============================================================" -ForegroundColor Cyan

    # 1. Проверяем установлено ли приложение
    $checkApp = Exec-Cmd "adb -s $serial shell pm path $PackageName"
    if ($checkApp.Stdout -notmatch "package:") {
        Write-Host "[-] Приложение $PackageName НЕ установлено." -ForegroundColor Yellow
        if ($apkPath -and (Test-Path $apkPath)) {
            Write-Host "[+] Устанавливаю $apkPath ..." -ForegroundColor Cyan
            $inst = Exec-Cmd "adb -s $serial install -r -g `"$apkPath`""
            if ($inst.Stdout -match "Success") {
                Write-Host "    [OK] Успешно установлено!" -ForegroundColor Green
            } else {
                Write-Host "    [!] Ошибка установки: $($inst.Stdout) $($inst.Stderr)" -ForegroundColor Red
                return $false
            }
        } else {
            Write-Host "    [!] APK-файл не найден рядом со скриптом." -ForegroundColor Red
        }
    } else {
        Write-Host "[OK] Приложение $PackageName уже установлено." -ForegroundColor Green
    }

    # 2. Выдаем RECEIVE_SENSITIVE_NOTIFICATIONS (защита Android 15/16)
    Write-Host "`n[1/4] Разблокировка чувствительных пуш-уведомлений (Android 15/16)..." -ForegroundColor Cyan
    Exec-Cmd "adb -s $serial shell cmd appops set --user 0 $PackageName RECEIVE_SENSITIVE_NOTIFICATIONS allow" | Out-Null
    $appop = Exec-Cmd "adb -s $serial shell cmd appops get --user 0 $PackageName RECEIVE_SENSITIVE_NOTIFICATIONS"
    if ($appop.Stdout -match "allow") {
        Write-Host "    [OK] RECEIVE_SENSITIVE_NOTIFICATIONS -> ALLOW" -ForegroundColor Green
    } else {
        Write-Host "    [i] Статус: $($appop.Stdout) (для Android 14 и старее это норма)" -ForegroundColor DarkGray
    }

    # 3. Активируем слушатель уведомлений
    Write-Host "`n[2/4] Активация системного сервиса чтения уведомлений..." -ForegroundColor Cyan
    Exec-Cmd "adb -s $serial shell cmd notification allow_listener $NotificationService 0" | Out-Null
    $listeners = Exec-Cmd "adb -s $serial shell settings get secure enabled_notification_listeners"
    if ($listeners.Stdout -match [regex]::Escape($PackageName)) {
        Write-Host "    [OK] NotificationListenerService включен в системе!" -ForegroundColor Green
    } else {
        $curr = if ($listeners.Stdout -ne "null") { $listeners.Stdout } else { "" }
        $newListeners = "$curr:$NotificationService".Trim(":")
        Exec-Cmd "adb -s $serial shell settings put secure enabled_notification_listeners `"$newListeners`"" | Out-Null
        Write-Host "    [OK] Прописан напрямую через settings secure." -ForegroundColor Green
    }

    # 4. Выдаем runtime permissions
    Write-Host "`n[3/4] Выдача всех системных runtime-разрешений (SMS, телефон, память)..." -ForegroundColor Cyan
    $granted = 0
    foreach ($perm in $RuntimePermissions) {
        $res = Exec-Cmd "adb -s $serial shell pm grant $PackageName $perm"
        if ($res.ExitCode -eq 0) { $granted++ }
    }
    Write-Host "    [OK] Проверено и выдано $granted/$($RuntimePermissions.Count) разрешений." -ForegroundColor Green

    # 5. Исключение из экономии батареи (Doze mode)
    Write-Host "`n[4/4] Исключение из энергосбережения батареи (фоновая работа)..." -ForegroundColor Cyan
    Exec-Cmd "adb -s $serial shell dumpsys deviceidle whitelist +$PackageName" | Out-Null
    Write-Host "    [OK] Добавлен в deviceidle whitelist!" -ForegroundColor Green

    Write-Host "`n============================================================" -ForegroundColor Green
    Write-Host "[+++] УСТРОЙСТВО $serial ($manuf $model) ПОЛНОСТЬЮ НАСТРОЕНО!" -ForegroundColor Green
    Write-Host "============================================================`n" -ForegroundColor Green
    return $true
}

$ApkPath = Join-Path $ScriptDir $DefaultApk
if (-not (Test-Path $ApkPath)) {
    $ApkPath = Join-Path $ScriptDir "app.apk"
}
if (Test-Path $ApkPath) {
    Write-Host "[*] Найден локальный APK: $ApkPath`n" -ForegroundColor White
} else {
    $ApkPath = $null
}

$SeenDevices = [System.Collections.Generic.HashSet[string]]::new()
$NotifiedUnauthorized = [System.Collections.Generic.HashSet[string]]::new()

while ($true) {
    $status = Get-DevicesStatus

    # Предупреждение о неавторизованных устройствах
    foreach ($ser in $status.Unauthorized) {
        if (-not $NotifiedUnauthorized.Contains($ser)) {
            Write-Host "`n[!] ВНИМАНИЕ: Телефон $ser подключен, но НЕ АВТОРИЗОВАН!" -ForegroundColor Yellow
            Write-Host "    -> Разблокируйте экран телефона и нажмите 'Разрешить отладку с этого компьютера' (Всегда разрешать)." -ForegroundColor Yellow
            $NotifiedUnauthorized.Add($ser) | Out-Null
        }
    }

    # Предупреждение об ошибке прав
    foreach ($ser in $status.NoPermissions) {
        Write-Host "`n[!] ОШИБКА ДОСТУПА к устройству $ser (no permissions)!" -ForegroundColor Red
        Write-Host "    -> Проверьте драйверы устройства в Диспетчере устройств Windows." -ForegroundColor Red
    }

    # Очищаем статусы оповещения, если устройство отключили
    $allCurrent = $status.Authorized + $status.Unauthorized + $status.NoPermissions
    $NotifiedUnauthorized.RemoveWhere({ -not ($allCurrent -contains $_) }) | Out-Null

    # Настраиваем новые авторизованные устройства
    foreach ($ser in $status.Authorized) {
        if (-not $SeenDevices.Contains($ser)) {
            Provision-Device $ser $ApkPath
            $SeenDevices.Add($ser) | Out-Null
            $NotifiedUnauthorized.Remove($ser) | Out-Null
            Write-Host "Готово! Вы можете отключить этот телефон и подключить следующий...`n" -ForegroundColor Cyan
        }
    }

    if ($status.Authorized.Count -eq 0 -and $status.Unauthorized.Count -eq 0) {
        Write-Host -NoNewline "`r[...] Ожидаю подключения телефона по USB (с включенной отладкой по ADB)..."
    }

    Start-Sleep -Seconds 2
}
