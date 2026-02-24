import '../exceptions/rate_limit_exceeded_exception.dart';
import 'rate_limiter.dart';

/// A [RateLimiter] implementing the **Sliding Window Counter** algorithm.
///
/// ## Algorithm
///
/// Uses two adjacent time-slot counters (*previous* and *current*) to
/// approximate the number of requests that fall within a rolling window
/// of [windowDuration]:
///
/// ```
/// estimatedCount = prevCount × (1 − elapsed/slotDuration)
///               + currCount
/// ```
///
/// When `estimatedCount < maxPermits`, the request is admitted and
/// `currCount` is incremented. When the current slot expires,
/// `prevCount ← currCount`, `currCount ← 0`, and the slot clock advances.
///
/// ## Characteristics
///
/// | Property         | Value                                            |
/// |------------------|--------------------------------------------------|
/// | Accuracy         | Approximate (≤ 1 window error at slot boundary)  |
/// | Memory           | O(1) — two integer counters                      |
/// | Burst suppression| ✅ Smoother than Fixed Window                    |
/// | Queue support    | ❌ [acquire] polls until capacity opens           |
///
/// ## Trade-off vs `SlidingWindowLogRateLimiter`
///
/// This implementation uses O(1) memory and is accurate enough for most
/// production workloads. For **exact** enforcement (zero approximation error)
/// at the cost of O([maxPermits]) memory, use `SlidingWindowLogRateLimiter`.
///
/// ## Example
///
/// ```dart
/// // ~100 requests per minute with O(1) memory.
/// final limiter = SlidingWindowRateLimiter(
///   maxPermits: 100,
///   windowDuration: Duration(minutes: 1),
/// );
/// ```
final class SlidingWindowRateLimiter extends RateLimiter {
  /// Creates a [SlidingWindowRateLimiter].
  ///
  /// [maxPermits]     — maximum requests in any [windowDuration]-wide window.
  /// [windowDuration] — width of the sliding window (also the slot duration).
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
        _slotStart = DateTime.now(),
        _currCount = 0,
        _prevCount = 0,
        _permitsAcquired = 0,
        _permitsRejected = 0;

  /// Max requests in any rolling [windowDuration]-wide window.
  final int maxPermits;

  /// Width of one time slot (equals the sliding window width).
  final Duration windowDuration;

  final Duration _pollInterval;
  DateTime _slotStart;
  int _currCount;
  int _prevCount;
  int _permitsAcquired;
  int _permitsRejected;
  bool _disposed = false;

  // ─────────────────────────────────────────────────────────────────────────
  // RateLimiter interface
  // ─────────────────────────────────────────────────────────────────────────

  @override
  bool tryAcquire() {
    _checkDisposed();
    _advanceSlotIfNeeded();
    if (_estimated() < maxPermits) {
      _currCount++;
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
      _advanceSlotIfNeeded();
      if (_estimated() < maxPermits) {
        _currCount++;
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
          retryAfter: _timeUntilSlotAdvances(),
        );
      }

      // Wait until the next slot advance or the poll interval, whichever
      // is sooner — that is when the estimated count is most likely to drop.
      final tillSlot = _timeUntilSlotAdvances();
      final wait = (tillSlot < _pollInterval && tillSlot > Duration.zero)
          ? tillSlot
          : _pollInterval;
      await Future<void>.delayed(wait);
      _checkDisposed();
    }
  }

  @override
  RateLimiterStatistics get statistics {
    _advanceSlotIfNeeded();
    final estimated = _estimated();
    return RateLimiterStatistics(
      permitsAcquired: _permitsAcquired,
      permitsRejected: _permitsRejected,
      currentPermits: (maxPermits - estimated).clamp(0, maxPermits).toInt(),
      maxPermits: maxPermits,
    );
  }

  @override
  void dispose() {
    _disposed = true;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Internal
  // ─────────────────────────────────────────────────────────────────────────

  /// Weighted estimate of requests within the rolling window.
  double _estimated() {
    final slotUs = windowDuration.inMicroseconds;
    final elapsedUs = DateTime.now().difference(_slotStart).inMicroseconds;
    final ratio = elapsedUs / slotUs;
    return _prevCount * (1.0 - ratio) + _currCount;
  }

  void _advanceSlotIfNeeded() {
    final elapsed = DateTime.now().difference(_slotStart);
    if (elapsed >= windowDuration) {
      final slotsPassed =
          elapsed.inMicroseconds ~/ windowDuration.inMicroseconds;
      // If more than one slot has passed the previous window is irrelevant.
      _prevCount = slotsPassed >= 2 ? 0 : _currCount;
      _currCount = 0;
      _slotStart = _slotStart.add(
        Duration(microseconds: slotsPassed * windowDuration.inMicroseconds),
      );
    }
  }

  Duration _timeUntilSlotAdvances() {
    final elapsed = DateTime.now().difference(_slotStart);
    final remaining = windowDuration - elapsed;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  void _checkDisposed() {
    if (_disposed) {
      throw StateError('SlidingWindowRateLimiter has been disposed.');
    }
  }
}
