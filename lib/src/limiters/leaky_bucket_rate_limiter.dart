import 'dart:async';

import '../exceptions/rate_limit_exceeded_exception.dart';
import 'rate_limiter.dart';

/// A [RateLimiter] implementing the **Leaky Bucket** algorithm.
///
/// ## Algorithm
///
/// Requests enter a fixed-size queue (the "bucket"). A leak timer processes
/// one request per [leakInterval], draining the queue at a steady rate.
/// New requests that arrive when the queue is full are rejected immediately.
///
/// ## Characteristics
///
/// | Property         | Value |
/// |------------------|-------|
/// | Output rate      | Constant (1 request per [leakInterval]) |
/// | Burst handling   | Absorbs bursts up to [capacity] |
/// | Memory           | O([capacity]) |
/// | Fairness         | FIFO queue |
/// | Use case         | Smooth downstream load; upstream can spike |
///
/// ## Example
///
/// ```dart
/// // Process up to 10 requests/second with a burst buffer of 50.
/// final limiter = LeakyBucketRateLimiter(
///   capacity: 50,
///   leakInterval: Duration(milliseconds: 100),  // 10 req/sec
/// );
/// ```
///
/// ## Note on [acquire]
///
/// [acquire] enqueues the caller and waits for it to be dequeued by the leak
/// timer. The effective wait time is proportional to the queue depth at entry.
final class LeakyBucketRateLimiter extends RateLimiter {
  /// Creates a [LeakyBucketRateLimiter].
  ///
  /// [capacity]     — maximum queue depth (bucket size).
  /// [leakInterval] — delay between processing consecutive requests.
  LeakyBucketRateLimiter({
    required this.capacity,
    required this.leakInterval,
  })  : assert(capacity > 0, 'capacity must be > 0'),
        assert(leakInterval > Duration.zero, 'leakInterval must be positive'),
        _permitsAcquired = 0,
        _permitsRejected = 0 {
    _startLeakTimer();
  }

  /// Maximum number of requests that can be queued simultaneously.
  final int capacity;

  /// Duration between processing consecutive requests from the queue.
  final Duration leakInterval;

  final List<_Waiter> _queue = [];
  int _permitsAcquired;
  int _permitsRejected;
  bool _disposed = false;
  Timer? _leakTimer;

  // ─────────────────────────────────────────────────────────────────────────
  // RateLimiter interface
  // ─────────────────────────────────────────────────────────────────────────

  @override
  bool tryAcquire() {
    _checkDisposed();
    if (_queue.length < capacity) {
      // Enqueue a pre-completed waiter to track slot usage.
      final w = _Waiter();
      w.completer.complete();
      _queue.add(w);
      _permitsAcquired++;
      return true;
    }
    _permitsRejected++;
    return false;
  }

  @override
  Future<void> acquire({Duration? timeout}) {
    _checkDisposed();
    if (_queue.length >= capacity) {
      _permitsRejected++;
      return Future.error(
        RateLimitExceededException(
          message: 'LeakyBucketRateLimiter: bucket capacity ($capacity) '
              'exceeded; request rejected.',
          limiterType: 'LeakyBucket',
          retryAfter: leakInterval,
        ),
      );
    }

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
            message: 'LeakyBucketRateLimiter: acquire timed out after '
                '${timeout.inMilliseconds}ms.',
            limiterType: 'LeakyBucket',
            retryAfter: _estimatedWait(),
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
        currentPermits: capacity - _queue.length,
        maxPermits: capacity,
        queueDepth: _queue.length,
      );

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _leakTimer?.cancel();
    _leakTimer = null;
    final pending = List<_Waiter>.of(_queue)
        .where((w) => !w.completer.isCompleted)
        .toList();
    _queue.clear();
    for (final w in pending) {
      w.completer.completeError(
        StateError(
          'LeakyBucketRateLimiter disposed while acquire was pending.',
        ),
      );
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Internal
  // ─────────────────────────────────────────────────────────────────────────

  void _startLeakTimer() {
    _leakTimer = Timer.periodic(leakInterval, (_) => _leak());
  }

  void _leak() {
    if (_queue.isEmpty) return;
    final waiter = _queue.removeAt(0);
    if (!waiter.completer.isCompleted) {
      _permitsAcquired++;
      waiter.completer.complete();
    }
  }

  Duration _estimatedWait() {
    final pos = _queue.length;
    return leakInterval * pos;
  }

  void _checkDisposed() {
    if (_disposed) {
      throw StateError('LeakyBucketRateLimiter has been disposed.');
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _Waiter
// ─────────────────────────────────────────────────────────────────────────────

final class _Waiter {
  final completer = Completer<void>();
}
