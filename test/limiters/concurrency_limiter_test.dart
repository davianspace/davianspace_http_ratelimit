import 'dart:async';

import 'package:davianspace_http_ratelimit/davianspace_http_ratelimit.dart';
import 'package:test/test.dart';

void main() {
  group('ConcurrencyLimiter', () {
    // ──────────────────────────────────────────────────────────────────────
    // Construction
    // ──────────────────────────────────────────────────────────────────────
    group('construction', () {
      test('starts with full capacity', () {
        final limiter = ConcurrencyLimiter(maxConcurrency: 5);
        addTearDown(limiter.dispose);
        final s = limiter.statistics;
        expect(s.currentPermits, 5);
        expect(s.maxPermits, 5);
        expect(s.queueDepth, 0);
      });

      test('asserts maxConcurrency > 0', () {
        expect(
          () => ConcurrencyLimiter(maxConcurrency: 0),
          throwsA(isA<AssertionError>()),
        );
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // tryAcquire / release
    // ──────────────────────────────────────────────────────────────────────
    group('tryAcquire / release', () {
      test('admits up to maxConcurrency', () {
        final limiter = ConcurrencyLimiter(maxConcurrency: 3);
        addTearDown(limiter.dispose);
        expect(limiter.tryAcquire(), isTrue);
        expect(limiter.tryAcquire(), isTrue);
        expect(limiter.tryAcquire(), isTrue);
        expect(limiter.statistics.currentPermits, 0);
      });

      test('rejects when all slots in use', () {
        final limiter = ConcurrencyLimiter(maxConcurrency: 2);
        addTearDown(limiter.dispose);
        limiter.tryAcquire();
        limiter.tryAcquire();
        expect(limiter.tryAcquire(), isFalse);
        expect(limiter.statistics.permitsRejected, 1);
      });

      test('release restores a slot', () {
        final limiter = ConcurrencyLimiter(maxConcurrency: 1);
        addTearDown(limiter.dispose);
        limiter.tryAcquire();
        expect(limiter.tryAcquire(), isFalse); // full
        limiter.release();
        expect(limiter.tryAcquire(), isTrue); // slot freed
      });

      test('release on zero in-flight is a no-op', () {
        final limiter = ConcurrencyLimiter(maxConcurrency: 3);
        addTearDown(limiter.dispose);
        expect(() => limiter.release(), returnsNormally);
        expect(limiter.statistics.currentPermits, 3);
      });

      test('tracks permitsAcquired and permitsRejected', () {
        final limiter = ConcurrencyLimiter(maxConcurrency: 2);
        addTearDown(limiter.dispose);
        limiter.tryAcquire();
        limiter.tryAcquire();
        limiter.tryAcquire(); // rejected
        final s = limiter.statistics;
        expect(s.permitsAcquired, 2);
        expect(s.permitsRejected, 1);
      });

      test('throws StateError after dispose', () {
        final limiter = ConcurrencyLimiter(maxConcurrency: 3);
        limiter.dispose();
        expect(limiter.tryAcquire, throwsStateError);
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // acquire – immediate path
    // ──────────────────────────────────────────────────────────────────────
    group('acquire – immediate', () {
      test('completes immediately when slot available', () async {
        final limiter = ConcurrencyLimiter(maxConcurrency: 3);
        addTearDown(limiter.dispose);
        await expectLater(limiter.acquire(), completes);
        expect(limiter.statistics.permitsAcquired, 1);
        expect(limiter.statistics.currentPermits, 2);
        limiter.release();
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // acquire – blocking (waits for release)
    // ──────────────────────────────────────────────────────────────────────
    group('acquire – waits for release', () {
      test('acquires after another caller releases', () async {
        final limiter = ConcurrencyLimiter(maxConcurrency: 1);
        addTearDown(limiter.dispose);

        // Occupy the single slot.
        await limiter.acquire();
        expect(limiter.statistics.currentPermits, 0);

        // Schedule release after a short delay.
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 50))
              .then((_) => limiter.release()),
        );

        // Second acquire should unblock when slot is released.
        await expectLater(
          limiter.acquire(timeout: const Duration(milliseconds: 200)),
          completes,
        );
        limiter.release();
        expect(limiter.statistics.permitsAcquired, 2);
      });

      test('queued acquires are dispatched in FIFO order', () async {
        final limiter = ConcurrencyLimiter(maxConcurrency: 1);
        addTearDown(limiter.dispose);

        await limiter.acquire(); // occupy slot

        final order = <int>[];
        // Queue 3 waiters.
        final f1 = limiter.acquire().then((_) => order.add(1));
        final f2 = limiter.acquire().then((_) => order.add(2));
        final f3 = limiter.acquire().then((_) => order.add(3));

        // Release repeatedly to drain the queue.
        limiter.release();
        await f1;
        limiter.release();
        await f2;
        limiter.release();
        await f3;
        limiter.release(); // release the last one

        expect(order, [1, 2, 3]);
      });

      test('throws RateLimitExceededException when timeout elapses', () async {
        final limiter = ConcurrencyLimiter(maxConcurrency: 1);
        addTearDown(limiter.dispose);

        await limiter.acquire(); // occupy only slot

        await expectLater(
          limiter.acquire(timeout: const Duration(milliseconds: 50)),
          throwsA(
            isA<RateLimitExceededException>()
                .having((e) => e.limiterType, 'limiterType', 'Concurrency'),
          ),
        );

        limiter.release();
        expect(limiter.statistics.permitsRejected, 1);
      });

      test('queueDepth reflects waiting callers', () async {
        final limiter = ConcurrencyLimiter(maxConcurrency: 1);
        addTearDown(limiter.dispose);

        await limiter.acquire();
        final f = limiter.acquire(); // queued
        // Allow microtask queue to process enqueue.
        await Future<void>.value();
        expect(limiter.statistics.queueDepth, 1);

        limiter.release(); // dispatch queued
        await f;
        limiter.release();
        expect(limiter.statistics.queueDepth, 0);
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // Dispose
    // ──────────────────────────────────────────────────────────────────────
    group('dispose', () {
      test('is idempotent', () {
        final limiter = ConcurrencyLimiter(maxConcurrency: 3);
        expect(
          () {
            limiter.dispose();
            limiter.dispose();
          },
          returnsNormally,
        );
      });

      test('pending waiters receive StateError on dispose', () async {
        final limiter = ConcurrencyLimiter(maxConcurrency: 1);
        await limiter.acquire(); // occupy slot

        final pending = limiter.acquire(); // queued
        limiter.dispose();

        await expectLater(pending, throwsStateError);
      });
    });
  });
}
