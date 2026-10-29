#!/usr/bin/env bash
set -e

# ANSI colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

PACKAGE_NAME="com.gadgets.auto"
NOTIFICATION_SERVICE="com.gadgets.auto/com.gadgets.auto.util.network.NotificationService"
APK_FILE="HEAD_2026.10.27_patched.apk"

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}      Android Auto-Provisioner for ${PACKAGE_NAME}          ${NC}"
echo -e "${BLUE}============================================================${NC}"

# Ensure ADB is available
if ! command -v adb &> /dev/null; then
    echo -e "${RED}[!] ADB не найден в PATH. Убедитесь, что Android platform-tools установлены.${NC}"
    exit 1
fi

echo -e "${YELLOW}[*] Ожидаю подключения телефона по USB (с включенной отладкой)...${NC}"
adb wait-for-device

DEVICE_MODEL=$(adb shell getprop ro.product.model 2>/dev/null || echo "Unknown")
DEVICE_MANUF=$(adb shell getprop ro.product.manufacturer 2>/dev/null || echo "Unknown")
ANDROID_VER=$(adb shell getprop ro.build.version.release 2>/dev/null || echo "Unknown")
SERIAL=$(adb get-serialno)

echo -e "${GREEN}[+] Устройство подключено: ${DEVICE_MANUF} ${DEVICE_MODEL} (Android ${ANDROID_VER}, S/N: ${SERIAL})${NC}"

# Вспомогательная функция установки с verifier-bypass.
# set -e активен, поэтому явно захватываем код выхода через || true.
_do_install_sh() {
    local target_apk="$1"
    adb shell settings put global package_verifier_enable 0 2>/dev/null || true
    adb shell settings put global verifier_verify_adb_installs 0 2>/dev/null || true
    # || true обязателен: без него set -e прерывает скрипт при ненулевом exit-коде adb install,
    # и INST_OUT никогда не попадёт в блок проверки INSTALL_FAILED_*.
    INST_OUT=$(adb install -r -g "${target_apk}" 2>&1) || true
    adb shell settings put global package_verifier_enable 1 2>/dev/null || true
    adb shell settings put global verifier_verify_adb_installs 1 2>/dev/null || true
}

# 1. Install / update APK (с обработкой signature mismatch и Realme/ColorOS verifier)
if [ -f "${APK_FILE}" ]; then
    # Сначала проверяем наличие пакета, потом запрашиваем версию (избегаем лишнего adb-вызова)
    if adb shell pm path "${PACKAGE_NAME}" 2>/dev/null | grep -q "package:"; then
        INSTALLED_VER=$(adb shell dumpsys package "${PACKAGE_NAME}" 2>/dev/null | grep "versionName=" | head -1 | sed 's/.*versionName=\([^ ]*\).*/\1/')
        echo -e "${YELLOW}[*] Обновляю ${PACKAGE_NAME} (сейчас: ${INSTALLED_VER})...${NC}"
    else
        echo -e "${YELLOW}[*] Устанавливаю ${APK_FILE}...${NC}"
    fi

    _do_install_sh "${APK_FILE}"

    if echo "${INST_OUT}" | grep -q "INSTALL_FAILED_UPDATE_INCOMPATIBLE"; then
        echo -e "${YELLOW}    [!] Конфликт подписей (signature mismatch) — удаляю старую версию...${NC}"
        adb shell pm uninstall --user 0 "${PACKAGE_NAME}" 2>/dev/null || true
        sleep 1
        _do_install_sh "${APK_FILE}"
    fi

    if echo "${INST_OUT}" | grep -q "Success"; then
        NEW_VER=$(adb shell dumpsys package "${PACKAGE_NAME}" 2>/dev/null | grep "versionName=" | head -1 | sed 's/.*versionName=\([^ ]*\).*/\1/')
        echo -e "${GREEN}    [OK] Установлено v${NEW_VER}.${NC}"
    else
        echo -e "${RED}    [!] Ошибка установки: ${INST_OUT}${NC}"
        echo -e "${RED}    [!] Настройка прервана — приложение не установлено.${NC}"
        exit 1
    fi
else
    if adb shell pm path "${PACKAGE_NAME}" 2>/dev/null | grep -q "package:"; then
        echo -e "${GREEN}[OK] Приложение ${PACKAGE_NAME} уже установлено.${NC}"
    else
        echo -e "${RED}[!] Файл ${APK_FILE} не найден, и приложение не установлено на телефоне.${NC}"
        echo -e "${RED}    Настройка прервана — раздавать права нечему.${NC}"
        exit 1
    fi
fi

# 2. Grant RECEIVE_SENSITIVE_NOTIFICATIONS
echo -e "${BLUE}[1/4] Разблокировка чувствительных пушей (Android 15/16)...${NC}"
# || true обязателен: на Android 14 RECEIVE_SENSITIVE_NOTIFICATIONS неизвестен,
# appops возвращает ненулевой код, set -e прерывает скрипт без него.
adb shell cmd appops set --user 0 "${PACKAGE_NAME}" RECEIVE_SENSITIVE_NOTIFICATIONS allow || true
# || echo: GET тоже может вернуть ненулевой код на Android 14 (неизвестная операция)
STATUS=$(adb shell cmd appops get --user 0 "${PACKAGE_NAME}" RECEIVE_SENSITIVE_NOTIFICATIONS || echo "unknown (Android 14)")
echo -e "${GREEN}    [OK] Статус: ${STATUS}${NC}"

# 3. Allow NotificationListenerService
echo -e "${BLUE}[2/4] Активация службы чтения уведомлений...${NC}"
adb shell cmd notification allow_listener "${NOTIFICATION_SERVICE}" 0 || true
CURRENT_LISTENERS=$(adb shell settings get secure enabled_notification_listeners || echo "")
if [[ "${CURRENT_LISTENERS}" != *"${PACKAGE_NAME}"* ]]; then
    # "null" — буквальный string который возвращает Android settings provider для незаданного ключа
    [[ "${CURRENT_LISTENERS}" == "null" ]] && CURRENT_LISTENERS=""
    # Убираем ведущее ":" если CURRENT_LISTENERS пустой (первая установка)
    NEW_LISTENERS="${CURRENT_LISTENERS:+${CURRENT_LISTENERS}:}${NOTIFICATION_SERVICE}"
    adb shell settings put secure enabled_notification_listeners "${NEW_LISTENERS}"
fi
echo -e "${GREEN}    [OK] Notification Listener активирован.${NC}"

# 4. Grant runtime permissions
echo -e "${BLUE}[3/4] Выдача всех необходимых разрешений (SMS, память, телефон)...${NC}"
PERMS=(
    "android.permission.READ_SMS"
    "android.permission.RECEIVE_SMS"
    "android.permission.SEND_SMS"
    "android.permission.POST_NOTIFICATIONS"
    "android.permission.READ_PHONE_STATE"
    "android.permission.READ_PHONE_NUMBERS"
    "android.permission.ACCESS_FINE_LOCATION"
    "android.permission.ACCESS_COARSE_LOCATION"
    "android.permission.READ_EXTERNAL_STORAGE"
    "android.permission.WRITE_EXTERNAL_STORAGE"
    "android.permission.CAMERA"
    "android.permission.RECEIVE_MMS"
    "android.permission.READ_MEDIA_IMAGES"
    "android.permission.READ_MEDIA_VIDEO"
    "android.permission.READ_MEDIA_AUDIO"
    "android.permission.READ_MEDIA_VISUAL_USER_SELECTED"
)

for perm in "${PERMS[@]}"; do
    adb shell pm grant "${PACKAGE_NAME}" "${perm}" 2>/dev/null || true
done
echo -e "${GREEN}    [OK] Разрешения успешно выданы.${NC}"

# 5. Whitelist battery optimization
echo -e "${BLUE}[4/5] Исключение из энергосбережения батареи (фоновая работа)...${NC}"
adb shell dumpsys deviceidle whitelist +"${PACKAGE_NAME}" >/dev/null 2>&1 || true
echo -e "${GREEN}    [OK] Добавлено в белый список энергосбережения.${NC}"

# 6. Airplane mode Wi-Fi protection
echo -e "${BLUE}[5/5] Защита от разлогина: настройка режима полёта (Wi-Fi не гаснет)...${NC}"
SET_OUT=$(adb shell settings put global airplane_mode_radios cell,bluetooth,nfc,wimax 2>&1 || true)
adb shell settings put global airplane_mode_toggleable_radios wifi,bluetooth >/dev/null 2>&1 || true
CHECK_RAD=$(adb shell settings get global airplane_mode_radios 2>/dev/null || echo "")

if [[ "${SET_OUT}" == *"SecurityException"* ]] || [[ "${SET_OUT}" == *"Permission denial"* ]] || [[ "${CHECK_RAD}" == *"wifi"* ]]; then
    echo -e "\n${YELLOW}============================================================${NC}"
    echo -e "${YELLOW}[!] ВНИМАНИЕ: Сработала защита Xiaomi/HyperOS от изменений по USB.${NC}"
    echo -e "    Для завершения настройки включите режим «USB-модем»:"
    echo -e "    1. На телефоне смахните шторку уведомлений сверху вниз."
    echo -e "    2. Нажмите на уведомление «Зарядка через USB» (Режим USB)."
    echo -e "    3. Выберите пункт «USB-модем» (USB tethering)."
    echo -e "${YELLOW}============================================================${NC}"
    echo -e "[*] Ожидаю включения USB-модема на телефоне (до 60 секунд)..."

    TETHER_IP=""
    for i in {1..30}; do
        sleep 2
        IP_LINE=$(adb shell "ip -o -4 addr show" 2>/dev/null | grep -E "rndis|usb|eth" | head -n1 || true)
        if [[ -n "${IP_LINE}" ]]; then
            TETHER_IP=$(echo "${IP_LINE}" | awk '{print $4}' | cut -d/ -f1)
            break
        fi
    done

    if [[ -n "${TETHER_IP}" ]]; then
        echo -e "${GREEN}[+] USB-модем активен! Прямой IP: ${TETHER_IP}${NC}"
        echo -e "${BLUE}[*] Переключаю ADB на защищённый сетевой канал...${NC}"
        adb tcpip 5555 >/dev/null 2>&1 || true
        sleep 2
        TCP_TARGET="${TETHER_IP}:5555"
        if adb connect "${TCP_TARGET}" | grep -q "connected"; then
            echo -e "${GREEN}[OK] Подключено к ${TCP_TARGET}! Повторно применяю настройки...${NC}"
            adb -s "${TCP_TARGET}" shell cmd appops set --user 0 "${PACKAGE_NAME}" RECEIVE_SENSITIVE_NOTIFICATIONS allow >/dev/null 2>&1 || true
            adb -s "${TCP_TARGET}" shell cmd notification allow_listener "${NOTIFICATION_SERVICE}" 0 >/dev/null 2>&1 || true
            # Полная проверка listener — как в основном пути (allow_listener может не сработать на некоторых ROM)
            _TCP_LISTENERS=$(adb -s "${TCP_TARGET}" shell settings get secure enabled_notification_listeners 2>/dev/null || echo "")
            if [[ "${_TCP_LISTENERS}" != *"${PACKAGE_NAME}"* ]]; then
                [[ "${_TCP_LISTENERS}" == "null" ]] && _TCP_LISTENERS=""
                _TCP_NEW="${_TCP_LISTENERS:+${_TCP_LISTENERS}:}${NOTIFICATION_SERVICE}"
                adb -s "${TCP_TARGET}" shell settings put secure enabled_notification_listeners "${_TCP_NEW}" >/dev/null 2>&1 || true
            fi
            for perm in "${PERMS[@]}"; do
                adb -s "${TCP_TARGET}" shell pm grant "${PACKAGE_NAME}" "${perm}" >/dev/null 2>&1 || true
            done
            adb -s "${TCP_TARGET}" shell dumpsys deviceidle whitelist +"${PACKAGE_NAME}" >/dev/null 2>&1 || true
            adb -s "${TCP_TARGET}" shell settings put global airplane_mode_radios cell,bluetooth,nfc,wimax >/dev/null 2>&1 || true
            adb -s "${TCP_TARGET}" shell settings put global airplane_mode_toggleable_radios wifi,bluetooth >/dev/null 2>&1 || true
            adb disconnect "${TCP_TARGET}" >/dev/null 2>&1 || true
            echo -e "${GREEN}[OK] Настройки успешно применены через канал USB-модема!${NC}"
        fi
    else
        echo -e "${YELLOW}[!] Время ожидания USB-модема истекло. Завершите настройку вручную.${NC}"
    fi
else
    echo -e "${GREEN}    [OK] airplane_mode_radios -> Wi-Fi защищён от отключения в авиарежиме!${NC}"
fi

echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}[+++] ТЕЛЕФОН ПОЛНОСТЬЮ НАСТРОЕН И ГОТОВ К РАБОТЕ!          ${NC}"
echo -e "${BLUE}[i] Для применения защиты от разлогина (сохранение Wi-Fi в авиарежиме)${NC}"
echo -e "${BLUE}    рекомендуется перезагрузить телефон: adb reboot${NC}"
echo -e "${GREEN}============================================================${NC}\n"
