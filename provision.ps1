# ============================================================
#   Android Auto-Provisioner for com.gadgets.auto (Windows PS)
#   Настройка чтения банковских пушей и SMS (Android 14-16)
# ============================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$PackageName = "com.gadgets.auto"
$NotificationService = "com.gadgets.auto/com.gadgets.auto.util.network.NotificationService"
$DefaultApk = "HEAD_2026.10.27_patched.apk"

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
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
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
    $proc.Arguments = "/s /c `"$cmd`""
    $proc.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $proc.StandardErrorEncoding = [System.Text.Encoding]::UTF8
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

function Get-TetherIp ($serial) {
    $res = Exec-Cmd "adb -s $serial shell `"ip -o -4 addr show`""
    $lines = $res.Stdout -split "`r?\n"
    foreach ($line in $lines) {
        if ($line -match "\s+(rndis|usb|eth)\w*\s+inet\s+([0-9\.]+)\/") {
            return $matches[2]
        }
    }
    return $null
}

function Apply-Device-Settings ($targetSerial) {
    $isBlocked = $false

    # 1. Выдаем RECEIVE_SENSITIVE_NOTIFICATIONS (защита Android 15/16)
    Write-Host "`n[1/5] Разблокировка чувствительных пуш-уведомлений (Android 15/16)..." -ForegroundColor Cyan
    $appopRes = Exec-Cmd "adb -s $targetSerial shell cmd appops set --user 0 $PackageName RECEIVE_SENSITIVE_NOTIFICATIONS allow"
    $appop = Exec-Cmd "adb -s $targetSerial shell cmd appops get --user 0 $PackageName RECEIVE_SENSITIVE_NOTIFICATIONS"
    if ($appop.Stdout -match "allow") {
        Write-Host "    [OK] RECEIVE_SENSITIVE_NOTIFICATIONS -> ALLOW" -ForegroundColor Green
    } else {
        Write-Host "    [i] Статус: $($appop.Stdout) (для Android 14 и старее это норма)" -ForegroundColor DarkGray
    }

    # 2. Активируем слушатель уведомлений
    Write-Host "`n[2/5] Активация системного сервиса чтения уведомлений..." -ForegroundColor Cyan
    Exec-Cmd "adb -s $targetSerial shell cmd notification allow_listener $NotificationService 0" | Out-Null
    $listeners = Exec-Cmd "adb -s $targetSerial shell settings get secure enabled_notification_listeners"
    if ($listeners.Stdout -match [regex]::Escape($PackageName)) {
        Write-Host "    [OK] NotificationListenerService включен в системе!" -ForegroundColor Green
    } else {
        $curr = if ($listeners.Stdout -ne "null") { $listeners.Stdout } else { "" }
        $newListeners = ($curr + ":" + $NotificationService).Trim(":")
        $setRes = Exec-Cmd "adb -s $targetSerial shell settings put secure enabled_notification_listeners `"$newListeners`""
        if ($setRes.Stderr -match "SecurityException|Permission denial") {
            $isBlocked = $true
        } else {
            Write-Host "    [OK] Прописан напрямую через settings secure." -ForegroundColor Green
        }
    }

    # 3. Выдаем runtime permissions
    Write-Host "`n[3/5] Выдача всех системных runtime-разрешений (SMS, телефон, память)..." -ForegroundColor Cyan
    $granted = 0
    $permDenied = $false
    foreach ($perm in $RuntimePermissions) {
        $res = Exec-Cmd "adb -s $targetSerial shell pm grant $PackageName $perm"
        if ($res.ExitCode -eq 0) {
            $granted++
        } elseif ($res.Stderr -match "SecurityException|Permission denial|not allowed to grant") {
            $permDenied = $true
        }
    }
    if ($granted -gt 0) {
        Write-Host "    [OK] Выдано $granted/$($RuntimePermissions.Count) разрешений." -ForegroundColor Green
    } else {
        $dump = Exec-Cmd "adb -s $targetSerial shell dumpsys package $PackageName"
        if ($dump.Stdout -match "android.permission.READ_SMS: granted=true") {
            Write-Host "    [OK] Все основные разрешения (SMS, память) уже активны!" -ForegroundColor Green
        } else {
            if ($permDenied) { $isBlocked = $true }
            Write-Host "    [!] Разрешения не применились по USB." -ForegroundColor Yellow
        }
    }

    # 4. Исключение из экономии батареи (Doze mode)
    Write-Host "`n[4/5] Исключение из энергосбережения батареи (фоновая работа)..." -ForegroundColor Cyan
    Exec-Cmd "adb -s $targetSerial shell dumpsys deviceidle whitelist +$PackageName" | Out-Null
    Write-Host "    [OK] Добавлен в deviceidle whitelist!" -ForegroundColor Green

    # 5. Фикс режима полёта (чтобы Wi-Fi не гас при отключении мобильной связи)
    Write-Host "`n[5/5] Защита от разлогина: настройка режима полёта (Wi-Fi не гаснет)..." -ForegroundColor Cyan
    $radRes = Exec-Cmd "adb -s $targetSerial shell settings put global airplane_mode_radios cell,bluetooth,nfc,wimax"
    Exec-Cmd "adb -s $targetSerial shell settings put global airplane_mode_toggleable_radios wifi,bluetooth" | Out-Null
    if ($radRes.Stderr -match "SecurityException|Permission denial") {
        $isBlocked = $true
        Write-Host "    [!] Запись global settings заблокирована системой." -ForegroundColor Yellow
    } else {
        $radCheck = Exec-Cmd "adb -s $targetSerial shell settings get global airplane_mode_radios"
        if ($radCheck.Stdout -and $radCheck.Stdout -notmatch "wifi") {
            Write-Host "    [OK] airplane_mode_radios -> Wi-Fi защищён от отключения в авиарежиме!" -ForegroundColor Green
        } else {
            $isBlocked = $true
            Write-Host "    [!] airplane_mode_radios не изменился (блокировка USB)." -ForegroundColor Yellow
        }
    }

    return @{
        IsBlocked = $isBlocked
        Granted = $granted
    }
}

function Provision-Device ($serial, $apkPath) {
    Write-Host "`n============================================================" -ForegroundColor Cyan
    Write-Host "[*] НАЧИНАЮ НАСТРОЙКУ УСТРОЙСТВА: $serial" -ForegroundColor Cyan
    
    $manuf = Get-DeviceProp $serial "ro.product.manufacturer"
    $model = Get-DeviceProp $serial "ro.product.model"
    $ver = Get-DeviceProp $serial "ro.build.version.release"
    Write-Host "[*] Модель: $manuf $model | Android $ver" -ForegroundColor White
    Write-Host "============================================================" -ForegroundColor Cyan

    # 1. Устанавливаем / обновляем приложение (с обработкой signature mismatch и Realme/ColorOS)
    if ($apkPath -and (Test-Path $apkPath)) {
        $checkApp = Exec-Cmd "adb -s $serial shell pm path $PackageName"
        if ($checkApp.Stdout -match "package:") {
            $dump0 = Exec-Cmd "adb -s $serial shell dumpsys package $PackageName"
            $curVer = if ($dump0.Stdout -match "versionName=([^\s]+)") { "v" + $matches[1] } else { "" }
            Write-Host "[*] Обновляю $PackageName (сейчас: $curVer)..." -ForegroundColor Cyan
        } else {
            Write-Host "[+] Устанавливаю $(Split-Path $apkPath -Leaf) ..." -ForegroundColor Cyan
        }

        # Отключаем package verifier (Realme/ColorOS блокирует сторонние APK)
        Exec-Cmd "adb -s $serial shell settings put global package_verifier_enable 0" | Out-Null
        Exec-Cmd "adb -s $serial shell settings put global verifier_verify_adb_installs 0" | Out-Null

        $inst = Exec-Cmd "adb -s $serial install -r -g `"$apkPath`""

        # Восстанавливаем verifier
        Exec-Cmd "adb -s $serial shell settings put global package_verifier_enable 1" | Out-Null
        Exec-Cmd "adb -s $serial shell settings put global verifier_verify_adb_installs 1" | Out-Null

        # Signature mismatch: удаляем старое и ставим заново
        if ($inst.Stdout -match "INSTALL_FAILED_UPDATE_INCOMPATIBLE" -or $inst.Stderr -match "INSTALL_FAILED_UPDATE_INCOMPATIBLE") {
            Write-Host "    [!] Конфликт подписей (signature mismatch) — удаляю старую версию..." -ForegroundColor Yellow
            Exec-Cmd "adb -s $serial shell pm uninstall --user 0 $PackageName" | Out-Null
            Start-Sleep -Seconds 1

            Exec-Cmd "adb -s $serial shell settings put global package_verifier_enable 0" | Out-Null
            Exec-Cmd "adb -s $serial shell settings put global verifier_verify_adb_installs 0" | Out-Null
            $inst = Exec-Cmd "adb -s $serial install -r -g `"$apkPath`""
            Exec-Cmd "adb -s $serial shell settings put global package_verifier_enable 1" | Out-Null
            Exec-Cmd "adb -s $serial shell settings put global verifier_verify_adb_installs 1" | Out-Null
        }

        if ($inst.Stdout -match "Success") {
            $dump2 = Exec-Cmd "adb -s $serial shell dumpsys package $PackageName"
            $newVer = if ($dump2.Stdout -match "versionName=([^\s]+)") { "v" + $matches[1] } else { "" }
            Write-Host "    [OK] Установлено $newVer!" -ForegroundColor Green
        } else {
            Write-Host "    [!] Ошибка установки: $($inst.Stdout) $($inst.Stderr)" -ForegroundColor Red
        }
    } else {
        $checkApp = Exec-Cmd "adb -s $serial shell pm path $PackageName"
        if ($checkApp.Stdout -match "package:") {
            $dump0 = Exec-Cmd "adb -s $serial shell dumpsys package $PackageName"
            $verName = if ($dump0.Stdout -match "versionName=([^\s]+)") { "v" + $matches[1] } else { "" }
            $verCode = if ($dump0.Stdout -match "versionCode=([0-9]+)") { "(код " + $matches[1] + ")" } else { "" }
            Write-Host "[OK] Приложение $PackageName установлено $verName $verCode." -ForegroundColor Green
        } else {
            Write-Host "    [!] APK-файл не найден рядом со скриптом." -ForegroundColor Red
        }
    }

    # 2. Применяем настройки по обычному USB
    $res = Apply-Device-Settings $serial

    # 3. Если сработала защита Xiaomi (Security Settings Block) - обходим через USB-модем
    if ($res.IsBlocked) {
        Write-Host "`n============================================================" -ForegroundColor Yellow
        Write-Host "[!] ВНИМАНИЕ: Сработала защита Xiaomi/HyperOS от изменений по USB." -ForegroundColor Yellow
        Write-Host "    Для завершения настройки включите режим «USB-модем»:" -ForegroundColor White
        Write-Host "    1. На телефоне смахните шторку уведомлений сверху вниз." -ForegroundColor Cyan
        Write-Host "    2. Нажмите на уведомление «Зарядка через USB» (Режим USB)." -ForegroundColor Cyan
        Write-Host "    3. Выберите пункт «USB-модем» (USB tethering)." -ForegroundColor Cyan
        Write-Host "============================================================" -ForegroundColor Yellow
        Write-Host "[*] Ожидаю включения USB-модема на телефоне (до 60 секунд)..." -ForegroundColor DarkGray

        $tetherIp = $null
        for ($wait = 0; $wait -lt 30; $wait++) {
            Start-Sleep -Seconds 2
            $currDevices = Get-DevicesStatus
            if ($currDevices.Authorized -contains $serial) {
                $tetherIp = Get-TetherIp $serial
                if ($tetherIp) { break }
            } else {
                foreach ($d in $currDevices.Authorized) {
                    $tetherIp = Get-TetherIp $d
                    if ($tetherIp) { $serial = $d; break }
                }
                if ($tetherIp) { break }
            }
        }

        if ($tetherIp) {
            Write-Host "`n[+] USB-модем активен! Прямой IP: $tetherIp" -ForegroundColor Green
            Write-Host "[*] Переключаю ADB на защищённый сетевой канал..." -ForegroundColor Cyan
            Exec-Cmd "adb -s $serial tcpip 5555" | Out-Null
            Start-Sleep -Seconds 2
            $tcpTarget = "$tetherIp:5555"
            $connRes = Exec-Cmd "adb connect $tcpTarget"
            if ($connRes.Stdout -match "connected") {
                Write-Host "[OK] Подключено к $tcpTarget! Повторно применяю настройки..." -ForegroundColor Green
                $null = Apply-Device-Settings $tcpTarget
                Exec-Cmd "adb disconnect $tcpTarget" | Out-Null
                Write-Host "[OK] Настройки успешно применены через канал USB-модема!" -ForegroundColor Green
            } else {
                Write-Host "[!] Не удалось подключиться к $tcpTarget: $($connRes.Stdout)" -ForegroundColor Red
            }
        } else {
            Write-Host "`n[!] Время ожидания USB-модема истекло." -ForegroundColor Yellow
            Write-Host "    Выдайте права вручную в настройках телефона или включите «Настройки безопасности» в меню разработчика." -ForegroundColor DarkGray
        }
    }

    Write-Host "`n============================================================" -ForegroundColor Green
    $msg = "[+++] УСТРОЙСТВО " + $serial + " (" + $manuf + " " + $model + ") ПОЛНОСТЬЮ НАСТРОЕНО!"
    Write-Host $msg -ForegroundColor Green
    Write-Host "[i] Для применения защиты от разлогина (сохранение Wi-Fi в авиарежиме)" -ForegroundColor Cyan
    Write-Host "    рекомендуется перезагрузить телефон [adb reboot]." -ForegroundColor Cyan
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

# Используем безопасные Hashtable вместо .NET generic HashSet
$SeenDevices = @{}
$NotifiedUnauthorized = @{}

while ($true) {
    $status = Get-DevicesStatus

    # Предупреждение о неавторизованных устройствах
    foreach ($ser in $status.Unauthorized) {
        if (-not $NotifiedUnauthorized.ContainsKey($ser)) {
            Write-Host "`n[!] ВНИМАНИЕ: Телефон $ser подключен, но НЕ АВТОРИЗОВАН!" -ForegroundColor Yellow
            Write-Host "    -> Разблокируйте экран телефона и подтвердите отладку (Всегда разрешать)." -ForegroundColor Yellow
            $NotifiedUnauthorized[$ser] = $true
        }
    }

    # Предупреждение об ошибке прав
    foreach ($ser in $status.NoPermissions) {
        Write-Host "`n[!] ОШИБКА ДОСТУПА к устройству $ser (no permissions)!" -ForegroundColor Red
        Write-Host "    -> Проверьте драйверы устройства в Диспетчере устройств Windows." -ForegroundColor Red
    }

    # Очищаем статусы оповещения для устройств, которые отключили
    $currentUnauth = @($status.Unauthorized)
    $keysToClear = @()
    foreach ($k in $NotifiedUnauthorized.Keys) {
        if ($currentUnauth -notcontains $k) {
            $keysToClear += $k
        }
    }
    foreach ($k in $keysToClear) {
        $NotifiedUnauthorized.Remove($k)
    }

    # Настраиваем новые авторизованные устройства
    foreach ($ser in $status.Authorized) {
        if (-not $SeenDevices.ContainsKey($ser)) {
            $null = Provision-Device $ser $ApkPath
            $SeenDevices[$ser] = $true
            if ($NotifiedUnauthorized.ContainsKey($ser)) {
                $NotifiedUnauthorized.Remove($ser)
            }
            Write-Host "Готово! Вы можете отключить этот телефон и подключить следующий...`n" -ForegroundColor Cyan
        }
    }

    if ($status.Authorized.Count -eq 0 -and $status.Unauthorized.Count -eq 0) {
        Write-Host -NoNewline "`r[...] Ожидаю подключения телефона по USB (с включенной отладкой по ADB)..."
    }

    Start-Sleep -Seconds 2
}
