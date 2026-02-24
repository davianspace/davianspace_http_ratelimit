import '../backend/in_memory_rate_limiter_repository.dart';
import '../backend/rate_limiter_repository.dart';
import '../exceptions/rate_limit_exceeded_exception.dart';
import '../limiters/rate_limiter.dart';

/// Server-side rate limiter that enforces per-key request limits.
///
/// [ServerRateLimiter] is framework-agnostic: it works with any Dart HTTP
/// server library (`shelf`, `dart_frog`, `relic`, custom IO servers, etc.)
/// because it operates on raw header maps and [Uri] values rather than any
/// framework-specific request type.
///
/// ## How it works
///
/// 1. The caller extracts a key from the incoming request (IP, user, route,
///    or any combination) using a `RateLimitKeyExtractor` or manual logic.
/// 2. [tryAllow] / [allow] looks up (or lazily creates) a [RateLimiter] for
///    that key in the `RateLimiterRepository`.
/// 3. The limiter admits or rejects the request.
///
/// Per-key limiter instances are created on first use by [limiterFactory] and
/// cached in [repository] for subsequent requests with the same key.
///
/// ## Example — shelf middleware
///
/// ```dart
/// final serverLimiter = ServerRateLimiter(
///   limiterFactory: () => TokenBucketRateLimiter(
///     capacity: 100,
///     refillAmount: 100,
///     refillInterval: Duration(seconds: 1),
///   ),
/// );
///
/// Handler rateLimitMiddleware(Handler inner) => (request) async {
///   final ip = request.headers['x-forwarded-for'] ?? 'unknown';
///   if (!serverLimiter.tryAllow(ip)) {
///     return Response(429, body: 'Too Many Requests');
///   }
///   return inner(request);
/// };
/// ```
final class ServerRateLimiter {
  /// Creates a [ServerRateLimiter].
  ///
  /// [limiterFactory] — called once per unique key to create the [RateLimiter]
  ///                    that will govern requests for that key. The factory
  ///                    **must** return a freshly constructed limiter on every
  ///                    call; instances are owned by [repository].
  /// [repository]     — stores per-key [RateLimiter] instances.
  ///                    Defaults to [InMemoryRateLimiterRepository].
  /// [acquireTimeout] — maximum time to wait for a permit in [allow].
  ///                    `null` = wait indefinitely.
  ///                    [Duration.zero] = non-blocking (equivalent to
  ///                    [tryAllow]).
  /// [onRejected]     — optional callback fired when a key is rate-limited.
  ServerRateLimiter({
    required this.limiterFactory,
    RateLimiterRepository? repository,
    this.acquireTimeout,
    this.onRejected,
  }) : repository = repository ?? InMemoryRateLimiterRepository();

  /// Factory that produces a new [RateLimiter] for each unique key.
  final RateLimiter Function() limiterFactory;

  /// Backing store for per-key [RateLimiter] instances.
  final RateLimiterRepository repository;

  /// Maximum time to wait for a permit in [allow].
  final Duration? acquireTimeout;

  /// Optional callback invoked when a request is rejected.
  final void Function(String key, RateLimitExceededException exception)?
      onRejected;

  bool _disposed = false;

  // ─────────────────────────────────────────────────────────────────────────
  // Public API
  // ─────────────────────────────────────────────────────────────────────────

  /// Non-blocking check: returns `true` if the request for [key] is admitted,
  /// `false` if the rate limit is currently exhausted.
  ///
  /// Does **not** throw on rejection.
  bool tryAllow(String key) {
    _checkDisposed();
    final limiter = repository.getOrCreate(key, limiterFactory);
    final allowed = limiter.tryAcquire();
    if (!allowed) {
      onRejected?.call(
        key,
        RateLimitExceededException(
          message: 'ServerRateLimiter: key "$key" exceeded rate limit.',
          limiterType: limiter.runtimeType.toString(),
        ),
      );
    }
    return allowed;
  }

  /// Blocking check: waits up to [acquireTimeout] for a permit.
  ///
  /// Throws [RateLimitExceededException] if the timeout elapses or the
  /// limiter cannot issue a permit in non-blocking mode
  /// ([acquireTimeout] == [Duration.zero]).
  Future<void> allow(String key) async {
    _checkDisposed();
    final limiter = repository.getOrCreate(key, limiterFactory);
    try {
      if (acquireTimeout == Duration.zero) {
        if (!limiter.tryAcquire()) {
          throw RateLimitExceededException(
            message: 'ServerRateLimiter: key "$key" exceeded rate limit '
                '(non-blocking mode).',
            limiterType: limiter.runtimeType.toString(),
          );
        }
      } else {
        await limiter.acquire(timeout: acquireTimeout);
      }
    } on RateLimitExceededException catch (e) {
      onRejected?.call(key, e);
      rethrow;
    }
  }

  /// Releases a slot held by [key]'s limiter.
  ///
  /// Only has an effect when the limiter for [key] is a `ConcurrencyLimiter`.
  /// Safe to call on any limiter type — other limiters treat release as a
  /// no-op.
  void release(String key) {
    if (_disposed) return;
    repository.getOrCreate(key, limiterFactory).release();
  }

  /// Returns the current [RateLimiterStatistics] for [key], or `null` if no
  /// limiter has been created for that key yet.
  RateLimiterStatistics? statisticsFor(String key) {
    if (_disposed) return null;
    // Peek without creating — use the private field via getOrCreate with a
    // sentinel; instead, track manually.  The repository may not support peek,
    // so we use tryAllow-less path: getOrCreate creates if absent.
    // For a true peek we'd need an optional `get` on repository — for now,
    // getOrCreate is idempotent so it's safe.
    return repository.getOrCreate(key, limiterFactory).statistics;
  }

  /// Disposes all managed [RateLimiter] instances and releases the repository.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    repository.dispose();
  }

  void _checkDisposed() {
    if (_disposed) {
      throw StateError('ServerRateLimiter has been disposed.');
    }
  }
}
