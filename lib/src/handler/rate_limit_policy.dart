import '../exceptions/rate_limit_exceeded_exception.dart';
import '../limiters/rate_limiter.dart';

/// Immutable configuration for `HttpRateLimitHandler`.
///
/// Combines a `RateLimiter` instance with policy metadata that controls how
/// the handler behaves when the rate limit is exceeded.
///
/// ## Example
///
/// ```dart
/// final policy = RateLimitPolicy(
///   limiter: TokenBucketRateLimiter(
///     capacity: 100,
///     refillAmount: 100,
///     refillInterval: Duration(seconds: 1),
///   ),
///   // Block until a permit is available (max 500 ms).
///   acquireTimeout: Duration(milliseconds: 500),
///   // Fire-and-forget telemetry on rejection.
///   onRejected: (ctx, e) =>
///     metrics.increment('rate_limit.rejected', tags: {'uri': '${ctx.request.uri}'}),
/// );
/// ```
final class RateLimitPolicy {
  /// Creates a `RateLimitPolicy`.
  ///
  /// [limiter]        — the `RateLimiter` instance to use.
  /// [acquireTimeout] — how long `HttpRateLimitHandler` waits for a permit
  ///                    before throwing `RateLimitExceededException`. `null`
  ///                    means wait indefinitely (use with care in production).
  /// [onRejected]     — optional callback invoked when a request is rejected
  ///                    (i.e. `acquireTimeout` elapsed or `tryAcquire` failed).
  /// [respectServerHeaders] — when `true`, the handler inspects `X-RateLimit-*`
  ///                    response headers and, on `HttpRateLimitHandler` pass-through,
  ///                    emits a warning if the server signals imminent exhaustion.
  const RateLimitPolicy({
    required this.limiter,
    this.acquireTimeout,
    this.onRejected,
    this.respectServerHeaders = false,
  });

  /// The `RateLimiter` that controls token issuance.
  final RateLimiter limiter;

  /// Maximum time to wait for a permit during `acquire`.
  ///
  /// `null` — wait indefinitely.
  /// `Duration.zero` — non-blocking (equivalent to `tryAcquire`).
  final Duration? acquireTimeout;

  /// Optional callback invoked when a request is rejected due to rate limiting.
  ///
  /// Use for metrics, alerting, or audit logging:
  ///
  /// ```dart
  /// onRejected: (ctx, exception) {
  ///   log.warning('Rate limit rejected request to ${ctx.request.uri}: $exception');
  /// }
  /// ```
  final void Function(Object? context, RateLimitExceededException exception)?
      onRejected;

  /// When `true`, `HttpRateLimitHandler` reads `X-RateLimit-*` response
  /// headers from upstream responses and makes them available for inspection
  /// via `RateLimitHeaders.from(response.headers)`.
  final bool respectServerHeaders;

  @override
  String toString() => 'RateLimitPolicy('
      'limiter=${limiter.runtimeType}, '
      'acquireTimeout=$acquireTimeout, '
      'respectServerHeaders=$respectServerHeaders)';
}
