import 'package:flutter_test/flutter_test.dart';

import 'package:gst_bill_app/features/capture/models/bill_search.dart';
import 'package:gst_bill_app/features/capture/models/upload_summary.dart';

/// Search by shop or invoice number, on what is loaded: "R" shows every shop
/// starting with R, "Ra" narrows that, each letter filters the previous result.

const _shops = [
  ('RADHE PHARMA', 'A100'),
  ('RAJ MEDICOS', 'B200'),
  ('PRIYA MEDICOS', 'C300'),
  ('KAPOOR TRADERS', 'R-77'),
  ('SHARMA AGENCY', 'D400'),
];

List<String> _find(String typed) => [
      for (final (shop, no) in _shops)
        if (matchesBillSearch(normaliseSearch(typed), shop: shop, invoiceNo: no)) shop,
    ];

void main() {
  group('the rule', () {
    test('nothing typed shows everything', () {
      expect(_find(''), hasLength(5));
      expect(_find('   '), hasLength(5), reason: 'spaces are not a search');
    });

    test('a shop name matches by its START, not by containing the letters', () {
      // "r" is IN Priya, Sharma and Kapoor, but only Radhe and Raj START with it.
      // (Kapoor Traders also appears, but through its invoice number R-77.)
      expect(_find('r'), unorderedEquals(['RADHE PHARMA', 'RAJ MEDICOS', 'KAPOOR TRADERS']));
      expect(_find('r'), isNot(contains('PRIYA MEDICOS')));
      expect(_find('r'), isNot(contains('SHARMA AGENCY')));
    });

    test('each letter narrows the previous result', () {
      final r = _find('r').toSet();
      final ra = _find('ra').toSet();
      final rad = _find('rad').toSet();
      expect(ra.difference(r), isEmpty, reason: '"ra" can only drop bills "r" showed');
      expect(rad.difference(ra), isEmpty);
      expect(ra, {'RADHE PHARMA', 'RAJ MEDICOS'});
      expect(rad, {'RADHE PHARMA'});
    });

    test('it is not case sensitive', () {
      expect(_find('RAD'), _find('rad'));
      expect(_find('Rad'), ['RADHE PHARMA']);
    });

    test('an invoice number matches by what it CONTAINS', () {
      expect(_find('300'), ['PRIYA MEDICOS']);
      expect(_find('-77'), ['KAPOOR TRADERS']);
    });

    test('a bill not read yet has nothing to be found by', () {
      expect(matchesBillSearch('r'), isFalse);
      expect(matchesBillSearch(''), isTrue);
    });

    test('stray spaces around a name or number do not matter', () {
      expect(matchesBillSearch('rad', shop: '  RADHE PHARMA '), isTrue);
    });
  });

  group('reading the list row', () {
    Map<String, dynamic> row(Map<String, dynamic> extra) => {
          'job_id': 1,
          'status': 'done',
          'source_image': '8/1.jpg',
          'created_at': '2026-10-08T10:00:00Z',
          ...extra,
        };

    test('takes the shop and the number', () {
      final u = UploadSummary.fromJson(row({'seller_name': 'RADHE PHARMA', 'invoice_no': 'A100'}));
      expect((u.sellerName, u.invoiceNo), ('RADHE PHARMA', 'A100'));
      expect(u.matchesSearch('rad'), isTrue);
    });

    test('blank or missing means none, and a server older than the fields still reads', () {
      final blank = UploadSummary.fromJson(row({'seller_name': '  ', 'invoice_no': ''}));
      expect((blank.sellerName, blank.invoiceNo), (null, null));
      final old = UploadSummary.fromJson(row({}));
      expect((old.sellerName, old.invoiceNo), (null, null));
    });

    test('filing a bill elsewhere keeps its shop and number', () {
      final u = UploadSummary.fromJson(row({'seller_name': 'RADHE PHARMA', 'invoice_no': 'A100'}));
      final moved = u.withFolder(5);
      expect((moved.sellerName, moved.invoiceNo), ('RADHE PHARMA', 'A100'));
    });
  });
}
