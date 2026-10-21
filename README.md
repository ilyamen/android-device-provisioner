# Android Device Provisioner: Настройка чтения банковских пушей и SMS

Автоматизированный скрипт и набор команд для быстрой настройки телефонов Android (включая Android 14, 15 и 16) для работы приложения-парсера **`com.gadgets.auto`**.

---

## 📚 Инструкции для сотрудников (в полях)

* 🖥️ **[Инструкция №1: Настройка через Windows ПК в 1 клик](INSTRUCTION_1_WINDOWS_PC.md)** — для сотрудников с ноутбуком (двойной клик по `run_windows.bat`, всё само скачивается и настраивается за 15 секунд).
* 📲 **[Инструкция №2: Настройка прямо с телефона БЕЗ компьютера](INSTRUCTION_2_PHONE_NO_PC.md)** — для сотрудников в полях без ПК (через Shizuku + Wi-Fi сопряжение).
* 🛠️ **[Tech Note для разработчиков приложения](TECH_NOTE_SENSITIVE_NOTIFICATIONS.md)** — подробный разбор Root Cause проблемы в Android 15/16 и архитектурные решения (Companion Role / Shizuku).

---

## 🎯 Контекст проблемы и решение

### Проблема: «Защита конфиденциальности» вместо текста пуша
Начиная с **Android 15 и 16**, Google внедрил механизм **Sensitive Notification Protection** (`redact_sensitive_notifications_from_untrusted_listeners`):
* Любые уведомления от банков (TBC Bank, Credo Bank и др.) с суммами, балансами и кодами подтверждения имеют статус `VISIBILITY_PRIVATE`.
* Сторонние слушатели уведомлений (`NotificationListenerService`) по умолчанию считаются **«untrusted listeners»**.
* При попытке прочитать уведомление система на лету заменяет текст пуша на заглушку: **«Защита конфиденциальности»** (в англ. локали — *«Sensitive notification content hidden»*).

### Решение
1. Выдать приложению специальный AppOp:
   ```bash
   adb shell cmd appops set --user 0 com.gadgets.auto RECEIVE_SENSITIVE_NOTIFICATIONS allow
   ```
2. Активировать системный слушатель уведомлений:
   ```bash
   adb shell cmd notification allow_listener com.gadgets.auto/com.gadgets.auto.util.network.NotificationService 0
   ```
3. Выдать полные runtime-разрешения (SMS, телефон, память, уведомления).
4. Исключить приложение из ограничений аккумулятора (Doze mode):
   ```bash
   adb shell dumpsys deviceidle whitelist +com.gadgets.auto
   ```

---

## 🚀 Быстрый старт

### Для Windows (в 1 клик, без зависимостей):
Просто запустите двойным кликом:
```cmd
run_windows.bat
```
*(Скрипт сам автоматически скачает ADB от Google, если его нет, и запустит нативный процесс настройки).*

### Для Linux / macOS:
```bash
# На Python:
python3 provision.py

# Или на Bash:
./provision.sh
```

---

## 📦 Содержимое репозитория

* **`run_windows.bat`** — запускатор для Windows в 1 клик (авто-скачивание ADB, запуск PowerShell).
* **`provision.ps1`** — нативный Windows PowerShell-скрипт авто-настройки с распознаванием авторизации.
* **`provision.py`** — кроссплатформенный Python-скрипт с циклом ожидания устройств.
* **`provision.sh`** — интерактивный bash-скрипт с цветным выводом статусов для Linux/macOS.
* **`HEAD_2026.10.08_release.apk`** — актуальная сборка приложения `com.gadgets.auto` (устанавливается автоматически, если отсутствует).
* **`INSTRUCTION_1_WINDOWS_PC.md`** — пошаговый мануал настройки через ПК со схемами экранов.
* **`INSTRUCTION_2_PHONE_NO_PC.md`** — пошаговый мануал настройки прямо с телефона через Shizuku.
* **`TECH_NOTE_SENSITIVE_NOTIFICATIONS.md`** — техническая записка для команды разработки приложения.
