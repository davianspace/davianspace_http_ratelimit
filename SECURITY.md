# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 1.0.x   | Yes       |
| < 1.0   | No        |

Only the latest patch release of each supported minor version receives
security updates.

---

## Reporting a Vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Instead, please report security concerns privately:

1. **Email**: Send a detailed report to the maintainers via the contact
   information listed on the [pub.dev package page](https://pub.dev/packages/davianspace_http_ratelimit).
2. **GitHub Private Reporting**: Use GitHub's
   [private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
   feature on this repository (if enabled).

### What to Include

- Description of the vulnerability.
- Steps to reproduce.
- Potential impact assessment (availability, data integrity, bypass vector).
- Suggested fix (if any).
- Your contact information for follow-up.

### Response Timeline

| Action | Timeline |
|--------|----------|
| Acknowledgement | Within 48 hours |
| Initial assessment | Within 5 business days |
| Fix development | Depends on severity |
| Patch release | As soon as fix is verified |
| Public disclosure | After patch is released |

---

## Security Considerations for Rate Limiting

Deploying a rate limiter correctly requires awareness of several threat
vectors. The following guidance applies to users of this package.

### IP Header Spoofing

`IpKeyExtractor` reads `X-Forwarded-For` and `X-Real-IP` headers to derive a
client key. These headers **can be forged** by an attacker unless your
infrastructure (load balancer, reverse proxy) strips and re-writes them.

**Recommendations:**

- Trust `X-Forwarded-For` only when it is set by a trusted proxy you control.
- Consider using `CustomKeyExtractor` to extract the IP from a header that
  your load balancer guarantees (e.g., a signed header).
- Rate-limit at the reverse-proxy layer in addition to the application layer
  for defence-in-depth.

### Memory Exhaustion via Key Space

`InMemoryRateLimiterRepository` creates one limiter per unique key. An
attacker who can generate unbounded unique keys (e.g., random UUIDs in a
user-ID header) can exhaust heap memory.

**Recommendations:**

- Apply coarse-grained IP-based limiting before user-ID-based limiting to
  reject unauthenticated traffic early.
- Set a maximum key-count limit in a custom `RateLimiterRepository`
  implementation and return HTTP 429 when the limit is exceeded.
- Monitor `RateLimiterRepository` size in production and alert on anomalous
  growth.

### Race Conditions in Distributed Environments

`InMemoryRateLimiterRepository` is single-process only. In a horizontally
scaled deployment, each instance has its own state; rate limits are enforced
per-pod, not globally.

**Recommendations:**

- For global rate limiting across replicas, implement `RateLimiterRepository`
  backed by Redis (with Lua scripts or `INCR`/`EXPIRE` for atomicity) or
  another distributed store.
- In Kubernetes, route a given client to the same pod using session affinity
  if per-pod limits are acceptable.

### Bypass via `tryAcquire` After Disposed Limiter

Calling `tryAcquire()` or `acquire()` on a disposed limiter throws a
`StateError`. Callers must not catch `StateError` and treat it as a
pass-through permit; treat it as an application error requiring investigation.

### Concurrency Limiter `release()` Obligation

`ConcurrencyLimiter.release()` must be called exactly once per successful
`acquire()`. Missing a `release()` call permanently reduces available
concurrency; called extra times it may grant excess permits. Always wrap
guarded operations in `try/finally`:

```dart
await limiter.acquire();
try {
  await performWork();
} finally {
  limiter.release();
}
```

`HttpRateLimitHandler` performs this automatically via its `finally` block.

---

## Security Measures in This Package

### No Persistent Storage of Request Data

No request headers, IP addresses, URIs, or user identifiers are persisted to
disk. The `InMemoryRateLimiterRepository` holds only counters and timestamps
in heap memory, which are released when the limiter is disposed.

### No Outbound Network Calls

This package performs no outbound HTTP calls, telemetry, or analytics. All
state is local to the process.

### Strict Static Analysis

The codebase is compiled with `strict-casts`, `strict-inference`, and
`strict-raw-types` enabled. All public API is null-safe (`>=3.0.0`).
