import 'package:flutter_test/flutter_test.dart';

import 'package:gst_bill_app/features/inventory/models/product.dart';

// DAS-81: the inventory list shows net rate / MRP / expiry from a product's
// soonest-expiring in-stock batch, sent as one bundle so the three values
// never come from different batches — all null together when nothing
// qualifies.

void main() {
  group('ProductSummary.fromJson', () {
    test('parses net rate, MRP and expiry when the server sends them', () {
      final p = ProductSummary.fromJson({
        'id': 1,
        'name': 'Paracetamol',
        'hsn_code': '3004',
        'pack': '10x10',
        'quantity_on_hand': 40,
        'net_rate': 8.5,
        'mrp': 12.0,
        'expiry_date': '2027-03-01T00:00:00',
      });
      expect(p.netRate, 8.5);
      expect(p.mrp, 12.0);
      expect(p.expiryDate, '2027-03-01');
    });

    test('an old server, or a product with nothing qualifying in stock, sends none of the three', () {
      final p = ProductSummary.fromJson({
        'id': 2,
        'name': 'Bandage',
        'quantity_on_hand': 0,
      });
      expect(p.netRate, isNull);
      expect(p.mrp, isNull);
      expect(p.expiryDate, isNull);
    });
  });
}
