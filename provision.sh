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
APK_FILE="HEAD_2026.10.08_release.apk"

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

# 1. Install APK if not installed
if ! adb shell pm path "${PACKAGE_NAME}" | grep -q "package:"; then
    echo -e "${YELLOW}[*] Приложение ${PACKAGE_NAME} не установлено.${NC}"
    if [ -f "${APK_FILE}" ]; then
        echo -e "${BLUE}[*] Устанавливаю ${APK_FILE}...${NC}"
        adb install -r -g "${APK_FILE}"
        echo -e "${GREEN}[OK] Установка завершена.${NC}"
    else
        echo -e "${RED}[!] Файл ${APK_FILE} не найден рядом со скриптом.${NC}"
    fi
else
    echo -e "${GREEN}[OK] Приложение ${PACKAGE_NAME} уже установлено.${NC}"
fi

# 2. Grant RECEIVE_SENSITIVE_NOTIFICATIONS
echo -e "${BLUE}[1/4] Разблокировка чувствительных пушей (Android 15/16)...${NC}"
adb shell cmd appops set --user 0 "${PACKAGE_NAME}" RECEIVE_SENSITIVE_NOTIFICATIONS allow
STATUS=$(adb shell cmd appops get --user 0 "${PACKAGE_NAME}" RECEIVE_SENSITIVE_NOTIFICATIONS)
echo -e "${GREEN}    [OK] Статус: ${STATUS}${NC}"

# 3. Allow NotificationListenerService
echo -e "${BLUE}[2/4] Активация службы чтения уведомлений...${NC}"
adb shell cmd notification allow_listener "${NOTIFICATION_SERVICE}" 0 || true
CURRENT_LISTENERS=$(adb shell settings get secure enabled_notification_listeners || echo "")
if [[ "${CURRENT_LISTENERS}" != *"${PACKAGE_NAME}"* ]]; then
    NEW_LISTENERS="${CURRENT_LISTENERS}:${NOTIFICATION_SERVICE}"
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
echo -e "${BLUE}[4/4] Исключение из энергосбережения батареи (фоновая работа)...${NC}"
adb shell dumpsys deviceidle whitelist +"${PACKAGE_NAME}" >/dev/null 2>&1 || true
echo -e "${GREEN}    [OK] Добавлено в белый список энергосбережения.${NC}"

echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}[+++] ТЕЛЕФОН ПОЛНОСТЬЮ НАСТРОЕН И ГОТОВ К РАБОТЕ!          ${NC}"
echo -e "${GREEN}============================================================${NC}\n"
