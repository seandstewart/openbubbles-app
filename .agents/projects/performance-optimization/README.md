# Performance Optimization — Project Overview

## Goal
Eliminate performance bottlenecks to make OpenBubbles usable on low-end Android devices (2–4 GB RAM, mid-range CPU).

## Problem Statement
- Cold start: 60–180 seconds (all iCloud services initialized sequentially)
- App must stay "always on" to avoid re-init cost
- Sluggish UI on non-flagship devices (100 ObjectBox watchers per conversation, O(N) contact scans)
- High memory crashes app on low-RAM devices (unbounded image cache, full-DB loads)
- Background service has ANR-class bugs

## Milestones

| ID | Milestone | Primary Files | Status |
|---|---|---|---|
| [M1](M1-startup.md) | Startup Time & Ready Signal | `rust/src/api/api.rs`, `rust/src/lib.rs` | In Progress (M1.1 ✅, M1.2 ✅, M1.3 ✅) |
| [M2](M2-message-delivery.md) | Message Delivery Pipeline | `rustpush_service.dart`, `native.rs`, `SocketIOForegroundService.kt` | In Progress (M2.1 ✅, M2.5 ✅) |
| [M3](M3-ui-responsiveness.md) | UI Responsiveness | `MessageWidgetController`, `GlobalChatService`, `contact_service.dart` | In Progress (M3.1-4 ✅, M3.7 ✅, M3.8 ✅, M3.9 ✅) |
| [M4](M4-memory.md) | Memory Footprint | `ConversationViewController`, `eraseCloudKitSync`, `MethodCallHandler.kt` | In Progress (M4.1 ✅, M4.2 ✅, M4.4 ✅) |
| [M5](M5-background-battery.md) | Background & Battery | `SocketIOForegroundService.kt`, `AndroidManifest.xml`, `DartWorker.kt` | In Progress (M5.1 ✅, M5.2 ✅, M5.3 ✅, M5.4 ✅) |
| [M6](M6-sync.md) | Sync Performance | All sync managers, `sync_helpers.dart` | In Progress (M6.1 ✅, M6.2 ✅, M6.3 ✅, M6.5 ✅) |
| [M7](M7-hardening.md) | Hardening & Correctness | Scattered | Proposed |

## Architecture Decision Records
All architectural decisions recorded in [../../adrs/](../../adrs/).

## Reference Documentation
Codebase implementation details used during planning: [../../reference/](../../reference/).

## Expected Outcomes

| Metric | Before | After (target) |
|---|---|---|
| Cold-start to "app ready" | 60–180 s | < 5 s |
| Message delivery latency (foreground) | 1–5 s | < 200 ms |
| RAM (100-message conversation) | 300–600 MB | 80–150 MB |
| RAM (media-heavy conversation) | Unbounded | Capped ~200 MB |
| Full sync time (200 chats) | 15–30 min | 2–5 min |
| Handle sync time (3000 handles) | 5–10 min | 30–60 s |
| CPU usage (idle, foreground) | 15–40% | < 5% |
| ANR frequency | Frequent | None |

## Implementation Order
```
Week 1–2:  M2.5, M1.2, M1.3, M2.1, M3.7, M3.8, M7.1  (quick wins, crash/ANR fixes)
Week 3–4:  M1.1, M3.1, M3.2, M3.3, M3.4               (high-impact architecture)
Week 5–6:  M4.1, M4.2, M3.5, M3.9, M6.1, M6.5         (memory + sync)
Week 7–8:  M1.4, M4.4, M5.2, M6.3, M7.3, M7.6         (persistence + security)
Ongoing:   M2.3, M2.4, M4.3, M5.1, M5.4, M7.4, M7.5   (lower risk, cleanup)
```
