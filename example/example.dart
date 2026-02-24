// ignore_for_file: avoid_print
import 'dart:async';

import 'package:davianspace_http_ratelimit/davianspace_http_ratelimit.dart';
import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';

/// ============================================================
/// davianspace_http_ratelimit — Production Usage Examples
/// ============================================================
///
/// This example demonstrates enterprise-ready patterns:
///
///  1. Token Bucket — burst-friendly client-side rate limiting
///  2. Fixed Window — simple quota enforcement
///  3. Sliding Window (counter) — approximate rolling window
///  4. Sliding Window Log — exact rolling window
///  5. Leaky Bucket — smooth output rate
///  6. Concurrency Limiter — cap in-flight requests
///  7. Server-side IP-based admission control
///  8. Server-side composite key (user + route)
///  9. Pipeline integration with HttpClientBuilder
///
/// Run with:
///   dart run example/example.dart
/// ============================================================

void main() async {
  await _example1TokenBucket();
  await _example2FixedWindow();
  await _example3SlidingWindowCounter();
  await _example4SlidingWindowLog();
  await _example5LeakyBucket();
  await _example6ConcurrencyLimiter();
  await _example7ServerSideIpRateLimit();
  await _example8ServerSideCompositeKey();
  _example9PipelineIntegration();
  print('\nAll examples completed.');
}

// ─────────────────────────────────────────────────────────────
// 1. Token Bucket — burst-friendly rate limiting
// ─────────────────────────────────────────────────────────────

Future<void> _example1TokenBucket() async {
  print('\n[Example 1] Token Bucket — burst up to capacity, then throttled');

  // Allow 100 requests/second with a burst of up to 200.
  final limiter = TokenBucketRateLimiter(
    capacity: 5,
    refillAmount: 2,
    refillInterval: const Duration(milliseconds: 100),
  );

  // Exhaust the initial burst.
  var allowed = 0;
  var rejected = 0;
  for (var i = 0; i < 8; i++) {
    if (limiter.tryAcquire()) {
      allowed++;
    } else {
      rejected++;
    }
  }
  print('  Burst phase: $allowed allowed, $rejected rejected');

  // Wait for one refill tick and try again.
  await Future<void>.delayed(const Duration(milliseconds: 120));
  if (limiter.tryAcquire()) {
    print('  After refill: 1 request allowed');
  }

  final s = limiter.statistics;
  print(
    '  Stats: acquired=${s.permitsAcquired}, '
    'rejected=${s.permitsRejected}, tokens=${s.currentPermits}',
  );
  limiter.dispose();
}

// ─────────────────────────────────────────────────────────────
// 2. Fixed Window — simple quota per time window
// ─────────────────────────────────────────────────────────────

Future<void> _example2FixedWindow() async {
  print('\n[Example 2] Fixed Window — 3 requests per 200 ms window');

  final limiter = FixedWindowRateLimiter(
    maxPermits: 3,
    windowDuration: const Duration(milliseconds: 200),
  );

  // Consume the window.
  for (var i = 1; i <= 4; i++) {
    final ok = limiter.tryAcquire();
    print('  Request $i: ${ok ? "ALLOWED" : "REJECTED (window exhausted)"}');
  }

  // Wait for the next window.
  await Future<void>.delayed(const Duration(milliseconds: 210));
  final ok = limiter.tryAcquire();
  print('  After window reset: ${ok ? "ALLOWED" : "REJECTED"}');
  limiter.dispose();
}

// ─────────────────────────────────────────────────────────────
// 3. Sliding Window Counter — approximate rolling window
// ─────────────────────────────────────────────────────────────

Future<void> _example3SlidingWindowCounter() async {
  print('\n[Example 3] Sliding Window Counter — approximate rolling window');

  // 5 requests per 500 ms rolling window.
  final limiter = SlidingWindowRateLimiter(
    maxPermits: 5,
    windowDuration: const Duration(milliseconds: 500),
  );

  var allowed = 0;
  var rejected = 0;
  for (var i = 0; i < 8; i++) {
    if (limiter.tryAcquire()) {
      allowed++;
    } else {
      rejected++;
    }
  }
  print('  $allowed allowed, $rejected rejected out of 8 attempts');

  // Partial window slide: wait ~260 ms (just over half the window).
  await Future<void>.delayed(const Duration(milliseconds: 260));
  final ok = limiter.tryAcquire();
  print(
    '  After ~half-window slide: ${ok ? "ALLOWED (window partially refreshed)" : "still REJECTED"}',
  );
  limiter.dispose();
}

// ─────────────────────────────────────────────────────────────
// 4. Sliding Window Log — exact rolling window
// ─────────────────────────────────────────────────────────────

Future<void> _example4SlidingWindowLog() async {
  print('\n[Example 4] Sliding Window Log — exact per-timestamp counting');

  // Exactly 3 requests per 300 ms rolling window.
  final limiter = SlidingWindowLogRateLimiter(
    maxPermits: 3,
    windowDuration: const Duration(milliseconds: 300),
  );

  limiter.tryAcquire(); // t=0
  limiter.tryAcquire(); // t≈0
  limiter.tryAcquire(); // t≈0 — window now full
  final rejected = !limiter.tryAcquire();
  print('  4th immediate request rejected: $rejected');

  // Wait for all three timestamps to expire.
  await Future<void>.delayed(const Duration(milliseconds: 310));
  final ok = limiter.tryAcquire();
  print('  After full window expiry: ${ok ? "ALLOWED" : "REJECTED"}');
  limiter.dispose();
}

// ─────────────────────────────────────────────────────────────
// 5. Leaky Bucket — smooth output rate
// ─────────────────────────────────────────────────────────────

Future<void> _example5LeakyBucket() async {
  print('\n[Example 5] Leaky Bucket — drains 1 request every 100 ms');

  // Queue capacity 3; one request leaks per 100 ms.
  final limiter = LeakyBucketRateLimiter(
    capacity: 3,
    leakInterval: const Duration(milliseconds: 100),
  );

  var allowed = 0;
  var rejected = 0;
  for (var i = 0; i < 5; i++) {
    if (limiter.tryAcquire()) {
      allowed++;
    } else {
      rejected++;
    }
  }
  print(
    '  Burst: $allowed queued, $rejected rejected (queue full after capacity)',
  );

  // Wait for one leak and try again.
  await Future<void>.delayed(const Duration(milliseconds: 110));
  if (limiter.tryAcquire()) {
    print('  After one leak: 1 request queued');
  }
  limiter.dispose();
}

// ─────────────────────────────────────────────────────────────
// 6. Concurrency Limiter — cap simultaneous in-flight requests
// ─────────────────────────────────────────────────────────────

Future<void> _example6ConcurrencyLimiter() async {
  print('\n[Example 6] Concurrency Limiter — at most 2 simultaneous requests');

  final limiter = ConcurrencyLimiter(maxConcurrency: 2);

  Future<void> simulateRequest(int id) async {
    print('  Request $id: acquiring...');
    await limiter.acquire();
    try {
      print('  Request $id: in-flight');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      print('  Request $id: done');
    } finally {
      limiter.release();
    }
  }

  // Launch 4 requests concurrently; only 2 run at a time.
  await Future.wait([
    simulateRequest(1),
    simulateRequest(2),
    simulateRequest(3),
    simulateRequest(4),
  ]);

  print('  Final stats: ${limiter.statistics}');
  limiter.dispose();
}

// ─────────────────────────────────────────────────────────────
// 7. Server-side IP-based admission control
// ─────────────────────────────────────────────────────────────

Future<void> _example7ServerSideIpRateLimit() async {
  print('\n[Example 7] Server-side rate limiting — per client IP');

  // Allow 5 requests per minute per IP, using a Token Bucket.
  final server = ServerRateLimiter(
    limiterFactory: () => TokenBucketRateLimiter(
      capacity: 5,
      refillAmount: 5,
      refillInterval: const Duration(minutes: 1),
    ),
    repository: InMemoryRateLimiterRepository(),
    acquireTimeout: Duration.zero, // non-blocking
  );

  const extractor = IpKeyExtractor();

  // Simulate two different client IPs.
  final headersIp1 = {'x-forwarded-for': '203.0.113.1'};
  final headersIp2 = {'x-forwarded-for': '203.0.113.2'};
  final uri = Uri.parse('https://api.example.com/data');

  for (var i = 1; i <= 6; i++) {
    final key = extractor.extractKey(headersIp1, uri);
    final allowed = server.tryAllow(key);
    print('  IP-1 request $i: ${allowed ? "ALLOWED" : "RATE LIMITED"}');
  }

  // Second IP has its own independent quota.
  final key2 = extractor.extractKey(headersIp2, uri);
  final allowed = server.tryAllow(key2);
  print(
    '  IP-2 request 1: ${allowed ? "ALLOWED (separate quota)" : "RATE LIMITED"}',
  );

  server.dispose();
}

// ─────────────────────────────────────────────────────────────
// 8. Server-side composite key — user + route
// ─────────────────────────────────────────────────────────────

Future<void> _example8ServerSideCompositeKey() async {
  print('\n[Example 8] Server-side rate limiting — user + route composite key');

  // 10 requests per minute per (user, route) pair.
  final server = ServerRateLimiter(
    limiterFactory: () => FixedWindowRateLimiter(
      maxPermits: 10,
      windowDuration: const Duration(minutes: 1),
    ),
    repository: InMemoryRateLimiterRepository(),
    acquireTimeout: Duration.zero,
  );

  // Composite key: user-id + path, joined by the default ':' separator.
  // ignore: prefer_const_constructors
  final extractor = CompositeKeyExtractor(
    [
      const UserKeyExtractor(),
      const RouteKeyExtractor(),
    ],
  );

  final headers = {'x-user-id': 'user-42'};
  final endpoint1 = Uri.parse('https://api.example.com/orders');
  final endpoint2 = Uri.parse('https://api.example.com/products');

  // Same user, different routes → different quotas.
  final key1 = extractor.extractKey(headers, endpoint1);
  final key2 = extractor.extractKey(headers, endpoint2);
  print('  Key for user-42 + /orders:   $key1');
  print('  Key for user-42 + /products: $key2');

  print('  /orders allowed: ${server.tryAllow(key1)}');
  print('  /products allowed: ${server.tryAllow(key2)}');

  server.dispose();
}

// ─────────────────────────────────────────────────────────────
// 9. Pipeline integration with HttpClientBuilder
// ─────────────────────────────────────────────────────────────

void _example9PipelineIntegration() {
  print('\n[Example 9] HttpClientBuilder.withRateLimit() pipeline integration');

  // Allow 100 req/s with a 200-burst token bucket.
  // Requests that cannot acquire a permit within 500 ms are rejected with
  // RateLimitExceededException; the onRejected callback logs the event.
  final limiter = TokenBucketRateLimiter(
    capacity: 200,
    refillAmount: 100,
    refillInterval: const Duration(seconds: 1),
  );

  final client = HttpClientBuilder()
      .withBaseUri(Uri.parse('https://api.example.com'))
      .withDefaultHeader('Accept', 'application/json')
      .withRateLimit(
        RateLimitPolicy(
          limiter: limiter,
          acquireTimeout: const Duration(milliseconds: 500),
          respectServerHeaders: true,
          onRejected: (ctx, e) {
            // ctx is typed Object? in the policy callback — cast for access.
            print('  [rate-limit] Request rejected: $e');
          },
        ),
      )
      .build();

  print('  Client built. Rate-limit handler wired into pipeline.');
  print(
    '  Limiter stats: ${limiter.statistics.currentPermits}/'
    '${limiter.statistics.maxPermits} tokens available',
  );

  // In production you would call:
  //   final response = await client.send(ctx);
  // The handler acquires a token before forwarding and releases it after.
  // When respectServerHeaders = true, parsed RateLimitHeaders are stored in
  // the HttpContext and accessible after the response:
  //   final headers = ctx.getProperty<RateLimitHeaders>(
  //     HttpRateLimitHandler.rateLimitHeadersPropertyKey,
  //   );

  client.dispose();
  limiter.dispose();
}
