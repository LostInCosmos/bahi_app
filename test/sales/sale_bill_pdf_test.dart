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

  test('amounts in words, the Indian way', () {
    expect(rupeesInWords(0), 'Rupees Zero Only');
    expect(rupeesInWords(699), 'Rupees Six Hundred Ninety-Nine Only');
    expect(rupeesInWords(1234.5), 'Rupees One Thousand Two Hundred Thirty-Four and Fifty Paise Only');
    expect(rupeesInWords(150000), 'Rupees One Lakh Fifty Thousand Only');
    expect(rupeesInWords(21000000), 'Rupees Two Crore Ten Lakh Only');
    expect(rupeesInWords(100.05), 'Rupees One Hundred and Five Paise Only');
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
