import '../limiters/rate_limiter.dart';

/// Stores and retrieves [RateLimiter] instances keyed by an arbitrary
/// string identifier.
///
/// The repository owns the lifecycle of all [RateLimiter] instances it
/// creates. Calling [dispose] disposes every managed limiter.
///
/// ## Implementing a custom backend
///
/// To integrate with an external store (Redis, Memcached, etc.) implement
/// this interface and pass your implementation to `ServerRateLimiter`:
///
/// ```dart
/// final class RedisRateLimiterRepository
///     implements RateLimiterRepository {
///   RedisRateLimiterRepository(this._redis);
///   final RedisClient _redis;
///
///   @override
///   RateLimiter getOrCreate(String key, RateLimiter Function() factory) {
///     // Custom logic backed by Redis.
///   }
///   // ...
/// }
/// ```
abstract interface class RateLimiterRepository {
  /// Returns the [RateLimiter] registered under [key].
  ///
  /// If no limiter exists for [key], one is created by invoking [factory] and
  /// stored for future calls with the same key.
  RateLimiter getOrCreate(String key, RateLimiter Function() factory);

  /// Removes and disposes the [RateLimiter] registered under [key].
  ///
  /// No-op if [key] is not present.
  void remove(String key);

  /// Removes all keys whose [RateLimiter] satisfies [predicate].
  ///
  /// Useful for evicting idle or expired limiters.
  void removeWhere(bool Function(String key, RateLimiter limiter) predicate);

  /// Disposes every managed [RateLimiter] and clears the repository.
  void dispose();
}
