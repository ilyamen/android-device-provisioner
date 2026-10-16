# Android Device Provisioner: Настройка чтения банковских пушей и SMS

Автоматизированный скрипт и набор команд для быстрой настройки телефонов Android (включая Android 14, 15 и 16) для работы приложения-парсера **`com.gadgets.auto`**.

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

## 🚀 Быстрый старт на ноутбуке

### Способ 1: Автоматический режим (Рекомендуется)
Скрипт работает в цикле: ждёт подключения телефона, настраивает его за 3 секунды, выводит отчёт и ждёт следующий телефон:

**На Python (Linux / macOS / Windows):**
```bash
python3 provision.py
```

**На Bash (Linux / macOS):**
```bash
./provision.sh
```

### Способ 2: Работа через ассистента Antigravity
Если ты открыл этот репозиторий в **Antigravity** на ноутбуке, тебе достаточно написать в чат:
> *«Я подключил очередной телефон, настрой его!»*

Ассистент прочитает этот файл, сразу поймёт весь контекст, запустит проверку через ADB и выдаст все нужные права подключенному устройству.

---

## 📦 Содержимое репозитория

* **`provision.py`** — кроссплатформенный скрипт авто-настройки с циклом ожидания устройств.
* **`provision.sh`** — интерактивный bash-скрипт с цветным выводом статусов.
* **`HEAD_2026.10.08_release.apk`** — актуальная сборка приложения `com.gadgets.auto` (если на телефоне приложение ещё не установлено, скрипт автоматически установит его).
* **`README.md`** — данная документация и база знаний.

---

## 🛠 Ручные команды для одного устройства (Cheat Sheet)

```bash
# 1. Установка APK со всеми разрешениями
adb install -r -g HEAD_2026.10.08_release.apk

# 2. Снятие цензуры чувствительных пушей (Android 15/16)
adb shell cmd appops set --user 0 com.gadgets.auto RECEIVE_SENSITIVE_NOTIFICATIONS allow

# 3. Активация чтения уведомлений
adb shell cmd notification allow_listener com.gadgets.auto/com.gadgets.auto.util.network.NotificationService 0

# 4. Исключение из энергосбережения
adb shell dumpsys deviceidle whitelist +com.gadgets.auto

# 5. Проверка статуса (должно быть: allow)
adb shell cmd appops get --user 0 com.gadgets.auto RECEIVE_SENSITIVE_NOTIFICATIONS
```
