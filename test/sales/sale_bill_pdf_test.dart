import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'package:gst_bill_app/core/config/gst_states.dart';
import 'package:gst_bill_app/features/auth/models/account.dart';
import 'package:gst_bill_app/features/sales/data/sale_bill_pdf.dart';
import 'package:gst_bill_app/features/sales/models/amount_words.dart';
import 'package:gst_bill_app/features/sales/models/sale.dart';

/// DAS-121: the sale bill, drawn on the phone from the server's sale.

BillFonts _fonts() => BillFonts(
      pw.Font.ttf(ByteData.sublistView(File('assets/fonts/NotoSans-Regular.ttf').readAsBytesSync())),
      pw.Font.ttf(ByteData.sublistView(File('assets/fonts/NotoSans-Bold.ttf').readAsBytesSync())),
    );

AccountInfo _shop({String? gstin = '09ABCDE1234F1Z5', String? dlNo = '20B/UP7820B001234', String? phone = '9839012345'}) =>
    AccountInfo(
      tenantName: 'Sharma Medical Store',
      gstin: gstin,
      address: '12, M.G. Road, Kanpur 208001',
      email: 's@example.com',
      businessType: 'medical',
      dlNo: dlNo,
      phone: phone,
    );

SaleLineItemDetail _line(int i) => SaleLineItemDetail(
      productName: 'Medicine number $i 500 mg tablet',
      qty: 2,
      rate: 112,
      gstPct: i.isEven ? 12 : 5,
      cgstAmount: i.isEven ? 12 : 5.33,
      sgstAmount: i.isEven ? 12 : 5.33,
      lineAmount: 224,
      discountAmount: i == 0 ? 20 : 0,
      hsn: '3004',
      batchNo: 'B$i',
      expiryDate: '2028-06-30',
      mrp: 112,
      pack: '1×10',
    );

SaleDetail _sale(int lines, {String? buyerGstin}) => SaleDetail(
      id: 1,
      saleNo: '2026-27/0042',
      saleDate: '2026-10-25',
      buyerName: buyerGstin == null ? null : 'City Nursing Home',
      buyerGstin: buyerGstin,
      subtotal: 0,
      totalCgst: 10,
      totalSgst: 10,
      grandTotal: 1234.5,
      lineItems: [for (var i = 0; i < lines; i++) _line(i)],
    );

/// Pages in an uncompressed PDF 1.4 file: one `/Type /Page` each.
int _pages(Uint8List bytes) => RegExp(r'/Type\s*/Page(?![s])').allMatches(latin1.decode(bytes)).length;

void main() {
  test('the bundled font has the rupee sign', () {
    final parser = TtfParser(ByteData.sublistView(File('assets/fonts/NotoSans-Regular.ttf').readAsBytesSync()));
    expect(parser.charToGlyphIndexMap.containsKey(0x20B9), isTrue);
  });

  test('a short sale is one page; a 60-line sale runs onto more', () async {
    final one = await buildSaleBillPdf(_sale(5), _shop(), _fonts(), compress: false);
    final long = await buildSaleBillPdf(_sale(60), _shop(), _fonts(), compress: false);
    expect(_pages(one), 1);
    expect(_pages(long), greaterThanOrEqualTo(2));
    // Kept for a look by eye (DAS-121 report): build/bill_samples/.
    Directory('build/bill_samples').createSync(recursive: true);
    File('build/bill_samples/one_page.pdf').writeAsBytesSync(await buildSaleBillPdf(_sale(5), _shop(), _fonts()));
    File('build/bill_samples/sixty_lines.pdf').writeAsBytesSync(await buildSaleBillPdf(_sale(60), _shop(), _fonts()));
    File('build/bill_samples/buyer_gstin.pdf')
        .writeAsBytesSync(await buildSaleBillPdf(_sale(3, buyerGstin: '09PQRST6789K1Z2'), _shop(), _fonts()));
    File('build/bill_samples/no_gstin_no_dl.pdf')
        .writeAsBytesSync(await buildSaleBillPdf(_sale(3), _shop(gstin: null, dlNo: null, phone: null), _fonts()));
  });

  test('only a shop with a GSTIN issues a tax invoice', () {
    expect(isTaxInvoice(_shop()), isTrue);
    expect(isTaxInvoice(_shop(gstin: null)), isFalse);
    expect(isTaxInvoice(_shop(gstin: '')), isFalse);
  });

  test('the GST summary adds up the server\'s own per-line figures, by rate', () {
    final rows = gstSummary(_sale(4));
    expect(rows.map((r) => r.rate), [5, 12]);
    final twelve = rows.last;
    // Two 12% lines: line 0 is 224 − 20 off − 24 GST = 180 taxable; line 2 is 200.
    expect(twelve.taxable, closeTo(380, 1e-9));
    expect(twelve.cgst, 24);
  });

  test('the file is named after the bill number', () {
    expect(billFileName(_sale(1)), 'Bill-2026-27-0042.pdf');
  });

  test('a GSTIN names its state', () {
    expect(stateOfGstin('09ABCDE1234F1Z5'), 'Uttar Pradesh (09)');
    expect(stateOfGstin('27AAAAA0000A1Z5'), 'Maharashtra (27)');
    expect(stateOfGstin(null), isNull);
    expect(stateOfGstin('99X'), isNull);
  });

  test('amounts in words, the Indian way, with Rupees after its number (DAS-170)', () {
    expect(rupeesInWords(0), 'Zero Rupees Only');
    expect(rupeesInWords(1), 'One Rupee Only');
    expect(rupeesInWords(699), 'Six Hundred Ninety-Nine Rupees Only');
    expect(rupeesInWords(1008.86), 'One Thousand Eight Rupees and Eighty-Six Paise Only');
    expect(rupeesInWords(1234.5), 'One Thousand Two Hundred Thirty-Four Rupees and Fifty Paise Only');
    expect(rupeesInWords(150000), 'One Lakh Fifty Thousand Rupees Only');
    expect(rupeesInWords(21000000), 'Two Crore Ten Lakh Rupees Only');
    expect(rupeesInWords(100.05), 'One Hundred Rupees and Five Paise Only');
    expect(rupeesInWords(0.01), 'Zero Rupees and One Paisa Only');
  });

  test('a quantity says what it counts: tablets, capsules, strips or pcs, never "unit" (DAS-170)', () {
    expect(saleQtyText(14, loose: true, unitKind: 'capsule', pack: '1*10'), '14 capsules');
    expect(saleQtyText(1, loose: true, unitKind: 'tablet', pack: '1×10'), '1 tablet');
    expect(saleQtyText(7, loose: true, unitKind: null, pack: '1*10'), '7 pcs');
    expect(saleQtyText(2, loose: false, unitKind: 'tablet', pack: '1×10'), '2 strips');
    expect(saleQtyText(1, loose: false, pack: '1*15'), '1 strip');
    expect(saleQtyText(1, loose: false, pack: '10*10'), '1 pc');
    expect(saleQtyText(3, loose: false, pack: '100ML'), '3 pcs');
    expect(saleQtyText(1, loose: false, pack: '1P'), '1 pc');
    expect(saleQtyText(2, loose: false, pack: null), '2 pcs');
    expect(isStripPack('1x30'), isTrue);
    expect(isStripPack('1x60'), isFalse);
    expect(isStripPack('1*1'), isFalse);
    for (final t in [
      saleQtyText(5, loose: true, unitKind: null),
      saleQtyText(5, loose: false, pack: 'BOX'),
      SaleLineItemDetail.fromJson({'product_name': 'X', 'qty': 7, 'rate': 1, 'gst_pct': 5, 'cgst_amount': 0, 'sgst_amount': 0, 'line_amount': 7, 'unit': 'loose', 'pack': '1*10'}).qtyText,
    ]) {
      expect(t, isNot(contains('unit')));
    }
  });

  test('the item table has no Pack column; Qty is wide enough for "14 capsules" on one line', () {
    expect(billColumns(true), isNot(contains('Pack')));
    expect(billColumns(false), isNot(contains('Pack')));
    expect(billColumns(true), contains('Qty'));
    // The Qty column's share of the A4 width (595 − 56 pt of margins), at the
    // 8 pt table font: Noto Sans sets "14 capsules" in about 44 pt.
    final total = billColumns(true).fold(0.0, (s, h) => s + billColumnWidth(h));
    expect(539 * billColumnWidth('Qty') / total - 4, greaterThan(46));
  });

  test('sample bills for a look by eye: pack-only, loose-only, mixed and long (DAS-170)', () async {
    SaleLineItemDetail li(String name, double qty, double rate, double amount,
            {bool loose = false, String? kind, String? pack, String? hsn, String? batch, String? exp, double? mrp, double disc = 0}) =>
        SaleLineItemDetail(
          productName: name, qty: qty, rate: rate, gstPct: 5, cgstAmount: amount * 0.05 / 2.1, sgstAmount: amount * 0.05 / 2.1,
          lineAmount: amount, discountAmount: disc, hsn: hsn, batchNo: batch, expiryDate: exp, mrp: mrp, pack: pack,
          loose: loose, unitKind: kind,
        );
    SaleDetail sale(String no, List<SaleLineItemDetail> lines, {String? buyer, String? doctor}) {
      final total = lines.fold(0.0, (s, l) => s + l.netAmount);
      return SaleDetail(
        id: 1, saleNo: no, saleDate: '2026-11-04', buyerName: buyer, doctorName: doctor, paymentMode: PaymentMode.cash,
        subtotal: 0, totalCgst: lines.fold(0.0, (s, l) => s + l.cgstAmount), totalSgst: lines.fold(0.0, (s, l) => s + l.sgstAmount),
        grandTotal: total, lineItems: lines,
      );
    }
    final packOnly = sale('2026-27/0101', [
      li('NERVITOP GEL', 1, 265, 265, pack: '1P', hsn: '30049081', batch: 'BYJ02AEA', exp: '2027-01-31', mrp: 265, disc: 26.5),
      li('CALTROL PLUS CAP', 2, 195, 390, pack: '1*10', hsn: '30049099', batch: 'P610601', exp: '2028-01-31', mrp: 195, kind: 'capsule'),
      li('BENADRYL COUGH SYRUP 100ML', 1, 112.5, 112.5, pack: '100ML', hsn: '30049011', batch: 'ZCG-029A', exp: '2027-06-30', mrp: 112.5),
      li('NACMED-SP TAB', 1, 108.2, 108.2, pack: '10*10', hsn: '300490', batch: 'UT-260900D', mrp: 108.2, kind: 'tablet'),
    ], buyer: 'Anuj');
    final looseOnly = sale('2026-27/0102', [
      li('CALTROL PLUS CAP', 14, 19.5, 273, loose: true, kind: 'capsule', pack: '1*10', hsn: '30049099', batch: 'P610601', exp: '2028-01-31', mrp: 195, disc: 27.3),
      li('GABAFIX-MNT', 7, 25.87, 181.09, loose: true, kind: null, pack: '1*10', hsn: '300490', batch: '26S38TA500', exp: '2028-03-31', mrp: 258.7, disc: 18.11),
      li('NACMED-SP TAB', 14, 1.08, 15.12, loose: true, kind: 'tablet', pack: '10*10', hsn: '300490', batch: 'UT-260900D', mrp: 108.2, disc: 1.51),
    ], buyer: 'Anuj', doctor: 'Raghvendra Tripathi');
    final mixed = sale('2026-27/0012', [
      li('NERVITOP GEL', 1, 265, 265, pack: '1P', hsn: '30049081', batch: 'BYJ02AEA', exp: '2027-01-31', mrp: 265, disc: 26.5),
      li('CALTROL PLUS CAP', 14, 19.5, 273, loose: true, kind: 'capsule', pack: '1*10', hsn: '30049099', batch: 'P610601', exp: '2028-01-31', mrp: 195, disc: 27.3),
      li('GABAFIX-MNT', 7, 25.87, 181.09, loose: true, kind: null, pack: '1*10', hsn: '300490', batch: '26S38TA500', exp: '2028-03-31', mrp: 258.7, disc: 18.11),
      li('CALCITAS D3 SOFTGEL', 7, 32.75, 229.25, loose: true, kind: null, pack: '1*10', hsn: '3004', batch: 'VHD2601005', exp: '2027-12-31', disc: 22.93),
      li('NACMED-SP TAB', 14, 1.08, 15.12, loose: true, kind: 'tablet', pack: '10*10', hsn: '300490', batch: 'UT-260900D', mrp: 108.2, disc: 1.51),
      li('EASE-D CAP', 14, 11.25, 157.5, loose: true, kind: 'capsule', pack: '1*10', hsn: '30049099', batch: 'ZCG-029A', exp: '2027-06-30', mrp: 112.5, disc: 15.75),
      li('CROCIN ADVANCE 500 MG TABLET STRIP OF FIFTEEN', 2, 30, 60, pack: '1*15', hsn: '30049099', batch: 'CR2611', exp: '2028-09-30', mrp: 30, kind: 'tablet'),
    ], buyer: 'Anuj', doctor: 'Raghvendra Tripathi');
    final long = sale('2026-27/0103', [
      for (var i = 0; i < 45; i++)
        i % 3 == 0
            ? li('LONG NAME MEDICINE NUMBER $i 500 MG TABLET', 2, 30, 60, pack: '1*10', hsn: '30049099', batch: 'B$i', exp: '2028-06-30', mrp: 30, kind: 'tablet')
            : li('MEDICINE $i', 14, 11.25, 157.5, loose: true, kind: i.isEven ? 'tablet' : 'capsule', pack: '1*10', hsn: '3004', batch: 'B$i', exp: '2028-06-30', mrp: 112.5),
    ], buyer: 'City Nursing Home');
    Directory('build/bill_samples').createSync(recursive: true);
    for (final (name, s) in [('pack_only', packOnly), ('loose_only', looseOnly), ('mixed', mixed), ('long', long)]) {
      File('build/bill_samples/das170_$name.pdf').writeAsBytesSync(await buildSaleBillPdf(s, _shop(), _fonts()));
    }
    expect(_pages(await buildSaleBillPdf(mixed, _shop(), _fonts(), compress: false)), 1);
  });

  test('a sale line reads the bill fields, and an older server leaves them null', () {
    final li = SaleLineItemDetail.fromJson({
      'product_name': 'X',
      'qty': 1,
      'rate': 10,
      'gst_pct': 12,
      'cgst_amount': 0.54,
      'sgst_amount': 0.53,
      'line_amount': 10,
      'hsn': '3004',
      'batch_no': 'B1',
      'expiry_date': '2028-06-30',
      'mrp': 10,
      'pack': '1×10',
    });
    expect((li.hsn, li.batchNo, li.expiryDate, li.mrp, li.pack), ('3004', 'B1', '2028-06-30', 10.0, '1×10'));
    final old = SaleLineItemDetail.fromJson(
        {'product_name': 'X', 'qty': 1, 'rate': 10, 'gst_pct': 12, 'cgst_amount': 0, 'sgst_amount': 0, 'line_amount': 10});
    expect((old.hsn, old.batchNo, old.expiryDate, old.mrp, old.pack), (null, null, null, null, null));
  });
}
