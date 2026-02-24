import 'dart:async';

import '../exceptions/rate_limit_exceeded_exception.dart';
import 'rate_limiter.dart';

/// A [RateLimiter] that limits the number of **concurrently in-flight**
/// operations rather than the rate of new requests over time.
///
/// ## Algorithm
///
/// Maintains an atomic in-flight counter. [tryAcquire] / [acquire] increment
/// the counter when a slot is available. [release] **must** be called when
/// the associated work completes — `HttpRateLimitHandler` calls it
/// automatically in a `try/finally` block.
///
/// ## Characteristics
///
/// | Property           | Value                                            |
/// |--------------------|--------------------------------------------------|
/// | Model              | Semaphore / bounded concurrency                  |
/// | Blocking [acquire] | ✅ FIFO queue, woken on [release]                |
/// | Time-based expiry  | ❌ Permits held until explicit [release]         |
/// | Use case           | Connection pools, downstream API concurrency cap |
///
/// ## ⚠ Release obligation
///
/// Unlike time-windowed limiters, permits acquired from [ConcurrencyLimiter]
/// are **not** automatically reclaimed. Always pair acquisition with a
/// `try/finally` that calls [release]:
///
/// ```dart
/// await limiter.acquire();
/// try {
///   // do work
/// } finally {
///   limiter.release();
/// }
/// ```
///
/// When used with `HttpRateLimitHandler`, this is handled automatically.
///
/// ## Example
///
/// ```dart
/// // Cap at 10 simultaneous outbound connections.
/// final limiter = ConcurrencyLimiter(maxConcurrency: 10);
/// ```
final class ConcurrencyLimiter extends RateLimiter {
  /// Creates a [ConcurrencyLimiter].
  ///
  /// [maxConcurrency] — maximum simultaneous in-flight permits.
  ConcurrencyLimiter({required this.maxConcurrency})
      : assert(maxConcurrency > 0, 'maxConcurrency must be > 0'),
        _inFlight = 0,
        _permitsAcquired = 0,
        _permitsRejected = 0;

  /// Maximum number of concurrent in-flight operations.
  final int maxConcurrency;

  int _inFlight;
  int _permitsAcquired;
  int _permitsRejected;
  bool _disposed = false;

  // FIFO queue of callers waiting for a slot.
  final _waiters = <_Waiter>[];

  // ─────────────────────────────────────────────────────────────────────────
  // RateLimiter interface
  // ─────────────────────────────────────────────────────────────────────────

  @override
  bool tryAcquire() {
    _checkDisposed();
    if (_inFlight < maxConcurrency) {
      _inFlight++;
      _permitsAcquired++;
      return true;
    }
    _permitsRejected++;
    return false;
  }

  @override
  Future<void> acquire({Duration? timeout}) {
    _checkDisposed();

    // Fast path — slot available.
    if (_inFlight < maxConcurrency) {
      _inFlight++;
      _permitsAcquired++;
      return Future<void>.value();
    }

    // Slow path — enqueue waiter and optionally arm a timeout.
    final waiter = _Waiter();
    _waiters.add(waiter);

    if (timeout != null) {
      waiter.timer = Timer(timeout, () {
        if (!waiter.completer.isCompleted) {
          _waiters.remove(waiter);
          _permitsRejected++;
          waiter.completer.completeError(
            RateLimitExceededException(
              message: 'ConcurrencyLimiter: acquire timed out after '
                  '${timeout.inMilliseconds}ms '
                  '($_inFlight/$maxConcurrency slots in use).',
              limiterType: 'Concurrency',
            ),
            StackTrace.current,
          );
        }
      });
    }

    return waiter.completer.future;
  }

  /// Releases a previously acquired slot, allowing the next queued waiter
  /// (if any) to proceed.
  ///
  /// Must be called exactly once per successful [acquire] / [tryAcquire].
  /// Extra calls are silently ignored when the in-flight count is already
  /// zero.
  @override
  void release() {
    if (_disposed || _inFlight == 0) return;
    _inFlight--;
    _dispatchNext();
  }

  @override
  RateLimiterStatistics get statistics => RateLimiterStatistics(
        permitsAcquired: _permitsAcquired,
        permitsRejected: _permitsRejected,
        currentPermits: maxConcurrency - _inFlight,
        maxPermits: maxConcurrency,
        queueDepth: _waiters.length,
      );

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // Fail all pending waiters.
    for (final w in _waiters) {
      w.timer?.cancel();
      if (!w.completer.isCompleted) {
        w.completer.completeError(
          StateError('ConcurrencyLimiter has been disposed.'),
          StackTrace.current,
        );
      }
    }
    _waiters.clear();
    _inFlight = 0;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Internal
  // ─────────────────────────────────────────────────────────────────────────

  void _dispatchNext() {
    while (_waiters.isNotEmpty && _inFlight < maxConcurrency) {
      final next = _waiters.removeAt(0);
      next.timer?.cancel();
      if (!next.completer.isCompleted) {
        _inFlight++;
        _permitsAcquired++;
        next.completer.complete();
        break;
      }
      // Waiter already timed out — skip and try the next one.
    }
  }

  void _checkDisposed() {
    if (_disposed) {
      throw StateError('ConcurrencyLimiter has been disposed.');
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal helpers
// ─────────────────────────────────────────────────────────────────────────────

final class _Waiter {
  final completer = Completer<void>();
  Timer? timer;
}
