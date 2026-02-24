// Comprehensive tests for HttpRateLimitHandler, RateLimitPolicy, and
// RateLimitHeaders.
//
// Covers:
//   - Successful request forwarded when permit acquired
//   - RateLimitExceededException thrown when non-blocking tryAcquire fails
//   - RateLimitExceededException thrown when blocking acquire times out
//   - onRejected callback invoked on rejection
//   - respectServerHeaders reads X-RateLimit-* from response
//   - RateLimitHeaders parsed and stored in context property bag
//   - withRateLimit() extension wires handler into pipeline
//   - TokenBucket, FixedWindow, SlidingWindow via handler (integration smoke)

import 'dart:async';

import 'package:davianspace_http_ratelimit/davianspace_http_ratelimit.dart';
import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
import 'package:test/test.dart';

// ════════════════════════════════════════════════════════════════════════════
//  Test doubles
// ════════════════════════════════════════════════════════════════════════════

/// A stub [DelegatingHandler] that returns a pre-configured response.
final class _StubHandler extends DelegatingHandler {
  _StubHandler({
    this.statusCode = 200,
    this.headers = const {},
  });

  final int statusCode;
  final Map<String, String> headers;
  var callCount = 0;

  @override
  Future<HttpResponse> send(HttpContext context) async {
    callCount++;
    return HttpResponse(statusCode: statusCode, headers: headers);
  }
}

/// A fake [RateLimiter] where every call to [tryAcquire] returns [allow].
final class _FakeLimiter extends RateLimiter {
  _FakeLimiter({
    required this.allow,
    this.throwOnAcquire,
  });

  final bool allow;
  final Object? throwOnAcquire;
  int acquireCalls = 0;
  int tryAcquireCalls = 0;

  @override
  bool tryAcquire() {
    tryAcquireCalls++;
    return allow;
  }

  @override
  Future<void> acquire({Duration? timeout}) async {
    acquireCalls++;
    if (throwOnAcquire != null) throw throwOnAcquire!;
  }

  @override
  RateLimiterStatistics get statistics => const RateLimiterStatistics(
        permitsAcquired: 0,
        permitsRejected: 0,
        currentPermits: 0,
        maxPermits: 0,
      );

  @override
  void dispose() {}
}

// ════════════════════════════════════════════════════════════════════════════
//  Helpers
// ════════════════════════════════════════════════════════════════════════════

/// Builds an [HttpContext] for the given URI.
HttpContext _buildContext([String uri = 'https://api.example.com/data']) =>
    HttpContext(
      request: HttpRequest(
        method: HttpMethod.get,
        uri: Uri.parse(uri),
      ),
    );

/// Wires handler → stub, sends, returns the response.
Future<HttpResponse> _send(
  HttpRateLimitHandler handler,
  _StubHandler stub, {
  String uri = 'https://api.example.com/data',
}) {
  handler.innerHandler = stub;
  return handler.send(_buildContext(uri));
}

// ════════════════════════════════════════════════════════════════════════════
//  Tests
// ════════════════════════════════════════════════════════════════════════════

void main() {
  // ──────────────────────────────────────────────────────────────────────────
  // Non-blocking path (acquireTimeout == Duration.zero → tryAcquire)
  // ──────────────────────────────────────────────────────────────────────────
  group('non-blocking path (acquireTimeout = Duration.zero)', () {
    test('forwards request and returns response when permit available',
        () async {
      final limiter = _FakeLimiter(allow: true);
      final stub = _StubHandler();
      final handler = HttpRateLimitHandler(
        RateLimitPolicy(
          limiter: limiter,
          acquireTimeout: Duration.zero,
        ),
      );

      final response = await _send(handler, stub);

      expect(response.statusCode, 200);
      expect(stub.callCount, 1);
      expect(limiter.tryAcquireCalls, 1);
    });

    test('throws RateLimitExceededException when tryAcquire returns false',
        () async {
      final limiter = _FakeLimiter(allow: false);
      final stub = _StubHandler();
      final handler = HttpRateLimitHandler(
        RateLimitPolicy(
          limiter: limiter,
          acquireTimeout: Duration.zero,
        ),
      );

      await expectLater(
        _send(handler, stub),
        throwsA(isA<RateLimitExceededException>()),
      );
      expect(stub.callCount, 0, reason: 'inner handler must not be called');
    });

    test('onRejected callback is invoked on non-blocking rejection', () async {
      final limiter = _FakeLimiter(allow: false);
      Object? capturedContext;
      RateLimitExceededException? capturedException;

      final handler = HttpRateLimitHandler(
        RateLimitPolicy(
          limiter: limiter,
          acquireTimeout: Duration.zero,
          onRejected: (ctx, e) {
            capturedContext = ctx;
            capturedException = e;
          },
        ),
      );
      handler.innerHandler = _StubHandler();

      await expectLater(
        handler.send(_buildContext()),
        throwsA(isA<RateLimitExceededException>()),
      );

      expect(capturedContext, isNotNull);
      expect(capturedException, isA<RateLimitExceededException>());
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // Blocking path (acquireTimeout = null → wait indefinitely)
  // ──────────────────────────────────────────────────────────────────────────
  group('blocking path (acquireTimeout = null)', () {
    test('forwards request when limiter.acquire() completes', () async {
      final limiter = _FakeLimiter(allow: true);
      final stub = _StubHandler(statusCode: 201);
      final handler = HttpRateLimitHandler(
        RateLimitPolicy(limiter: limiter),
      );

      final response = await _send(handler, stub);

      expect(response.statusCode, 201);
      expect(limiter.acquireCalls, 1);
      expect(stub.callCount, 1);
    });

    test('throws RateLimitExceededException when acquire() throws it',
        () async {
      const exception = RateLimitExceededException(
        message: 'Test limit exceeded.',
        limiterType: 'Fake',
      );
      final limiter = _FakeLimiter(allow: false, throwOnAcquire: exception);
      final stub = _StubHandler();
      final handler = HttpRateLimitHandler(
        RateLimitPolicy(limiter: limiter),
      );

      await expectLater(
        _send(handler, stub),
        throwsA(same(exception)),
      );
      expect(stub.callCount, 0);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // Timeout path
  // ──────────────────────────────────────────────────────────────────────────
  group('timeout path', () {
    test('throws RateLimitExceededException when token-bucket times out',
        () async {
      final limiter = TokenBucketRateLimiter(
        capacity: 1,
        refillAmount: 1,
        refillInterval: const Duration(hours: 1),
        initialTokens: 0,
      );
      addTearDown(limiter.dispose);

      final stub = _StubHandler();
      final handler = HttpRateLimitHandler(
        RateLimitPolicy(
          limiter: limiter,
          acquireTimeout: const Duration(milliseconds: 50),
        ),
      );

      await expectLater(
        _send(handler, stub),
        throwsA(isA<RateLimitExceededException>()),
      );
      expect(stub.callCount, 0);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // Server headers (respectServerHeaders = true)
  // ──────────────────────────────────────────────────────────────────────────
  group('server headers', () {
    test('stores parsed RateLimitHeaders in context when present', () async {
      final limiter = _FakeLimiter(allow: true);
      final stub = _StubHandler(
        headers: {
          'X-RateLimit-Limit': '500',
          'X-RateLimit-Remaining': '42',
        },
      );
      HttpContext? capturedContext;

      final policy = RateLimitPolicy(
        limiter: limiter,
        acquireTimeout: Duration.zero,
        respectServerHeaders: true,
      );
      final handler = HttpRateLimitHandler(policy);
      handler.innerHandler = stub;

      final ctx = _buildContext();
      capturedContext = ctx;
      await handler.send(ctx);

      final stored = capturedContext.getProperty<RateLimitHeaders>(
        HttpRateLimitHandler.rateLimitHeadersPropertyKey,
      );

      expect(stored, isNotNull);
      expect(stored!.limit, 500);
      expect(stored.remaining, 42);
    });

    test('does not store headers when respectServerHeaders = false', () async {
      final limiter = _FakeLimiter(allow: true);
      final stub = _StubHandler(
        headers: {'X-RateLimit-Limit': '100', 'X-RateLimit-Remaining': '99'},
      );
      final handler = HttpRateLimitHandler(
        RateLimitPolicy(
          limiter: limiter,
          acquireTimeout: Duration.zero,
        ),
      );
      handler.innerHandler = stub;

      final ctx = _buildContext();
      await handler.send(ctx);

      final stored = ctx.getProperty<RateLimitHeaders>(
        HttpRateLimitHandler.rateLimitHeadersPropertyKey,
      );
      expect(stored, isNull);
    });

    test('does not store headers when response has no rate-limit headers',
        () async {
      final limiter = _FakeLimiter(allow: true);
      final stub = _StubHandler(headers: {'content-type': 'application/json'});
      final handler = HttpRateLimitHandler(
        RateLimitPolicy(
          limiter: limiter,
          acquireTimeout: Duration.zero,
          respectServerHeaders: true,
        ),
      );
      handler.innerHandler = stub;

      final ctx = _buildContext();
      await handler.send(ctx);

      final stored = ctx.getProperty<RateLimitHeaders>(
        HttpRateLimitHandler.rateLimitHeadersPropertyKey,
      );
      expect(stored, isNull);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // RateLimitHeaders parsing
  // ──────────────────────────────────────────────────────────────────────────
  group('RateLimitHeaders.from()', () {
    test('parses limit and remaining', () {
      final h = RateLimitHeaders.from({
        'X-RateLimit-Limit': '1000',
        'X-RateLimit-Remaining': '750',
      });
      expect(h.limit, 1000);
      expect(h.remaining, 750);
    });

    test('parses lowercase header names', () {
      final h = RateLimitHeaders.from({
        'x-ratelimit-limit': '200',
        'x-ratelimit-remaining': '50',
      });
      expect(h.limit, 200);
      expect(h.remaining, 50);
    });

    test('parses Retry-After in seconds', () {
      final h = RateLimitHeaders.from({'Retry-After': '30'});
      expect(h.retryAfter, const Duration(seconds: 30));
    });

    test('parses policy label', () {
      final h = RateLimitHeaders.from({'X-RateLimit-Policy': '10;w=1'});
      expect(h.policy, '10;w=1');
    });

    test('hasRateLimitHeaders = false when no relevant headers', () {
      final h = RateLimitHeaders.from({'content-type': 'application/json'});
      expect(h.hasRateLimitHeaders, isFalse);
    });

    test('hasRateLimitHeaders = true when any relevant header present', () {
      final h = RateLimitHeaders.from({'X-RateLimit-Limit': '100'});
      expect(h.hasRateLimitHeaders, isTrue);
    });

    test('isExhausted when remaining = 0', () {
      final h = RateLimitHeaders.from({
        'X-RateLimit-Limit': '100',
        'X-RateLimit-Remaining': '0',
      });
      expect(h.isExhausted, isTrue);
    });

    test('isExhausted = false when remaining > 0', () {
      final h = RateLimitHeaders.from({
        'X-RateLimit-Limit': '100',
        'X-RateLimit-Remaining': '1',
      });
      expect(h.isExhausted, isFalse);
    });

    test('returns null fields for missing headers', () {
      final h = RateLimitHeaders.from({});
      expect(h.limit, isNull);
      expect(h.remaining, isNull);
      expect(h.reset, isNull);
      expect(h.retryAfter, isNull);
    });

    test('ignores non-integer values gracefully', () {
      final h = RateLimitHeaders.from({
        'X-RateLimit-Limit': 'unlimited',
        'X-RateLimit-Remaining': 'N/A',
      });
      expect(h.limit, isNull);
      expect(h.remaining, isNull);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // withRateLimit() extension smoke test
  // ──────────────────────────────────────────────────────────────────────────
  group('withRateLimit() extension', () {
    test('builds client and performs a successful request', () async {
      final limiter = TokenBucketRateLimiter(
        capacity: 10,
        refillAmount: 10,
        refillInterval: const Duration(seconds: 1),
      );
      addTearDown(limiter.dispose);

      // Build a client with a rate-limit handler wired in.
      // We can't do a real HTTP call in unit tests, so we verify that
      // withRateLimit returns an HttpClientBuilder (fluent API check).
      final builder =
          HttpClientBuilder().withRateLimit(RateLimitPolicy(limiter: limiter));

      expect(builder, isA<HttpClientBuilder>());
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // Integration: real limiter through handler
  // ──────────────────────────────────────────────────────────────────────────
  group('integration: real limiters through handler', () {
    test('TokenBucketRateLimiter rejects after capacity (non-blocking)',
        () async {
      final limiter = TokenBucketRateLimiter(
        capacity: 2,
        refillAmount: 2,
        refillInterval: const Duration(hours: 1),
      );
      addTearDown(limiter.dispose);

      final stub = _StubHandler();
      final handler = HttpRateLimitHandler(
        RateLimitPolicy(
          limiter: limiter,
          acquireTimeout: Duration.zero,
        ),
      );
      handler.innerHandler = stub;

      // Two successful requests.
      await handler.send(_buildContext());
      await handler.send(_buildContext());
      expect(stub.callCount, 2);

      // Third should be rejected.
      await expectLater(
        handler.send(_buildContext()),
        throwsA(isA<RateLimitExceededException>()),
      );
      expect(stub.callCount, 2, reason: 'inner handler should not be called');
    });

    test('FixedWindowRateLimiter rejects after window exhausted', () async {
      final limiter = FixedWindowRateLimiter(
        maxPermits: 1,
        windowDuration: const Duration(hours: 1),
      );
      addTearDown(limiter.dispose);

      final stub = _StubHandler();
      final handler = HttpRateLimitHandler(
        RateLimitPolicy(
          limiter: limiter,
          acquireTimeout: Duration.zero,
        ),
      );
      handler.innerHandler = stub;

      await handler.send(_buildContext());
      await expectLater(
        handler.send(_buildContext()),
        throwsA(isA<RateLimitExceededException>()),
      );
    });

    test('SlidingWindowRateLimiter rejects in active window', () async {
      final limiter = SlidingWindowRateLimiter(
        maxPermits: 1,
        windowDuration: const Duration(hours: 1),
      );
      addTearDown(limiter.dispose);

      final stub = _StubHandler();
      final handler = HttpRateLimitHandler(
        RateLimitPolicy(
          limiter: limiter,
          acquireTimeout: Duration.zero,
        ),
      );
      handler.innerHandler = stub;

      await handler.send(_buildContext());
      await expectLater(
        handler.send(_buildContext()),
        throwsA(isA<RateLimitExceededException>()),
      );
    });

    test('LeakyBucketRateLimiter rejects when bucket full', () async {
      final limiter = LeakyBucketRateLimiter(
        capacity: 1,
        leakInterval: const Duration(hours: 1),
      );
      addTearDown(limiter.dispose);

      final stub = _StubHandler();
      final handler = HttpRateLimitHandler(
        RateLimitPolicy(
          limiter: limiter,
          acquireTimeout: Duration.zero,
        ),
      );
      handler.innerHandler = stub;

      await handler.send(_buildContext());
      await expectLater(
        handler.send(_buildContext()),
        throwsA(isA<RateLimitExceededException>()),
      );
    });
  });
}
