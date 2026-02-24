/// Parses standard `X-RateLimit-*` response headers returned by many APIs.
///
/// These headers are not standardised by HTTP RFCs, but the
/// `X-RateLimit-Limit`, `X-RateLimit-Remaining`, and
/// `X-RateLimit-Reset` convention is widely used by GitHub, Twitter,
/// Stripe, and similar APIs.
///
/// ## Usage
///
/// ```dart
/// final limits = RateLimitHeaders.from(response.headers);
/// if (limits.remaining != null && limits.remaining! < 10) {
///   log.warning('Approaching rate limit: ${limits.remaining} remaining');
/// }
/// ```
final class RateLimitHeaders {
  /// Creates a [RateLimitHeaders] from the provided values.
  ///
  /// All fields are optional — APIs vary in which headers they include.
  const RateLimitHeaders({
    this.limit,
    this.remaining,
    this.reset,
    this.retryAfter,
    this.policy,
  });

  /// Parses `X-RateLimit-*` and `Retry-After` headers from [headers].
  ///
  /// Missing or unparseable headers are stored as `null`.
  factory RateLimitHeaders.from(Map<String, String> headers) {
    final limit = _parseInt(
      headers['x-ratelimit-limit'] ?? headers['X-RateLimit-Limit'],
    );
    final remaining = _parseInt(
      headers['x-ratelimit-remaining'] ?? headers['X-RateLimit-Remaining'],
    );

    final resetRaw =
        headers['x-ratelimit-reset'] ?? headers['X-RateLimit-Reset'];
    Duration? reset;
    if (resetRaw != null) {
      // Could be Unix timestamp (seconds) or offset in seconds.
      final seconds = int.tryParse(resetRaw.trim());
      if (seconds != null) {
        final epoch = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
        final now = DateTime.now();
        if (epoch.isAfter(now)) {
          reset = epoch.difference(now);
        } else {
          reset = Duration.zero;
        }
      }
    }

    final retryAfterRaw = headers['retry-after'] ?? headers['Retry-After'];
    Duration? retryAfter;
    if (retryAfterRaw != null) {
      final seconds = int.tryParse(retryAfterRaw.trim());
      if (seconds != null && seconds >= 0) {
        retryAfter = Duration(seconds: seconds);
      }
    }

    final policy =
        headers['x-ratelimit-policy'] ?? headers['X-RateLimit-Policy'];

    return RateLimitHeaders(
      limit: limit,
      remaining: remaining,
      reset: reset,
      retryAfter: retryAfter,
      policy: policy,
    );
  }

  // ─── Fields ───────────────────────────────────────────────────────────────

  /// `X-RateLimit-Limit`: the maximum number of requests allowed.
  final int? limit;

  /// `X-RateLimit-Remaining`: requests remaining in the current window.
  final int? remaining;

  /// Duration until the current rate-limit window resets, derived from
  /// `X-RateLimit-Reset` (Unix epoch seconds).
  final Duration? reset;

  /// `Retry-After`: explicit wait time returned by the server, typically
  /// alongside a 429 or 503 response.
  final Duration? retryAfter;

  /// `X-RateLimit-Policy`: arbitrary policy label from the API.
  ///
  /// Not universally present; useful for logging and debugging.
  final String? policy;

  /// Whether **any** rate-limit headers were present in the source map.
  bool get hasRateLimitHeaders =>
      limit != null || remaining != null || reset != null || retryAfter != null;

  /// Whether the rate limit is exhausted or nearly exhausted.
  ///
  /// Returns `true` when [remaining] == 0, or `false` if unknown.
  bool get isExhausted => remaining == null ? false : remaining! == 0;

  @override
  String toString() => 'RateLimitHeaders('
      'limit=$limit, '
      'remaining=$remaining, '
      'reset=${reset?.inSeconds}s, '
      'retryAfter=${retryAfter?.inSeconds}s)';

  // ─── Internal ─────────────────────────────────────────────────────────────

  static int? _parseInt(String? s) {
    if (s == null) return null;
    return int.tryParse(s.trim());
  }
}
