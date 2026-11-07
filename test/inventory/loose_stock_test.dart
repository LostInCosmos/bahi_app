import 'package:flutter_test/flutter_test.dart';

import 'package:gst_bill_app/features/inventory/models/loose_stock.dart';
import 'package:gst_bill_app/features/inventory/models/product.dart';
import 'package:gst_bill_app/features/sales/models/sale.dart';

/// DAS-160: a medicine sold by the tablet counts its stock and its sale lines
/// in tablets; anything else, and every reply from an older server, stays in
/// packs exactly as before.

Map<String, dynamic> _strip({int units = 45, double packs = 4.5}) => {
      'id': 1,
      'name': 'Paracetamol 650',
      'quantity_on_hand': packs,
      'units_per_pack': 10,
      'sold_loose': true,
      'unit_kind': 'tablet',
      'units_on_hand': units,
      'unit_mrp': 10.0,
    };

void main() {
  test('a strip of 10 sold loose reads its stock in tablets, with the strips beside it', () {
    final p = ProductSummary.fromJson(_strip());
    expect(p.loose.loose, isTrue);
    expect(p.loose.stock(p.quantityOnHand), '45 tablets');
    expect(p.loose.packBreakdown(p.quantityOnHand), '4 strips + 5');
    expect(p.loose.packBreakdown(4), isNull, reason: '4 strips is not 45 tablets: mixed sizes, so no split');
    expect(p.loose.typingHint, 'Strip of 10, so 2 strips = 20 tablets');
    expect(p.loose.fieldLabel, 'Tablets');
    expect(p.loose.wholeOnly, isFalse);
  });

  test('a whole number of strips has no remainder, and under one strip has no split', () {
    expect(ProductSummary.fromJson(_strip(units: 40, packs: 4)).loose.packBreakdown(4), '4 strips');
    expect(ProductSummary.fromJson(_strip(units: 5, packs: 0.5)).loose.packBreakdown(0.5), isNull);
  });

  test('a box of 100 is a pack, not a strip', () {
    final box = LooseStock.fromJson({'units_per_pack': 100, 'sold_loose': true, 'unit_kind': 'tablet', 'units_on_hand': 230});
    expect(box.packBreakdown(2.3), '2 packs + 30');
  });

  test('a loose count with no stated form is in units', () {
    final l = LooseStock.fromJson({'units_per_pack': 10, 'sold_loose': true, 'units_on_hand': 1});
    expect(l.stock(0.1), '1 unit');
    expect(l.fieldLabel, 'Units');
  });

  test('a bottle the server says is pack only stays in packs, and is whole only', () {
    final p = ProductSummary.fromJson({
      'id': 2,
      'name': 'Thyronorm 50',
      'quantity_on_hand': 3,
      'units_per_pack': 60,
      'sold_loose': false,
      'unit_kind': 'capsule',
      'units_on_hand': null,
    });
    expect(p.loose.loose, isFalse);
    expect(p.loose.stock(p.quantityOnHand), '3');
    expect(p.loose.packBreakdown(3), isNull);
    expect(p.loose.typingHint, isNull);
    expect(p.loose.wholeOnly, isTrue);
  });

  test('sold_loose without a pack size is not loose: the server would refuse the line', () {
    expect(LooseStock.fromJson({'sold_loose': true}).loose, isFalse);
  });

  test('an older server sends none of it: packs, as before, and not called whole only', () {
    final p = ProductSummary.fromJson({'id': 3, 'name': 'Dolo', 'quantity_on_hand': 7});
    expect(p.loose.loose, isFalse);
    expect(p.loose.wholeOnly, isFalse);
    expect(p.loose.stock(7), '7');
  });

  test('a batch and a product detail carry their own pack size, kept across an MRP edit', () {
    final d = ProductDetail.fromJson({
      ..._strip(),
      'total_quantity': 4.5,
      'batches': [
        {'id': 7, 'quantity_on_hand': 4.5, 'gst_pct': 12, 'is_expired': false, 'mrp': 100, ..._strip()..remove('id')},
      ],
    });
    expect(d.loose.loose, isTrue);
    final b = d.batches.single.withMrp(120);
    expect(b.loose.unitsPerPack, 10);
    expect(d.withBatch(b).loose.loose, isTrue);
  });

  test('a sale line sold loose says how many tablets; a pack line says pcs (DAS-170)', () {
    final loose = SaleLineItemDetail.fromJson({
      'product_name': 'Paracetamol 650',
      'qty': 20,
      'rate': 10,
      'gst_pct': 12,
      'cgst_amount': 10.71,
      'sgst_amount': 10.71,
      'line_amount': 200,
      'unit': 'loose',
      'unit_kind': 'tablet',
    });
    expect(loose.qtyText, '20 tablets');
    final pack = SaleLineItemDetail.fromJson({
      'product_name': 'Cough Syrup',
      'qty': 2,
      'rate': 85,
      'gst_pct': 12,
      'cgst_amount': 9.11,
      'sgst_amount': 9.11,
      'line_amount': 170,
    });
    expect(pack.qtyText, '2 pcs');
  });

  test('the oversell note counts tablets on a loose line', () {
    expect(stockNote(50, 45, loose: true, unitKind: 'tablet'),
        'Only 45 tablets in inventory. The item is still billed; only this note stays off the bill.');
    expect(stockNote(5, 3), 'Only 3 in inventory. The item is still billed; only this note stays off the bill.');
    final c = CartEntry(
        productBatchId: 7, productName: 'P', qty: 50, rate: 10, gstPct: 12, available: 45, loose: true, unitKind: 'tablet');
    expect(c.shortStockNote, 'Only 45 tablets in inventory · still billed');
    expect(c.edited(qty: 20, rate: 10).loose, isTrue, reason: 'an edit keeps the unit');
  });
}
