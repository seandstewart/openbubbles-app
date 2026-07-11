# Database Layer

## Engine

**ObjectBox v4** (`objectbox ^4.0.1`)

- Single embedded `Store` per process; opened at startup
- No server process required — pure embedded
- Mobile size limit: up to **5 GB** (`maxDBSizeInKB: 5 * 1024 * 1024`)
- Desktop: no explicit size limit configured
- Store file location: `{appDocDir}/objectbox/`

## `Database` Class

**File:** `lib/database/database.dart`

Pure static facade exposing typed `Box<T>` handles. All DB access goes through this class.

```dart
class Database {
    static int version = 5;

    static late final Store store;
    static late final Box<Attachment> attachments;
    static late final Box<Chat> chats;
    static late final Box<Contact> contacts;
    static late final Box<FCMData> fcmData;
    static late final Box<Handle> handles;
    static late final Box<Message> messages;
    static late final Box<ScheduledMessage> scheduledMessages;
    static late final Box<ThemeStruct> themes;
    static late final Box<ThemeEntry> themeEntries;
}
```

`store` populated by `Database.init()` during startup. On mobile, `Store.attach()` used when store already open (e.g., background isolate). On desktop, `openStore()` called directly.

## Schema Entities

### `Attachment`

| Field | Type | Notes |
|-------|------|-------|
| `id` | `int` (ObjectBox ID) | Auto-assigned |
| `guid` | `String` | **UNIQUE index**; format: `{messageGuid}_{partIndex}` for RustPush |
| `messageId` | `int` | FK → Message (not enforced by OB) |
| `mimeType` | `String?` | MIME type |
| `uti` | `String?` | UTI type string |
| `totalBytes` | `int?` | File size in bytes |
| `transferName` | `String?` | Display filename |
| `isOutgoing` | `bool` | True if sent by this device |
| `metadata` | `Map?` | Arbitrary metadata; `metadata["rustpush"]` stores serialized `api.Attachment` |
| `ckRecordId` | `String?` | CloudKit record ID; null if not yet synced |

### `Chat`

| Field | Type | Notes |
|-------|------|-------|
| `id` | `int` | ObjectBox ID |
| `guid` | `String` | **Index**; format: `iMessage;-;{address}` or `iMessage;+;chat{id}` |
| `originalROWID` | `int?` | Server-side ROWID for BB server sync |
| `handles` | `ToMany<Handle>` | Participants (many-to-many join) |
| `apnTitle` | `String?` | Group name from APN/iMessage |
| `displayName` | `String?` | User-overridden display name |
| `ckRecordId` | `String?` | CloudKit record ID |
| `ckSyncState` | `bool` | False = needs upload to CloudKit |
| `isRpSms` | `bool` | True = SMS chat in RustPush mode |
| `usingHandle` | `String?` | Which of our handles to use in this chat |
| `dbOnlyLatestMessageDate` | `int` | Indexed; used for sorting and queries |

### `Contact`

| Field | Type | Notes |
|-------|------|-------|
| `id` | `String` | CloudKit record key or device contact ID |
| `dbId` | `int?` | ObjectBox internal ID |
| `displayName` | `String?` | Display name |
| `isShared` | `bool` | True = received via iMessage profile sharing |
| `avatar` | `Uint8List?` | Decoded avatar bytes stored in DB |

### `Handle`

| Field | Type | Notes |
|-------|------|-------|
| `id` | `int` | ObjectBox ID |
| `address` | `String` | Phone number or email (no prefix) |
| `service` | `String?` | `"iMessage"` or `"SMS"` |
| `contactRelation` | `ToOne<Contact>` | Linked contact |
| `originalROWID` | `int?` | Server-side ROWID |

**Index:** `(address, service)` composite — used for `Handle.findOne(addressAndService: ...)` lookups.

### `Message`

Largest entity — 50+ properties.

| Field | Type | Notes |
|-------|------|-------|
| `id` | `int` | ObjectBox ID |
| `guid` | `String?` | **Index**; iMessage GUID or temp GUID |
| `stagingGuid` | `String?` | Final GUID while outgoing message in-flight |
| `originalROWID` | `int?` | Server-side ROWID |
| `text` | `String?` | Plain text content |
| `attributedBody` | `List<AttributedBody>` | Rich text with runs; serialized |
| `messageSummaryInfo` | `List<MessageSummaryInfo>` | Edit history, retracted parts |
| `payloadData` | `PayloadData?` | App balloon / link preview payload |
| `threadOriginatorGuid` | `String?` | GUID of message being replied to |
| `associatedMessageGuid` | `String?` | GUID of message being reacted to |
| `associatedMessageType` | `String?` | Reaction type string |
| `dateEdited` | `DateTime?` | Set when message edited or unsent |
| `dateDeleted` | `DateTime?` | Set when message deleted |
| `dateScheduled` | `DateTime?` | Scheduled send time |
| `ckRecordId` | `String?` | CloudKit record ID |
| `ckSyncState` | `bool` | False = needs upload |
| `isFromMe` | `bool?` | True if sent by this device |
| `handleId` | `int?` | FK → Handle (originalROWID) |
| `itemType` | `int` | 0 = message, 1 = participant change, 2 = rename, 3 = icon |
| `chat` | `ToOne<Chat>` | Owning chat |
| `handle` | `ToOne<Handle>` | Sender handle |

### `ScheduledMessage`

| Field | Type | Notes |
|-------|------|-------|
| `id` | `int` | ObjectBox ID |
| `scheduledDate` | `DateTime` | **Index**; when to send |
| `chatGuid` | `String` | Target chat GUID |

### `ThemeStruct`

| Field | Type | Notes |
|-------|------|-------|
| `id` | `int` | ObjectBox ID |
| `name` | `String` | **Index**; theme display name |
| `data` | `String` | JSON-serialized theme data |

## Watcher Pattern (Reactive Queries)

ObjectBox `.watch(triggerImmediately: true)` is primary UI reactivity mechanism. Queries return `Stream` emitting new result set whenever any matching row changes.

### Usage Sites

| Site | Query | Behavior |
|------|-------|----------|
| `GlobalChatService.watchChats()` | `Database.chats.query(...).watch()` | **Fires on ALL chat writes** — no filter; any chat write triggers full re-evaluation |
| `ChatsService` | Count watcher on unread chats | Drives unread badge |
| `ChatLifecycleManager` | Per-chat message watcher | Notifies UI when messages added/changed |
| `MessagesService.init()` | Per-chat message count watcher | Drives `_messages` list rebuilds |
| `MessageWidgetController.onInit()` | Per-message watcher | **One watcher per visible message** — 100 visible messages = 100 active ObjectBox query subscriptions |

**Scale issue:** `MessageWidgetController` creates one ObjectBox watcher per visible message bubble. 50 visible messages = 50 concurrent DB subscriptions. Each write to `messages` box wakes all 50 watchers.

## Common Query Patterns

### By GUID (single)

```dart
final chat = Database.chats
    .query(Chat_.guid.equals(guid))
    .build()
    .findFirst();
```

### Batch by GUID

```dart
final messages = Database.messages
    .query(Message_.guid.oneOf(guids))
    .build()
    .find();
```

### Linked / Join query

```dart
final query = Database.messages
    .query(Message_.dateCreated.greaterThan(since))
    .link(Message_.chat, Chat_.id.equals(chatId))
    .watch(triggerImmediately: true);
```

### Bulk (full table)

```dart
final allChats = Database.chats.getAll();
```

`getAll()` loads entire table into memory with no pagination. Used in:
- `eraseCloudKitSync()` — loads all messages, chats, and attachments simultaneously
- `HandleSyncManager` — loads all handles before streaming replacements
- DB migration v2 — loads all messages for handleId rewrite

## Sync Helper Batch Write Pattern

**File:** `lib/helpers/backend/sync_helpers.dart`

Multi-step pattern to upsert entities while preserving relations:

```dart
// 1. Query existing entities by GUID
final existing = Database.chats
    .query(Chat_.guid.oneOf(guids))
    .build()
    .find();

// 2. Put new entities (insert, assigning IDs)
Database.chats.putMany(newItems);

// 3. Put existing entities with update mode
Database.chats.putMany(existing, mode: PutMode.update);

// 4. Re-query by GUID to get assigned IDs
final withIds = Database.chats
    .query(Chat_.guid.oneOf(guids))
    .build()
    .find();

// 5. Put again to persist relations (ToMany)
Database.chats.putMany(withIds);
```

Pattern wrapped in retry loop (up to 3 attempts) to handle transient ObjectBox errors.

**Important:** Pattern **not wrapped in explicit transaction**. Each `putMany()` is own commit. Process crash between steps leaves partial state. Use `Database.runInTransaction()` when atomicity required.

## Version-Based Migrations

`Database._performDatabaseMigrations()` runs at startup after `Database.init()`. Current version: **5**.

| Version | Migration |
|---------|----------|
| 1 → 2 | Rewrites `handleId` on all messages to use `originalROWID` instead of local ObjectBox ID; loads all messages and handles into memory |
| 2 → 3 | Resets chat `autoSendReadReceipts` and `autoSendTypingIndicators` overrides to follow global settings |
| 3 → 4 | Persists FCM data from settings to database |
| 4 → 5 | Resets "Bright White" and "OLED Dark" theme colors to new defaults |

Migrations run **bottom-up** via recursive `switch` falling through to next version. `_performDatabaseMigrations(versionOverride: nextVersion)` called recursively to apply each pending version in sequence.

## `Store.attach()` — Secondary Isolate Access

Background isolates (CloudKit sync, incremental sync) need DB access. Use:

```dart
// In _initDatabaseMobile() when store already open:
store = Store.attach(getObjectBoxModel(), objectBoxDirectory.path);
```

`Store.attach()` opens new `Store` handle pointing to same on-disk DB as primary store. ObjectBox handles concurrent access from multiple isolates correctly (multiple readers, one writer at a time). Attached store must be closed when isolate exits.

## `runInTransaction` Wrapper

`Database` exposes:

```dart
static R runInTransaction<R>(TxMode mode, R Function() fn) {
    return store.runInTransaction(mode, fn);
}
```

- `TxMode.read` — read-only transaction; multiple can run concurrently
- `TxMode.write` — exclusive write transaction; serialized with all other writes

**Usage in sync helpers:** Multi-step sync write pattern described above **does not** use `runInTransaction`. Each `putMany` committed independently. Wrapping entire pattern in `runInTransaction(TxMode.write, ...)` would batch all commits into single atomic operation — significantly improves performance and consistency.
