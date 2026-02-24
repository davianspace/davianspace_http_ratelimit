import 'package:davianspace_http_resilience/davianspace_http_resilience.dart';

import 'http_rate_limit_handler.dart';
import 'rate_limit_policy.dart';

/// Extends [HttpClientBuilder] with a [withRateLimit] method.
///
/// Import this package alongside `davianspace_http_resilience` to unlock
/// rate-limiting support in the [HttpClientBuilder] fluent API:
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
///         capacity: 500,
///         refillAmount: 500,
///         refillInterval: Duration(seconds: 1),
///       ),
///     ))
///     .build();
/// ```
extension HttpClientBuilderRateLimitExtension on HttpClientBuilder {
  /// Inserts an [HttpRateLimitHandler] at the current pipeline position.
  ///
  /// Place this handler **after** [HttpClientBuilder.withLogging] (so logging
  /// captures the full picture) and **before**
  /// [HttpClientBuilder.withRetry] (so retries are also rate-limited):
  ///
  /// ```
  /// withLogging()
  ///   .withRateLimit(policy)     ← here
  ///   .withRetry(retryPolicy)
  ///   .withTimeout(timeoutPolicy)
  /// ```
  ///
  /// The method returns `this` to continue the fluent chain.
  HttpClientBuilder withRateLimit(RateLimitPolicy policy) {
    addHandler(HttpRateLimitHandler(policy));
    return this;
  }
}
