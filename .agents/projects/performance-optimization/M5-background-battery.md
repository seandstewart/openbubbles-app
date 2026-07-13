# M5 — Background & Battery

**Theme:** Correct lifecycle, no ANRs, battery-friendly when idle  
**Status:** In Progress (M5.1 ✅, M5.2 ✅, M5.3 ✅, M5.4 ✅)

---

## Task 5.1 — Guard `SocketIOForegroundService` Restart Receiver with Permission

**Severity:** 🟡 Medium  
**Effort:** Low  

**Files:**
- `android/app/src/main/AndroidManifest.xml`

**Problem:** `ForegroundServiceBroadcastReceiver` exported without `permission` attribute. Any installed app can restart foreground service (battery drain / DoS vector).

**Solution:**
```xml
<receiver
    android:name=".services.foreground.ForegroundServiceBroadcastReceiver"
    android:exported="true"
    android:permission="com.bluebubbles.messaging.RESTART_SERVICE">
    <intent-filter>
        <action android:name="restartservice" />
    </intent-filter>
</receiver>
```
Define permission as `protectionLevel="signature"` so only same-signed apps can send it.

**Acceptance Criteria:**
- [x] Third-party apps cannot trigger `restartservice`
- [x] Own app (same signature) can still send restart intent

**Verification:** ✅ Signature permission defined in manifest

---

## Task 5.2 — Add CloudKit Sync Concurrency Guard

**Severity:** 🟠 High  
**Effort:** Low  

**Files:**
- `lib/services/rustpush/rustpush_service.dart` — `doCloudKitSync()`

**Problem:** On desktop, CloudKit sync can run concurrently from startup trigger and daily timer, causing conflicting DB writes.

**Solution:**
```dart
bool _ckSyncInProgress = false;

Future<void> doCloudKitSync() async {
  if (_ckSyncInProgress) return;
  _ckSyncInProgress = true;
  try {
    await doCloudKitSyncPrivate();
  } finally {
    _ckSyncInProgress = false;
  }
}
```

**Acceptance Criteria:**
- [ ] Only one CloudKit sync runs at a time
- [ ] Second invocation returns immediately without error

---

## Task 5.3 — Remove `SharedPreferences.reload()` from CloudKit Upload Loop

**Severity:** 🟡 Medium  
**Effort:** Low  

**Files:**
- `lib/services/rustpush/rustpush_service.dart` — `getCutoffTime()` and upload batch loop

**Problem:** `ss.prefs.reload()` (disk read) called inside 3,000-message upload batch loop on every iteration.

**Solution:** Call `prefs.reload()` once before loop; pass value as parameter.

**Acceptance Criteria:**
- [ ] No `prefs.reload()` calls inside upload loop

---

## Task 5.4 — Fix `DartWorker.currentJobs` Race Condition

**Severity:** 🟡 Medium  
**Effort:** Low  

**Files:**
- `android/app/src/main/kotlin/com/bluebubbles/messaging/services/backend_ui_interop/DartWorker.kt`

**Problem:** `AtomicInteger.getAndDecrement()` and engine-close decision not atomically paired. Engine can be destroyed while suspended coroutine still executing.

**Solution:** Replace timer/counter with `Job` set tracked per active work item. Only schedule engine close when set is empty:
```kotlin
private val activeJobs = Collections.synchronizedSet(mutableSetOf<Job>())

fun trackJob(job: Job) {
    activeJobs.add(job)
    job.invokeOnCompletion {
        activeJobs.remove(job)
        if (activeJobs.isEmpty()) scheduleEngineClose()
    }
}
```

**Acceptance Criteria:**
- [ ] Engine never destroyed while any job executing
- [ ] Engine close deferred correctly under rapid concurrent job completions
