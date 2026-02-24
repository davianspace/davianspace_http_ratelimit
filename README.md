# davianspace_http_ratelimit

[![pub version](https://img.shields.io/pub/v/davianspace_http_ratelimit.svg)](https://pub.dev/packages/davianspace_http_ratelimit)
[![Dart SDK](https://img.shields.io/badge/dart-%3E%3D3.0.0-blue.svg)](https://dart.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Tests](https://img.shields.io/badge/tests-158%20passing-brightgreen)
![Analyzer](https://img.shields.io/badge/analyzer-0%20issues-brightgreen)

Enterprise-grade HTTP rate limiting for Dart and Flutter. Six battle-tested
algorithms, client-side pipeline integration for
[davianspace_http_resilience](https://pub.dev/packages/davianspace_http_resilience),
and a framework-agnostic server-side admission control layer — all with a
pluggable backend, strict null-safety, and zero reflection.

---

## Table of Contents

- [Why This Package?](#why-this-package)
- [Algorithm Comparison](#algorithm-comparison)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
  - [Client-Side Rate Limiting](#client-side-rate-limiting)
  - [Server-Side Admission Control](#server-side-admission-control)
- [Usage Guide](#usage-guide)
  - [Token Bucket](#token-bucket)
  - [Fixed Window](#fixed-window)
  - [Sliding Window Counter (Approximate)](#sliding-window-counter-approximate)
  - [Sliding Window Log (Exact)](#sliding-window-log-exact)
  - [Leaky Bucket](#leaky-bucket)
  - [Concurrency Limiter](#concurrency-limiter)
  - [HTTP Pipeline Handler](#http-pipeline-handler)
  - [Respecting Server-Sent Rate Headers](#respecting-server-sent-rate-headers)
  - [Server-Side Admission Control](#server-side-admission-control-1)
  - [Key Extractors](#key-extractors)
  - [Composite Keys](#composite-keys)
  - [Custom Backend Repository](#custom-backend-repository)
  - [Statistics & Observability](#statistics--observability)
  - [Handling Rate Limit Exceeded](#handling-rate-limit-exceeded)
- [Lifecycle & Disposal](#lifecycle--disposal)
- [Testing](#testing)
- [Architecture](#architecture)
- [API Reference](#api-reference)
- [Contributing](#contributing)
- [Security](#security)
- [License](#license)

---

## Why This Package?

| Concern | How We Address It |
|---------|-------------------|
| **Client quota enforcement** | Six algorithms cover every common rate-shaping problem |
| **Server-side admission** | Framework-agnostic `ServerRateLimiter` with per-key isolation |
| **Fairness** | FIFO waiter queues; `tryAcquire` denied when blockers are queued |
| **Burst traffic** | Token Bucket and Leaky Bucket absorb and shape bursts independently |
| **Exact vs. approximate** | Two sliding-window variants; choose accuracy vs. O(1) memory |
| **Backend flexibility** | Swap `InMemoryRateLimiterRepository` for a Redis-backed adapter |
| **Ops visibility** | Per-limiter statistics: acquired, rejected, queue depth, current permits |
| **Pipeline integration** | First-class `HttpClientBuilder.withRateLimit()` extension |
| **Resource safety** | Deterministic `dispose()` on every limiter, repository, and server |

---

## Algorithm Comparison

| Algorithm | Burst | Smoothing | Memory | Use when |
|-----------|-------|-----------|--------|----------|
| **Token Bucket** | ✅ Up to `capacity` | ✅ Continuous | O(1) | API client quotas; allow short bursts |
| **Fixed Window** | ⚠️ Up to `2×maxPermits` | ❌ | O(1) | Simple per-minute / per-hour quotas |
| **Sliding Window Counter** | ⚠️ Weighted estimate | ✅ Approximate | O(1) | High-throughput with acceptable approximation |
| **Sliding Window Log** | ❌ Strict | ✅ Exact | O(n) | Low-volume; exact per-window enforcement required |
| **Leaky Bucket** | ❌ Queued, not burst | ✅ Constant drain | O(n) | Enforce a constant outflow rate (e.g., outbound SMS) |
| **Concurrency Limiter** | N/A | N/A | O(n) | Limit simultaneous in-flight requests / connections |

---

## Requirements

- **Dart SDK** `>=3.0.0 <4.0.0`
- [`davianspace_http_resilience`](https://pub.dev/packages/davianspace_http_resilience) `^1.0.1`
  (required only for `HttpRateLimitHandler`; core limiters have no HTTP dependency)

---

## Installation

```yaml
dependencies:
  davianspace_http_ratelimit: ^1.0.0
```

```bash
dart pub get
```

---

## Quick Start

### Client-Side Rate Limiting

```dart
import 'package:davianspace_http_ratelimit/davianspace_http_ratelimit.dart';
import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';

final limiter = TokenBucketRateLimiter(
  capacity: 200,
  refillAmount: 100,
  refillInterval: const Duration(seconds: 1),
);

final client = HttpClientBuilder()
    .withBaseUri(Uri.parse('https://api.example.com'))
    .withRateLimit(
      RateLimitPolicy(
        limiter: limiter,
        acquireTimeout: const Duration(milliseconds: 500),
        respectServerHeaders: true,
        onRejected: (ctx, e) => log.warning('Rate limit hit: $e'),
      ),
    )
    .build();

// At shutdown:
client.dispose();
limiter.dispose();
```

### Server-Side Admission Control

```dart
import 'package:davianspace_http_ratelimit/davianspace_http_ratelimit.dart';

final server = ServerRateLimiter(
  limiterFactory: () => TokenBucketRateLimiter(
    capacity: 100,
    refillAmount: 100,
    refillInterval: const Duration(minutes: 1),
  ),
  repository: InMemoryRateLimiterRepository(),
  acquireTimeout: Duration.zero, // non-blocking
);

final extractor = IpKeyExtractor();

// In your request handler:
Future<Response> handleRequest(Request request) async {
  final key = extractor.extractKey(request.headers, request.uri);
  if (!server.tryAllow(key)) {
    return Response(429, body: 'Too Many Requests');
  }
  return processRequest(request);
}
```

---

## Usage Guide

### Token Bucket

Tokens are added to a bucket at `refillAmount` per `refillInterval`,
capped at `capacity`. Each request consumes one token.

```dart
final limiter = TokenBucketRateLimiter(
  capacity: 100,          // burst up to 100
  refillAmount: 10,       // 10 tokens added per interval
  refillInterval: const Duration(seconds: 1),
  initialTokens: 50,      // optional: start with a half-full bucket
);
addTearDown(limiter.dispose);

// Non-blocking check:
if (limiter.tryAcquire()) {
  // proceed
}

// Blocking with timeout:
try {
  await limiter.acquire(timeout: const Duration(seconds: 2));
  // proceed
} on RateLimitExceededException catch (e) {
  // retry after e.retryAfter, or return HTTP 429
}
```

**FIFO fairness:** When blocking `acquire()` callers are queued, `tryAcquire()`
returns `false` even if tokens are available. Queued callers have priority.

---

### Fixed Window

Allows at most `maxPermits` requests in each fixed-duration window.

```dart
final limiter = FixedWindowRateLimiter(
  maxPermits: 1000,
  windowDuration: const Duration(minutes: 1),
);
addTearDown(limiter.dispose);

for (var i = 0; i < 1005; i++) {
  if (!limiter.tryAcquire()) {
    // window exhausted — back off until next window
    break;
  }
}
```

> **Note:** In the worst case (requests split across two adjacent windows),
> up to `2 × maxPermits` may be allowed within a single window span. Use a
> Sliding Window variant when this matters.

---

### Sliding Window Counter (Approximate)

O(1) memory. Uses two slots and a weighted formula:

```
estimated = prevCount × (1 − elapsed/window) + currCount
```

```dart
final limiter = SlidingWindowRateLimiter(
  maxPermits: 500,
  windowDuration: const Duration(seconds: 60),
);
addTearDown(limiter.dispose);

if (limiter.tryAcquire()) {
  // within rolling 60-second limit
}
```

Suitable for high-throughput workloads where ~5% counting error is acceptable.

---

### Sliding Window Log (Exact)

O(n) memory (one `DateTime` per request within the window). Exact counting.

```dart
final limiter = SlidingWindowLogRateLimiter(
  maxPermits: 10,
  windowDuration: const Duration(seconds: 1),
  pollInterval: const Duration(milliseconds: 10), // for blocking acquire
);
addTearDown(limiter.dispose);

if (limiter.tryAcquire()) {
  // guaranteed: at most 10 requests in the last second
}
```

---

### Leaky Bucket

Requests enter a queue of size `capacity`. A timer drains one entry per
`leakInterval`, enforcing a constant outflow rate.

```dart
final limiter = LeakyBucketRateLimiter(
  capacity: 50,
  leakInterval: const Duration(milliseconds: 200), // 5 req/s outflow
);
addTearDown(limiter.dispose);

if (limiter.tryAcquire()) {
  // queued; will be processed at the constant drain rate
}
```

> Use the Leaky Bucket when you need to **smooth the output rate**, not just
> cap the count (e.g., sending outbound webhooks at a fixed pace).

---

### Concurrency Limiter

Limits the number of simultaneously in-flight operations. `release()` **must**
be called exactly once per successful `acquire()`.

```dart
final limiter = ConcurrencyLimiter(maxConcurrency: 10);
addTearDown(limiter.dispose);

await limiter.acquire(timeout: const Duration(seconds: 5));
try {
  await performExpensiveOperation();
} finally {
  limiter.release(); // always release, even on error
}
```

`HttpRateLimitHandler` handles `release()` automatically in its `finally` block.

---

### HTTP Pipeline Handler

`HttpRateLimitHandler` wires any `RateLimiter` into the
`davianspace_http_resilience` middleware pipeline.

```dart
final limiter = SlidingWindowRateLimiter(
  maxPermits: 1000,
  windowDuration: const Duration(seconds: 60),
);

final client = HttpClientBuilder()
    .withBaseUri(Uri.parse('https://api.stripe.com'))
    .withDefaultHeader('Authorization', 'Bearer $apiKey')
    .withRetry(RetryPolicy.exponential(maxRetries: 3))
    .withRateLimit(
      RateLimitPolicy(
        limiter: limiter,
        acquireTimeout: const Duration(seconds: 30),
        onRejected: (ctx, e) {
          metrics.increment('rate_limit.rejected');
          log.warning('Rate limited: ${ctx.request.uri}');
        },
      ),
    )
    .build();
```

**Handler ordering:** Place `withRateLimit()` **before** `withRetry()` so that
retries consume permits (rate-limiting applies per-attempt). Place it **after**
`withRetry()` to share one permit across all retry attempts for a single
logical request.

---

### Respecting Server-Sent Rate Headers

When `respectServerHeaders: true`, the handler parses `X-RateLimit-*` and
`Retry-After` response headers and stores them in the `HttpContext` for
downstream inspection.

```dart
final policy = RateLimitPolicy(
  limiter: limiter,
  respectServerHeaders: true,
);

final response = await client.send(ctx);

final serverHeaders = ctx.getProperty<RateLimitHeaders>(
  HttpRateLimitHandler.rateLimitHeadersPropertyKey,
);
if (serverHeaders != null) {
  print('Remaining: ${serverHeaders.remaining}');
  if (serverHeaders.isExhausted) {
    print('Server quota exhausted; retry in ${serverHeaders.retryAfter}');
  }
}
```

Parsed fields:

| Field | Header |
|-------|--------|
| `limit` | `X-RateLimit-Limit` |
| `remaining` | `X-RateLimit-Remaining` |
| `reset` | `X-RateLimit-Reset` (Unix epoch → `Duration`) |
| `retryAfter` | `Retry-After` (seconds) |
| `policy` | `X-RateLimit-Policy` |

---

### Server-Side Admission Control

`ServerRateLimiter` manages a per-key pool of limiters, lazily created by
`limiterFactory`. It is entirely framework-agnostic.

```dart
final server = ServerRateLimiter(
  limiterFactory: () => FixedWindowRateLimiter(
    maxPermits: 100,
    windowDuration: const Duration(minutes: 1),
  ),
  repository: InMemoryRateLimiterRepository(),
  acquireTimeout: Duration.zero,
  onRejected: (key, e) => log.warning('Rejected key=$key: $e'),
);
```

**Non-blocking:**

```dart
if (!server.tryAllow(key)) {
  return Response(429, headers: {'Retry-After': '60'});
}
```

**Blocking:**

```dart
try {
  await server.allow(key); // waits up to acquireTimeout
} on RateLimitExceededException catch (e) {
  return Response(429);
}
```

**Statistics per key:**

```dart
final stats = server.statisticsFor(key);
print('Key $key: ${stats?.permitsAcquired} acquired, '
      '${stats?.queueDepth} queued');
```

---

### Key Extractors

Choose or compose a key extraction strategy for `ServerRateLimiter`:

```dart
// Global single-bucket limit:
final extractor = GlobalKeyExtractor();

// Per-IP (reads X-Forwarded-For, X-Real-IP, or falls back to fallbackKey):
final extractor = IpKeyExtractor(fallbackKey: 'cf-connecting-ip');

// Per-authenticated user (default header is 'x-user-id'):
final extractor = UserKeyExtractor(header: 'x-api-key');

// Per-URI-path (e.g., '/api/v1/orders'):
final extractor = RouteKeyExtractor();

// Custom logic:
final extractor = CustomKeyExtractor(
  (headers, uri) => '${headers['x-tenant-id']}:${uri.path}',
);
```

---

### Composite Keys

Combine two or more extractors to create compound rate-limit keys:

```dart
// Rate-limit per (IP address + API route):
final extractor = CompositeKeyExtractor(
  [IpKeyExtractor(), RouteKeyExtractor()],
);
// Produces keys like: '203.0.113.42:/api/v1/orders'
```

---

### Custom Backend Repository

Replace `InMemoryRateLimiterRepository` with a distributed implementation:

```dart
class RedisRateLimiterRepository implements RateLimiterRepository {
  final _redis = RedisClient();
  final _local = <String, RateLimiter>{};

  @override
  RateLimiter getOrCreate(String key, RateLimiter Function(String) factory) {
    return _local.putIfAbsent(key, () => factory(key));
    // For true distribution, push counter increments to Redis and
    // sync _local state on each getOrCreate call.
  }

  @override
  void remove(String key) => _local.remove(key)?.dispose();

  @override
  void removeWhere(bool Function(String, RateLimiter) test) {
    _local.removeWhere((k, v) {
      if (test(k, v)) { v.dispose(); return true; }
      return false;
    });
  }

  @override
  void dispose() { _local.forEach((_, v) => v.dispose()); _local.clear(); }
}
```

---

### Statistics & Observability

All limiters expose a `statistics` getter returning an immutable
`RateLimiterStatistics` snapshot:

```dart
final stats = limiter.statistics;
print('Acquired : ${stats.permitsAcquired}');
print('Rejected : ${stats.permitsRejected}');
print('Available: ${stats.currentPermits} / ${stats.maxPermits}');
print('Queued   : ${stats.queueDepth}');
```

Integrate with your metrics system:

```dart
Timer.periodic(const Duration(seconds: 30), (_) {
  final s = limiter.statistics;
  metrics
    ..gauge('ratelimit.tokens', s.currentPermits)
    ..gauge('ratelimit.queue_depth', s.queueDepth)
    ..counter('ratelimit.acquired', s.permitsAcquired)
    ..counter('ratelimit.rejected', s.permitsRejected);
});
```

---

### Handling Rate Limit Exceeded

```dart
try {
  await limiter.acquire(timeout: const Duration(seconds: 5));
  final response = await sendRequest(ctx);
  return response;
} on RateLimitExceededException catch (e) {
  final retryAfter = e.retryAfter ?? const Duration(seconds: 60);
  return HttpResponse(
    statusCode: 429,
    headers: {
      'Retry-After': retryAfter.inSeconds.toString(),
      'X-RateLimit-Limit': limiter.statistics.maxPermits.toString(),
    },
    body: '{"error":"Too Many Requests","retryAfterSeconds":${retryAfter.inSeconds}}',
  );
}
```

---

## Lifecycle & Disposal

Every `RateLimiter`, `RateLimiterRepository`, and `ServerRateLimiter` must be
disposed when no longer needed.

```dart
// Always wrap limiters in try/finally or register with a DI container.
final limiter = ConcurrencyLimiter(maxConcurrency: 10);
try {
  // ... use limiter
} finally {
  limiter.dispose();
}
```

**What `dispose()` does:**

- Cancels all internal `Timer` instances.
- Completes all pending `acquire()` futures with `StateError`.
- Guards `tryAcquire()` and `acquire()` against post-disposal calls.
- All `dispose()` implementations are **idempotent** (safe to call multiple times).

**`HttpRateLimitHandler` note:** The handler pipeline is disposed by
`HttpClient.dispose()` (from `davianspace_http_resilience`). The `RateLimiter`
itself must be disposed separately by its creator.

---

## Testing

```bash
# Static analysis (zero issues required)
dart analyze --fatal-infos

# Test suite
dart test

# Publish dry-run
dart pub publish --dry-run
```

The package ships with 158+ tests covering:
- Construction and argument validation for all 6 algorithms
- `tryAcquire` success, rejection, and FIFO fairness guard
- `acquire` immediate, blocking, and timeout paths
- `dispose` idempotency and pending-waiter rejection
- `HttpRateLimitHandler` non-blocking, blocking, timeout, `onRejected`, and
  server-header paths
- `ServerRateLimiter` tryAllow, allow, release, and statistics
- All 6 key extractors including composite and edge cases
- `RateLimitHeaders` parsing (case-insensitive, missing fields, epoch reset)

**Using `fake_async` in your own tests** avoids real wall-clock delays:

```dart
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

test('token bucket refills after interval', () {
  fakeAsync((async) {
    final limiter = TokenBucketRateLimiter(
      capacity: 1,
      refillAmount: 1,
      refillInterval: const Duration(seconds: 1),
      initialTokens: 0,
    );
    expect(limiter.tryAcquire(), isFalse);
    async.elapse(const Duration(seconds: 1));
    expect(limiter.tryAcquire(), isTrue);
    limiter.dispose();
  });
});
```

---

## Architecture

See [doc/architecture.md](doc/architecture.md) for a detailed description of
the three-layer design:

```
┌──────────────────────────────────────────────────────────────┐
│  Client Layer                                                │
│  HttpRateLimitHandler ← RateLimitPolicy                      │
│         │                                                    │
│         ▼                                                    │
├──────────────────────────────────────────────────────────────┤
│  Algorithm Layer                                             │
│  TokenBucket | FixedWindow | SlidingCounter | SlidingLog     │
│  LeakyBucket | ConcurrencyLimiter                            │
├──────────────────────────────────────────────────────────────┤
│  Server Layer                                                │
│  ServerRateLimiter ← RateLimitKeyExtractor                   │
│         │                                                    │
│         ▼                                                    │
├──────────────────────────────────────────────────────────────┤
│  Backend Layer                                               │
│  RateLimiterRepository (InMemory | Redis | custom)           │
└──────────────────────────────────────────────────────────────┘
```

---

## API Reference

### Limiters

| Class | Key Parameters |
|-------|---------------|
| `TokenBucketRateLimiter` | `capacity`, `refillAmount`, `refillInterval`, `initialTokens?` |
| `FixedWindowRateLimiter` | `maxPermits`, `windowDuration` |
| `SlidingWindowRateLimiter` | `maxPermits`, `windowDuration` |
| `SlidingWindowLogRateLimiter` | `maxPermits`, `windowDuration`, `pollInterval?` |
| `LeakyBucketRateLimiter` | `capacity`, `leakInterval` |
| `ConcurrencyLimiter` | `maxConcurrency` |

### Client-Side

| Symbol | Description |
|--------|-------------|
| `HttpRateLimitHandler` | `DelegatingHandler`; acquire before forward, release after |
| `RateLimitPolicy` | Immutable config: limiter, timeout, callback, server-headers flag |
| `withRateLimit(policy)` | Extension on `HttpClientBuilder` |
| `HttpRateLimitHandler.rateLimitHeadersPropertyKey` | `HttpContext` property key for server headers |
| `RateLimitHeaders` | Parsed `X-RateLimit-*` and `Retry-After` value object |

### Server-Side

| Symbol | Description |
|--------|-------------|
| `ServerRateLimiter` | Framework-agnostic per-key admission gate |
| `GlobalKeyExtractor` | Single shared bucket |
| `IpKeyExtractor` | Client IP from `X-Forwarded-For` / `X-Real-IP` |
| `UserKeyExtractor` | User ID from configurable header |
| `RouteKeyExtractor` | `uri.path` as key |
| `CustomKeyExtractor` | Caller-provided key function |
| `CompositeKeyExtractor` | Joins two or more extractors |

### Backend

| Symbol | Description |
|--------|-------------|
| `RateLimiterRepository` | Abstract interface for limiter storage |
| `InMemoryRateLimiterRepository` | Default `Map`-backed implementation |

### Exceptions & Statistics

| Symbol | Description |
|--------|-------------|
| `RateLimitExceededException` | Thrown when a limit is exceeded; carries `limiterType` and `retryAfter` |
| `RateLimiterStatistics` | Immutable snapshot: `permitsAcquired`, `permitsRejected`, `currentPermits`, `maxPermits`, `queueDepth` |

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, coding standards,
testing requirements, and pull request guidelines.

---

## Security

See [SECURITY.md](SECURITY.md) for supported versions, vulnerability reporting,
and guidance on IP-header spoofing, memory exhaustion, and distributed
deployments.

---

## License

[MIT License](LICENSE) — Copyright (c) 2026 DavianSpace
