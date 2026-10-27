import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/config/gst_states.dart';
import '../../auth/models/account.dart';
import '../models/amount_words.dart';
import '../models/sale.dart';

/// The two weights of the bill's font. Noto Sans (SIL OFL, bundled under
/// assets/fonts): the PDF's built-in fonts have no ₹.
class BillFonts {
  final pw.Font regular;
  final pw.Font bold;
  const BillFonts(this.regular, this.bold);

  static Future<BillFonts> load() async => BillFonts(
        pw.Font.ttf(await rootBundle.load('assets/fonts/NotoSans-Regular.ttf')),
        pw.Font.ttf(await rootBundle.load('assets/fonts/NotoSans-Bold.ttf')),
      );
}

/// Whether the shop's bill is a tax invoice: only a shop with a GSTIN can
/// issue one. Without, it is a bill of supply.
bool isTaxInvoice(AccountInfo shop) => (shop.gstin ?? '').isNotEmpty;

/// The file name a bill is shared and saved under: `Bill-2026-27-0042.pdf`.
String billFileName(SaleDetail sale) => 'Bill-${sale.saleNo.replaceAll(RegExp(r'[^A-Za-z0-9-]'), '-')}.pdf';

/// The sale as an A4 bill (DAS-121), drawn on the phone from the server's
/// sale — its numbers, rounding and GST split, never the cart's — so a
/// reprint always matches. Long sales run onto more pages: the first carries
/// the full shop header, later ones a one-line header; the column headings
/// repeat; the totals come once, at the end.
///
/// A shop with a GSTIN issues a TAX INVOICE. One without cannot, so its bill
/// is a BILL OF SUPPLY with no GST columns or summary.
///
/// [compress] is for tests, which read the file's structure back.
Future<Uint8List> buildSaleBillPdf(SaleDetail sale, AccountInfo shop, BillFonts fonts, {bool compress = true}) {
  final taxInvoice = isTaxInvoice(shop);
  final doc = pw.Document(
    compress: compress,
    version: compress ? PdfVersion.pdf_1_5 : PdfVersion.pdf_1_4,
    title: 'Bill ${sale.saleNo}',
    author: shop.tenantName,
    creator: 'Dastavez',
  );
  final theme = pw.ThemeData.withFont(base: fonts.regular, bold: fonts.bold).copyWith(
        defaultTextStyle: pw.TextStyle(font: fonts.regular, fontBold: fonts.bold, fontSize: 8),
      );
  doc.addPage(pw.MultiPage(
    theme: theme,
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.fromLTRB(28, 28, 28, 24),
    // A long sale fits; the default of 20 pages would refuse a very long one.
    maxPages: 100,
    header: (ctx) => ctx.pageNumber == 1 ? _fullHeader(sale, shop, taxInvoice) : _miniHeader(sale, shop),
    footer: (ctx) => pw.Column(children: [
      if (ctx.pageNumber < ctx.pagesCount)
        pw.Container(
          alignment: pw.Alignment.centerRight,
          margin: const pw.EdgeInsets.only(top: 4),
          child: pw.Text('Continued on page ${ctx.pageNumber + 1} …', style: const pw.TextStyle(fontWeight: pw.FontWeight.bold)),
        ),
      pw.Container(
        alignment: pw.Alignment.center,
        margin: const pw.EdgeInsets.only(top: 6),
        child: pw.Text('Bill ${sale.saleNo} · Page ${ctx.pageNumber} of ${ctx.pagesCount}',
            style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey700)),
      ),
    ]),
    build: (ctx) => [
      _items(sale, taxInvoice),
      pw.SizedBox(height: 10),
      _totals(sale, taxInvoice),
      pw.SizedBox(height: 14),
      _signature(shop, taxInvoice),
    ],
  ));
  return doc.save();
}

String _date(String iso) {
  final p = iso.split('-');
  return p.length == 3 ? '${p[2]}-${p[1]}-${p[0]}' : iso;
}

String _expiry(String? iso) {
  if (iso == null) return '';
  final p = iso.split('-');
  return p.length >= 2 ? '${p[1]}/${p[0].substring(2)}' : iso;
}

String _money(double v) => v.toStringAsFixed(2);

String _qty(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

/// "98390 12345" from the 10 digits the server stores.
String _phone(String p) => p.length == 10 ? '${p.substring(0, 5)} ${p.substring(5)}' : p;

/// The prescriber as the bill prints it: "Dr" in front unless typed already.
String doctorLine(String name) => RegExp(r'^dr\b', caseSensitive: false).hasMatch(name) ? name : 'Dr $name';

final _border = pw.Border.all(width: 1, color: PdfColors.grey800);

pw.Widget _fullHeader(SaleDetail sale, AccountInfo shop, bool taxInvoice) {
  final state = stateOfGstin(shop.gstin);
  final buyerState = stateOfGstin(sale.buyerGstin);
  return pw.Column(children: [
    pw.Container(
      decoration: pw.BoxDecoration(border: _border),
      padding: const pw.EdgeInsets.all(8),
      child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Expanded(
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text(shop.tenantName.toUpperCase(), style: const pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold)),
            // A line with nothing to say is left out, never printed blank.
            if ((shop.address ?? '').isNotEmpty) pw.Text(shop.address!),
            if ((shop.phone ?? '').isNotEmpty) pw.Text('Phone: ${_phone(shop.phone!)}'),
            if ((shop.dlNo ?? '').isNotEmpty) pw.Text('D.L. No.: ${shop.dlNo}'),
            if (taxInvoice) pw.Text('GSTIN: ${shop.gstin}${state == null ? '' : ' · State: $state'}'),
          ]),
        ),
        pw.SizedBox(width: 12),
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
          pw.Text(taxInvoice ? 'TAX INVOICE' : 'BILL OF SUPPLY',
              style: const pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, letterSpacing: 1)),
          pw.SizedBox(height: 4),
          pw.Text('Bill No.: ${sale.saleNo}', style: const pw.TextStyle(fontWeight: pw.FontWeight.bold)),
          pw.Text('Date: ${_date(sale.saleDate)}'),
        ]),
      ]),
    ),
    pw.Container(
      decoration: pw.BoxDecoration(
          border: pw.Border(
              left: _border.left, right: _border.right, bottom: _border.bottom)),
      padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text('Buyer: ${(sale.buyerName ?? '').isEmpty ? 'Cash' : sale.buyerName}',
              style: const pw.TextStyle(fontWeight: pw.FontWeight.bold)),
          if ((sale.buyerGstin ?? '').isNotEmpty)
            pw.Text('GSTIN: ${sale.buyerGstin}${buyerState == null ? '' : ' · State: $buyerState'}'),
          // DAS-150: given at the sale, printed only when given.
          if ((sale.buyerPhone ?? '').isNotEmpty) pw.Text('Phone: ${_phone(sale.buyerPhone!)}'),
          if ((sale.doctorName ?? '').isNotEmpty) pw.Text('Prescribed by: ${doctorLine(sale.doctorName!)}'),
        ]),
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
          if (state != null) pw.Text('Place of supply: $state'),
          if (sale.paymentMode != null) pw.Text('Paid by: ${sale.paymentMode!.label}'),
        ]),
      ]),
    ),
    pw.SizedBox(height: 6),
  ]);
}

pw.Widget _miniHeader(SaleDetail sale, AccountInfo shop) => pw.Container(
      decoration: pw.BoxDecoration(border: _border),
      padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      margin: const pw.EdgeInsets.only(bottom: 6),
      child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Text(
            '${shop.tenantName.toUpperCase()}${(shop.gstin ?? '').isEmpty ? '' : ' · GSTIN ${shop.gstin}'}',
            style: const pw.TextStyle(fontWeight: pw.FontWeight.bold)),
        pw.Text('Bill No. ${sale.saleNo} · ${_date(sale.saleDate)}'),
      ]),
    );

pw.Widget _cell(String text, {pw.TextAlign align = pw.TextAlign.left, bool bold = false}) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      child: pw.Text(text, textAlign: align, style: bold ? const pw.TextStyle(fontWeight: pw.FontWeight.bold) : null),
    );

// HSN and Batch hold an 8-digit code and a batch of up to 10 characters on
// one line at 8 pt (they wrapped at 0.85 and 1.1); the item name gives way.
const _widths = {
  '#': 0.45, 'Item': 4.3, 'HSN': 1.2, 'Pack': 0.85, 'Batch': 1.65, 'Exp': 0.8,
  'MRP': 1.0, 'Qty': 0.6, 'Rate': 1.0, 'Disc': 0.85, 'GST%': 0.75, 'Amount': 1.25,
};

pw.Widget _items(SaleDetail sale, bool taxInvoice) {
  final headings = ['#', 'Item', 'HSN', 'Pack', 'Batch', 'Exp', 'MRP', 'Qty', 'Rate', 'Disc', if (taxInvoice) 'GST%', 'Amount'];
  final right = {'MRP', 'Qty', 'Rate', 'Disc', 'Amount'};
  final center = {'#', 'HSN', 'Pack', 'Batch', 'Exp', 'GST%'};
  pw.TextAlign alignOf(String h) =>
      right.contains(h) ? pw.TextAlign.right : (center.contains(h) ? pw.TextAlign.center : pw.TextAlign.left);
  return pw.Table(
    border: pw.TableBorder(
      left: _border.left,
      right: _border.right,
      top: _border.top,
      bottom: _border.bottom,
      verticalInside: const pw.BorderSide(width: 0.6, color: PdfColors.grey700),
    ),
    // The item name takes what the numbers leave, so a name rarely wraps and
    // a 60-line sale stays at two pages.
    columnWidths: {
      for (var c = 0; c < headings.length; c++) c: pw.FlexColumnWidth(_widths[headings[c]] ?? 1),
    },
    children: [
      // Repeated at the top of every page the table runs onto.
      pw.TableRow(
        repeat: true,
        decoration: const pw.BoxDecoration(
            color: PdfColors.grey200, border: pw.Border(bottom: pw.BorderSide(width: 0.8))),
        children: [for (final h in headings) _cell(h, align: pw.TextAlign.center, bold: true)],
      ),
      for (var i = 0; i < sale.lineItems.length; i++)
        () {
          final li = sale.lineItems[i];
          final values = [
            '${i + 1}',
            li.productName,
            li.hsn ?? '',
            li.pack ?? '',
            li.batchNo ?? '',
            _expiry(li.expiryDate),
            li.mrp == null ? '' : _money(li.mrp!),
            _qty(li.qty),
            _money(li.rate),
            li.discountTotal > 0 ? _money(li.discountTotal) : '',
            if (taxInvoice) _qty(li.gstPct),
            _money(li.netAmount),
          ];
          return pw.TableRow(children: [
            for (var c = 0; c < values.length; c++) _cell(values[c], align: alignOf(headings[c])),
          ]);
        }(),
    ],
  );
}

/// Taxable value, CGST and SGST by GST rate, from the server's own per-line
/// figures — never recomputed here.
List<({double rate, double taxable, double cgst, double sgst})> gstSummary(SaleDetail sale) {
  final byRate = <double, ({double taxable, double cgst, double sgst})>{};
  for (final li in sale.lineItems) {
    final r = byRate[li.gstPct] ?? (taxable: 0.0, cgst: 0.0, sgst: 0.0);
    byRate[li.gstPct] =
        (taxable: r.taxable + li.taxableValue, cgst: r.cgst + li.cgstAmount, sgst: r.sgst + li.sgstAmount);
  }
  final rates = byRate.keys.toList()..sort();
  return [for (final k in rates) (rate: k, taxable: byRate[k]!.taxable, cgst: byRate[k]!.cgst, sgst: byRate[k]!.sgst)];
}

pw.Widget _totals(SaleDetail sale, bool taxInvoice) {
  final summary = gstSummary(sale);
  final taxable = summary.fold(0.0, (s, r) => s + r.taxable);
  final discount = sale.lineItems.fold(0.0, (s, li) => s + li.discountTotal);
  pw.Widget line(String k, String v, {bool strong = false}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
        child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text(k, style: strong ? const pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11) : null),
          pw.Text(v, style: strong ? const pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11) : null),
        ]),
      );
  return pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
    pw.Expanded(
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        if (taxInvoice)
          pw.Table(
            border: pw.TableBorder.all(width: 0.6, color: PdfColors.grey700),
            children: [
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfColors.grey200),
                children: [for (final h in ['GST%', 'Taxable', 'CGST', 'SGST']) _cell(h, align: pw.TextAlign.center, bold: true)],
              ),
              for (final r in summary)
                pw.TableRow(children: [
                  _cell(_qty(r.rate), align: pw.TextAlign.center),
                  _cell(_money(r.taxable), align: pw.TextAlign.right),
                  _cell(_money(r.cgst), align: pw.TextAlign.right),
                  _cell(_money(r.sgst), align: pw.TextAlign.right),
                ]),
            ],
          ),
        pw.SizedBox(height: 6),
        pw.Text(rupeesInWords(sale.grandTotal)),
      ]),
    ),
    pw.SizedBox(width: 24),
    pw.SizedBox(
      width: 190,
      child: pw.Column(children: [
        line('Items (${sale.lineItems.length})', _money(sale.itemsTotal)),
        if (discount > 0) line('Discount', '−${_money(discount)}'),
        if (taxInvoice) ...[
          line('Taxable value', _money(taxable)),
          line('CGST', _money(sale.totalCgst)),
          line('SGST', _money(sale.totalSgst)),
        ],
        pw.Divider(height: 6, thickness: 1),
        line(taxInvoice ? 'Total (incl. GST)' : 'Total', '₹ ${_money(sale.grandTotal)}', strong: true),
        pw.Divider(height: 6, thickness: 1),
      ]),
    ),
  ]);
}

pw.Widget _signature(AccountInfo shop, bool taxInvoice) => pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      crossAxisAlignment: pw.CrossAxisAlignment.end,
      children: [
        pw.Text('Goods once sold will not be taken back.\n${taxInvoice ? 'Prices include GST. ' : ''}Made with Dastavez.',
            style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey800)),
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
          pw.Text('For ${shop.tenantName.toUpperCase()}'),
          pw.SizedBox(height: 26),
          pw.Container(
            width: 130,
            decoration: const pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(width: 0.6))),
            padding: const pw.EdgeInsets.only(top: 2),
            child: pw.Text('Authorised signatory', textAlign: pw.TextAlign.right),
          ),
        ]),
      ],
    );
