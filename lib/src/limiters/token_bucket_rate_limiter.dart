import 'dart:async';

import '../exceptions/rate_limit_exceeded_exception.dart';
import 'rate_limiter.dart';

/// A [RateLimiter] implementing the **Token Bucket** algorithm.
///
/// ## Algorithm
///
/// A bucket holds up to [capacity] tokens. Tokens are refilled continuously
/// at `refillRate` tokens per second (or [refillAmount] tokens per
/// [refillInterval]). Each [acquire] / [tryAcquire] consumes one token.
///
/// * When the bucket is full, excess tokens are discarded.
/// * When the bucket is empty, [tryAcquire] returns `false`; [acquire] blocks
///   until enough tokens are refilled.
///
/// ## Characteristics
///
/// | Property         | Value |
/// |------------------|-------|
/// | Burst support    | ✅ Up to [capacity] requests |
/// | Smooth smoothing | ✅ Continuous token generation |
/// | Queue support    | ✅ Blocking [acquire] with optional timeout |
/// | Fairness         | FIFO (completion order) |
///
/// ## Example
///
/// ```dart
/// // Allow 100 requests/second with a burst of 200.
/// final limiter = TokenBucketRateLimiter(
///   capacity: 200,
///   refillAmount: 100,
///   refillInterval: Duration(seconds: 1),
/// );
/// ```
final class TokenBucketRateLimiter extends RateLimiter {
  /// Creates a [TokenBucketRateLimiter].
  ///
  /// [capacity]       — maximum tokens the bucket can hold. Also the initial
  ///                    token count (bucket starts full).
  /// [refillAmount]   — tokens added per [refillInterval].
  /// [refillInterval] — how often to add [refillAmount] tokens.
  /// [initialTokens]  — starting token count; defaults to [capacity].
  TokenBucketRateLimiter({
    required this.capacity,
    required this.refillAmount,
    required this.refillInterval,
    int? initialTokens,
  })  : assert(capacity > 0, 'capacity must be > 0'),
        assert(refillAmount > 0, 'refillAmount must be > 0'),
        assert(
          refillInterval > Duration.zero,
          'refillInterval must be positive',
        ),
        _tokens = (initialTokens ?? capacity).clamp(0, capacity),
        _permitsAcquired = 0,
        _permitsRejected = 0 {
    _startRefillTimer();
  }

  /// Maximum tokens the bucket can hold.
  final int capacity;

  /// Tokens added per [refillInterval].
  final int refillAmount;

  /// Interval between refill ticks.
  final Duration refillInterval;

  int _tokens;
  int _permitsAcquired;
  int _permitsRejected;
  bool _disposed = false;

  // FIFO queue of pending waiters.
  final _queue = <_Waiter>[];
  Timer? _refillTimer;

  // ─────────────────────────────────────────────────────────────────────────
  // RateLimiter interface
  // ─────────────────────────────────────────────────────────────────────────

  @override
  bool tryAcquire() {
    _checkDisposed();
    if (_tokens > 0) {
      _tokens--;
      _permitsAcquired++;
      return true;
    }
    _permitsRejected++;
    return false;
  }

  @override
  Future<void> acquire({Duration? timeout}) {
    _checkDisposed();
    if (_tokens > 0) {
      _tokens--;
      _permitsAcquired++;
      return Future.value();
    }
    // Enqueue the waiter.
    final waiter = _Waiter();
    _queue.add(waiter);

    Timer? timeoutTimer;
    if (timeout != null) {
      timeoutTimer = Timer(timeout, () {
        if (waiter.completer.isCompleted) return;
        _queue.remove(waiter);
        _permitsRejected++;
        waiter.completer.completeError(
          RateLimitExceededException(
            message: 'TokenBucketRateLimiter: acquire timed out after '
                '${timeout.inMilliseconds}ms.',
            limiterType: 'TokenBucket',
            retryAfter: refillInterval,
          ),
        );
      });
    }

    return waiter.completer.future.whenComplete(() => timeoutTimer?.cancel());
  }

  @override
  RateLimiterStatistics get statistics => RateLimiterStatistics(
        permitsAcquired: _permitsAcquired,
        permitsRejected: _permitsRejected,
        currentPermits: _tokens,
        maxPermits: capacity,
        queueDepth: _queue.length,
      );

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _refillTimer?.cancel();
    _refillTimer = null;
    // Drain pending waiters with an error.
    final pending = List<_Waiter>.of(_queue);
    _queue.clear();
    for (final w in pending) {
      if (!w.completer.isCompleted) {
        w.completer.completeError(
          StateError(
            'TokenBucketRateLimiter disposed while acquire was pending.',
          ),
        );
      }
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Internal
  // ─────────────────────────────────────────────────────────────────────────

  void _startRefillTimer() {
    _refillTimer = Timer.periodic(refillInterval, (_) => _refill());
  }

  void _refill() {
    _tokens = (_tokens + refillAmount).clamp(0, capacity);
    _drainQueue();
  }

  void _drainQueue() {
    while (_queue.isNotEmpty && _tokens > 0) {
      final waiter = _queue.removeAt(0);
      if (waiter.completer.isCompleted) continue; // timed-out waiter
      _tokens--;
      _permitsAcquired++;
      waiter.completer.complete();
    }
  }

  void _checkDisposed() {
    if (_disposed) {
      throw StateError('TokenBucketRateLimiter has been disposed.');
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _Waiter — internal pending-acquire record
// ─────────────────────────────────────────────────────────────────────────────

final class _Waiter {
  final completer = Completer<void>();
}
