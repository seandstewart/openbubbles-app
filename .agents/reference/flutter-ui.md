# Flutter UI Layer

## Three UI Skins

App ships three visual "skins" selected at runtime via `ThemeSwitcher` wrapper widget. Each skin has separate implementations for each major layout:

| Skin | Description |
|------|-------------|
| **Cupertino** | iOS-style design; bubbles, fonts, animations matching Messages.app |
| **Material** | Android Material Design styling |
| **Samsung** | Samsung One UI-inspired design |

`ThemeSwitcher` wraps each major layout and selects among three skin implementations based on `ss.settings.skin` at build time. Switching skins triggers full widget tree rebuild.

## Tablet Mode

On iPad and large-screen Android, app uses split-pane layout with two nested GetX Navigators:

- `nestedKey(1)` — left pane (conversation list)
- `nestedKey(2)` — right pane (conversation view)

Navigation to conversation pushes into `nestedKey(2)` without replacing left pane. Navigator keys are global `GlobalKey<NavigatorState>` instances used throughout codebase for targeted navigation.

## Widget Tree

### Conversation List

```
ConversationList (StatefulWidget)
└── ThemeSwitcher
    └── [CupertinoConversationList | MaterialConversationList | SamsungConversationList]
        └── ListView / SliverList
            └── ConversationTile (CustomStateful<ConversationTileController>)
```

`ConversationTile` uses `CustomStateful<ConversationTileController>` so individual tiles can be surgically updated (e.g., badge count, last message preview) without rebuilding whole list.

### Conversation View

```
ConversationView (OptimizedState)
└── Obx(() => Theme(...))           // reactive theme wrapping
    └── Scaffold
        └── GradientBackground
            └── Stack
                ├── ImagePoster         // full-screen contact poster background
                ├── ScreenEffectsWidget // iMessage screen effects (fireworks, etc.)
                └── Column
                    ├── MessagesView (SliverAnimatedList, reverse: true)
                    │   └── MessageHolder (CustomStateful<MessageWidgetController>)
                    │       └── [per-part widgets — see below]
                    └── ConversationTextField
```

`ConversationView` extends `OptimizedState` (not `CustomStateful`) — no controller-driven surgical updates needed; entire view reacts via `Obx`.

### `MessageHolder` Sub-Widget Structure

Each `MessageHolder` renders one message. `CustomStateful<MessageWidgetController>`; builds column of optional sub-widgets depending on message content and position:

| Sub-widget | When rendered |
|-----------|---------------|
| `TimestampSeparator` | Time gap before this message |
| `MessageSender` | Group chats — sender name + avatar above bubble |
| `SelectCheckbox` | Multi-select mode |
| `SlideToReply` | Swipe-to-reply gesture wrapper |
| `ReplyBubble` | Message has thread originator |
| `TextBubble` | Text content |
| `AttachmentHolder` | Images, videos, files |
| `InteractiveHolder` | App balloon / extension payload |
| `StickerHolder` | Sticker overlay |
| `ReactionHolder` | Tapback reactions row |
| `BubbleEffects` | iMessage bubble effects (slam, loud, gentle, etc.) |
| `DeliveredIndicator` | "Delivered" / "Read" status |
| `ContactAvatarWidget` | Contact avatar beside incoming bubbles |

## Custom Widget Update System (`stateful_boilerplate.dart`)

Standard Flutter `setState()` rebuilds entire subtree. Custom update system lets controller push **targeted update to specific widget type** without rebuilding whole tree.

**Core types:**

```dart
// Base controller
class StatefulController extends GetxController {
    final Map<Object, List<Function>> updateWidgetFunctions = {};

    void updateWidgets<T>(Object? arg) {
        updateWidgetFunctions[T]?.forEach((e) => e.call(arg));
    }
}

// Widget base
abstract class CustomStateful<T extends StatefulController> extends StatefulWidget {
    final T parentController;
}

// State base
abstract class CustomState<T extends CustomStateful, R, S extends StatefulController>
    extends State<T> {
    void updateWidget(R newVal) { setState(() {}); }
}
```

**How it works:**

1. In `initState()`, each `CustomState` registers its `updateWidget` function into `parentController.updateWidgetFunctions[T]`
2. Controller calls `updateWidgets<SomeWidgetType>(payload)` → invokes `updateWidget(payload)` on all live instances of `SomeWidgetType` sharing that controller
3. Avoids calling `setState` on parent and rebuilding entire subtree

**Example usage:**

```dart
// From MessageWidgetController
mwc(message).updateWidgets<ReactionHolder>(null);
// Only ReactionHolder instances for this message rebuild
```

System also gates rebuilds on animation completion (`animCompleted` future) and defers rebuilds arriving during active frame rendering to `SchedulerBinding.endOfFrame`.

## GetX Per-Chat Scoped Controllers

Controllers **tagged by GUID** — each chat/message gets independent instance:

```dart
MessagesService ms(String guid) =>
    Get.isRegistered<MessagesService>(tag: guid)
        ? Get.find<MessagesService>(tag: guid)
        : Get.put(MessagesService(), tag: guid);

ConversationViewController cvc(Chat chat) =>
    Get.isRegistered<ConversationViewController>(tag: chat.guid)
        ? Get.find<ConversationViewController>(tag: chat.guid)
        : Get.put(ConversationViewController(chat), tag: chat.guid);

MessageWidgetController mwc(Message message) =>
    Get.isRegistered<MessageWidgetController>(tag: message.guid!)
        ? Get.find<MessageWidgetController>(tag: message.guid!)
        : Get.put(MessageWidgetController(message), tag: message.guid!);
```

- `ms(guid)` — `MessagesService` tagged by chat GUID; created lazily when chat opened
- `cvc(chat)` — `ConversationViewController` tagged by chat GUID; one per open conversation
- `mwc(message)` — `MessageWidgetController` tagged by message GUID; one per visible message bubble

Controllers **not automatically deleted** when chat closed unless `Get.delete<T>(tag: guid)` called. `CustomState.dispose()` calls `Get.delete<S>(tag: _tag)` by default when `_forceDelete == true`.

## `ConversationViewController` State

Each open conversation's `ConversationViewController` carries large in-memory state:

| Field | Type | Notes |
|-------|------|-------|
| `imageData` | `Map<String, Uint8List>` | Decoded image cache; **no eviction policy** |
| `videoPlayers` | `Map<String, VideoPlayerController>` | Active video player instances |
| `audioPlayers` | `Map<String, AudioPlayer>` | Active audio player instances (mobile) |
| `audioPlayersDesktop` | `Map<String, AudioPlayer>` | Active audio player instances (desktop) |
| `mlKitParsedText` | `Map<String, List<EntityAnnotation>>` | ML Kit entity extraction results; cached per message |
| `stickerData` | `Map<String, ...>` | Decoded sticker data |
| `legacyUrlPreviews` | `Map<String, ...>` | Legacy URL preview data |
| `images` | `Map<String, ui.Image>` | Decoded `dart:ui` images |

`imageData` map has no size cap or LRU eviction. Conversations with many images cause significant memory pressure. Memory reclaimed only when `ConversationViewController` disposed (chat closed, GetX controller deleted).

## `MessagesService`

**File:** `lib/services/ui/message/messages_service.dart`

| Field | Type | Notes |
|-------|------|-------|
| `_messages` | `List<Message>` | Sorted on every insert/update event |
| `cachedBubbleSizes` | `static Map<String, Size>` | Static map — never evicted across chat navigations |
| `imageCacheQueue` | serial queue | Processes image decoding one at a time to avoid memory spikes |

`cachedBubbleSizes` is `static` — shared across **all** `MessagesService` instances for all chats. Cache grows for process lifetime with no eviction.

## Event Bus

**File:** `lib/services/backend_ui_interop/event_dispatcher.dart`

```dart
StreamController<Tuple2<String, dynamic>> eventDispatcher;
```

Events are `Tuple2<String, dynamic>` — string event name + optional payload. Every `MessageHolder` subscribes in `initState()`.

**Known events:**

| Event Name | Payload | Triggered by |
|-----------|---------|-------------|
| `update-contacts` | null | ContactsService refresh |
| `update-highlight` | message GUID | Search result highlighting |
| `refresh-messagebloc` | null | Force full message list reload |
| `add-custom-smartreply` | reply text | Smart reply chip injection |
| `refresh-avatar` | handle address | Avatar update |

**Known issue:** `MessageHolder` subscribes to event bus in `initState()` but subscriptions **not consistently cancelled** in `dispose()`. If `MessageHolder` instances retained after disposal (e.g., by `SliverAnimatedList` during remove animations), stream subscriptions remain active; listener callbacks execute on dead state.

## `SliverAnimatedList` Initialization

`MessagesView` uses `SliverAnimatedList` with `reverse: true` (newest message at bottom). Initial messages inserted using:

```dart
for (var message in messages) {
    _listKey.currentState?.insertItem(
        0,
        duration: const Duration(milliseconds: 0),
    );
}
```

Each of 25–100 initial messages calls `insertItem` with zero duration — triggers frame per item, adding CPU cost at open time even though animation invisible.

## `runAsync` Helper

```dart
Future<T> runAsync<T>(FutureOr<T> Function() computation) {
    return SchedulerBinding.instance
        .scheduleTask(computation, Priority.animation);
}
```

Despite name, `runAsync` **does not run on background isolate**. Schedules computation as task on Flutter scheduler with `Priority.animation` priority — runs on **UI isolate** between frames. Useful for deferring CPU work to avoid jank; does not provide true concurrency.

## `ChatsService.init()` Batch Loading

```dart
// ChatsService processes chats in sequential batches of 15
for (var i = 0; i < allChats.length; i += 15) {
    var batch = allChats.sublist(i, min(i + 15, allChats.length));
    // process batch ...
    chats.value = newChats; // RxList notification fires per batch
}
```

Each batch triggers `RxList` notification via `chats.value = newChats`, causing `Obx` widgets listening to chat list to rebuild. 100+ chats produces ~7 rebuilds at startup.
