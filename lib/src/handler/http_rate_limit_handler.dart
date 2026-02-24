import 'dart:async';

import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';

import '../exceptions/rate_limit_exceeded_exception.dart';
import '../headers/rate_limit_headers.dart';
import 'rate_limit_policy.dart';

/// A [DelegatingHandler] that enforces client-side HTTP rate limiting using
/// the configured `RateLimitPolicy`.
///
/// ## Behaviour
///
/// Before forwarding a request to the inner handler, `HttpRateLimitHandler`
/// calls `RateLimiter.acquire` (or uses `RateLimiter.tryAcquire` when
/// `acquireTimeout == Duration.zero`). If a permit cannot be acquired within
/// the timeout, `RateLimitExceededException` is thrown.
///
/// When `RateLimitPolicy.respectServerHeaders` is `true`, the handler reads
/// `X-RateLimit-*` headers from the upstream response and makes them
/// available via `response.headers`.
///
/// ## Placement in the pipeline
///
/// Place `HttpRateLimitHandler` **after** logging and **before** retry to
/// ensure retries are also rate-limited:
///
/// ```
/// LoggingHandler
///   → HttpRateLimitHandler   ← controls outbound request rate
///     → RetryHandler
///       → TimeoutHandler
///         → TerminalHandler
/// ```
///
/// ## Example
///
/// ```dart
/// final client = HttpClientBuilder()
///     .withBaseUri(Uri.parse('https://api.github.com'))
///     .withLogging()
///     .withRateLimit(RateLimitPolicy(
///       limiter: TokenBucketRateLimiter(
///         capacity: 5000,
///         refillAmount: 5000,
///         refillInterval: Duration(hours: 1),
///       ),
///       acquireTimeout: Duration(milliseconds: 500),
///     ))
///     .withRetry(RetryPolicy.exponential(maxRetries: 3))
///     .build();
/// ```
final class HttpRateLimitHandler extends DelegatingHandler {
  /// Creates an [HttpRateLimitHandler] driven by the given policy.
  HttpRateLimitHandler(this._policy);

  final RateLimitPolicy _policy;

  @override
  Future<HttpResponse> send(HttpContext context) async {
    context.throwIfCancelled();

    await _acquirePermit(context);

    try {
      final response = await innerHandler.send(context);

      if (_policy.respectServerHeaders) {
        _inspectServerHeaders(response, context);
      }

      return response;
    } finally {
      // No-op for time-windowed limiters; releases the in-flight slot for
      // ConcurrencyLimiter.
      _policy.limiter.release();
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Internal
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _acquirePermit(HttpContext context) async {
    final timeout = _policy.acquireTimeout;
    try {
      if (timeout == Duration.zero) {
        // Non-blocking path.
        if (!_policy.limiter.tryAcquire()) {
          throw RateLimitExceededException(
            message: 'Rate limit reached for ${context.request.uri}: '
                'no permit available (non-blocking mode).',
            limiterType: _policy.limiter.runtimeType.toString(),
          );
        }
      } else {
        await _policy.limiter.acquire(timeout: timeout);
      }
    } on RateLimitExceededException catch (e) {
      _policy.onRejected?.call(context, e);
      rethrow;
    }
  }

  void _inspectServerHeaders(HttpResponse response, HttpContext context) {
    if (response.headers.isEmpty) return;
    final headers = RateLimitHeaders.from(response.headers);
    if (headers.hasRateLimitHeaders) {
      // Store the parsed headers for downstream inspection.
      context.setProperty(_rateLimitHeadersKey, headers);
    }
  }

  /// Property bag key used to store [RateLimitHeaders] in [HttpContext].
  ///
  /// Retrieve via:
  /// ```dart
  /// final headers = context.getProperty<RateLimitHeaders>(
  ///     HttpRateLimitHandler.rateLimitHeadersPropertyKey);
  /// ```
  static const String rateLimitHeadersPropertyKey = 'ratelimit.serverHeaders';

  // private alias used internally
  static const String _rateLimitHeadersKey = rateLimitHeadersPropertyKey;
}
