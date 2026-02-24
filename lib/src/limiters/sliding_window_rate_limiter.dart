import 'dart:async';
import 'dart:collection';

import '../exceptions/rate_limit_exceeded_exception.dart';
import 'rate_limiter.dart';

/// A [RateLimiter] implementing the **Sliding Window** algorithm (also called
/// *sliding log*).
///
/// ## Algorithm
///
/// Every call is timestamped. Before deciding whether to admit a new request,
/// all timestamps older than `now - windowDuration` are discarded. If the
/// count of remaining timestamps is less than [maxPermits], the request is
/// admitted and its timestamp is appended.
///
/// ## Characteristics
///
/// | Property         | Value |
/// |------------------|-------|
/// | Burst suppression| ✅ No window-boundary burst (unlike Fixed Window) |
/// | Memory           | O([maxPermits]) — only admitted timestamps stored |
/// | Queue support    | ❌ [acquire] polls at configurable intervals |
/// | Precision        | Wall-clock accurate |
///
/// ## Trade-off vs Fixed Window
///
/// No edge-burst risk. The cost is O([maxPermits]) memory and O(n) cleanup
/// on each check. This is acceptable for typical API rate limits
/// (e.g. 1 000 req/min).
///
/// ## Example
///
/// ```dart
/// // 200 requests per 10 seconds, no edge burst.
/// final limiter = SlidingWindowRateLimiter(
///   maxPermits: 200,
///   windowDuration: Duration(seconds: 10),
/// );
/// ```
final class SlidingWindowRateLimiter extends RateLimiter {
  /// Creates a [SlidingWindowRateLimiter].
  ///
  /// [maxPermits]     — maximum requests in any [windowDuration]-wide window.
  /// [windowDuration] — width of the sliding window.
  /// [pollInterval]   — how often [acquire] polls when waiting for capacity;
  ///                    defaults to 50 ms.
  SlidingWindowRateLimiter({
    required this.maxPermits,
    required this.windowDuration,
    Duration pollInterval = const Duration(milliseconds: 50),
  })  : assert(maxPermits > 0, 'maxPermits must be > 0'),
        assert(
          windowDuration > Duration.zero,
          'windowDuration must be positive',
        ),
        assert(pollInterval > Duration.zero, 'pollInterval must be positive'),
        _pollInterval = pollInterval,
        _permitsAcquired = 0,
        _permitsRejected = 0;

  /// Max requests in any rolling [windowDuration]-wide window.
  final int maxPermits;

  /// Width of the sliding window.
  final Duration windowDuration;

  final Duration _pollInterval;
  final Queue<DateTime> _log = Queue<DateTime>();
  int _permitsAcquired;
  int _permitsRejected;
  bool _disposed = false;

  // ─────────────────────────────────────────────────────────────────────────
  // RateLimiter interface
  // ─────────────────────────────────────────────────────────────────────────

  @override
  bool tryAcquire() {
    _checkDisposed();
    _evictExpired();
    if (_log.length < maxPermits) {
      _log.add(DateTime.now());
      _permitsAcquired++;
      return true;
    }
    _permitsRejected++;
    return false;
  }

  @override
  Future<void> acquire({Duration? timeout}) async {
    _checkDisposed();
    final deadline = timeout != null ? DateTime.now().add(timeout) : null;

    while (true) {
      _evictExpired();
      if (_log.length < maxPermits) {
        _log.add(DateTime.now());
        _permitsAcquired++;
        return;
      }

      final now = DateTime.now();
      if (deadline != null && now.isAfter(deadline)) {
        _permitsRejected++;
        throw RateLimitExceededException(
          message: 'SlidingWindowRateLimiter: acquire timed out after '
              '${timeout!.inMilliseconds}ms.',
          limiterType: 'SlidingWindow',
          retryAfter: _timeUntilCapacity(),
        );
      }

      // Wait for the oldest entry to expire, or the poll interval,
      // whichever is sooner.
      var waitDuration = _pollInterval;
      if (_log.isNotEmpty) {
        final oldestExpiry =
            _log.first.add(windowDuration).difference(DateTime.now());
        if (oldestExpiry < waitDuration) {
          waitDuration = oldestExpiry;
        }
      }
      if (waitDuration < Duration.zero) {
        waitDuration = Duration.zero;
      }

      await Future<void>.delayed(waitDuration);
      _checkDisposed();
    }
  }

  @override
  RateLimiterStatistics get statistics {
    _evictExpired();
    return RateLimiterStatistics(
      permitsAcquired: _permitsAcquired,
      permitsRejected: _permitsRejected,
      currentPermits: maxPermits - _log.length,
      maxPermits: maxPermits,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _log.clear();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Internal
  // ─────────────────────────────────────────────────────────────────────────

  void _evictExpired() {
    final cutoff = DateTime.now().subtract(windowDuration);
    while (_log.isNotEmpty && _log.first.isBefore(cutoff)) {
      _log.removeFirst();
    }
  }

  Duration _timeUntilCapacity() {
    if (_log.isEmpty || _log.length < maxPermits) return Duration.zero;
    final oldestExpiry =
        _log.first.add(windowDuration).difference(DateTime.now());
    return oldestExpiry.isNegative ? Duration.zero : oldestExpiry;
  }

  void _checkDisposed() {
    if (_disposed) {
      throw StateError('SlidingWindowRateLimiter has been disposed.');
    }
  }
}
