import 'dart:async';

import '../exceptions/rate_limit_exceeded_exception.dart';
import 'rate_limiter.dart';

/// A [RateLimiter] implementing the **Fixed Window** algorithm.
///
/// ## Algorithm
///
/// Time is divided into fixed, non-overlapping windows of [windowDuration].
/// Each window starts with [maxPermits] tokens. Requests are admitted until
/// the window's token budget is exhausted; further requests are rejected until
/// the next window begins.
///
/// ## Characteristics
///
/// | Property         | Value |
/// |------------------|-------|
/// | Burst support    | ✅ At window boundaries (up to 2× [maxPermits]) |
/// | Memory           | O(1) |
/// | Queue support    | ❌ [acquire] retries on next window tick |
/// | Edge burst       | ⚠️ Two consecutive max-rate windows can briefly admit 2× load |
///
/// The edge-burst issue is the primary weakness of fixed windows. For more
/// precise control use `SlidingWindowRateLimiter`.
///
/// ## Example
///
/// ```dart
/// // 100 requests per minute.
/// final limiter = FixedWindowRateLimiter(
///   maxPermits: 100,
///   windowDuration: Duration(minutes: 1),
/// );
/// ```
final class FixedWindowRateLimiter extends RateLimiter {
  /// Creates a [FixedWindowRateLimiter].
  ///
  /// [maxPermits]     — number of requests allowed per [windowDuration].
  /// [windowDuration] — length of each window.
  FixedWindowRateLimiter({
    required this.maxPermits,
    required this.windowDuration,
  })  : assert(maxPermits > 0, 'maxPermits must be > 0'),
        assert(
          windowDuration > Duration.zero,
          'windowDuration must be positive',
        ),
        _remaining = maxPermits,
        _windowEnd = DateTime.now().add(windowDuration),
        _permitsAcquired = 0,
        _permitsRejected = 0;

  /// Maximum requests allowed per [windowDuration].
  final int maxPermits;

  /// Duration of each window.
  final Duration windowDuration;

  int _remaining;
  DateTime _windowEnd;
  int _permitsAcquired;
  int _permitsRejected;
  bool _disposed = false;

  // ─────────────────────────────────────────────────────────────────────────
  // RateLimiter interface
  // ─────────────────────────────────────────────────────────────────────────

  @override
  bool tryAcquire() {
    _checkDisposed();
    _advanceWindowIfNeeded();
    if (_remaining > 0) {
      _remaining--;
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
      _advanceWindowIfNeeded();
      if (_remaining > 0) {
        _remaining--;
        _permitsAcquired++;
        return;
      }

      // Wait until the current window resets.
      final waitUntil = _windowEnd;
      final now = DateTime.now();

      if (deadline != null && now.isAfter(deadline)) {
        _permitsRejected++;
        throw RateLimitExceededException(
          message: 'FixedWindowRateLimiter: acquire timed out after '
              '${timeout!.inMilliseconds}ms.',
          limiterType: 'FixedWindow',
          retryAfter: _timeUntilNextWindow(),
        );
      }

      final waitDuration = waitUntil.difference(now);
      final clampedWait = (deadline != null)
          ? waitDuration < deadline.difference(now)
              ? waitDuration
              : deadline.difference(now)
          : waitDuration;

      if (clampedWait > Duration.zero) {
        await Future<void>.delayed(clampedWait);
      }

      _checkDisposed();
    }
  }

  @override
  RateLimiterStatistics get statistics {
    _advanceWindowIfNeeded();
    return RateLimiterStatistics(
      permitsAcquired: _permitsAcquired,
      permitsRejected: _permitsRejected,
      currentPermits: _remaining,
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

  void _advanceWindowIfNeeded() {
    final now = DateTime.now();
    if (!now.isBefore(_windowEnd)) {
      // Advance by however many windows have elapsed.
      while (!now.isBefore(_windowEnd)) {
        _windowEnd = _windowEnd.add(windowDuration);
      }
      _remaining = maxPermits;
    }
  }

  Duration _timeUntilNextWindow() => _windowEnd.difference(DateTime.now());

  void _checkDisposed() {
    if (_disposed) {
      throw StateError('FixedWindowRateLimiter has been disposed.');
    }
  }
}
