import 'dart:async';

import 'package:davianspace_http_ratelimit/davianspace_http_ratelimit.dart';
import 'package:test/test.dart';

void main() {
  group('LeakyBucketRateLimiter', () {
    // ──────────────────────────────────────────────────────────────────────
    // Construction
    // ──────────────────────────────────────────────────────────────────────
    group('construction', () {
      test('starts with empty queue (full capacity available)', () {
        final limiter = LeakyBucketRateLimiter(
          capacity: 5,
          leakInterval: const Duration(milliseconds: 100),
        );
        addTearDown(limiter.dispose);
        final s = limiter.statistics;
        expect(s.currentPermits, 5);
        expect(s.maxPermits, 5);
        expect(s.queueDepth, 0);
      });

      test('asserts capacity > 0', () {
        expect(
          () => LeakyBucketRateLimiter(
            capacity: 0,
            leakInterval: const Duration(milliseconds: 100),
          ),
          throwsA(isA<AssertionError>()),
        );
      });

      test('asserts leakInterval > Duration.zero', () {
        expect(
          () => LeakyBucketRateLimiter(
            capacity: 5,
            leakInterval: Duration.zero,
          ),
          throwsA(isA<AssertionError>()),
        );
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // tryAcquire
    // ──────────────────────────────────────────────────────────────────────
    group('tryAcquire', () {
      test('returns true while capacity not exceeded', () {
        final limiter = LeakyBucketRateLimiter(
          capacity: 3,
          leakInterval: const Duration(seconds: 10),
        );
        addTearDown(limiter.dispose);
        expect(limiter.tryAcquire(), isTrue);
        expect(limiter.tryAcquire(), isTrue);
        expect(limiter.tryAcquire(), isTrue);
      });

      test('returns false when bucket is full', () {
        final limiter = LeakyBucketRateLimiter(
          capacity: 2,
          leakInterval: const Duration(seconds: 10),
        );
        addTearDown(limiter.dispose);
        limiter.tryAcquire();
        limiter.tryAcquire();
        expect(limiter.tryAcquire(), isFalse);
      });

      test('queueDepth reflects enqueued items', () {
        final limiter = LeakyBucketRateLimiter(
          capacity: 3,
          leakInterval: const Duration(seconds: 10),
        );
        addTearDown(limiter.dispose);
        limiter.tryAcquire();
        limiter.tryAcquire();
        expect(limiter.statistics.queueDepth, 2);
        expect(limiter.statistics.currentPermits, 1);
      });

      test('tracks permitsAcquired and permitsRejected', () {
        final limiter = LeakyBucketRateLimiter(
          capacity: 2,
          leakInterval: const Duration(seconds: 10),
        );
        addTearDown(limiter.dispose);
        limiter.tryAcquire(); // ok
        limiter.tryAcquire(); // ok
        limiter.tryAcquire(); // rejected
        final s = limiter.statistics;
        expect(s.permitsAcquired, 2);
        expect(s.permitsRejected, 1);
      });

      test('throws StateError after dispose', () {
        final limiter = LeakyBucketRateLimiter(
          capacity: 5,
          leakInterval: const Duration(milliseconds: 100),
        );
        limiter.dispose();
        expect(limiter.tryAcquire, throwsStateError);
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // acquire – immediate rejection when bucket full
    // ──────────────────────────────────────────────────────────────────────
    group('acquire – bucket full', () {
      test('throws RateLimitExceededException when bucket is full', () async {
        final limiter = LeakyBucketRateLimiter(
          capacity: 1,
          leakInterval: const Duration(hours: 1), // effectively no leak
        );
        addTearDown(limiter.dispose);
        limiter.tryAcquire(); // fill

        await expectLater(
          limiter.acquire(),
          throwsA(
            isA<RateLimitExceededException>()
                .having((e) => e.limiterType, 'limiterType', 'LeakyBucket')
                .having((e) => e.retryAfter, 'retryAfter', isNotNull),
          ),
        );
        expect(limiter.statistics.permitsRejected, 1);
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // acquire – waits for leak to drain slot
    // ──────────────────────────────────────────────────────────────────────
    group('acquire – draining', () {
      test('completes after leak drains the waiter', () async {
        const leakInterval = Duration(milliseconds: 60);
        final limiter = LeakyBucketRateLimiter(
          capacity: 2,
          leakInterval: leakInterval,
        );
        addTearDown(limiter.dispose);

        // Acquire via the blocking path; should complete after ~60 ms.
        await expectLater(
          limiter.acquire(timeout: const Duration(milliseconds: 300)),
          completes,
        );
        expect(limiter.statistics.permitsAcquired, greaterThanOrEqualTo(1));
      });

      test('times out when leak is too slow', () async {
        final limiter = LeakyBucketRateLimiter(
          capacity: 2,
          leakInterval: const Duration(seconds: 10),
        );
        addTearDown(limiter.dispose);

        // Put a waiter in the queue.
        final pendingFuture =
            limiter.acquire(timeout: const Duration(milliseconds: 60));

        await expectLater(
          pendingFuture,
          throwsA(
            isA<RateLimitExceededException>()
                .having((e) => e.limiterType, 'limiterType', 'LeakyBucket'),
          ),
        );
      });

      test('multiple concurrent acquires are processed in FIFO order',
          () async {
        const leakInterval = Duration(milliseconds: 50);
        final limiter = LeakyBucketRateLimiter(
          capacity: 3,
          leakInterval: leakInterval,
        );
        addTearDown(limiter.dispose);

        final completionOrder = <int>[];
        Future<void> tracked(int id) =>
            limiter.acquire().then((_) => completionOrder.add(id));

        await Future.wait(
          [tracked(1), tracked(2), tracked(3)],
        );
        expect(completionOrder, [1, 2, 3]);
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // Constant output rate
    // ──────────────────────────────────────────────────────────────────────
    group('constant output rate', () {
      test('spacing between consecutive completions ≥ leakInterval', () async {
        const leakInterval = Duration(milliseconds: 50);
        final limiter = LeakyBucketRateLimiter(
          capacity: 3,
          leakInterval: leakInterval,
        );
        addTearDown(limiter.dispose);

        final timestamps = <DateTime>[];
        for (var i = 0; i < 3; i++) {
          await limiter.acquire();
          timestamps.add(DateTime.now());
        }

        for (var i = 1; i < timestamps.length; i++) {
          final gap = timestamps[i].difference(timestamps[i - 1]);
          // Allow 25 ms slack for timer jitter on CI.
          expect(
            gap.inMilliseconds,
            greaterThanOrEqualTo(leakInterval.inMilliseconds - 25),
            reason: 'gap between completions should be ≥ leakInterval',
          );
        }
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // Statistics
    // ──────────────────────────────────────────────────────────────────────
    group('statistics', () {
      test('initial statistics zeroed', () {
        final limiter = LeakyBucketRateLimiter(
          capacity: 10,
          leakInterval: const Duration(milliseconds: 100),
        );
        addTearDown(limiter.dispose);
        final s = limiter.statistics;
        expect(s.permitsAcquired, 0);
        expect(s.permitsRejected, 0);
        expect(s.queueDepth, 0);
        expect(s.currentPermits, 10);
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // Dispose
    // ──────────────────────────────────────────────────────────────────────
    group('dispose', () {
      test('dispose is idempotent', () {
        final limiter = LeakyBucketRateLimiter(
          capacity: 5,
          leakInterval: const Duration(milliseconds: 100),
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
        final leakyLimiter = LeakyBucketRateLimiter(
          capacity: 2,
          leakInterval: const Duration(hours: 1), // slow leak
        );

        // Put a waiter in the pending queue.
        final pendingFuture = leakyLimiter.acquire();
        leakyLimiter.dispose();

        await expectLater(pendingFuture, throwsStateError);
      });
    });
  });
}
