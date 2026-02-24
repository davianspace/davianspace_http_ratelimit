import 'dart:async';

// ============================================================================
// RateLimiterStatistics
// ============================================================================

/// A point-in-time snapshot of a [RateLimiter]'s internal state.
///
/// Returned by [RateLimiter.statistics]. All fields are immutable at the
/// moment of capture; a fresh call to [RateLimiter.statistics] reflects the
/// latest state.
final class RateLimiterStatistics {
  /// Creates a [RateLimiterStatistics] snapshot.
  const RateLimiterStatistics({
    required this.permitsAcquired,
    required this.permitsRejected,
    required this.currentPermits,
    required this.maxPermits,
    this.queueDepth = 0,
  });

  /// Cumulative number of permits that were successfully issued since creation.
  final int permitsAcquired;

  /// Cumulative number of permits that were **rejected** (returned `false`
  /// from [RateLimiter.tryAcquire] or threw `RateLimitExceededException`).
  final int permitsRejected;

  /// Current number of available permits (or tokens) in the limiter.
  ///
  /// Semantics differ per algorithm:
  /// * Token Bucket — tokens currently in the bucket.
  /// * Fixed / Sliding Window — remaining calls allowed in the current window.
  /// * Leaky Bucket — spare capacity in the queue.
  final int currentPermits;

  /// Maximum permits the limiter can hold at any one time.
  final int maxPermits;

  /// Number of callers currently waiting in [RateLimiter.acquire]'s queue.
  ///
  /// Always `0` for non-queuing limiters (Fixed/Sliding Window).
  final int queueDepth;

  @override
  String toString() => 'RateLimiterStatistics('
      'acquired=$permitsAcquired, '
      'rejected=$permitsRejected, '
      'current=$currentPermits/$maxPermits, '
      'queued=$queueDepth)';
}

// ============================================================================
// RateLimiter
// ============================================================================

/// Abstract base for all rate-limiting algorithms in this package.
///
/// ## Contract
///
/// * [tryAcquire] is **non-blocking** and returns immediately.
/// * [acquire] blocks (asynchronously) until a permit is available, or until
///   `timeout` elapses, at which point it throws `RateLimitExceededException`.
/// * [dispose] releases all resources (timers, pending waiters). After
///   disposal, any in-flight [acquire] calls complete with an error; future
///   calls throw [StateError].
///
/// ## Thread safety
///
/// Dart is single-threaded within an isolate; all methods must be called from
/// the same isolate. They are **not** safe to call from multiple isolates.
abstract class RateLimiter {
  /// Creates a [RateLimiter].
  const RateLimiter();

  /// Attempts to acquire one permit immediately without blocking.
  ///
  /// Returns `true` if a permit was issued, `false` if the rate limit is
  /// currently exceeded.
  bool tryAcquire();

  /// Waits asynchronously until a permit is available, then returns.
  ///
  /// If [timeout] is provided and elapses before a permit is available, throws
  /// `RateLimitExceededException`. If [timeout] is `null`, the call waits
  /// indefinitely.
  ///
  /// Throws [StateError] if the limiter has been disposed.
  Future<void> acquire({Duration? timeout});

  /// Current point-in-time statistics snapshot.
  ///
  /// Implementations must return a new, immutable [RateLimiterStatistics]
  /// instance on every call. Callers must not cache the result.
  RateLimiterStatistics get statistics;

  /// Signals that a previously acquired permit has been consumed (i.e. the
  /// associated work is complete).
  ///
  /// The default implementation is a **no-op** for non-concurrency limiters
  /// (Token Bucket, Fixed Window, Sliding Window, Leaky Bucket) where permits
  /// are consumed at acquisition time and do not need to be returned.
  ///
  /// `ConcurrencyLimiter` overrides this to decrement the in-flight counter
  /// and wake any blocked [acquire] waiters.
  ///
  /// `HttpRateLimitHandler` calls this automatically in a `try/finally` block
  /// after the inner handler completes.
  void release() {}

  /// Releases all internal resources.
  ///
  /// After calling [dispose]:
  /// * Any in-flight [acquire] waiters are completed with [StateError].
  /// * Future calls to [acquire] or [tryAcquire] throw [StateError].
  ///
  /// Safe to call multiple times (idempotent).
  void dispose();
}
