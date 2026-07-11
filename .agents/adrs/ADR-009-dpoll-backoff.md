# ADR-009 — Exponential Backoff in `doPoll()` Error Handling

**Status:** Proposed  
**Date:** 2026-07-11  
**Project:** [Performance Optimization](../projects/performance-optimization/M2-message-delivery.md)

## Context

`RustPushService.doPoll()` runs infinite loop awaiting `api.recvWait()`:

```dart
while (true) {
  final res = await api.recvWait(...);
  handleMsg(res);
}
```

No error handling. If `api.recvWait()` returns unexpectedly without blocking (e.g., APNs drops and Rust returns error rather than hanging), or if `handleMsg()` throws, loop either:
1. Spins at full CPU until process killed, or
2. Unwinds and stops receiving messages entirely

Both leave user without message delivery.

Rust-side `recv_wait()` should always block until message arrives or connection closes. Relying on this without safety net in Dart is fragile.

## Decision

Add exponential backoff with cap to `doPoll()`:

```dart
int _backoffMs = 100;

Future<void> doPoll() async {
  while (true) {
    try {
      final res = await api.recvWait(state: _state);
      _backoffMs = 100; // reset on success
      await _handleMsg(res);
    } on AnyhowException catch (e) {
      Logger.error('recvWait AnyhowException', error: e);
      await Future.delayed(Duration(milliseconds: _backoffMs));
      _backoffMs = (_backoffMs * 2).clamp(100, 30000);
    } catch (e, s) {
      Logger.error('recvWait unexpected error', error: e, trace: s);
      await Future.delayed(Duration(milliseconds: _backoffMs));
      _backoffMs = (_backoffMs * 2).clamp(100, 30000);
    }
  }
}
```

Backoff starts at 100ms, doubles on each consecutive error, caps at 30s. Successful `recvWait()` resets backoff to 100ms.

## Consequences

**Positive:**
- CPU doesn't spike during APNs connection errors
- `doPoll()` recovers automatically after transient Rust-side errors
- Errors logged with full context for debugging

**Negative:**
- During persistent APNs outage, messages delayed up to 30s per retry cycle
- Backoff doesn't distinguish recoverable (network timeout) vs unrecoverable (invalid credentials) errors — future improvement could add error type branching

## Alternatives Considered

**A: Wrap entire `doPoll()` in `while(true)` restarter**  
Less granular — can't reset backoff on individual success.

**B: Use `Stream.retryWhen` from `rxdart`**  
Requires restructuring `recvWait` as stream. More complex given current architecture.
