import 'package:davianspace_dependencyinjection/davianspace_dependencyinjection.dart';

import '../limiters/concurrency_limiter.dart';
import '../limiters/fixed_window_rate_limiter.dart';
import '../limiters/leaky_bucket_rate_limiter.dart';
import '../limiters/rate_limiter.dart';
import '../limiters/sliding_window_log_rate_limiter.dart';
import '../limiters/sliding_window_rate_limiter.dart';
import '../limiters/token_bucket_rate_limiter.dart';
import '../server/server_rate_limiter.dart';

// =============================================================================
// RateLimitServiceCollectionExtensions
// =============================================================================

/// Extension methods that register `davianspace_http_ratelimit` types into
/// [ServiceCollection].
///
/// ## Quick start
///
/// ```dart
/// final provider = ServiceCollection()
///   ..addTokenBucketRateLimiter(
///     capacity: 100,
///     refillAmount: 10,
///     refillInterval: Duration(seconds: 1),
///   )
///   ..addServerRateLimiter(
///     limiterFactory: () => TokenBucketRateLimiter(
///       capacity: 200,
///       refillAmount: 20,
///       refillInterval: Duration(seconds: 1),
///     ),
///   )
///   .buildServiceProvider();
///
/// // Inject a specific limiter:
/// final limiter = provider.getRequired<TokenBucketRateLimiter>();
///
/// // Inject the server limiter:
/// final server = provider.getRequired<ServerRateLimiter>();
/// ```
extension RateLimitServiceCollectionExtensions on ServiceCollection {
  // -------------------------------------------------------------------------
  // addRateLimiter — generic typed registration
  // -------------------------------------------------------------------------

  /// Registers an already-constructed [limiter] as a singleton of its
  /// concrete type [TLimiter] and the abstract [RateLimiter] base.
  ///
  /// Use this when you have a pre-configured limiter instance and need it
  /// injectable by both its concrete type and the abstract interface.
  ///
  /// ```dart
  /// services.addRateLimiter<TokenBucketRateLimiter>(
  ///   TokenBucketRateLimiter(
  ///     capacity: 100,
  ///     refillAmount: 10,
  ///     refillInterval: Duration(seconds: 1),
  ///   ),
  /// );
  /// ```
  ServiceCollection addRateLimiter<TLimiter extends RateLimiter>(
    TLimiter limiter,
  ) {
    if (!isRegistered<TLimiter>()) {
      addInstance<TLimiter>(limiter);
    }
    if (!isRegistered<RateLimiter>()) {
      // Register the base type pointing to the same instance.
      addSingletonFactory<RateLimiter>(
        (p) => p.getRequired<TLimiter>(),
      );
    }
    return this;
  }

  // -------------------------------------------------------------------------
  // Per-algorithm conveniences
  // -------------------------------------------------------------------------

  /// Registers a singleton [TokenBucketRateLimiter].
  ServiceCollection addTokenBucketRateLimiter({
    required int capacity,
    required int refillAmount,
    required Duration refillInterval,
    int? initialTokens,
  }) {
    if (!isRegistered<TokenBucketRateLimiter>()) {
      addSingletonFactory<TokenBucketRateLimiter>(
        (_) => TokenBucketRateLimiter(
          capacity: capacity,
          refillAmount: refillAmount,
          refillInterval: refillInterval,
          initialTokens: initialTokens,
        ),
      );
    }
    return this;
  }

  /// Registers a singleton [FixedWindowRateLimiter].
  ServiceCollection addFixedWindowRateLimiter({
    required int maxPermits,
    required Duration windowDuration,
  }) {
    if (!isRegistered<FixedWindowRateLimiter>()) {
      addSingletonFactory<FixedWindowRateLimiter>(
        (_) => FixedWindowRateLimiter(
          maxPermits: maxPermits,
          windowDuration: windowDuration,
        ),
      );
    }
    return this;
  }

  /// Registers a singleton [SlidingWindowRateLimiter].
  ServiceCollection addSlidingWindowRateLimiter({
    required int maxPermits,
    required Duration windowDuration,
  }) {
    if (!isRegistered<SlidingWindowRateLimiter>()) {
      addSingletonFactory<SlidingWindowRateLimiter>(
        (_) => SlidingWindowRateLimiter(
          maxPermits: maxPermits,
          windowDuration: windowDuration,
        ),
      );
    }
    return this;
  }

  /// Registers a singleton [SlidingWindowLogRateLimiter].
  ServiceCollection addSlidingWindowLogRateLimiter({
    required int maxPermits,
    required Duration windowDuration,
  }) {
    if (!isRegistered<SlidingWindowLogRateLimiter>()) {
      addSingletonFactory<SlidingWindowLogRateLimiter>(
        (_) => SlidingWindowLogRateLimiter(
          maxPermits: maxPermits,
          windowDuration: windowDuration,
        ),
      );
    }
    return this;
  }

  /// Registers a singleton [LeakyBucketRateLimiter].
  ServiceCollection addLeakyBucketRateLimiter({
    required int capacity,
    required Duration leakInterval,
  }) {
    if (!isRegistered<LeakyBucketRateLimiter>()) {
      addSingletonFactory<LeakyBucketRateLimiter>(
        (_) => LeakyBucketRateLimiter(
          capacity: capacity,
          leakInterval: leakInterval,
        ),
      );
    }
    return this;
  }

  /// Registers a singleton [ConcurrencyLimiter].
  ServiceCollection addConcurrencyLimiter({
    required int maxConcurrency,
  }) {
    if (!isRegistered<ConcurrencyLimiter>()) {
      addSingletonFactory<ConcurrencyLimiter>(
        (_) => ConcurrencyLimiter(maxConcurrency: maxConcurrency),
      );
    }
    return this;
  }

  // -------------------------------------------------------------------------
  // addServerRateLimiter
  // -------------------------------------------------------------------------

  /// Registers a singleton [ServerRateLimiter].
  ///
  /// [limiterFactory] is called once per unique key to create a per-key
  /// [RateLimiter].
  ///
  /// ```dart
  /// services.addServerRateLimiter(
  ///   limiterFactory: () => FixedWindowRateLimiter(
  ///     maxPermits: 100,
  ///     windowDuration: Duration(minutes: 1),
  ///   ),
  ///   keyExtractor: IpKeyExtractor(),
  ///   acquireTimeout: Duration(milliseconds: 500),
  /// );
  ///
  /// // Inject:
  /// final limiter = provider.getRequired<ServerRateLimiter>();
  /// ```
  ServiceCollection addServerRateLimiter({
    required RateLimiter Function() limiterFactory,
    Duration? acquireTimeout,
    void Function(String key, dynamic exception)? onRejected,
  }) {
    if (!isRegistered<ServerRateLimiter>()) {
      addSingletonFactory<ServerRateLimiter>(
        (_) => ServerRateLimiter(
          limiterFactory: limiterFactory,
          acquireTimeout: acquireTimeout,
        ),
      );
    }
    return this;
  }
}
