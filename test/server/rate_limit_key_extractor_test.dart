import 'package:davianspace_http_ratelimit/davianspace_http_ratelimit.dart';
import 'package:test/test.dart';

void main() {
  group('RateLimitKeyExtractor', () {
    // ──────────────────────────────────────────────────────────────────────
    // GlobalKeyExtractor
    // ──────────────────────────────────────────────────────────────────────
    group('GlobalKeyExtractor', () {
      test('always returns the __global__ sentinel', () {
        const extractor = GlobalKeyExtractor();
        expect(
          extractor.extractKey({}, Uri.parse('https://example.com/v1/data')),
          GlobalKeyExtractor.key,
        );
      });

      test('is invariant across different headers and uris', () {
        const extractor = GlobalKeyExtractor();
        const expected = GlobalKeyExtractor.key;
        expect(
          extractor.extractKey({'x-ip': '1.2.3.4'}, Uri.parse('/a')),
          expected,
        );
        expect(
          extractor.extractKey({'x-ip': '5.6.7.8'}, Uri.parse('/b')),
          expected,
        );
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // IpKeyExtractor
    // ──────────────────────────────────────────────────────────────────────
    group('IpKeyExtractor', () {
      const uri = 'https://example.com/';
      final u = Uri.parse(uri);

      test('reads first IP from x-forwarded-for', () {
        const e = IpKeyExtractor();
        expect(
          e.extractKey({'x-forwarded-for': '1.2.3.4, 5.6.7.8'}, u),
          '1.2.3.4',
        );
      });

      test('falls back to x-real-ip when xForwardedFor absent', () {
        const e = IpKeyExtractor();
        expect(e.extractKey({'x-real-ip': '9.10.11.12'}, u), '9.10.11.12');
      });

      test('falls back to fallbackKey when both headers absent', () {
        const e = IpKeyExtractor();
        expect(e.extractKey({}, u), 'unknown');
      });

      test('custom fallbackKey is used', () {
        const e = IpKeyExtractor(fallbackKey: 'n/a');
        expect(e.extractKey({}, u), 'n/a');
      });

      test('header lookup is case-insensitive', () {
        const e = IpKeyExtractor();
        expect(
          e.extractKey({'X-Forwarded-For': '2.2.2.2'}, u),
          '2.2.2.2',
        );
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // UserKeyExtractor
    // ──────────────────────────────────────────────────────────────────────
    group('UserKeyExtractor', () {
      final u = Uri.parse('https://example.com/');

      test('reads default x-user-id header', () {
        const e = UserKeyExtractor();
        expect(e.extractKey({'x-user-id': 'user_abc'}, u), 'user_abc');
      });

      test('reads custom header', () {
        const e = UserKeyExtractor(header: 'x-api-key');
        expect(e.extractKey({'x-api-key': 'key_xyz'}, u), 'key_xyz');
      });

      test('returns fallbackKey when header absent', () {
        const e = UserKeyExtractor();
        expect(e.extractKey({}, u), 'anonymous');
      });

      test('custom fallbackKey', () {
        const e = UserKeyExtractor(fallbackKey: 'guest');
        expect(e.extractKey({}, u), 'guest');
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // RouteKeyExtractor
    // ──────────────────────────────────────────────────────────────────────
    group('RouteKeyExtractor', () {
      test('returns uri.path', () {
        const e = RouteKeyExtractor();
        expect(
          e.extractKey({}, Uri.parse('https://api.example.com/v1/items')),
          '/v1/items',
        );
      });

      test('root path', () {
        const e = RouteKeyExtractor();
        expect(e.extractKey({}, Uri.parse('https://example.com/')), '/');
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // CustomKeyExtractor
    // ──────────────────────────────────────────────────────────────────────
    group('CustomKeyExtractor', () {
      test('delegates to supplied function', () {
        final e = CustomKeyExtractor(
          (headers, uri) => '${headers['x-tenant'] ?? 'none'}:${uri.path}',
        );
        expect(
          e.extractKey(
            {'x-tenant': 'acme'},
            Uri.parse('https://api.example.com/orders'),
          ),
          'acme:/orders',
        );
      });
    });

    // ──────────────────────────────────────────────────────────────────────
    // CompositeKeyExtractor
    // ──────────────────────────────────────────────────────────────────────
    group('CompositeKeyExtractor', () {
      test('joins two keys with default separator', () {
        final e = CompositeKeyExtractor([
          const IpKeyExtractor(),
          const RouteKeyExtractor(),
        ]);
        expect(
          e.extractKey(
            {'x-forwarded-for': '1.1.1.1'},
            Uri.parse('https://example.com/v1/data'),
          ),
          '1.1.1.1:/v1/data',
        );
      });

      test('custom separator', () {
        final e = CompositeKeyExtractor(
          [const IpKeyExtractor(), const UserKeyExtractor()],
          separator: '|',
        );
        expect(
          e.extractKey(
            {'x-forwarded-for': '1.1.1.1', 'x-user-id': 'alice'},
            Uri.parse('/'),
          ),
          '1.1.1.1|alice',
        );
      });

      test('asserts at least 2 extractors', () {
        expect(
          () => CompositeKeyExtractor([const IpKeyExtractor()]),
          throwsA(isA<AssertionError>()),
        );
      });
    });
  });
}
