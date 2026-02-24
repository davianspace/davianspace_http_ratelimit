import '../limiters/rate_limiter.dart';
import 'rate_limiter_repository.dart';

/// Default in-memory implementation of [RateLimiterRepository].
///
/// Stores [RateLimiter] instances in a [Map] keyed by an arbitrary string.
/// All state exists within the current Dart isolate — suitable for
/// single-process deployments. For distributed or multi-instance deployments,
/// implement [RateLimiterRepository] backed by an external store.
///
/// ## Example
///
/// ```dart
/// final repo = InMemoryRateLimiterRepository();
///
/// final serverLimiter = ServerRateLimiter(
///   limiterFactory: () => TokenBucketRateLimiter(
///     capacity: 100,
///     refillAmount: 100,
///     refillInterval: Duration(seconds: 1),
///   ),
///   repository: repo,
/// );
/// ```
final class InMemoryRateLimiterRepository implements RateLimiterRepository {
  final _store = <String, RateLimiter>{};
  bool _disposed = false;

  @override
  RateLimiter getOrCreate(String key, RateLimiter Function() factory) {
    _checkDisposed();
    return _store.putIfAbsent(key, factory);
  }

  @override
  void remove(String key) {
    _store.remove(key)?.dispose();
  }

  @override
  void removeWhere(
    bool Function(String key, RateLimiter limiter) predicate,
  ) {
    final toRemove = _store.entries
        .where((e) => predicate(e.key, e.value))
        .map((e) => e.key)
        .toList();
    for (final key in toRemove) {
      _store.remove(key)?.dispose();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final limiter in _store.values) {
      limiter.dispose();
    }
    _store.clear();
  }

  void _checkDisposed() {
    if (_disposed) {
      throw StateError('InMemoryRateLimiterRepository has been disposed.');
    }
  }
}
