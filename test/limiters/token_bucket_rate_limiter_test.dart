import 'package:davianspace_http_ratelimit/davianspace_http_ratelimit.dart';
import 'package:test/test.dart';

void main() {
  group('TokenBucketRateLimiter', () {
    // ──────────────────────────────────────────────────────────────────────
    // Construction / defaults
    // ──────────────────────────────────────────────────────────────────────
    group('construction', () {
      test('starts full (bucket = capacity)', () {
        final limiter = TokenBucketRateLimiter(
          capacity: 5,
          refillAmount: 5,
          refillInterval: const Duration(seconds: 1),
        );
        addTearDown(limiter.dispose);
        final stats = limiter.statistics;
        expect(stats.currentPermits, 5);
        expect(stats.maxPermits, 5);
      });

      test('respects custom initialTokens', () {
        final limiter = TokenBucketRateLimiter(
          capacity: 10,
          refillAmount: 5,
          refillInterval: const Duration(seconds: 1),
          initialTokens: 3,
        );
        addTearDown(limiter.dispose);
        expect(limiter.statistics.currentPermits, 3);
      });

      test('initialTokens clamps to capacity', () {
        final limiter = TokenBucketRateLimiter(
          capacity: 5,
          refillAmount: 5,
          refillInterval: const Duration(seconds: 1),
          initialTokens: 100,
        );
        addTearDown(limiter.dispose);
        expect(limiter.statistics.currentPermits, 5);
      });

      test('asserts capacity > 0', () {
        expect(
          () => TokenBucketRateLimiter(
            capacity: 0,
            refillAmount: 1,
            refillInterval: const Duration(seconds: 1),
          ),
          throwsA(isA<AssertionError>()),
        );
      });

      test('asserts refillAmount > 0', () {
        expect(
          () => TokenBucketRateLimiter(
            capacity: 10,
            refillAmount: 0,
            refillInterval: const Duration(seconds: 1),
          ),
          throwsA(isA<AssertionError>()),
        );
      });

      test('asserts refillInterval > Duration.zero', () {
        expect(
          () => TokenBucketRateLimiter(
            capacity: 10,
            refillAmount: 5,
            refillInterval: Duration.zero,
          ),
          throwsA(isA<AssertionError>()),
        );
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // tryAcquire
    // ──────────────────────────────────────────────────────────────────────
    group('tryAcquire', () {
      test('returns true when tokens available', () {
        final limiter = TokenBucketRateLimiter(
          capacity: 3,
          refillAmount: 3,
          refillInterval: const Duration(seconds: 10),
        );
        addTearDown(limiter.dispose);
        expect(limiter.tryAcquire(), isTrue);
        expect(limiter.tryAcquire(), isTrue);
        expect(limiter.tryAcquire(), isTrue);
      });

      test('returns false when bucket is empty', () {
        final limiter = TokenBucketRateLimiter(
          capacity: 2,
          refillAmount: 2,
          refillInterval: const Duration(seconds: 10),
        );
        addTearDown(limiter.dispose);
        limiter.tryAcquire();
        limiter.tryAcquire();
        expect(limiter.tryAcquire(), isFalse);
      });

      test('decrements token count', () {
        final limiter = TokenBucketRateLimiter(
          capacity: 5,
          refillAmount: 5,
          refillInterval: const Duration(seconds: 10),
        );
        addTearDown(limiter.dispose);
        limiter.tryAcquire();
        limiter.tryAcquire();
        expect(limiter.statistics.currentPermits, 3);
      });

      test('increments permitsAcquired on success', () {
        final limiter = TokenBucketRateLimiter(
          capacity: 5,
          refillAmount: 5,
          refillInterval: const Duration(seconds: 10),
        );
        addTearDown(limiter.dispose);
        limiter.tryAcquire();
        limiter.tryAcquire();
        expect(limiter.statistics.permitsAcquired, 2);
      });

      test('increments permitsRejected on failure', () {
        final limiter = TokenBucketRateLimiter(
          capacity: 1,
          refillAmount: 1,
          refillInterval: const Duration(seconds: 10),
        );
        addTearDown(limiter.dispose);
        limiter.tryAcquire();
        limiter.tryAcquire(); // rejected
        expect(limiter.statistics.permitsRejected, 1);
      });

      test('throws StateError after dispose', () {
        final limiter = TokenBucketRateLimiter(
          capacity: 5,
          refillAmount: 5,
          refillInterval: const Duration(seconds: 10),
        );
        limiter.dispose();
        expect(limiter.tryAcquire, throwsStateError);
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // acquire (immediate path)
    // ──────────────────────────────────────────────────────────────────────
    group('acquire – immediate', () {
      test('completes immediately when tokens available', () async {
        final limiter = TokenBucketRateLimiter(
          capacity: 5,
          refillAmount: 5,
          refillInterval: const Duration(seconds: 10),
        );
        addTearDown(limiter.dispose);
        await expectLater(limiter.acquire(), completes);
        expect(limiter.statistics.permitsAcquired, 1);
      });

      test('all burst tokens consumed synchronously', () async {
        final limiter = TokenBucketRateLimiter(
          capacity: 3,
          refillAmount: 3,
          refillInterval: const Duration(seconds: 10),
        );
        addTearDown(limiter.dispose);
        await limiter.acquire();
        await limiter.acquire();
        await limiter.acquire();
        expect(limiter.statistics.currentPermits, 0);
        expect(limiter.statistics.permitsAcquired, 3);
      });

      test('throws StateError after dispose', () {
        final limiter = TokenBucketRateLimiter(
          capacity: 5,
          refillAmount: 5,
          refillInterval: const Duration(seconds: 10),
        );
        limiter.dispose();
        // acquire() calls _checkDisposed() synchronously before returning
        // a Future, so the throw is synchronous.
        expect(() => limiter.acquire(), throwsStateError);
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // acquire – timeout
    // ──────────────────────────────────────────────────────────────────────
    group('acquire – timeout', () {
      test('throws RateLimitExceededException when timeout elapses', () async {
        final limiter = TokenBucketRateLimiter(
          capacity: 1,
          refillAmount: 1,
          refillInterval: const Duration(hours: 1), // effectively no refill
          initialTokens: 0,
        );
        addTearDown(limiter.dispose);

        await expectLater(
          limiter.acquire(timeout: const Duration(milliseconds: 50)),
          throwsA(
            isA<RateLimitExceededException>()
                .having((e) => e.limiterType, 'limiterType', 'TokenBucket')
                .having((e) => e.retryAfter, 'retryAfter', isNotNull),
          ),
        );
        expect(limiter.statistics.permitsRejected, 1);
      });

      test('succeeds when token becomes available before timeout', () async {
        const refillInterval = Duration(milliseconds: 80);
        final limiter = TokenBucketRateLimiter(
          capacity: 1,
          refillAmount: 1,
          refillInterval: refillInterval,
          initialTokens: 0,
        );
        addTearDown(limiter.dispose);

        // Wait up to 300 ms; refill happens at ~80 ms.
        await expectLater(
          limiter.acquire(timeout: const Duration(milliseconds: 300)),
          completes,
        );
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // Statistics
    // ──────────────────────────────────────────────────────────────────────
    group('statistics', () {
      test('initial statistics are zero counters with full bucket', () {
        final limiter = TokenBucketRateLimiter(
          capacity: 10,
          refillAmount: 10,
          refillInterval: const Duration(seconds: 1),
        );
        addTearDown(limiter.dispose);
        final s = limiter.statistics;
        expect(s.permitsAcquired, 0);
        expect(s.permitsRejected, 0);
        expect(s.currentPermits, 10);
        expect(s.maxPermits, 10);
        expect(s.queueDepth, 0);
      });

      test('queue depth reflects pending waiters', () {
        final limiter = TokenBucketRateLimiter(
          capacity: 1,
          refillAmount: 1,
          refillInterval: const Duration(hours: 1),
          initialTokens: 0,
        );

        // Fire two pending acquires; do not await them.
        // Ignore the errors from dispose() draining waiters.
        limiter.acquire().ignore();
        limiter.acquire().ignore();

        expect(limiter.statistics.queueDepth, 2);
        // Dispose inline (not via addTearDown) to avoid unhandled errors.
        limiter.dispose();
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // Dispose
    // ──────────────────────────────────────────────────────────────────────
    group('dispose', () {
      test('dispose is idempotent', () {
        final limiter = TokenBucketRateLimiter(
          capacity: 5,
          refillAmount: 5,
          refillInterval: const Duration(seconds: 1),
        );
        expect(
          () {
            limiter.dispose();
            limiter.dispose();
          },
          returnsNormally,
        );
      });

      test('pending waiters receive StateError on dispose', () async {
        final limiter = TokenBucketRateLimiter(
          capacity: 1,
          refillAmount: 1,
          refillInterval: const Duration(hours: 1),
          initialTokens: 0,
        );

        final pendingFuture = limiter.acquire();
        limiter.dispose();

        await expectLater(pendingFuture, throwsStateError);
      });
    });
  });
}
