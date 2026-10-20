# [Tech Note] Проблема подмены пуш-уведомлений на «Защита конфиденциальности» в Android 15/16: Root Cause, временный фикс и архитектурные решения для команды

**Кому:** Команде разработки приложения чтения SMS/Push (`com.gadgets.auto`)  
**Тема:** Цензурирование банковских пушей в Android 15 и 16 через `NotificationListenerService`  
**Критичность:** High (блокирует чтение сумм, балансов и OTP в финансовых пушах)

---

## 1. В чём проблема (Root Cause Analysis)

Начиная с **Android 15 (и далее в Android 16)**, Google внедрил механизм **Sensitive Notification Protection** (в кодовой базе AOSP регулируется системным флагом `redact_sensitive_notifications_from_untrusted_listeners`).

### Механика воспроизведения:
1. Банковские приложения (TBC Bank, Credo Bank, большинство европейских и СНГ банков) отправляют транзакционные уведомления со статусом `VISIBILITY_PRIVATE` (значение `0`), часто используя стиль `BigTextStyle`.
2. Системный UI (`SystemUI`) устройства считается доверенным, поэтому **в системной шторке пользователь видит полный оригинальный текст**.
3. Сторонние приложения, реализующие `NotificationListenerService`, по умолчанию классифицируются Android как **`untrusted listeners`**.
4. Системный сервис `NotificationManagerService` перед передачей `StatusBarNotification` в наш слушатель **принудительно перехватывает объект** и заменяет поля `android.title`, `android.text` и `android.bigText` на системную локализованную заглушку:
   * В русской локали: **`Защита конфиденциальности`**
   * В английской локали: **`Sensitive notification content hidden`**
5. В результате парсер получает пустую заглушку вместо реальных данных о транзакции.

*(Примечание: на Android 13 и 14 этой защиты ещё нет, проблема касается исключительно девайсов на Android 15+).*

---

## 2. Как мы решили проблему в инфраструктуре (Временный Workaround)

Защита завязана на системный AppOp: **`RECEIVE_SENSITIVE_NOTIFICATIONS`** (`OPSTR_RECEIVE_SENSITIVE_NOTIFICATIONS`).

Для всех рабочих устройств мы автоматизировали выдачу прав через ADB:

```bash
# 1. Снятие цензурирования пушей для конкретного пакета:
adb shell cmd appops set --user 0 com.gadgets.auto RECEIVE_SENSITIVE_NOTIFICATIONS allow

# 2. Активация слушателя уведомлений без ручного захода в меню настроек:
adb shell cmd notification allow_listener com.gadgets.auto/com.gadgets.auto.util.network.NotificationService 0

# 3. Исключение из Doze mode (чтобы фоновый процесс не убивался системой):
adb shell dumpsys deviceidle whitelist +com.gadgets.auto
```

После выполнения команды `appops set ... allow` система помечает наш `NotificationListenerService` как **доверенный (trusted)**, и Android начинает отдавать в `onNotificationPosted()` сырые, незацензурированные данные с реальными суммами и балансами.

---

## 3. Почему нельзя просто вызвать `requestPermissions()` в коде

В платформе Android у этого разрешения зашит следующий уровень защиты:
```xml
<permission android:name="android.permission.RECEIVE_SENSITIVE_NOTIFICATIONS" 
            android:protectionLevel="role|signature" />
```
Здесь **нет** уровня `runtime`.  
Если просто прописать его в `AndroidManifest.xml` и вызвать стандартный метод `ActivityCompat.requestPermissions()`, Android **не покажет системное диалоговое окно** и сразу вернёт отказ, так как сторонним приложениям запрещено запрашивать `role|signature` разрешения обычным путём.

---

## 4. Как команде разработки правильно решить проблему в самом приложении

Чтобы приложение могло работать автономно без обязательного подключения к ПК по проводу, есть три инженерных варианта:

### Вариант А: Запрос роли сопутствующего устройства (Companion Device Role) — Рекомендуется
Так как в уровне защиты указан флаг **`role`**, система обязана автоматически выдать это разрешение приложению, обладающему ролью компаньона (например, статус часов/аксессуара).

1. В `AndroidManifest.xml` объявляется фича компаньона:
   ```xml
   <uses-feature android:name="android.software.companion_device_setup" />
   <uses-permission android:name="android.permission.REQUEST_COMPANION_RUN_IN_BACKGROUND" />
   <uses-permission android:name="android.permission.REQUEST_COMPANION_USE_DATA_IN_BACKGROUND" />
   ```
2. В коде (например, в мастере первого запуска) вызывается системный `RoleManager`:
   ```kotlin
   val roleManager = getSystemService(RoleManager::class.java)
   if (roleManager.isRoleAvailable(RoleManager.ROLE_COMPANION_DEVICE_WATCH)) {
       val intent = roleManager.createRequestRoleIntent(RoleManager.ROLE_COMPANION_DEVICE_WATCH)
       startActivityForResult(intent, REQUEST_CODE_COMPANION)
   }
   ```
3. Пользователю отображается штатное системное окно: *«Разрешить приложению подключение в качестве сопутствующего устройства?»*.
4. **Результат:** При нажатии «Разрешить» ОС автоматически присваивает роль и **вместе с ней выдаёт `RECEIVE_SENSITIVE_NOTIFICATIONS` без какого-либо ADB**, а также защищает фоновый процесс от выгрузки из ОЗУ. Именно так работают сторонние клиенты носимых устройств на Android 15/16.

---

### Вариант Б: Подключение библиотеки Shizuku API (Для внутренних / Power-user утилит)
Если приложение является внутренним корпоративным инструментом, самый простой и гибкий путь — поддержать **Shizuku API**:
1. Подключается зависимость:
   ```groovy
   implementation 'rikka.shizuku:api:13.1.5'
   implementation 'rikka.shizuku:provider:13.1.5'
   ```
2. Если на устройстве запущен Shizuku (его можно активировать прямо с телефона через Wireless Debugging в пару тапов):
   ```kotlin
   if (Shizuku.pingBinder() && Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED) {
       // Выполняем системный вызов AppOps от имени Shell (UID 2000):
       val appOpsService = IAppOpsService.Stub.asInterface(
           ShizukuBinderWrapper(SystemServiceHelper.getSystemService("appops"))
       )
       appOpsService.setMode(
           AppOpsManager.strOpToOp("android:receive_sensitive_notifications"),
           android.os.Process.myUid(),
           packageName,
           AppOpsManager.MODE_ALLOWED
       )
   }
   ```
   Пользователь один раз жмёт «Разрешить» в UI Shizuku на экране телефона, и приложение само себе выставляет `allow`.

---

### Вариант В: Детектирование заглушки в коде парсера (UI / Fallback)
Как минимум, в логику парсера уведомлений необходимо добавить детектор:
```kotlin
val text = sbn.notification.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: ""
val isRedacted = text == "Защита конфиденциальности" || text == "Sensitive notification content hidden"

if (isRedacted) {
    Log.w("NotificationParser", "Обнаружено цензурирование Android 15/16 для пакета ${sbn.packageName}")
    // 1. Отправляем алерт на бэкенд о необходимости настройки устройства
    // 2. В UI приложения выводим плашку с подсказкой оператору:
    //    "На данном телефоне требуется выдать разрешение через ADB: 
    //     adb shell cmd appops set --user 0 com.gadgets.auto RECEIVE_SENSITIVE_NOTIFICATIONS allow"
}
```
