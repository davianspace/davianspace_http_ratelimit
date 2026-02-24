/// davianspace_http_ratelimit
///
/// Enterprise-grade client-side HTTP rate limiting for the
/// `davianspace_http_resilience` pipeline.
///
/// ## Algorithms
///
/// | Class                        | Algorithm      | Burst | Queue |
/// |------------------------------|----------------|-------|-------|
/// | `TokenBucketRateLimiter`     | Token Bucket   | ✅     | ✅     |
/// | `FixedWindowRateLimiter`     | Fixed Window   | ✅*    | ❌     |
/// | `SlidingWindowRateLimiter`   | Sliding Window | ✅     | ❌     |
/// | `LeakyBucketRateLimiter`     | Leaky Bucket   | ✅     | ✅     |
///
/// *Fixed Window supports burst at window boundaries — use Sliding Window
///  for precise burst control.
///
/// ## Quick start
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
library davianspace_http_ratelimit;

// Exception
export 'src/exceptions/rate_limit_exceeded_exception.dart';

// Handler, policy, builder-extension
export 'src/handler/http_client_builder_extension.dart';
export 'src/handler/http_rate_limit_handler.dart';
export 'src/handler/rate_limit_policy.dart';

// Headers
export 'src/headers/rate_limit_headers.dart';

// Algorithms
export 'src/limiters/fixed_window_rate_limiter.dart';
export 'src/limiters/leaky_bucket_rate_limiter.dart';
export 'src/limiters/rate_limiter.dart';
export 'src/limiters/sliding_window_rate_limiter.dart';
export 'src/limiters/token_bucket_rate_limiter.dart';
