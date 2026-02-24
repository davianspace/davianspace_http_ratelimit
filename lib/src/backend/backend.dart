/// Backend storage layer for `ServerRateLimiter`.
///
/// Provides `RateLimiterRepository` for managing per-key `RateLimiter`
/// instances, with `InMemoryRateLimiterRepository` as the built-in default.
///
/// To use a distributed backend (Redis, Memcached, etc.) implement
/// `RateLimiterRepository` and supply it to `ServerRateLimiter`.
library;

export 'in_memory_rate_limiter_repository.dart';
export 'rate_limiter_repository.dart';
