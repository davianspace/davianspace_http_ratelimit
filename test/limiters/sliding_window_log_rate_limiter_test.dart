import 'package:davianspace_http_ratelimit/davianspace_http_ratelimit.dart';
import 'package:test/test.dart';

void main() {
  group('SlidingWindowLogRateLimiter', () {
    // ──────────────────────────────────────────────────────────────────────
    // Construction
    // ──────────────────────────────────────────────────────────────────────
    group('construction', () {
      test('starts with full capacity and empty log', () {
        final limiter = SlidingWindowLogRateLimiter(
          maxPermits: 5,
          windowDuration: const Duration(seconds: 1),
        );
        addTearDown(limiter.dispose);
        final s = limiter.statistics;
        expect(s.currentPermits, 5);
        expect(s.maxPermits, 5);
        expect(s.permitsAcquired, 0);
        expect(s.permitsRejected, 0);
      });

      test('asserts maxPermits > 0', () {
        expect(
          () => SlidingWindowLogRateLimiter(
            maxPermits: 0,
            windowDuration: const Duration(seconds: 1),
          ),
          throwsA(isA<AssertionError>()),
        );
      });

      test('asserts windowDuration > Duration.zero', () {
        expect(
          () => SlidingWindowLogRateLimiter(
            maxPermits: 5,
            windowDuration: Duration.zero,
          ),
          throwsA(isA<AssertionError>()),
        );
      });

      test('asserts pollInterval > Duration.zero', () {
        expect(
          () => SlidingWindowLogRateLimiter(
            maxPermits: 5,
            windowDuration: const Duration(seconds: 1),
            pollInterval: Duration.zero,
          ),
          throwsA(isA<AssertionError>()),
        );
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // tryAcquire
    // ──────────────────────────────────────────────────────────────────────
    group('tryAcquire', () {
      test('admits requests up to maxPermits', () {
        final limiter = SlidingWindowLogRateLimiter(
          maxPermits: 3,
          windowDuration: const Duration(seconds: 10),
        );
        addTearDown(limiter.dispose);
        expect(limiter.tryAcquire(), isTrue);
        expect(limiter.tryAcquire(), isTrue);
        expect(limiter.tryAcquire(), isTrue);
      });

      test('rejects when log is saturated', () {
        final limiter = SlidingWindowLogRateLimiter(
          maxPermits: 2,
          windowDuration: const Duration(seconds: 10),
        );
        addTearDown(limiter.dispose);
        limiter.tryAcquire();
        limiter.tryAcquire();
        expect(limiter.tryAcquire(), isFalse);
      });

      test('tracks permitsAcquired and permitsRejected', () {
        final limiter = SlidingWindowLogRateLimiter(
          maxPermits: 2,
          windowDuration: const Duration(seconds: 10),
        );
        addTearDown(limiter.dispose);
        limiter.tryAcquire();
        limiter.tryAcquire();
        limiter.tryAcquire(); // rejected
        final s = limiter.statistics;
        expect(s.permitsAcquired, 2);
        expect(s.permitsRejected, 1);
      });

      test('currentPermits decrements as log fills', () {
        final limiter = SlidingWindowLogRateLimiter(
          maxPermits: 5,
          windowDuration: const Duration(seconds: 10),
        );
        addTearDown(limiter.dispose);
        limiter.tryAcquire();
        limiter.tryAcquire();
        expect(limiter.statistics.currentPermits, 3);
      });

      test('old timestamps expire and capacity is restored', () async {
        const windowDuration = Duration(milliseconds: 100);
        final limiter = SlidingWindowLogRateLimiter(
          maxPermits: 2,
          windowDuration: windowDuration,
          pollInterval: const Duration(milliseconds: 10),
        );
        addTearDown(limiter.dispose);

        limiter.tryAcquire();
        limiter.tryAcquire();
        expect(limiter.tryAcquire(), isFalse);

        await Future<void>.delayed(const Duration(milliseconds: 150));

        expect(
          limiter.tryAcquire(),
          isTrue,
          reason: 'expired timestamps must free capacity',
        );
      });

      test('throws StateError after dispose', () {
        final limiter = SlidingWindowLogRateLimiter(
          maxPermits: 5,
          windowDuration: const Duration(seconds: 10),
        );
        limiter.dispose();
        expect(limiter.tryAcquire, throwsStateError);
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // acquire – immediate
    // ──────────────────────────────────────────────────────────────────────
    group('acquire – immediate', () {
      test('completes immediately when capacity available', () async {
        final limiter = SlidingWindowLogRateLimiter(
          maxPermits: 5,
          windowDuration: const Duration(seconds: 10),
        );
        addTearDown(limiter.dispose);
        await expectLater(limiter.acquire(), completes);
        expect(limiter.statistics.permitsAcquired, 1);
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // acquire – blocking
    // ──────────────────────────────────────────────────────────────────────
    group('acquire – waits for capacity', () {
      test('acquires after timestamps expire', () async {
        const windowDuration = Duration(milliseconds: 100);
        final limiter = SlidingWindowLogRateLimiter(
          maxPermits: 1,
          windowDuration: windowDuration,
          pollInterval: const Duration(milliseconds: 20),
        );
        addTearDown(limiter.dispose);
        limiter.tryAcquire();

        await expectLater(
          limiter.acquire(timeout: const Duration(milliseconds: 300)),
          completes,
        );
        expect(limiter.statistics.permitsAcquired, 2);
      });

      test('throws RateLimitExceededException on timeout', () async {
        final limiter = SlidingWindowLogRateLimiter(
          maxPermits: 1,
          windowDuration: const Duration(hours: 1),
          pollInterval: const Duration(milliseconds: 20),
        );
        addTearDown(limiter.dispose);
        limiter.tryAcquire();

        await expectLater(
          limiter.acquire(timeout: const Duration(milliseconds: 60)),
          throwsA(
            isA<RateLimitExceededException>().having(
              (e) => e.limiterType,
              'limiterType',
              'SlidingWindowLog',
            ),
          ),
        );
        expect(limiter.statistics.permitsRejected, 1);
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // No boundary burst (exact timestamps — unlike Fixed Window)
    // ──────────────────────────────────────────────────────────────────────
    group('no edge burst', () {
      test('cannot burst 2x at window boundary', () async {
        const windowDuration = Duration(milliseconds: 120);
        final limiter = SlidingWindowLogRateLimiter(
          maxPermits: 3,
          windowDuration: windowDuration,
          pollInterval: const Duration(milliseconds: 10),
        );
        addTearDown(limiter.dispose);

        limiter.tryAcquire();
        limiter.tryAcquire();
        limiter.tryAcquire();
        expect(limiter.tryAcquire(), isFalse);

        // Timestamps not yet expired  — still within 120 ms window.
        await Future<void>.delayed(const Duration(milliseconds: 70));
        expect(
          limiter.tryAcquire(),
          isFalse,
          reason: 'oldest timestamp still within the window',
        );
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // Dispose
    // ──────────────────────────────────────────────────────────────────────
    group('dispose', () {
      test('is safe to call twice', () {
        final limiter = SlidingWindowLogRateLimiter(
          maxPermits: 5,
          windowDuration: const Duration(seconds: 1),
        );
        limiter.tryAcquire();
        expect(
          () {
            limiter.dispose();
            limiter.dispose();
          },
          returnsNormally,
        );
      });

      test('tryAcquire throws StateError after dispose', () {
        final limiter = SlidingWindowLogRateLimiter(
          maxPermits: 5,
          windowDuration: const Duration(seconds: 10),
        );
        limiter.dispose();
        expect(limiter.tryAcquire, throwsStateError);
      });
    });
  });
}
