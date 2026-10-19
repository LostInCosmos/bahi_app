import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/inventory/data/inventory_api.dart';

/// DAS-105: a conditional GET. The product list is re-fetched on every tab
/// open; with the ETag sent back, an unchanged list is a 304 with no body.

http.Response _json(Object body, Map<String, String> headers) =>
    http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json', ...headers});

void main() {
  setUp(() => ApiClient.instance.token = 'session');
  tearDown(() => ApiClient.instance.token = null);

  test('the ETag comes back with the list, goes out as If-None-Match, and a 304 is "unchanged", not an error',
      () async {
    final seen = <String?>[];
    final client = MockClient((req) async {
      seen.add(req.headers['If-None-Match'] ?? req.headers['if-none-match']);
      if (seen.last == '"abc"') return http.Response('', 304, headers: {'etag': '"abc"'});
      return _json([
        {'id': 1, 'name': 'Dolo 650', 'quantity_on_hand': 3},
      ], {'etag': '"abc"'});
    });
    await http.runWithClient(() async {
      final first = await ApiClient.instance.fetchProducts();
      expect(first!.products.single.name, 'Dolo 650');
      expect(first.etag, '"abc"');

      final second = await ApiClient.instance.fetchProducts(ifNoneMatch: first.etag);
      expect(second, isNull, reason: 'a 304 means the held list is current');
      expect(seen, [null, '"abc"']);
      expect(ApiClient.instance.token, 'session', reason: 'a 304 is not a refused session');
    }, () => client);
  });

  test('a server without ETags answers the full list every time', () async {
    final client = MockClient((req) async => _json([
          {'id': 1, 'name': 'Dolo 650', 'quantity_on_hand': 3},
        ], {}));
    await http.runWithClient(() async {
      final page = await ApiClient.instance.fetchProducts(ifNoneMatch: '"stale"');
      expect(page, isNotNull);
      expect(page!.etag, isNull);
    }, () => client);
  });

  test('a 304 to a plain GET (no If-None-Match sent) is still an error', () async {
    final client = MockClient((req) async => http.Response('', 304));
    await http.runWithClient(() async {
      expect(() => ApiClient.instance.get('/x'), throwsA(isA<ApiException>()));
    }, () => client);
  });
}
