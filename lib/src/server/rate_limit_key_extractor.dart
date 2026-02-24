/// Extracts a rate-limit partition key from an incoming HTTP server request.
///
/// Built-in implementations cover the most common key strategies:
///
/// | Class                    | Key value                              |
/// |--------------------------|----------------------------------------|
/// | [GlobalKeyExtractor]     | `'__global__'` — single shared bucket  |
/// | [IpKeyExtractor]         | Client IP from forwarding headers      |
/// | [UserKeyExtractor]       | Configurable per-user/API-key header   |
/// | [RouteKeyExtractor]      | `uri.path`                             |
/// | [CustomKeyExtractor]     | Caller-supplied `String Function(…)`   |
///
/// Keys may be **composed** using [CompositeKeyExtractor] to combine multiple
/// dimensions (e.g. per-IP per-route).
///
/// ## Implementing a custom extractor
///
/// ```dart
/// final class TenantKeyExtractor implements RateLimitKeyExtractor {
///   @override
///   String extractKey(Map<String, String> headers, Uri uri) =>
///       headers['x-tenant-id'] ?? 'unknown';
/// }
/// ```
abstract interface class RateLimitKeyExtractor {
  /// Returns a rate-limit partition key derived from [headers] and [uri].
  ///
  /// The returned string is used to look up (or create) the per-key
  /// `RateLimiter` instance in the `RateLimiterRepository`. Keys must be
  /// stable and deterministic for the same logical caller.
  String extractKey(Map<String, String> headers, Uri uri);
}

// ─────────────────────────────────────────────────────────────────────────────
// Built-in extractors
// ─────────────────────────────────────────────────────────────────────────────

/// A [RateLimitKeyExtractor] that applies a **single shared bucket** to all
/// requests — effectively a global rate limit.
///
/// Use when you want to cap total throughput regardless of caller identity.
///
/// ```dart
/// final extractor = GlobalKeyExtractor();
/// // All requests share the key '__global__'.
/// ```
final class GlobalKeyExtractor implements RateLimitKeyExtractor {
  /// Creates a [GlobalKeyExtractor].
  const GlobalKeyExtractor();

  /// The shared key returned for every request.
  static const String key = '__global__';

  @override
  String extractKey(Map<String, String> headers, Uri uri) => key;
}

/// A [RateLimitKeyExtractor] that partitions by **client IP address**.
///
/// Reads the IP from the following headers in priority order:
/// 1. [forwardedForHeader] (default `'x-forwarded-for'`) — first value in the
///    comma-separated list (proxied IP chain).
/// 2. [realIpHeader] (default `'x-real-ip'`).
/// 3. Falls back to [fallbackKey] (default `'unknown'`) when no header is
///    present.
///
/// ```dart
/// final extractor = IpKeyExtractor();
/// ```
final class IpKeyExtractor implements RateLimitKeyExtractor {
  /// Creates an [IpKeyExtractor].
  const IpKeyExtractor({
    this.forwardedForHeader = 'x-forwarded-for',
    this.realIpHeader = 'x-real-ip',
    this.fallbackKey = 'unknown',
  });

  /// Header name for the forwarded IP chain (case-insensitive).
  final String forwardedForHeader;

  /// Header name for the real client IP (case-insensitive).
  final String realIpHeader;

  /// Key used when no IP header is present.
  final String fallbackKey;

  @override
  String extractKey(Map<String, String> headers, Uri uri) {
    final forwarded = _header(headers, forwardedForHeader);
    if (forwarded != null && forwarded.isNotEmpty) {
      // First entry in a comma list is the original client IP.
      return forwarded.split(',').first.trim();
    }
    return _header(headers, realIpHeader) ?? fallbackKey;
  }
}

/// A [RateLimitKeyExtractor] that partitions by **user identity** read from
/// a request header (e.g. `Authorization`, `X-API-Key`, `X-User-ID`).
///
/// ```dart
/// final extractor = UserKeyExtractor(header: 'x-api-key');
/// ```
final class UserKeyExtractor implements RateLimitKeyExtractor {
  /// Creates a [UserKeyExtractor].
  ///
  /// [header]      — the header name to read (case-insensitive).
  /// [fallbackKey] — key used when the header is absent (default `'anonymous'`).
  const UserKeyExtractor({
    this.header = 'x-user-id',
    this.fallbackKey = 'anonymous',
  });

  /// Header name containing the user or API-key identifier.
  final String header;

  /// Key used when [header] is absent.
  final String fallbackKey;

  @override
  String extractKey(Map<String, String> headers, Uri uri) =>
      _header(headers, header) ?? fallbackKey;
}

/// A [RateLimitKeyExtractor] that partitions by **request path** (`uri.path`).
///
/// Suitable for per-endpoint rate limiting.
///
/// ```dart
/// final extractor = RouteKeyExtractor();
/// // GET /v1/items  → key: '/v1/items'
/// ```
final class RouteKeyExtractor implements RateLimitKeyExtractor {
  /// Creates a [RouteKeyExtractor].
  const RouteKeyExtractor();

  @override
  String extractKey(Map<String, String> headers, Uri uri) => uri.path;
}

/// A [RateLimitKeyExtractor] driven by a caller-supplied function.
///
/// Use for any custom keying strategy not covered by the built-in extractors.
///
/// ```dart
/// final extractor = CustomKeyExtractor(
///   (headers, uri) => '${headers['x-tenant-id']}:${uri.path}',
/// );
/// ```
final class CustomKeyExtractor implements RateLimitKeyExtractor {
  /// Creates a [CustomKeyExtractor] backed by [extract].
  const CustomKeyExtractor(this.extract);

  /// User-supplied key extraction function.
  final String Function(Map<String, String> headers, Uri uri) extract;

  @override
  String extractKey(Map<String, String> headers, Uri uri) =>
      extract(headers, uri);
}

/// A [RateLimitKeyExtractor] that **combines** multiple extractors by
/// joining their keys with [separator].
///
/// Useful for multi-dimensional rate limiting (e.g. per-IP per-route).
///
/// ```dart
/// final extractor = CompositeKeyExtractor([
///   IpKeyExtractor(),
///   RouteKeyExtractor(),
/// ]);
/// // Produces keys like '1.2.3.4:/v1/items'
/// ```
final class CompositeKeyExtractor implements RateLimitKeyExtractor {
  /// Creates a [CompositeKeyExtractor].
  ///
  /// [extractors] — two or more extractors whose keys are joined.
  /// [separator]  — string placed between key segments (default `':'`).
  const CompositeKeyExtractor(
    this.extractors, {
    this.separator = ':',
  }) : assert(
          extractors.length >= 2,
          'CompositeKeyExtractor requires at least 2 extractors.',
        );

  /// Ordered list of extractors whose outputs are joined.
  final List<RateLimitKeyExtractor> extractors;

  /// Separator string between key segments.
  final String separator;

  @override
  String extractKey(Map<String, String> headers, Uri uri) =>
      extractors.map((e) => e.extractKey(headers, uri)).join(separator);
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal helper
// ─────────────────────────────────────────────────────────────────────────────

/// Case-insensitive header lookup.
String? _header(Map<String, String> headers, String name) {
  final lower = name.toLowerCase();
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == lower) return entry.value;
  }
  return null;
}
