import 'package:davianspace_http_ratelimit/davianspace_http_ratelimit.dart';
import 'package:test/test.dart';

void main() {
  group('SlidingWindowRateLimiter', () {
    // ──────────────────────────────────────────────────────────────────────
    // Construction
    // ──────────────────────────────────────────────────────────────────────
    group('construction', () {
      test('creates limiter with empty window', () {
        final limiter = SlidingWindowRateLimiter(
          maxPermits: 5,
          windowDuration: const Duration(seconds: 1),
        );
        addTearDown(limiter.dispose);
        final s = limiter.statistics;
        expect(s.currentPermits, 5);
        expect(s.maxPermits, 5);
        expect(s.permitsAcquired, 0);
      });

      test('asserts maxPermits > 0', () {
        expect(
          () => SlidingWindowRateLimiter(
            maxPermits: 0,
            windowDuration: const Duration(seconds: 1),
          ),
          throwsA(isA<AssertionError>()),
        );
      });

      test('asserts windowDuration > Duration.zero', () {
        expect(
          () => SlidingWindowRateLimiter(
            maxPermits: 5,
            windowDuration: Duration.zero,
          ),
          throwsA(isA<AssertionError>()),
        );
      });

      test('asserts pollInterval > Duration.zero', () {
        expect(
          () => SlidingWindowRateLimiter(
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
        final limiter = SlidingWindowRateLimiter(
          maxPermits: 3,
          windowDuration: const Duration(seconds: 10),
        );
        addTearDown(limiter.dispose);
        expect(limiter.tryAcquire(), isTrue);
        expect(limiter.tryAcquire(), isTrue);
        expect(limiter.tryAcquire(), isTrue);
      });

      test('rejects when window is saturated', () {
        final limiter = SlidingWindowRateLimiter(
          maxPermits: 2,
          windowDuration: const Duration(seconds: 10),
        );
        addTearDown(limiter.dispose);
        limiter.tryAcquire();
        limiter.tryAcquire();
        expect(limiter.tryAcquire(), isFalse);
      });

      test('tracks permitsAcquired and permitsRejected', () {
        final limiter = SlidingWindowRateLimiter(
          maxPermits: 2,
          windowDuration: const Duration(seconds: 10),
        );
        addTearDown(limiter.dispose);
        limiter.tryAcquire(); // ok
        limiter.tryAcquire(); // ok
        limiter.tryAcquire(); // rejected
        final s = limiter.statistics;
        expect(s.permitsAcquired, 2);
        expect(s.permitsRejected, 1);
      });

      test('currentPermits decrements as log fills', () {
        final limiter = SlidingWindowRateLimiter(
          maxPermits: 5,
          windowDuration: const Duration(seconds: 10),
        );
        addTearDown(limiter.dispose);
        limiter.tryAcquire();
        limiter.tryAcquire();
        expect(limiter.statistics.currentPermits, 3);
      });

      test('old entries expire and capacity is restored', () async {
        const windowDuration = Duration(milliseconds: 100);
        final limiter = SlidingWindowRateLimiter(
          maxPermits: 2,
          windowDuration: windowDuration,
          pollInterval: const Duration(milliseconds: 10),
        );
        addTearDown(limiter.dispose);

        limiter.tryAcquire();
        limiter.tryAcquire();
        expect(limiter.tryAcquire(), isFalse); // saturated

        // Wait for the window to slide past the old timestamps.
        await Future<void>.delayed(const Duration(milliseconds: 150));

        expect(
          limiter.tryAcquire(),
          isTrue,
          reason: 'expired timestamps should free capacity',
        );
      });

      test('throws StateError after dispose', () {
        final limiter = SlidingWindowRateLimiter(
          maxPermits: 5,
          windowDuration: const Duration(seconds: 10),
        );
        limiter.dispose();
        expect(limiter.tryAcquire, throwsStateError);
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // acquire – immediate path
    // ──────────────────────────────────────────────────────────────────────
    group('acquire – immediate', () {
      test('completes immediately when capacity available', () async {
        final limiter = SlidingWindowRateLimiter(
          maxPermits: 5,
          windowDuration: const Duration(seconds: 10),
        );
        addTearDown(limiter.dispose);
        await expectLater(limiter.acquire(), completes);
        expect(limiter.statistics.permitsAcquired, 1);
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // acquire – blocking until capacity (short window)
    // ──────────────────────────────────────────────────────────────────────
    group('acquire – waits for capacity', () {
      test('acquires after old entries expire', () async {
        const windowDuration = Duration(milliseconds: 100);
        final limiter = SlidingWindowRateLimiter(
          maxPermits: 1,
          windowDuration: windowDuration,
          pollInterval: const Duration(milliseconds: 20),
        );
        addTearDown(limiter.dispose);
        limiter.tryAcquire(); // fill window

        // Should complete once the 100 ms window rolls past the entry.
        await expectLater(
          limiter.acquire(timeout: const Duration(milliseconds: 300)),
          completes,
        );
        expect(limiter.statistics.permitsAcquired, 2);
      });

      test('throws RateLimitExceededException on timeout', () async {
        final limiter = SlidingWindowRateLimiter(
          maxPermits: 1,
          windowDuration: const Duration(hours: 1), // very long window
          pollInterval: const Duration(milliseconds: 20),
        );
        addTearDown(limiter.dispose);
        limiter.tryAcquire(); // fill window

        await expectLater(
          limiter.acquire(timeout: const Duration(milliseconds: 60)),
          throwsA(
            isA<RateLimitExceededException>()
                .having((e) => e.limiterType, 'limiterType', 'SlidingWindow'),
          ),
        );
        expect(limiter.statistics.permitsRejected, 1);
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // No boundary burst (key differentiator vs FixedWindow)
    // ──────────────────────────────────────────────────────────────────────
    group('no edge burst', () {
      test('cannot burst 2× at window boundary', () async {
        // With a fixed window you could: exhaust one window, wait for the next,
        // and immediately fire maxPermits again = 2× in rapid succession.
        // The sliding window prevents this because the earlier timestamps are
        // still within the rolling window at the transition point.
        const windowDuration = Duration(milliseconds: 120);
        final limiter = SlidingWindowRateLimiter(
          maxPermits: 3,
          windowDuration: windowDuration,
          pollInterval: const Duration(milliseconds: 10),
        );
        addTearDown(limiter.dispose);

        // Exhaust just before the midpoint of the window.
        limiter.tryAcquire();
        limiter.tryAcquire();
        limiter.tryAcquire();
        expect(limiter.tryAcquire(), isFalse);

        // Wait for slightly more than half the window — old entries not gone.
        await Future<void>.delayed(const Duration(milliseconds: 70));
        expect(
          limiter.tryAcquire(),
          isFalse,
          reason: 'oldest timestamp still in window',
        );
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // Dispose
    // ──────────────────────────────────────────────────────────────────────
    group('dispose', () {
      test('dispose clears log and is safe to call twice', () {
        final limiter = SlidingWindowRateLimiter(
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
        final limiter = SlidingWindowRateLimiter(
          maxPermits: 5,
          windowDuration: const Duration(seconds: 10),
        );
        limiter.dispose();
        expect(limiter.tryAcquire, throwsStateError);
      });
    });
  });
}
