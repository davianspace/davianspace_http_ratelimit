import 'dart:async';

import 'package:davianspace_http_ratelimit/davianspace_http_ratelimit.dart';
import 'package:test/test.dart';

void main() {
  group('ServerRateLimiter', () {
    // ──────────────────────────────────────────────────────────────────────
    // tryAllow
    // ──────────────────────────────────────────────────────────────────────
    group('tryAllow', () {
      test('admits requests within limit', () {
        final limiter = ServerRateLimiter(
          limiterFactory: () => FixedWindowRateLimiter(
            maxPermits: 5,
            windowDuration: const Duration(minutes: 1),
          ),
        );
        addTearDown(limiter.dispose);

        for (var i = 0; i < 5; i++) {
          expect(limiter.tryAllow('user1'), isTrue);
        }
      });

      test('rejects when key limit is exhausted', () {
        final limiter = ServerRateLimiter(
          limiterFactory: () => FixedWindowRateLimiter(
            maxPermits: 2,
            windowDuration: const Duration(minutes: 1),
          ),
        );
        addTearDown(limiter.dispose);

        limiter.tryAllow('a');
        limiter.tryAllow('a');
        expect(limiter.tryAllow('a'), isFalse);
      });

      test('keys are isolated from each other', () {
        final limiter = ServerRateLimiter(
          limiterFactory: () => FixedWindowRateLimiter(
            maxPermits: 1,
            windowDuration: const Duration(minutes: 1),
          ),
        );
        addTearDown(limiter.dispose);

        expect(limiter.tryAllow('user1'), isTrue);
        expect(limiter.tryAllow('user1'), isFalse); // user1 exhausted
        expect(limiter.tryAllow('user2'), isTrue); // user2 is fresh
      });

      test('calls onRejected callback with key and exception', () {
        String? rejectedKey;
        final limiter = ServerRateLimiter(
          limiterFactory: () => FixedWindowRateLimiter(
            maxPermits: 1,
            windowDuration: const Duration(minutes: 1),
          ),
          onRejected: (key, _) => rejectedKey = key,
        );
        addTearDown(limiter.dispose);

        limiter.tryAllow('ip1');
        limiter.tryAllow('ip1'); // triggers callback
        expect(rejectedKey, 'ip1');
      });

      test('throws StateError after dispose', () {
        final limiter = ServerRateLimiter(
          limiterFactory: () => FixedWindowRateLimiter(
            maxPermits: 5,
            windowDuration: const Duration(minutes: 1),
          ),
        );
        limiter.dispose();
        expect(() => limiter.tryAllow('x'), throwsStateError);
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // allow (async)
    // ──────────────────────────────────────────────────────────────────────
    group('allow', () {
      test('completes when limit not exceeded', () async {
        final limiter = ServerRateLimiter(
          limiterFactory: () => TokenBucketRateLimiter(
            capacity: 10,
            refillAmount: 10,
            refillInterval: const Duration(seconds: 1),
          ),
          acquireTimeout: Duration.zero,
        );
        addTearDown(limiter.dispose);

        await expectLater(limiter.allow('user1'), completes);
      });

      test('throws RateLimitExceededException in non-blocking mode', () async {
        final limiter = ServerRateLimiter(
          limiterFactory: () => FixedWindowRateLimiter(
            maxPermits: 1,
            windowDuration: const Duration(minutes: 1),
          ),
          acquireTimeout: Duration.zero,
        );
        addTearDown(limiter.dispose);

        await limiter.allow('key1'); // consumes the only permit
        await expectLater(
          limiter.allow('key1'),
          throwsA(isA<RateLimitExceededException>()),
        );
      });

      test('onRejected is called on async rejection', () async {
        String? rejectedKey;
        final limiter = ServerRateLimiter(
          limiterFactory: () => FixedWindowRateLimiter(
            maxPermits: 1,
            windowDuration: const Duration(minutes: 1),
          ),
          acquireTimeout: Duration.zero,
          onRejected: (key, _) => rejectedKey = key,
        );
        addTearDown(limiter.dispose);

        await limiter.allow('k');
        try {
          await limiter.allow('k');
        } on RateLimitExceededException {
          // expected
        }
        expect(rejectedKey, 'k');
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // release + ConcurrencyLimiter integration
    // ──────────────────────────────────────────────────────────────────────
    group('release with ConcurrencyLimiter', () {
      test('release frees slot for next request', () async {
        final limiter = ServerRateLimiter(
          limiterFactory: () => ConcurrencyLimiter(maxConcurrency: 1),
          acquireTimeout: const Duration(milliseconds: 200),
        );
        addTearDown(limiter.dispose);

        await limiter.allow('key');
        // Slot occupied — second allow would block. Schedule release.
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 30))
              .then((_) => limiter.release('key')),
        );

        await expectLater(limiter.allow('key'), completes);
        limiter.release('key');
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // statisticsFor
    // ──────────────────────────────────────────────────────────────────────
    group('statisticsFor', () {
      test('returns stats once a key has been used', () {
        final limiter = ServerRateLimiter(
          limiterFactory: () => FixedWindowRateLimiter(
            maxPermits: 5,
            windowDuration: const Duration(minutes: 1),
          ),
        );
        addTearDown(limiter.dispose);

        limiter.tryAllow('user1');
        limiter.tryAllow('user1');
        final stats = limiter.statisticsFor('user1');
        expect(stats, isNotNull);
        expect(stats!.permitsAcquired, 2);
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // Custom repository
    // ──────────────────────────────────────────────────────────────────────
    group('custom repository', () {
      test('accepts InMemoryRateLimiterRepository explicitly', () {
        final repo = InMemoryRateLimiterRepository();
        final limiter = ServerRateLimiter(
          limiterFactory: () => FixedWindowRateLimiter(
            maxPermits: 3,
            windowDuration: const Duration(minutes: 1),
          ),
          repository: repo,
        );
        addTearDown(limiter.dispose);

        expect(limiter.tryAllow('k'), isTrue);
        // The same repo should now hold a limiter for 'k'.
        expect(limiter.statisticsFor('k')?.permitsAcquired, 1);
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // Dispose
    // ──────────────────────────────────────────────────────────────────────
    group('dispose', () {
      test('is idempotent', () {
        final limiter = ServerRateLimiter(
          limiterFactory: () => FixedWindowRateLimiter(
            maxPermits: 5,
            windowDuration: const Duration(minutes: 1),
          ),
        );
        expect(
          () {
            limiter.dispose();
            limiter.dispose();
          },
          returnsNormally,
        );
      });
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // InMemoryRateLimiterRepository
  // ──────────────────────────────────────────────────────────────────────────
  group('InMemoryRateLimiterRepository', () {
    test('getOrCreate returns same instance for the same key', () {
      final repo = InMemoryRateLimiterRepository();
      addTearDown(repo.dispose);

      RateLimiter factory() => FixedWindowRateLimiter(
            maxPermits: 5,
            windowDuration: const Duration(minutes: 1),
          );
      final a = repo.getOrCreate('k', factory);
      final b = repo.getOrCreate('k', factory);
      expect(identical(a, b), isTrue);
    });

    test('different keys get different instances', () {
      final repo = InMemoryRateLimiterRepository();
      addTearDown(repo.dispose);

      RateLimiter factory() => FixedWindowRateLimiter(
            maxPermits: 5,
            windowDuration: const Duration(minutes: 1),
          );
      final a = repo.getOrCreate('k1', factory);
      final b = repo.getOrCreate('k2', factory);
      expect(identical(a, b), isFalse);
    });

    test('remove disposes and evicts the key', () {
      final repo = InMemoryRateLimiterRepository();
      RateLimiter factory() => FixedWindowRateLimiter(
            maxPermits: 5,
            windowDuration: const Duration(minutes: 1),
          );
      repo.getOrCreate('k', factory);
      repo.remove('k');

      // Creating again returns a fresh (non-disposed) instance.
      final fresh = repo.getOrCreate('k', factory);
      expect(() => fresh.tryAcquire(), returnsNormally);
      repo.dispose();
    });

    test('removeWhere evicts matching keys', () {
      final repo = InMemoryRateLimiterRepository();
      RateLimiter factory() => FixedWindowRateLimiter(
            maxPermits: 5,
            windowDuration: const Duration(minutes: 1),
          );
      repo.getOrCreate('ip:1.1.1.1', factory);
      repo.getOrCreate('ip:2.2.2.2', factory);
      repo.getOrCreate('user:alice', factory);

      // Remove all IP-keyed limiters.
      repo.removeWhere((key, _) => key.startsWith('ip:'));

      // user:alice remains; ip keys are gone.
      final alice = repo.getOrCreate('user:alice', factory)..tryAcquire();
      expect(alice.statistics.permitsAcquired, 1);
      repo.dispose();
    });

    test('dispose is idempotent', () {
      final repo = InMemoryRateLimiterRepository();
      expect(
        () {
          repo.dispose();
          repo.dispose();
        },
        returnsNormally,
      );
    });

    test('throws StateError after dispose', () {
      final repo = InMemoryRateLimiterRepository();
      repo.dispose();
      expect(
        () => repo.getOrCreate(
          'k',
          () => FixedWindowRateLimiter(
            maxPermits: 1,
            windowDuration: const Duration(minutes: 1),
          ),
        ),
        throwsStateError,
      );
    });
  });
}
