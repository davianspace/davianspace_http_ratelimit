/// Server-side rate limiting layer.
///
/// Provides `ServerRateLimiter` for per-key request admission control in
/// any Dart HTTP server framework, plus `RateLimitKeyExtractor` with
/// built-in strategies for IP, user, route, global, and composite keying.
library;

export 'rate_limit_key_extractor.dart';
export 'server_rate_limiter.dart';
