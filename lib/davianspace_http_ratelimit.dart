/// davianspace_http_ratelimit
///
/// Enterprise-grade HTTP rate limiting for Dart and Flutter — both
/// **client-side** (pipeline handler for `davianspace_http_resilience`) and
/// **server-side** (per-key admission control for any HTTP server framework).
///
/// ## Algorithms
///
/// | Class                          | Algorithm              | Memory  | Queue | Notes                        |
/// |--------------------------------|------------------------|---------|-------|------------------------------|
/// | `TokenBucketRateLimiter`       | Token Bucket           | O(1)    | ✅     | Burst up to capacity         |
/// | `FixedWindowRateLimiter`       | Fixed Window           | O(1)    | ❌     | Simple; edge-burst at boundary|
/// | `SlidingWindowRateLimiter`     | Sliding Window Counter | O(1)    | ❌     | Approximate; no edge burst   |
/// | `SlidingWindowLogRateLimiter`  | Sliding Window Log     | O(n)    | ❌     | Exact; timestamp-per-request |
/// | `LeakyBucketRateLimiter`       | Leaky Bucket           | O(cap)  | ✅     | Constant output rate         |
/// | `ConcurrencyLimiter`           | Semaphore              | O(1)    | ✅     | Caps in-flight count         |
///
/// ## Client-side quick start
///
/// ```dart
/// import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';
/// import 'package:davianspace_http_ratelimit/davianspace_http_ratelimit.dart';
///
/// final client = HttpClientBuilder()
///     .withBaseUri(Uri.parse('https://api.example.com'))
///     .withLogging()
///     .withRateLimit(RateLimitPolicy(
///       limiter: TokenBucketRateLimiter(
///         capacity: 100,
///         refillAmount: 100,
///         refillInterval: Duration(seconds: 1),
///       ),
///       acquireTimeout: Duration(milliseconds: 500),
///     ))
///     .withRetry(RetryPolicy.exponential(maxRetries: 3))
///     .build();
///
/// final response = await client.get(Uri.parse('/v1/items'));
/// ```
///
/// ## Server-side quick start
///
/// ```dart
/// // Framework-agnostic: pass raw headers map + uri.
/// final limiter = ServerRateLimiter(
///   limiterFactory: () => FixedWindowRateLimiter(
///     maxPermits: 100,
///     windowDuration: Duration(minutes: 1),
///   ),
/// );
///
/// // In your request handler:
/// final ip = IpKeyExtractor().extractKey(request.headers, request.uri);
/// if (!limiter.tryAllow(ip)) {
///   return Response(429, body: 'Rate limit exceeded');
/// }
/// ```
library;

export 'src/backend/in_memory_rate_limiter_repository.dart';
export 'src/backend/rate_limiter_repository.dart';
export 'src/exceptions/rate_limit_exceeded_exception.dart';
export 'src/handler/http_client_builder_extension.dart';
export 'src/handler/http_rate_limit_handler.dart';
export 'src/handler/rate_limit_policy.dart';
export 'src/headers/rate_limit_headers.dart';
export 'src/limiters/concurrency_limiter.dart';
export 'src/limiters/fixed_window_rate_limiter.dart';
export 'src/limiters/leaky_bucket_rate_limiter.dart';
export 'src/limiters/rate_limiter.dart';
export 'src/limiters/sliding_window_log_rate_limiter.dart';
export 'src/limiters/sliding_window_rate_limiter.dart';
export 'src/limiters/token_bucket_rate_limiter.dart';
export 'src/server/rate_limit_key_extractor.dart';
export 'src/server/server_rate_limiter.dart';
