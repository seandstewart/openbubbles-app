# Android Native Layer

## Package and Build Config

| Setting | Value |
|---------|-------|
| Package name | `com.openbubbles.messaging` (formerly `com.bluebubbles.messaging` — Kotlin code still uses `com.bluebubbles.messaging`) |
| `compileSdk` | 36 |
| `minSdk` | 24 (Android 7.0) |
| `targetSdk` | 36 |
| Java / Kotlin source compatibility | Java 21 |

Kotlin package path remains `com.bluebubbles.messaging.*` throughout source. Manifest application ID changed to `com.openbubbles.messaging` for publishing.

## Key Kotlin Files

### `MainActivity` (`FlutterFragmentActivity`)

**File:** `android/app/src/main/kotlin/com/bluebubbles/messaging/MainActivity.kt`

- Extends `FlutterFragmentActivity` — hosts primary Flutter engine
- `onCreate()`: immediately starts `APNService` as foreground service
- `configureFlutterEngine()`: stores engine reference in `companion object`; sets up `MethodChannel` handler; registers `KeyboardViewFactory` and `LiveExtensionFactory` platform views
- `onDestroy()`: sets `engine = null`; if `keepAppAlive == true` and activity destroyed by system (not graceful finish), broadcasts `"restartservice"` to `ForegroundServiceBroadcastReceiver` to restart `SocketIOForegroundService`
- Companion object `engine: FlutterEngine?` and `engine_ready: Boolean` checked by `APNService` and `DartWorker` to determine message routing

### `BubbleActivity`

**File:** `android/app/src/main/kotlin/com/bluebubbles/messaging/BubbleActivity.kt`

- Separate `FlutterActivity` subclass for Android chat bubbles
- Runs `bubble` Dart entry point (separate Flutter engine instance)
- Receives chat GUID from notification's `BubbleMetadata` intent

### `APNService`

**File:** `android/app/src/main/kotlin/com/bluebubbles/messaging/services/rustpush/APNService.kt`

Core Android background service for RustPush backend.

- Extends `Service`, implements `MsgReceiver` (UniFFI callback trait)
- Declared as foreground service with type `specialUse` in manifest
- Started from `MainActivity.onCreate()` and from `BootReceiver`

**Startup sequence** (`launchAgent()`):

1. `SMSObserver.init()` — registers SMS content observer
2. `start(filesDir, AndroidFilePackager, HandleWifiNetworksCallback)` — calls UniFFI `start()`; provides file packager for media metadata
3. `setupKeystore(filesDir, keystore)` — calls UniFFI `setupKeystore()` with `AndroidNativeKeystore`
4. `keystore.checkMaster()` — ensures master key exists in Android Keystore
5. `initNative(filesDir, null, this)` — calls UniFFI `initNative()`; `this` is `MsgReceiver` callback; `null` handle = fresh init (no existing state pointer)

After `nativeReady(state)` callback fires, `startLoop(this)` called on `NativePushState`.

**`MsgReceiver` implementation:**

```kotlin
override fun receievedMsg(ptr: ULong, retry: ULong) {
    Handler(Looper.getMainLooper()).post {
        if (MainActivity.engine != null) {
            // App is alive, deliver directly via MethodChannel
            MethodCallHandler.invokeMethod("APNMsg", mapOf(
                "pointer" to ptr.toString(),
                "retry" to retry.toString()
            ))
        } else {
            // App not alive, enqueue via WorkManager
            CoroutineScope(Dispatchers.Main).launch {
                DartWorker.callMethod(this@APNService, "APNMsg", mapOf(
                    "pointer" to ptr.toString(),
                    "retry" to retry.toString()
                ))
            }
        }
    }
}
```

- Posts to main looper so engine check is thread-safe
- `retry: ULong` passed through to Dart for prioritization

**`configured()`** — called from Dart via MethodChannel when Dart finishes init (`notify-native-configured`); triggers `pushState?.startLoop(this)` so Rust message loop begins.

### `DartWorker`

**File:** `android/app/src/main/kotlin/com/bluebubbles/messaging/services/backend_ui_interop/DartWorker.kt`

`ListenableWorker` (WorkManager) that runs Dart callbacks in background Flutter engine when main engine not alive.

**Engine lifecycle:**

```kotlin
companion object {
    var workerEngine: FlutterEngine? = null
    var engineReady = Mutex()
    var currentJobs = AtomicInteger(0)
    var currentCancelTask: TimerTask? = null
}
```

- `workerEngine` is static companion object field — **reused across multiple work items** to avoid cost of creating new engine per task
- Engine creation serialized via `engineReady` (`kotlinx.coroutines.sync.Mutex`)
- 30-second `Timer` destroys engine after all jobs complete; timer reset on each new job
- `currentJobs: AtomicInteger` tracks in-flight work items

**Known race condition:** Check `if (engine == null && workerEngine == null)` inside `engineReady.withLock { }` is correct, but `currentJobs.getAndIncrement()` happens **after** lock released and before `MethodChannel.invokeMethod` call completes. Rapid incoming messages can increment `currentJobs` without successful `invokeMethod`, causing cancel timer to never fire if engine destroyed mid-work.

### `DartWorkManager`

**File:** `android/app/src/main/kotlin/com/bluebubbles/messaging/services/backend_ui_interop/DartWorkManager.kt`

Creates `OneTimeWorkRequest` instances with `EXPEDITED` priority:

```kotlin
val request = OneTimeWorkRequestBuilder<DartWorker>()
    .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
    .setInputData(workDataOf("method" to method, "data" to gson.toJson(arguments)))
    .build()
WorkManager.getInstance(context).enqueue(request)
```

Expedited work requests run with higher OS priority. Falls back to non-expedited if app exceeded expedited work quota.

### `SocketIOForegroundService`

**File:** `android/app/src/main/kotlin/com/bluebubbles/messaging/services/foreground/SocketIOForegroundService.kt`

Used for BlueBubbles server mode keepalive. Not active in RustPush mode.

- Extends `Service`, foreground type `remoteMessaging`
- Reads server config from `FlutterSharedPreferences` on `onCreate()`
- Connects Socket.IO; on any incoming non-blacklisted event, calls `DartWorkManager.createWorker("socket-event", ...)`

**Security issue:**

```kotlin
val encodedPw = URLEncoder.encode(storedPassword, "UTF-8")
opts.query = "password=$encodedPw"
```

Password embedded in Socket.IO query string. Visible in Android logcat, proxy logs, and network traces.

**ANR risk:**

```kotlin
private fun tryReconnect() {
    if (mSocket != null && !mSocket!!.connected()) {
        Thread.sleep(30000)  // blocks the Service's thread
        mSocket!!.connect()
    }
}
```

`Thread.sleep(30000)` called on service thread. If on main thread (which `Service.onCreate()` executes on), triggers ANR (Application Not Responding) on Android.

### `MethodCallHandler`

**File:** `android/app/src/main/kotlin/com/bluebubbles/messaging/services/backend_ui_interop/MethodCallHandler.kt`

Dispatches 40+ method calls from Dart. Key companion object state:

```kotlin
companion object {
    var queueId = 0
    var queuedMessages = HashMap<Int, String>()  // no size cap
}
```

- `queuedMessages` stores SMS message payloads keyed by integer ID; used for SMS deduplication between `APNService` and `DartWorker`
- **No size cap** — if Dart never ACKs SMS messages, map grows unboundedly

`invokeMethod()` calls `MethodChannel.invokeMethod()` on `engine` without result callback for most calls — fire-and-forget. Called from `APNService.receievedMsg()`.

## Message Routing Path

```
Rust recv_wait()
    │
    ▼
NativePushState.start_loop() [Tokio thread]
    │
    ├── TwoFaAuthEvent → handler.twofa_event() [direct, no queue]
    │
    └── all other PushMessage
          │
          ├── insert into QUEUED_MESSAGES[key]
          ├── spawn retry task (30s × 5)
          └── handler.receievedMsg(key, 0) [UniFFI JNI callback]
                │
                └── APNService.receievedMsg() [posted to main looper]
                      │
                      ├── if MainActivity.engine != null:
                      │     MethodCallHandler.invokeMethod("APNMsg", {pointer, retry})
                      │         → Dart MethodChannel → pushService.recievedMsgPointer(key)
                      │             → api.ptrToDart(key) → removes from QUEUED_MESSAGES
                      │             → handleMsgInner(msg)
                      │
                      └── if engine == null:
                            DartWorker.callMethod("APNMsg", {pointer, retry})
                                → creates/reuses background FlutterEngine
                                → Dart backgroundIsolateEntrypoint
                                → pushService.recievedMsgPointer(key)
```

## Notification Pipeline

### `CreateIncomingMessageNotification`

**File:** `android/app/src/main/kotlin/com/bluebubbles/messaging/services/notifications/CreateIncomingMessageNotification.kt`

Called from Dart via MethodChannel with all notification parameters.

**Per-chat conversation channels:** Each chat gets own `NotificationChannel` on Android 11+ (`Build.VERSION_CODES.R`), channel ID `"com.bluebubbles.new_messages.$chatGuid"`. Enables per-conversation notification settings.

**MessagingStyle threading:** Extracts existing `MessagingStyle` from active notification (if present); appends new message, enabling multi-message threading in single notification.

**Actions:**

| Action | Implementation | Notes |
|--------|----------------|-------|
| Reply | `RemoteInput` → `InternalIntentReceiver` → `DartWorker` → `OutgoingQueue` | Inline reply |
| Mark Read | `InternalIntentReceiver` | Calls Dart to mark read |
| Delete | `InternalIntentReceiver` | Dismisses notification |

**Bubble support:** Creates `BubbleMetadata` pointing to `BubbleActivity` for Android chat bubbles.

**WearableExtender:** Adds mark-as-read and reply actions for Wear OS.

**Deduplication check:**

```kotlin
val notificationPostedAlready = notificationManager.activeNotifications
    .firstOrNull {
        it.notification.extras.getString("chatGuid") == chatGuid &&
        it.notification.extras.getString("messageGuid") == messageGuid
    } != null
if (notificationPostedAlready) return result.success(null)
```

Scans `activeNotifications` for matching `chatGuid + messageGuid` extras. Linear scan — acceptable for typical notification counts.

**Avatar byte flow:**

```dart
// Dart side
final bytes = contact.avatar;  // Uint8List
mcs.invokeMethod("create-incoming-message-notification", {
    "contact_avatar": bytes,
    ...
});
```

```kotlin
// Kotlin side
val contactIcon: ByteArray? = call.argument("contact_avatar")
val contactBitmap = Utils.getAdaptiveIconFromByteArray(contactIcon!!)
```

Avatar bytes decoded in Dart, passed through MethodChannel as `ByteArray`, decoded again to `Bitmap` in Kotlin. Both representations exist in memory simultaneously during call.

## Broadcast Receivers

| Receiver | Exported | Permission | Purpose |
|----------|----------|-----------|---------|
| `BootReceiver` | Yes | `RECEIVE_BOOT_COMPLETED` | Starts `APNService` on device boot |
| `AutoStartReceiver` | Yes | varies by OEM | Starts `SocketIOForegroundService` on OEM autostart |
| `ForegroundServiceBroadcastReceiver` | Yes | **none** | Restarts `SocketIOForegroundService`; **exported with no permission — any app can trigger restart** |
| `InternalIntentReceiver` | No | internal | Handles notification action intents (reply, mark read, delete) |
| `UnifiedPushReceiver` | Yes | UnifiedPush permission | Receives push notifications from UnifiedPush distributors |
| `SMSReceiver` | Yes | SMS permissions, priority 1000 | Intercepts incoming SMS before default handler |
| `PDUReceiver` | Yes | SMS permissions | Receives SMS PDU data |

**Security issue:** `ForegroundServiceBroadcastReceiver` is `android:exported="true"` with no `android:permission`. Any app on device can send `"restartservice"` to trigger foreground service restart.

## Notification Channels

| Channel ID | Name | Importance | Purpose |
|-----------|------|-----------|---------|
| `com.bluebubbles.new_messages` | New Messages | HIGH | Parent channel for conversation-specific channels |
| `com.bluebubbles.errors` | Errors | DEFAULT | Error notifications (registration failure, etc.) |
| `com.bluebubbles.sharedstreams` | Shared Streams | LOW | Shared album updates |
| `com.bluebubbles.sharedbeacons` | Find My | DEFAULT | AirTag / Find My beacon shares |
| `com.bluebubbles.reminders` | Reminders | DEFAULT | Reminder notifications |
| `com.bluebubbles.incoming_facetimes` | FaceTime | HIGH | Incoming FaceTime calls |
| `com.bluebubbles.foreground_service` | Foreground Service | MIN | APNService persistent notification |
| `com.bluebubbles.auth_codes` | Auth Codes | HIGH | 2FA code notifications |
| `com.bluebubbles.sync_status` | Sync Status | LOW | CloudKit sync progress |

## `AndroidNativeKeystore`

**File:** `android/app/src/main/kotlin/com/bluebubbles/messaging/services/rustpush/AndroidNativeKeystore.kt`  
(referenced as `val keystore = AndroidNativeKeystore(this)` in `APNService`)

Implements UniFFI `NativeKeystore` trait to bridge Rust keystore abstraction to Android Keystore system (via JNI).

Operations bridge:
- `createKey()` → `KeyPairGenerator` / `KeyGenerator` with `KeyGenParameterSpec`
- `sign()`, `verify()` → `Signature`
- `encrypt()`, `decrypt()` → `Cipher` with AES-GCM or RSA
- `importKey()` → key wrapping via `KeyProtection`/OAEP for secure import into hardware-backed store

## Security Issues Summary

| Issue | Location | Severity |
|-------|----------|---------|
| Password in Socket.IO query string | `SocketIOForegroundService.kt` | High — visible in logs and network traces |
| `ForegroundServiceBroadcastReceiver` exported with no permission | `AndroidManifest.xml` | Medium — any app can restart foreground service |
| `android:usesCleartextTraffic="true"` | `AndroidManifest.xml` | Medium — allows HTTP traffic to BB server |
| Desktop keystore uses hardcoded AES key | `rust/src/api/api.rs` L575 | Medium — identity not hardware-protected on desktop |
