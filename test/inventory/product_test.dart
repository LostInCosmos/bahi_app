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

  // DAS-82: each batch names the purchase it came from, so the shopkeeper
  // can tell which shop/invoice a batch was bought on and open the full bill.
  group('ProductBatchInfo.fromJson', () {
    test('parses the source purchase when the batch has one', () {
      final b = ProductBatchInfo.fromJson({
        'id': 10,
        'batch_no': 'B1',
        'expiry_date': '2027-01-01T00:00:00',
        'quantity_on_hand': 5,
        'gst_pct': 12,
        'is_expired': false,
        'source_invoice_id': 99,
        'vendor_name': 'Sharma Medical Agency',
        'invoice_no': 'INV-2201',
      });
      expect(b.sourceInvoiceId, 99);
      expect(b.vendorName, 'Sharma Medical Agency');
      expect(b.invoiceNo, 'INV-2201');
    });

    test('a batch with no linked purchase sends none of the three', () {
      final b = ProductBatchInfo.fromJson({
        'id': 11,
        'batch_no': 'B2',
        'quantity_on_hand': 5,
        'gst_pct': 12,
        'is_expired': false,
      });
      expect(b.sourceInvoiceId, isNull);
      expect(b.vendorName, isNull);
      expect(b.invoiceNo, isNull);
    });

    // DAS-82, widened: the deal (rate/discount/free scheme) the batch was
    // bought on, from the originating purchase line — same field names
    // GET /invoices/{id} already uses for a line item.
    test('parses the deal when the server sends it', () {
      final b = ProductBatchInfo.fromJson({
        'id': 12,
        'batch_no': 'B3',
        'quantity_on_hand': 5,
        'gst_pct': 12,
        'is_expired': false,
        'net_rate': 8.5,
        'rate': 10.0,
        'discount_pct': 15,
        'discount_amount': 1.5,
        'free_qty': 2,
        'free_scheme': '10+2',
      });
      expect(b.netRate, 8.5);
      expect(b.rate, 10.0);
      expect(b.discountPct, 15);
      expect(b.discountAmount, 1.5);
      expect(b.freeQty, 2);
      expect(b.freeScheme, '10+2');
    });

    test('a server that has not shipped the deal fields yet sends none of them', () {
      final b = ProductBatchInfo.fromJson({
        'id': 13,
        'batch_no': 'B4',
        'quantity_on_hand': 5,
        'gst_pct': 12,
        'is_expired': false,
      });
      expect(b.netRate, isNull);
      expect(b.rate, isNull);
      expect(b.discountPct, isNull);
      expect(b.discountAmount, isNull);
      expect(b.freeQty, isNull);
      expect(b.freeScheme, isNull);
    });
  });
}
