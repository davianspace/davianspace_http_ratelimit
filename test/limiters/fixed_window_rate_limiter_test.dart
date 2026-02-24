import 'package:davianspace_http_ratelimit/davianspace_http_ratelimit.dart';
import 'package:test/test.dart';

void main() {
  group('FixedWindowRateLimiter', () {
    // ──────────────────────────────────────────────────────────────────────
    // Construction
    // ──────────────────────────────────────────────────────────────────────
    group('construction', () {
      test('creates limiter with full initial permits', () {
        final limiter = FixedWindowRateLimiter(
          maxPermits: 5,
          windowDuration: const Duration(seconds: 1),
        );
        addTearDown(limiter.dispose);
        expect(limiter.statistics.currentPermits, 5);
        expect(limiter.statistics.maxPermits, 5);
      });

      test('asserts maxPermits > 0', () {
        expect(
          () => FixedWindowRateLimiter(
            maxPermits: 0,
            windowDuration: const Duration(seconds: 1),
          ),
          throwsA(isA<AssertionError>()),
        );
      });

      test('asserts windowDuration > Duration.zero', () {
        expect(
          () => FixedWindowRateLimiter(
            maxPermits: 5,
            windowDuration: Duration.zero,
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
        final limiter = FixedWindowRateLimiter(
          maxPermits: 3,
          windowDuration: const Duration(seconds: 10),
        );
        addTearDown(limiter.dispose);
        expect(limiter.tryAcquire(), isTrue);
        expect(limiter.tryAcquire(), isTrue);
        expect(limiter.tryAcquire(), isTrue);
      });

      test('rejects when limit reached', () {
        final limiter = FixedWindowRateLimiter(
          maxPermits: 2,
          windowDuration: const Duration(seconds: 10),
        );
        addTearDown(limiter.dispose);
        limiter.tryAcquire();
        limiter.tryAcquire();
        expect(limiter.tryAcquire(), isFalse);
      });

      test('decrements currentPermits', () {
        final limiter = FixedWindowRateLimiter(
          maxPermits: 5,
          windowDuration: const Duration(seconds: 10),
        );
        addTearDown(limiter.dispose);
        limiter.tryAcquire();
        limiter.tryAcquire();
        expect(limiter.statistics.currentPermits, 3);
      });

      test('tracks permitsAcquired and permitsRejected', () {
        final limiter = FixedWindowRateLimiter(
          maxPermits: 2,
          windowDuration: const Duration(seconds: 10),
        );
        addTearDown(limiter.dispose);
        limiter.tryAcquire(); // acquired
        limiter.tryAcquire(); // acquired
        limiter.tryAcquire(); // rejected
        final s = limiter.statistics;
        expect(s.permitsAcquired, 2);
        expect(s.permitsRejected, 1);
      });

      test('throws StateError after dispose', () {
        final limiter = FixedWindowRateLimiter(
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
      test('completes immediately when permits available', () async {
        final limiter = FixedWindowRateLimiter(
          maxPermits: 5,
          windowDuration: const Duration(seconds: 10),
        );
        addTearDown(limiter.dispose);
        await expectLater(limiter.acquire(), completes);
        expect(limiter.statistics.permitsAcquired, 1);
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // acquire – timeout path (real time, short window)
    // ──────────────────────────────────────────────────────────────────────
    group('acquire – timeout', () {
      test('throws RateLimitExceededException when timeout expires', () async {
        final limiter = FixedWindowRateLimiter(
          maxPermits: 1,
          // Large window so it won't reset during the test.
          windowDuration: const Duration(hours: 1),
        );
        addTearDown(limiter.dispose);
        limiter.tryAcquire(); // exhaust the window

        await expectLater(
          limiter.acquire(timeout: const Duration(milliseconds: 50)),
          throwsA(
            isA<RateLimitExceededException>()
                .having((e) => e.limiterType, 'limiterType', 'FixedWindow')
                .having((e) => e.retryAfter, 'retryAfter', isNotNull),
          ),
        );
        expect(limiter.statistics.permitsRejected, 1);
      });

      test('acquires when new window opens before timeout', () async {
        const windowDuration = Duration(milliseconds: 80);
        final limiter = FixedWindowRateLimiter(
          maxPermits: 1,
          windowDuration: windowDuration,
        );
        addTearDown(limiter.dispose);
        limiter.tryAcquire(); // exhaust current window

        // A 300 ms timeout is long enough for the 80 ms window to reset.
        await expectLater(
          limiter.acquire(timeout: const Duration(milliseconds: 300)),
          completes,
        );
        expect(limiter.statistics.permitsAcquired, 2);
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // Window advance
    // ──────────────────────────────────────────────────────────────────────
    group('window advance', () {
      test('resets permits after window elapses', () async {
        final limiter = FixedWindowRateLimiter(
          maxPermits: 2,
          windowDuration: const Duration(milliseconds: 80),
        );
        addTearDown(limiter.dispose);

        limiter.tryAcquire();
        limiter.tryAcquire();
        expect(limiter.tryAcquire(), isFalse);

        // Wait for window to reset.
        await Future<void>.delayed(const Duration(milliseconds: 120));

        expect(
          limiter.tryAcquire(),
          isTrue,
          reason: 'new window should allow requests',
        );
        expect(limiter.statistics.currentPermits, 1);
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // Dispose
    // ──────────────────────────────────────────────────────────────────────
    group('dispose', () {
      test('dispose is idempotent (no-op on second call)', () {
        final limiter = FixedWindowRateLimiter(
          maxPermits: 5,
          windowDuration: const Duration(seconds: 1),
        );
        expect(
          () {
            limiter.dispose();
            limiter.dispose();
          },
          returnsNormally,
        );
      });

      test('tryAcquire throws StateError after dispose', () {
        final limiter = FixedWindowRateLimiter(
          maxPermits: 5,
          windowDuration: const Duration(seconds: 10),
        );
        limiter.dispose();
        expect(limiter.tryAcquire, throwsStateError);
      });
    });
  });
}
