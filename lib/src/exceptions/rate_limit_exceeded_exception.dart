/// Thrown when a `RateLimiter` cannot issue a permit within the allowed time.
///
/// This exception propagates from:
/// * `RateLimiter.acquire` when `timeout` elapses before a permit is
///   available.
/// * `HttpRateLimitHandler` when the configured `RateLimitPolicy` has
///   `throwOnExceeded: true` and the request cannot be admitted.
///
/// Catch this within a fallback or retry handler when you need specific
/// rate-limit error handling:
///
/// ```dart
/// try {
///   final response = await client.get(uri);
/// } on RateLimitExceededException catch (e) {
///   log.warning('Rate limited: ${e.message}');
///   return cachedResponse;
/// }
/// ```
final class RateLimitExceededException implements Exception {
  /// Creates a [RateLimitExceededException].
  ///
  /// [message]    — human-readable reason for the rejection.
  /// [retryAfter] — optional hint: how long to wait before retrying.
  /// [limiterType]— string label of the algorithm that rejected the request.
  const RateLimitExceededException({
    required this.message,
    this.retryAfter,
    this.limiterType,
  });

  /// Human-readable description of the rejection.
  final String message;

  /// Optional hint: caller should wait at least this long before retrying.
  ///
  /// `null` when the limiter cannot determine an appropriate wait time.
  final Duration? retryAfter;

  /// String identifier of the rate-limiting algorithm that rejected the call.
  ///
  /// Examples: `'TokenBucket'`, `'FixedWindow'`, `'SlidingWindow'`,
  /// `'LeakyBucket'`.
  final String? limiterType;

  @override
  String toString() {
    final parts = <String>['RateLimitExceededException: $message'];
    if (limiterType != null) parts.add('limiter=$limiterType');
    if (retryAfter != null) {
      parts.add('retryAfter=${retryAfter!.inMilliseconds}ms');
    }
    return parts.join(', ');
  }
}
