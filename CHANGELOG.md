# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.3] — 2026-02-25

### Added

- **`davianspace_dependencyinjection` integration** — `davianspace_dependencyinjection ^1.0.3`
  is now a runtime dependency. New extension methods on `ServiceCollection`:
  - `addRateLimiter<TLimiter>(limiter)` — registers a pre-constructed limiter as both its concrete type and `RateLimiter`.
  - `addTokenBucketRateLimiter(capacity, refillAmount, refillInterval, [initialTokens])` — singleton `TokenBucketRateLimiter`.
  - `addFixedWindowRateLimiter(maxPermits, windowDuration)` — singleton `FixedWindowRateLimiter`.
  - `addSlidingWindowRateLimiter(maxPermits, windowDuration)` — singleton `SlidingWindowRateLimiter`.
  - `addSlidingWindowLogRateLimiter(maxPermits, windowDuration)` — singleton `SlidingWindowLogRateLimiter`.
  - `addLeakyBucketRateLimiter(capacity, leakInterval)` — singleton `LeakyBucketRateLimiter`.
  - `addConcurrencyLimiter(maxConcurrency)` — singleton `ConcurrencyLimiter`.
  - `addServerRateLimiter(limiterFactory, [acquireTimeout])` — singleton `ServerRateLimiter`. All methods use try-add semantics.

### Changed

- **Removed `meta` dependency** — `@immutable` and `@internal` annotations dropped; `final class` already enforces immutability in Dart 3.
- `davianspace_http_resilience` minimum version raised to `^1.0.3`.

---

## [1.0.0] — 2026-02-24

### Added

**Rate-limiting algorithms**

* `TokenBucketRateLimiter` — continuous token refill with configurable
  capacity, refill amount, and refill interval. Supports burst up to capacity.
  FIFO queue for blocking callers; `tryAcquire` denies requests when queued
  waiters are present to prevent starvation.
* `FixedWindowRateLimiter` — O(1) counter; window resets at a fixed cadence.
  Multi-window gap is handled correctly (no phantom counter accumulation).
* `SlidingWindowRateLimiter` (approximate) — O(1) two-bucket weighted estimate
  (`prevCount × (1 − elapsed/slot) + currCount`). Smooths spikes without
  storing per-request timestamps.
* `SlidingWindowLogRateLimiter` (exact) — O(n) `Queue<DateTime>` log;
  evicts expired entries on every access. Exact per-window counting for
  workloads that require precise enforcement.
* `LeakyBucketRateLimiter` — FIFO queue with a configurable leak timer that
  drains one entry per `leakInterval`. Limits outflow rate rather than count.
* `ConcurrencyLimiter` — semaphore-style in-flight cap. `release()` must be
  called after the guarded operation to decrement the counter. Designed for
  limiting simultaneous open connections or long-running tasks.

**Client-side pipeline integration**

* `HttpRateLimitHandler` — `DelegatingHandler` that acquires a permit before
  forwarding requests and releases it (via `release()`) in a `finally` block.
  Integrates with `davianspace_http_resilience` HTTP pipeline.
* `RateLimitPolicy` — immutable configuration holder: `limiter`,
  `acquireTimeout`, `onRejected` callback, and `respectServerHeaders` flag.
* `HttpClientBuilder.withRateLimit()` — fluent builder extension for adding
  a rate-limit handler to the resilience pipeline.
* `rateLimitHeadersPropertyKey` — well-known `HttpContext` property key for
  accessing parsed server headers after a response.

**Server-side admission control**

* `ServerRateLimiter` — framework-agnostic server gate. Manages a
  `RateLimiterRepository` of per-key limiters.
  * `tryAllow(String key)` — non-blocking admission check.
  * `allow(String key)` — async admission with optional timeout.
  * `release(String key)` — delegates to the per-key limiter's `release()`.
  * `statisticsFor(String key)` — per-key `RateLimiterStatistics` snapshot.
  * `dispose()` — disposes the repository and all managed limiters.
* `RateLimitKeyExtractor` — pluggable key-extraction interface with six
  built-in implementations:
  * `GlobalKeyExtractor` — single global bucket.
  * `IpKeyExtractor` — extracts client IP from `X-Forwarded-For`,
    `X-Real-IP`, or a configurable fallback header. Case-insensitive.
  * `UserKeyExtractor` — configurable user-identity header (default
    `x-user-id`); falls back to `'anonymous'`.
  * `RouteKeyExtractor` — per-URI-path bucket.
  * `CustomKeyExtractor` — caller-supplied `String Function(headers, uri)`.
  * `CompositeKeyExtractor` — joins two or more extractors with a separator
    for compound keys (e.g., IP + route).

**Backend / persistence layer**

* `RateLimiterRepository` — abstract interface: `getOrCreate`, `remove`,
  `removeWhere`, `dispose`. Designed for replacement with a Redis or
  distributed implementation.
* `InMemoryRateLimiterRepository` — `Map`-backed default implementation.
  `dispose()` disposes all managed limiters idempotently.

**Headers & exceptions**

* `RateLimitHeaders` — parses `X-RateLimit-Limit`, `X-RateLimit-Remaining`,
  `X-RateLimit-Reset` (Unix epoch → `Duration`), `Retry-After`, and
  `X-RateLimit-Policy`. Case-insensitive lookup. `hasRateLimitHeaders` and
  `isExhausted` convenience getters.
* `RateLimitExceededException` — structured exception with `message`,
  `limiterType`, and `retryAfter`. Thrown by all limiters when the limit is
  reached (blocking path on timeout, or non-blocking path on rejection).

**Base abstractions**

* `RateLimiter` — abstract base class for all limiters:
  `tryAcquire()`, `acquire({Duration? timeout})`, `statistics`, `release()`
  (no-op default; overridden by `ConcurrencyLimiter`), `dispose()`.
* `RateLimiterStatistics` — immutable value class: `permitsAcquired`,
  `permitsRejected`, `currentPermits`, `maxPermits`, `queueDepth`.
