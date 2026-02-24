# Architecture of davianspace_http_ratelimit

This document describes the internal design, layering, and key invariants of
the `davianspace_http_ratelimit` package. It is intended for contributors and
advanced users who need to extend or embed the package.

---

## Table of Contents

- [High-Level Overview](#high-level-overview)
- [Layer Diagram](#layer-diagram)
- [Core Abstractions](#core-abstractions)
  - [RateLimiter](#ratelimiter)
  - [RateLimiterStatistics](#ratelimiterstatistics)
  - [RateLimitExceededException](#ratelimitexceededexception)
- [Algorithm Implementations](#algorithm-implementations)
  - [TokenBucketRateLimiter](#tokenbucketratelimiter)
  - [FixedWindowRateLimiter](#fixedwindowratelimiter)
  - [SlidingWindowRateLimiter (Counter)](#slidingwindowratelimiter-counter)
  - [SlidingWindowLogRateLimiter (Exact)](#slidingwindowlogratelimiter-exact)
  - [LeakyBucketRateLimiter](#leakybucketratelimiter)
  - [ConcurrencyLimiter](#concurrencylimiter)
- [Client-Side HTTP Layer](#client-side-http-layer)
  - [HttpRateLimitHandler](#httpratelimithandler)
  - [RateLimitPolicy](#ratelimitpolicy)
  - [HttpClientBuilder Extension](#httpclientbuilder-extension)
  - [RateLimitHeaders](#ratelimitheaders)
- [Server-Side Admission Control Layer](#server-side-admission-control-layer)
  - [ServerRateLimiter](#serverratelimiter)
  - [RateLimitKeyExtractor](#ratelimitkeyextractor)
- [Backend / Repository Layer](#backend--repository-layer)
  - [RateLimiterRepository](#ratelimiterrepository)
  - [InMemoryRateLimiterRepository](#inmemoryratelimiterrepository)
- [Lifecycle & Disposal](#lifecycle--disposal)
- [FIFO Fairness Invariant](#fifo-fairness-invariant)
- [Thread Safety](#thread-safety)
- [Extension Points](#extension-points)
- [Decision Log](#decision-log)

---

## High-Level Overview

```
┌─────────────────────────────────────────────────────────────────┐
│  Client application                                             │
│                                                                 │
│   HttpClientBuilder                                             │
│     .withRateLimit(RateLimitPolicy)      ← Client-side layer   │
│     .build()                                                    │
│         │                                                       │
│         ▼                                                       │
│   HttpRateLimitHandler (DelegatingHandler)                      │
│     acquire() ──────────────────────────── TokenBucket          │
│     innerHandler.send()                    FixedWindow          │
│     release() ──────────────────────────── SlidingCounter       │
│                                            SlidingLog           │
│                                            LeakyBucket          │
│                                            Concurrency          │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  Server middleware / framework handler                          │
│                                                                 │
│   RateLimitKeyExtractor.extract(headers, uri) → key            │
│                                                                 │
│   ServerRateLimiter                          ← Server layer     │
│     .tryAllow(key) / .allow(key)                                │
│     .release(key)                                               │
│         │                                                       │
│         ▼                                                       │
│   RateLimiterRepository                      ← Backend layer    │
│     .getOrCreate(key, factory)                                  │
│     InMemoryRateLimiterRepository (default)                     │
│     [Custom Redis / distributed adapter]                        │
└─────────────────────────────────────────────────────────────────┘
```

---

## Layer Diagram

```
lib/
├── davianspace_http_ratelimit.dart     ← Public barrel
└── src/
    ├── limiters/                       ← Algorithm implementations
    │   ├── rate_limiter.dart           ← Abstract base
    │   ├── token_bucket_rate_limiter.dart
    │   ├── fixed_window_rate_limiter.dart
    │   ├── sliding_window_rate_limiter.dart      (approximate)
    │   ├── sliding_window_log_rate_limiter.dart  (exact)
    │   ├── leaky_bucket_rate_limiter.dart
    │   └── concurrency_limiter.dart
    │
    ├── exceptions/
    │   └── rate_limit_exceeded_exception.dart
    │
    ├── headers/
    │   └── rate_limit_headers.dart     ← X-RateLimit-* parser
    │
    ├── handler/                        ← Client-side HTTP integration
    │   ├── http_rate_limit_handler.dart
    │   ├── rate_limit_policy.dart
    │   └── http_client_builder_extension.dart
    │
    ├── server/                         ← Server-side admission control
    │   ├── server_rate_limiter.dart
    │   ├── rate_limit_key_extractor.dart
    │   └── server.dart                 ← Internal barrel
    │
    └── backend/                        ← Pluggable storage
        ├── rate_limiter_repository.dart
        ├── in_memory_rate_limiter_repository.dart
        └── backend.dart                ← Internal barrel
```

---

## Core Abstractions

### RateLimiter

```dart
abstract class RateLimiter {
  bool tryAcquire();
  Future<void> acquire({Duration? timeout});
  RateLimiterStatistics get statistics;
  void release();   // no-op by default; ConcurrencyLimiter overrides
  void dispose();
}
```

`RateLimiter` is the single seam between the algorithm layer and all consumers
(handler, server). Consumers program to `RateLimiter`, not to concrete types.

`acquire({Duration? timeout})` semantics:
- `timeout == null` — wait indefinitely.
- `timeout == Duration.zero` — effectively equivalent to `tryAcquire()` but
  via the async path (use `tryAcquire()` for truly synchronous non-blocking
  checks).
- `timeout > Duration.zero` — throw `RateLimitExceededException` if the permit
  is not available within the deadline.

### RateLimiterStatistics

Immutable snapshot returned by `RateLimiter.statistics`:

| Field | Description |
|-------|-------------|
| `permitsAcquired` | Cumulative successful acquisitions |
| `permitsRejected` | Cumulative failed acquisitions |
| `currentPermits` | Available permits at snapshot time |
| `maxPermits` | Algorithm-defined upper bound |
| `queueDepth` | Number of callers currently blocked |

### RateLimitExceededException

Thrown by all limiter implementations when a request cannot be granted:
- Non-blocking path: `tryAcquire()` returns `false` and callers may throw it.
- Blocking path: `acquire(timeout: t)` throws it when the timeout elapses.

Contains `limiterType` (e.g., `'TokenBucket'`) and optional `retryAfter`
`Duration` for `Retry-After` header generation.

---

## Algorithm Implementations

### TokenBucketRateLimiter

**Category:** Burst-tolerant, rate-smoothed

**State:** `_tokens: int`, `_queue: List<_Waiter>`, `_refillTimer: Timer`

**Refill:** A `Timer.periodic` fires every `refillInterval`, adding
`refillAmount` tokens capped at `capacity`. The timer calls `_drainQueue()`
to wake blocked waiters in FIFO order.

**acquire:** If tokens available and queue empty, consumes one token
synchronously. Otherwise enqueues a `_Waiter` (Completer + optional
timeout Timer).

**tryAcquire FIFO guard:** Returns `false` whenever `_queue.isNotEmpty`,
even if tokens are available. This prevents non-blocking callers from
bypassing queued blocking callers and starving them.

**Complexity:** O(1) per acquire/tryAcquire, O(n) drain (n = waiters woken
per refill tick).

---

### FixedWindowRateLimiter

**Category:** Simple quota, O(1)

**State:** `_count: int`, `_windowStart: DateTime`

**Window advance:** `_advanceWindowIfNeeded()` computes the number of full
windows elapsed since `_windowStart` and resets `_count` to 0, advancing
`_windowStart` by `n × windowDuration`. This handles gaps of multiple windows
correctly without drift.

**acquire:** Blocking path polls by sleeping until `_advanceWindowIfNeeded()`
creates space.

**Limitation:** Allows up to `2 × maxPermits` within a 1-window span straddling
two adjacent windows. Use `SlidingWindow*` variants if this burst behaviour is
unacceptable.

---

### SlidingWindowRateLimiter (Counter / Approximate)

**Category:** Approximate rolling window, O(1)

**State:** `_prevCount: int`, `_currCount: int`, `_slotStart: DateTime`

**Algorithm:**
```
estimated = prevCount × (1 − elapsed/window) + currCount
allow if estimated < maxPermits
```
Uses weighted interpolation between the previous and current slot counts.
Accuracy improves as the window size increases relative to request variance.

**Advance:** `_advanceSlotIfNeeded()` discards `_prevCount` when more than
one slot has passed (counts are irrelevant beyond one window).

---

### SlidingWindowLogRateLimiter (Exact)

**Category:** Exact rolling window, O(n) per access

**State:** `_log: Queue<DateTime>`

Each request appends a timestamp. Before checking, `_evictExpired()` removes
all entries older than `windowDuration`. A request is allowed if
`_log.length < maxPermits` after eviction.

**Trade-offs:** Exact counting at the cost of memory proportional to
`maxPermits`. Prefer for low-traffic, high-accuracy scenarios.

---

### LeakyBucketRateLimiter

**Category:** Smooth output rate, queue-based

**State:** `_queue: List<_Waiter>`, `_leakTimer: Timer`

Requests enqueue in `_queue` (capacity bounded by `capacity`). A
`Timer.periodic` fires every `leakInterval` and wakes the front waiter
(`_leak()`). Excess requests beyond capacity are rejected immediately via
`tryAcquire()`.

**Distinction from Token Bucket:** Token Bucket smooths the input rate and
allows bursts limited by capacity; Leaky Bucket enforces a constant output
rate regardless of input bursts.

---

### ConcurrencyLimiter

**Category:** In-flight concurrency cap (semaphore)

**State:** `_inFlight: int`, `_waiters: List<_Waiter>`

`acquire()` increments `_inFlight` if `_inFlight < maxConcurrency`; otherwise
enqueues a waiter. `release()` decrements `_inFlight` and calls
`_dispatchNext()` to wake the first queued waiter.

`_dispatchNext()` skips already-timed-out waiters (completer already
completed by the timeout Timer) — this prevents accidental over-counting
of `_inFlight`.

`release()` is not a no-op on `ConcurrencyLimiter`; it is *required* after
every successful `acquire()`.

---

## Client-Side HTTP Layer

### HttpRateLimitHandler

Extends `DelegatingHandler` (from `davianspace_http_resilience`).

```
send(ctx):
  _acquirePermit()          ← may block or throw RateLimitExceededException
  try {
    response = innerHandler.send(ctx)
    if (respectServerHeaders) _parseAndStoreHeaders(ctx, response)
    return response
  } finally {
    policy.limiter.release()  ← always called after successful acquire
  }
```

Key invariant: `release()` is called **only** when `_acquirePermit()` returns
without throwing. It is in the `finally` of the `try` block that wraps
`innerHandler.send()`, not the `try` that wraps `_acquirePermit()`.

### RateLimitPolicy

Immutable configuration value object:

| Field | Default | Description |
|-------|---------|-------------|
| `limiter` | required | The `RateLimiter` instance to use |
| `acquireTimeout` | `null` (wait for ever) | `Duration.zero` → non-blocking |
| `onRejected` | `null` | Callback fired before re-throwing |
| `respectServerHeaders` | `false` | Parse and store `X-RateLimit-*` headers |

### HttpClientBuilder Extension

```dart
extension RateLimitHttpClientBuilderExtension on HttpClientBuilder {
  HttpClientBuilder withRateLimit(RateLimitPolicy policy);
}
```

Wraps the inner pipeline with an `HttpRateLimitHandler` bearing the given
policy. Composable with other handlers (retry, circuit breaker, etc.).

### RateLimitHeaders

Parses `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset`
(Unix epoch → `Duration`), `Retry-After`, and `X-RateLimit-Policy` from a
`Map<String, String>`. Case-insensitive key lookup (tries both lower-case and
canonical forms).

Stored in the `HttpContext` property bag under
`HttpRateLimitHandler.rateLimitHeadersPropertyKey` when
`RateLimitPolicy.respectServerHeaders == true` and the response contains at
least one relevant header.

---

## Server-Side Admission Control Layer

### ServerRateLimiter

Framework-agnostic. Accepts `Map<String, String>` headers and `Uri`; does not
depend on any framework request type.

```
tryAllow(key):
  limiter = repository.getOrCreate(key, limiterFactory)
  return limiter.tryAcquire()

allow(key):
  limiter = repository.getOrCreate(key, limiterFactory)
  await limiter.acquire(timeout: acquireTimeout)

release(key):
  limiter = repository.getOrCreate(key, limiterFactory)
  limiter.release()
```

Each unique key (e.g., an IP address or user ID) gets its own `RateLimiter`
instance, lazily created by `limiterFactory()` on first access.

### RateLimitKeyExtractor

```dart
abstract class RateLimitKeyExtractor {
  String extract(Map<String, String> headers, Uri uri);
}
```

Built-in implementations:

| Extractor | Key produced |
|-----------|-------------|
| `GlobalKeyExtractor` | `'__global__'` (single shared bucket) |
| `IpKeyExtractor` | First value of `X-Forwarded-For`, else `X-Real-IP`, else fallback |
| `UserKeyExtractor` | Value of configurable header, else `'anonymous'` |
| `RouteKeyExtractor` | `uri.path` |
| `CustomKeyExtractor` | Result of caller-supplied function |
| `CompositeKeyExtractor` | Two or more extractor outputs joined by separator |

---

## Backend / Repository Layer

### RateLimiterRepository

```dart
abstract class RateLimiterRepository {
  RateLimiter getOrCreate(String key, RateLimiter Function(String) factory);
  void remove(String key);
  void removeWhere(bool Function(String key, RateLimiter limiter) test);
  void dispose();
}
```

The repository owns the lifecycle of its managed limiters. `dispose()` must
dispose all limiters it holds.

### InMemoryRateLimiterRepository

`Map<String, RateLimiter>` backed. `dispose()` iterates all entries, calls
`limiter.dispose()`, and clears the map. Idempotent.

**Production note:** For multi-replica deployments, implement
`RateLimiterRepository` against a distributed store. The interface is the only
dependency `ServerRateLimiter` has on storage.

---

## Lifecycle & Disposal

Every stateful object exposes `dispose()`. The disposal contract:

1. **Idempotent** — safe to call multiple times.
2. **Fail pending waiters** — any `acquire()` futures still pending receive a
   `StateError` with a descriptive message.
3. **Cancel timers** — all internal `Timer` instances are cancelled.
4. **Post-dispose guard** — `tryAcquire()` and `acquire()` throw `StateError`
   after disposal.

`HttpClient.dispose()` (from `davianspace_http_resilience`) disposes the
handler chain, which disposes the `HttpRateLimitHandler`. **The limiter itself
is NOT automatically disposed by the handler** — the caller that created
the limiter is responsible for disposing it.

```dart
final limiter = TokenBucketRateLimiter(...);
final client = HttpClientBuilder()
    .withRateLimit(RateLimitPolicy(limiter: limiter))
    .build();

// At shutdown:
client.dispose();  // disposes the handler pipeline
limiter.dispose(); // caller disposes the limiter
```

---

## FIFO Fairness Invariant

All blocking-capable limiters (`TokenBucketRateLimiter`, `LeakyBucketRateLimiter`,
`ConcurrencyLimiter`) maintain a FIFO waiter queue. The invariant is:

> **When the waiter queue is non-empty, `tryAcquire()` must return `false`.**

This ensures that non-blocking callers cannot bypass queued blocking callers
and starve them. Without this guard, a continuous stream of `tryAcquire()`
calls can prevent `acquire()` callers from ever being served.

Implementation pattern:

```dart
@override
bool tryAcquire() {
  _checkDisposed();
  if (_queue.isNotEmpty) {   // ← fairness guard
    _permitsRejected++;
    return false;
  }
  if (_hasCapacity()) {
    _consumeOne();
    _permitsAcquired++;
    return true;
  }
  _permitsRejected++;
  return false;
}
```

---

## Thread Safety

Dart is single-threaded within an isolate. All limiter state mutations occur
synchronously on the event loop. `Timer` callbacks and `Future` completions
interleave on the event loop but do not run concurrently. No locks are needed.

If limiters are shared across isolates (unusual), the caller is responsible for
isolate-boundary serialisation.

---

## Extension Points

| Extension Point | How to extend |
|----------------|--------------|
| New algorithm | Extend `RateLimiter`; register in barrel and docs |
| New key strategy | Implement `RateLimitKeyExtractor.extract()` |
| Distributed storage | Implement `RateLimiterRepository` backed by Redis/DB |
| Custom rejection | Provide `onRejected` callback in `RateLimitPolicy` |
| Per-key limiter config | Use `CustomKeyExtractor` + factory closure in `ServerRateLimiter` |

---

## Decision Log

| Decision | Rationale |
|----------|-----------|
| `final class` for all limiter implementations | Prevents unsafe subclassing; algorithm semantics must not be altered by inheritance |
| `release()` is no-op by default on `RateLimiter` | Most limiters are auto-releasing (counter-based); only semaphore-style limiters need explicit release |
| `InMemoryRateLimiterRepository` does NOT auto-expire keys | Expiry policy is domain-specific; callers use `removeWhere()` on a schedule if needed |
| `SlidingWindowRateLimiter` uses two buckets (counter), not timestamps | O(1) memory and CPU regardless of `maxPermits`; acceptable accuracy for most use cases |
| `SlidingWindowLogRateLimiter` uses `Queue<DateTime>` | O(n) but exact; provided for workloads where approximate counting is unacceptable |
| `ServerRateLimiter` takes raw headers + `Uri`, not a framework `Request` | Framework-agnostic; integrates with Shelf, Dart Frog, custom HTTP servers without coupling |
| `RateLimitHeaders.reset` derived from Unix epoch, not offset | Most real-world APIs (GitHub, Twitter, Stripe) send Unix epoch seconds, not relative offsets |
