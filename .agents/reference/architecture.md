# Architecture Overview

## Four-Layer Diagram

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Flutter UI Layer                                                        │
│  lib/app/  — widgets, layouts, conversation views, message rendering     │
├──────────────────────────────────────────────────────────────────────────┤
│  Flutter Service Layer                                                   │
│  lib/services/  — GetX services, sync, notifications, action handler    │
├──────────────────────────────────────────────────────────────────────────┤
│  Rust Backend (rustpush)                                                 │
│  rust/src/  — iMessage protocol, APS, iCloud, FaceTime, Keystore        │
├──────────────────────────────────────────────────────────────────────────┤
│  Android Native Layer (Kotlin)                                           │
│  android/  — APNService foreground service, WorkManager, notifications   │
└──────────────────────────────────────────────────────────────────────────┘
```

## Two Backend Modes

`usingRustPush` (declared in `lib/main.dart`) controls active backend:

```dart
var usingRustPush = true;   // set once at startup, never changes at runtime
```

| Mode | When Active | Backend Class | Description |
|------|-------------|---------------|-------------|
| **RustPush** | `usingRustPush == true` | `RustPushBackend` | Direct iMessage via Rust lib; no Mac server; implements `BackendService` interface |
| **BlueBubbles Server** | `usingRustPush == false` | `BackgroundService` | Relays through user-hosted Mac running BlueBubbles server; communicates via Socket.IO + REST |

`usingRustPush` hardcoded `true`. Server-relay path retained but not primary for OpenBubbles.

## Technology Stack

| Layer | Technology | Version / Notes |
|-------|-----------|-----------------|
| UI / App framework | Flutter + Dart | Null-safe Dart |
| State management | GetX | `get` package; services registered via `Get.put` |
| Local database | ObjectBox | `objectbox ^4.0.1`; embedded; up to 5 GB on mobile |
| Rust ↔ Dart FFI | flutter_rust_bridge | 2.3.0; generates `lib/src/rust/` |
| Rust ↔ Kotlin FFI | UniFFI | Generates Kotlin bindings in `android/`; active simultaneously with FRB |
| Rust async runtime | Tokio | v1; single worker thread named `tokio-rustpush` |
| iMessage protocol | rustpush | Git submodule at `rustpush/` |

## Global Singleton Shortcuts

Top-level getters used pervasively in Dart codebase. All GetX-registered singletons, retrieved lazily.

| Shortcut | Expands to | Type | Purpose |
|----------|-----------|------|---------|
| `ss` | `SettingsService` | `GetxService` | App settings, SharedPreferences, FCM data |
| `cs` | `ContactsService` | `GetxService` | Device address book integration |
| `chats` | `ChatsService` | `GetxService` | Reactive chat list; drives ConversationList |
| `cm` | `ChatManager` | `GetxService` | Tracks active chat; manages `ChatLifecycleManager` per open chat |
| `as` | `AttachmentsService` | `GetxService` | File save/download helpers |
| `ms(guid)` | `MessagesService` | `GetxService` | Per-chat message list; tagged by chat GUID |
| `cvc(chat)` | `ConversationViewController` | `GetxController` | Per-chat view state; tagged by chat GUID |
| `mwc(msg)` | `MessageWidgetController` | `StatefulController` | Per-message widget state; tagged by message GUID |
| `notif` | `NotificationsService` | `GetxService` | Creates Android/desktop notifications |
| `mcs` | `MethodChannelService` | `GetxService` | Dart → Kotlin MethodChannel bridge |
| `ls` | `LifecycleService` | `GetxService` | App foreground/background state |
| `ts` | `ThemesService` | `GetxService` | Theme management |
| `fs` | `FilesystemService` | `GetxService` | App document/support directories |
| `inq` | `IncomingQueue` | `GetxService` | Serial queue for inbound message processing |
| `http` | `HttpService` | `GetxService` | Dio HTTP client for BlueBubbles server |
| `socket` | `SocketService` | `GetxService` | Socket.IO client for BlueBubbles server |
| `backend` | `BackendService` | Interface | Current backend (`RustPushBackend` or `BackgroundService`) |

## Service Initialization Order

Enforced by `StartupTasks.initStartupServices()` in `lib/helpers/backend/startup_tasks.dart`. **Order matters** — later services may depend on earlier ones.

1. `RustLib.init()` — initializes flutter_rust_bridge
2. `fs.init()` — FilesystemService (app directories)
3. `Logger.init()` — logging
4. `ss.init()` — SettingsService (SharedPreferences loaded)
5. `Database.init()` — ObjectBox store opened, migrations run
6. `ss.getFcmData()` — loads FCM token from database into settings
7. `mcs.init()` — MethodChannelService (Android MethodChannel set up)
8. `ls.init()` — LifecycleService
9. `ts.init()` — ThemesService
10. `es.refreshCache()` — ExtensionService
11. `cs.init()` — ContactsService (non-web only)
12. `GlobalChatService` — instantiated (non-web only)
13. `notif.init()` — NotificationsService
14. `intents.init()` — IntentsService

After these return, `StartupTasks.onStartup()` runs async (non-blocking):
- `chats.init()` — ChatsService (mobile only, starts ObjectBox watcher)
- `ss.getServerDetails()` — server metadata
- `fcm.registerDevice()` — FCM registration

## Key Entry Points

| Function | File | Description |
|----------|------|-------------|
| `main()` | `lib/main.dart` | Primary Flutter entry point; calls `initApp(false, args)` |
| `bubble()` | `lib/main.dart` | Android chat bubbles entry point; calls `initApp(true, [])` with separate Flutter engine |
| `backgroundSyncIsolate()` | `lib/services/rustpush/rustpush_service.dart` | `@pragma('vm:entry-point')` function; runs CloudKit sync in `FlutterIsolate` on Android; sends status back to main isolate via `IsolateNameServer` |
| `backgroundIsolateEntrypoint()` | `lib/services/backend/java_dart_interop/background_isolate.dart` | Entry point for WorkManager background engine on Android |

## Dart Isolate Topology

```
Main Isolate (primary Flutter engine)
│
│  owns api.SharedPushState on desktop
│  doPoll() loop runs here on desktop
│
├── backgroundSyncIsolate (FlutterIsolate, Android only)
│     re-inits services, runs doCloudKitSyncPrivate()
│     sends status strings back via IsolateNameServer port
│
└── [APNService / Rust] (Android native, separate process not a Dart isolate)
      owns NativePushState + Tokio runtime
      forwards messages to main Dart engine via MethodChannel "APNMsg"
      or to DartWorker background engine when app is not alive
```

**Desktop:** main Dart isolate calls `api.SharedPushState.restore()` directly, owns Rust state. `doPoll()` loop (`while(true) await api.recvWait(...)`) runs on main isolate.

**Android:** `APNService` (foreground Kotlin service) owns `NativePushState`. Calls `start()`, `setupKeystore()`, `initNative()` via UniFFI. Main Dart isolate receives messages via MethodChannel.

## Directory Map

| Directory | Purpose |
|-----------|---------|
| `lib/app/` | All Flutter widgets and layouts (UI layer) |
| `lib/app/layouts/conversation_list/` | Chat list screens (Cupertino/Material/Samsung skins) |
| `lib/app/layouts/conversation_view/` | Message thread view and text input |
| `lib/app/wrappers/` | Shared widget wrappers including `stateful_boilerplate.dart` |
| `lib/services/` | All GetX services (service layer) |
| `lib/services/rustpush/` | `RustPushService` — central iMessage backend service |
| `lib/services/backend/` | ActionHandler, sync, notifications, settings, queue |
| `lib/services/ui/` | Chat/message/navigation UI services (ChatsService, MessagesService, etc.) |
| `lib/helpers/` | Utility functions; `startup_tasks.dart` lives here |
| `lib/database/` | ObjectBox `Database` class and model definitions |
| `lib/src/rust/` | flutter_rust_bridge auto-generated Dart bindings |
| `rust/src/` | Rust FFI layer |
| `rust/src/api/api.rs` | Main Rust API (~2800 lines) |
| `rust/src/api/mirrors.rs` | FFI mirror types (~1700 lines) |
| `rust/src/native.rs` | UniFFI/Kotlin bindings |
| `rust/src/keystore.rs` | Keystore abstraction (hardware + software) |
| `rustpush/` | Git submodule: iMessage/APS protocol implementation |
| `android/` | Kotlin native layer |
| `android/app/src/main/kotlin/com/bluebubbles/messaging/` | Kotlin entry points and services |
