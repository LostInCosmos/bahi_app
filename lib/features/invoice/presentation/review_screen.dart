import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/api/api_client.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/busy_button.dart';
import '../data/invoice_api.dart';
import '../models/invoice.dart';
import '../widgets/saved_tick.dart';

/// How a number is written into a field, and read back: see [numText]. A
/// whole number stays whole and a fraction keeps Dart's own spelling, so the
/// round trip through `double.tryParse` is exact.
String _fmt(double v) => numText(v);
String _fmtNullable(double? v) => numText(v);

/// A bill doesn't always print a combined GST% — sometimes it only gives
/// CGST/SGST rates, or only the rupee amounts. Rather than leaving the
/// field blank (or hiding it) in those cases, derive it: CGST and SGST are
/// always equal for an intrastate sale, so whichever side is missing
/// mirrors the one that's present, and a rate not given at all is worked
/// back out of its amount (amount / (rate*qty) * 100).
double _computeGstPct(LineItem item) {
  if (item.gstPct > 0) return item.gstPct;
  final cgstPct = item.cgstPct ?? 0;
  final sgstPct = item.sgstPct ?? 0;
  if (cgstPct > 0 || sgstPct > 0) {
    final c = cgstPct > 0 ? cgstPct : sgstPct;
    final s = sgstPct > 0 ? sgstPct : cgstPct;
    return c + s;
  }
  final rateQty = item.rate * item.qty;
  if (rateQty > 0) {
    final amount = item.cgstAmount ?? item.sgstAmount;
    if (amount != null && amount > 0) {
      return (amount / rateQty * 100) * 2;
    }
  }
  return item.gstPct;
}

/// Backend validation issues on a line item come back as "Line [N].field"
/// (N is 0-based, matching this screen's own item index) — not the
/// "line_items[N].field" shape this screen used to expect. Shared here so
/// both the row-to-issues split below and each card's own field lookup stay
/// in sync with whatever the backend actually sends.
final _lineItemIssuePattern = RegExp(r'^Line \[(\d+)\]\.(.+)$');

/// Holds one line item's editable fields as controllers so the form can be
/// built/torn down per row without re-parsing on every keystroke.
class _LineItemForm {
  // Not editable UI fields (no TextEditingController) — a printed GST rate
  // is a fixed government slab, not something that goes stale when qty/
  // rate/discount changes the way cgstAmount/sgstAmount do, so there's no
  // "recompute" story for these the way forceRederiveTax has for the
  // amounts below. Plain pass-through fields, carried from the incoming
  // LineItem straight back out — toLineItem() used to just never set
  // these, silently dropping a bill's ONLY tax signal on every trip
  // through this screen when the extraction gave a rate (cgst_pct/
  // sgst_pct) rather than a plain gst_pct or a rupee amount.
  double? cgstPct;
  double? sgstPct;
  double? igstPct;
  // The server's per-unit rate after discount (DAS-136): not on the form,
  // carried back out so the save sends what the server sent.
  double? netRate;

  // Decided once, from whatever the extraction actually printed — a bill
  // states its discount as either a percentage or a flat amount, never
  // both, so only the one that's actually present is worth showing/editing.
  final bool showDiscountAmount;
  // The printed Disc value the server resolved from (DAS-9). Not editable —
  // the two boxes below are. Kept so revalidate can re-resolve it, and
  // dropped the moment the user overrides either box.
  final double? printedDiscount;
  final String _origDiscountPct;
  final String _origDiscountAmount;

  final TextEditingController productName;
  final TextEditingController pack;
  final TextEditingController batchNo;
  final TextEditingController expiry;
  final TextEditingController hsnCode;
  final TextEditingController qty;
  final TextEditingController freeQty;
  final TextEditingController freeScheme;
  final TextEditingController mrp;
  final TextEditingController rate;
  final TextEditingController discountPct;
  final TextEditingController discountAmount;
  final TextEditingController gstPct;
  final TextEditingController cgstAmount;
  final TextEditingController sgstAmount;
  final TextEditingController igstAmount;
  final TextEditingController grossAmount;

  _LineItemForm.fromLineItem(LineItem item)
      : printedDiscount = item.discount,
        _origDiscountPct = _fmtNullable(item.discountPct),
        _origDiscountAmount = _fmtNullable(item.discountAmount),
        cgstPct = item.cgstPct,
        sgstPct = item.sgstPct,
        igstPct = item.igstPct,
        netRate = item.netRate,
        showDiscountAmount =
            (item.discountPct == null || item.discountPct == 0) &&
                item.discountAmount != null,
        productName = TextEditingController(text: item.productName),
        pack = TextEditingController(text: item.pack ?? ''),
        batchNo = TextEditingController(text: item.batchNo ?? ''),
        expiry = TextEditingController(text: item.expiry ?? ''),
        hsnCode = TextEditingController(text: item.hsnCode ?? ''),
        qty = TextEditingController(text: _fmt(item.qty)),
        freeQty = TextEditingController(text: _fmtNullable(item.freeQty)),
        freeScheme = TextEditingController(text: item.freeScheme ?? ''),
        mrp = TextEditingController(text: _fmtNullable(item.mrp)),
        rate = TextEditingController(text: _fmt(item.rate)),
        discountPct =
            TextEditingController(text: _fmtNullable(item.discountPct)),
        discountAmount =
            TextEditingController(text: _fmtNullable(item.discountAmount)),
        gstPct = TextEditingController(text: _fmt(_computeGstPct(item))),
        cgstAmount = TextEditingController(text: _fmtNullable(item.cgstAmount)),
        sgstAmount = TextEditingController(text: _fmtNullable(item.sgstAmount)),
        igstAmount = TextEditingController(text: _fmtNullable(item.igstAmount)),
        grossAmount = TextEditingController(text: _fmt(item.grossAmount));

  _LineItemForm.empty() : this.fromLineItem(LineItem());

  /// True once the user has typed over either discount box, so their value
  /// must win over the printed figure the server resolved earlier.
  bool get discountEdited =>
      discountPct.text != _origDiscountPct ||
      discountAmount.text != _origDiscountAmount;

  LineItem toLineItem() => LineItem(
        productName: productName.text,
        pack: pack.text.isEmpty ? null : pack.text,
        batchNo: batchNo.text.isEmpty ? null : batchNo.text,
        expiry: expiry.text.isEmpty ? null : expiry.text,
        hsnCode: hsnCode.text.isEmpty ? null : hsnCode.text,
        qty: double.tryParse(qty.text) ?? 0,
        freeQty: double.tryParse(freeQty.text),
        freeScheme: freeScheme.text.isEmpty ? null : freeScheme.text,
        mrp: double.tryParse(mrp.text),
        rate: double.tryParse(rate.text) ?? 0,
        discount: discountEdited ? null : printedDiscount,
        discountPct: double.tryParse(discountPct.text),
        discountAmount: double.tryParse(discountAmount.text),
        gstPct: double.tryParse(gstPct.text) ?? 0,
        cgstPct: cgstPct,
        sgstPct: sgstPct,
        igstPct: igstPct,
        cgstAmount: double.tryParse(cgstAmount.text),
        sgstAmount: double.tryParse(sgstAmount.text),
        igstAmount: double.tryParse(igstAmount.text),
        grossAmount: double.tryParse(grossAmount.text) ?? 0,
        netRate: netRate,
      );

  void dispose() {
    for (final c in [
      productName,
      pack,
      batchNo,
      expiry,
      hsnCode,
      qty,
      freeQty,
      freeScheme,
      mrp,
      rate,
      discountPct,
      discountAmount,
      gstPct,
      cgstAmount,
      sgstAmount,
      igstAmount,
      grossAmount,
    ]) {
      c.dispose();
    }
  }
}

class ReviewScreen extends StatefulWidget {
  final ExtractionResult result;
  // Fired right after a revalidate call completes (clean or not) — lets the
  // caller (CaptureScreen) keep its own batch-item status in sync even if
  // the user backs out of this screen without saving. Without this, a bill
  // that was pushed here because it needed review, then got cleanly fixed
  // and revalidated, would still show the stale "needs review" badge on the
  // batch grid until it's actually saved.
  final void Function(ExtractionResult updatedResult, bool hasErrors)?
      onRevalidated;

  /// The folder the bill is saved into; null is home.
  final int? folderId;
  const ReviewScreen(
      {super.key, required this.result, this.onRevalidated, this.folderId});

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  late final TextEditingController sellerName;
  late final TextEditingController sellerGstin;
  late final TextEditingController sellerAddress;
  late final TextEditingController sellerDlNo;
  late final TextEditingController buyerName;
  late final TextEditingController buyerDlNo;
  late final TextEditingController invoiceNo;
  late final TextEditingController invoiceDate;
  late final TextEditingController placeOfSupply;
  String? invoiceType;
  // Not shown on this form, but read off the bill — carried through so a
  // save or revalidate does not erase it.
  String? sellerPhone;
  // Totals the form does not show, carried through the same way (DAS-136):
  // a second printed discount and the printed total GST.
  double? totalDiscount2;
  double? totalGst;

  late List<_LineItemForm> items;

  late final TextEditingController subtotal;
  late final TextEditingController totalDiscount;
  late final TextEditingController totalCgst;
  late final TextEditingController totalSgst;
  late final TextEditingController totalIgst;
  late final TextEditingController roundOff;
  late final TextEditingController grandTotal;

  bool _saving = false;
  bool _revalidating = false;
  String? _error;
  late List<ValidationIssue> _issues;
  bool _overrideErrors = false;

  Uint8List? _photoBytes;
  bool _photoFailed = false;
  bool _photoMinimized = false;

  /// The photo stays at the top while the form scrolls under it, zoomed in
  /// place (DAS-115). Its height is the shopkeeper's to drag; null is the
  /// default share of the screen. [_dragHeight] is the finger's own height
  /// during a drag, unclamped, so dragging well past the top collapses it.
  double? _photoHeight;
  double _dragHeight = 0;
  final TransformationController _photoZoom = TransformationController();

  static const _photoMinHeight = 96.0;
  static const _photoDefaultShare = 0.3;
  static const _photoMaxShare = 0.5;

  /// The issues split once per change of [_issues], not once per field: the
  /// form has some thirty decorated fields, and each used to rebuild this map
  /// from the whole list on every build.
  Map<String, ValidationIssue> _headerIssues = const {};
  Map<int, List<ValidationIssue>> _lineIssues = const {};

  void _indexIssues() {
    final header = <String, ValidationIssue>{};
    final lines = <int, List<ValidationIssue>>{};
    for (final i in _issues) {
      final m = _lineItemIssuePattern.firstMatch(i.field);
      if (m == null) {
        header[i.field] = i;
      } else {
        (lines[int.parse(m.group(1)!)] ??= []).add(i);
      }
    }
    _headerIssues = header;
    _lineIssues = lines;
  }

  List<ValidationIssue> _issuesForLineItem(int index) =>
      _lineIssues[index] ?? const [];

  InputDecoration _decoration(String label, String field) {
    // The supplier's GSTIN is settled by our team, not flagged to the shop
    // (ADR-008, then DAS-71). The server already withholds it, but a stale
    // issue list from an older build must not put the red underline back.
    final issue = field == 'seller_gstin' ? null : _headerIssues[field];
    if (issue == null) return InputDecoration(labelText: label);
    if (issue.isError) {
      return InputDecoration(
          labelText: label, errorText: issue.message, errorMaxLines: 3);
    }
    return InputDecoration(
      labelText: label,
      helperText: issue.message,
      helperMaxLines: 3,
      helperStyle: const TextStyle(color: Color(0xFFB45309)),
    );
  }

  @override
  void initState() {
    super.initState();
    _issues = List<ValidationIssue>.from(widget.result.issues);
    _indexIssues();
    final inv = widget.result.invoice;
    sellerName = TextEditingController(text: inv.sellerName);
    sellerGstin = TextEditingController(text: inv.sellerGstin);
    sellerAddress = TextEditingController(text: inv.sellerAddress ?? '');
    sellerDlNo = TextEditingController(text: inv.sellerDlNo ?? '');
    buyerName = TextEditingController(text: inv.buyerName ?? '');
    buyerDlNo = TextEditingController(text: inv.buyerDlNo ?? '');
    invoiceNo = TextEditingController(text: inv.invoiceNo);
    invoiceDate = TextEditingController(text: inv.invoiceDate);
    placeOfSupply = TextEditingController(text: inv.placeOfSupply ?? '');
    invoiceType = inv.invoiceType;
    sellerPhone = inv.sellerPhone;
    totalDiscount2 = inv.totals.totalDiscount2;
    totalGst = inv.totals.totalGst;
    items = inv.lineItems.map((i) => _LineItemForm.fromLineItem(i)).toList();

    subtotal = TextEditingController(text: _fmt(inv.totals.subtotal));
    totalDiscount =
        TextEditingController(text: _fmtNullable(inv.totals.totalDiscount));
    totalCgst = TextEditingController(text: _fmt(inv.totals.totalCgst));
    totalSgst = TextEditingController(text: _fmt(inv.totals.totalSgst));
    totalIgst = TextEditingController(text: _fmtNullable(inv.totals.totalIgst));
    roundOff = TextEditingController(text: _fmtNullable(inv.totals.roundOff));
    grandTotal = TextEditingController(text: _fmt(inv.totals.grandTotal));
    _loadPhoto();
  }

  Future<void> _loadPhoto() async {
    if (_photoFailed) setState(() => _photoFailed = false);
    try {
      final bytes = await ApiClient.instance.fetchImage(
        widget.result.meta.sourceImage,
        imageRev: widget.result.meta.imageRev,
      );
      if (!mounted) return;
      setState(() => _photoBytes = bytes);
    } catch (_) {
      if (!mounted) return;
      setState(() => _photoFailed = true);
    }
  }

  void _viewPhotoFullScreen() {
    final bytes = _photoBytes;
    if (bytes == null) return;
    showDialog(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(Spacing.s),
        backgroundColor: Colors.black,
        child: InteractiveViewer(
            minScale: 0.5, maxScale: 5, child: Image.memory(bytes)),
      ),
    );
  }

  @override
  void dispose() {
    _photoZoom.dispose();
    for (final c in [
      sellerName,
      sellerGstin,
      sellerAddress,
      sellerDlNo,
      buyerName,
      buyerDlNo,
      invoiceNo,
      invoiceDate,
      placeOfSupply,
      subtotal,
      totalDiscount,
      totalCgst,
      totalSgst,
      totalIgst,
      roundOff,
      grandTotal,
    ]) {
      c.dispose();
    }
    for (final item in items) {
      item.dispose();
    }
    super.dispose();
  }

  void _addItem() => setState(() => items.add(_LineItemForm.empty()));

  void _removeItem(int index) => setState(() {
        items[index].dispose();
        items.removeAt(index);
      });

  Future<void> _pickDate() async {
    final initial = DateTime.tryParse(invoiceDate.text) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(
          () => invoiceDate.text = picked.toIso8601String().split('T').first);
    }
  }

  InvoiceData _buildInvoiceData({bool forceRederiveTax = false}) {
    final lineItems = items.map((f) {
      final li = f.toLineItem();
      if (forceRederiveTax) {
        // Revalidate is "recompute from my current inputs" — an amount
        // derived on a *previous* click would look like a printed value and
        // be trusted as input instead of recomputed. Clear each one ONLY when
        // its percentage counterpart survives to recompute it from: on a bill
        // that prints tax (or a discount) in rupees with no percentage, that
        // figure is the only copy there is, and dropping it made the server
        // see no discount/tax at all and flag every total (DAS-9).
        if (li.discount != null) li.discountAmount = null;
        if (li.cgstPct != null || li.gstPct != 0) li.cgstAmount = null;
        if (li.sgstPct != null || li.gstPct != 0) li.sgstAmount = null;
        if (li.igstPct != null) li.igstAmount = null;
      }
      return li;
    }).toList();

    return InvoiceData(
      sellerName: sellerName.text,
      sellerGstin: sellerGstin.text,
      sellerAddress: sellerAddress.text.isEmpty ? null : sellerAddress.text,
      sellerPhone: sellerPhone,
      sellerDlNo: sellerDlNo.text.isEmpty ? null : sellerDlNo.text,
      buyerName: buyerName.text.isEmpty ? null : buyerName.text,
      buyerDlNo: buyerDlNo.text.isEmpty ? null : buyerDlNo.text,
      invoiceNo: invoiceNo.text,
      invoiceDate: invoiceDate.text,
      invoiceType: invoiceType,
      placeOfSupply: placeOfSupply.text.isEmpty ? null : placeOfSupply.text,
      lineItems: lineItems,
      totals: Totals(
        subtotal: double.tryParse(subtotal.text) ?? 0,
        totalDiscount: double.tryParse(totalDiscount.text),
        totalCgst: double.tryParse(totalCgst.text) ?? 0,
        totalSgst: double.tryParse(totalSgst.text) ?? 0,
        totalIgst: double.tryParse(totalIgst.text),
        roundOff: double.tryParse(roundOff.text),
        grandTotal: double.tryParse(grandTotal.text) ?? 0,
        totalDiscount2: totalDiscount2,
        totalGst: totalGst,
      ),
    );
  }

  /// Updates the existing controllers in place rather than tearing down and
  /// rebuilding the form — revalidate doesn't add/remove line items, and
  /// rebuilding would lose scroll position/focus mid-edit.
  void _applyInvoiceToControllers(InvoiceData inv) {
    sellerName.text = inv.sellerName;
    sellerGstin.text = inv.sellerGstin;
    sellerAddress.text = inv.sellerAddress ?? '';
    sellerDlNo.text = inv.sellerDlNo ?? '';
    buyerName.text = inv.buyerName ?? '';
    buyerDlNo.text = inv.buyerDlNo ?? '';
    invoiceNo.text = inv.invoiceNo;
    invoiceDate.text = inv.invoiceDate;
    invoiceType = inv.invoiceType;
    sellerPhone = inv.sellerPhone;
    totalDiscount2 = inv.totals.totalDiscount2;
    totalGst = inv.totals.totalGst;
    placeOfSupply.text = inv.placeOfSupply ?? '';

    subtotal.text = _fmt(inv.totals.subtotal);
    totalDiscount.text = _fmtNullable(inv.totals.totalDiscount);
    totalCgst.text = _fmt(inv.totals.totalCgst);
    totalSgst.text = _fmt(inv.totals.totalSgst);
    totalIgst.text = _fmtNullable(inv.totals.totalIgst);
    roundOff.text = _fmtNullable(inv.totals.roundOff);
    grandTotal.text = _fmt(inv.totals.grandTotal);

    for (var i = 0; i < items.length && i < inv.lineItems.length; i++) {
      final item = inv.lineItems[i];
      final form = items[i];
      form.productName.text = item.productName;
      form.pack.text = item.pack ?? '';
      form.batchNo.text = item.batchNo ?? '';
      form.expiry.text = item.expiry ?? '';
      form.hsnCode.text = item.hsnCode ?? '';
      form.qty.text = _fmt(item.qty);
      form.freeQty.text = _fmtNullable(item.freeQty);
      form.freeScheme.text = item.freeScheme ?? '';
      form.mrp.text = _fmtNullable(item.mrp);
      form.rate.text = _fmt(item.rate);
      form.discountPct.text = _fmtNullable(item.discountPct);
      form.discountAmount.text = _fmtNullable(item.discountAmount);
      form.gstPct.text = _fmt(_computeGstPct(item));
      form.cgstAmount.text = _fmtNullable(item.cgstAmount);
      form.sgstAmount.text = _fmtNullable(item.sgstAmount);
      form.igstAmount.text = _fmtNullable(item.igstAmount);
      form.grossAmount.text = _fmt(item.grossAmount);
      // The server's own answer, so the next save echoes it rather than the
      // rates this form was opened with.
      form.cgstPct = item.cgstPct;
      form.sgstPct = item.sgstPct;
      form.igstPct = item.igstPct;
      form.netRate = item.netRate;
    }
  }

  Future<void> _revalidate() async {
    if (_revalidating) return;
    setState(() {
      _revalidating = true;
      _error = null;
    });
    try {
      final result = await ApiClient.instance
          .revalidateInvoice(_buildInvoiceData(forceRederiveTax: true));
      if (!mounted) return;
      final hasErrors = result.issues.any((i) => i.isError);
      setState(() {
        _issues = result.issues;
        _indexIssues();
        _applyInvoiceToControllers(result.invoice);
        _error = hasErrors
            ? "Still has flagged fields below — fix and revalidate again, or tick the box to save anyway."
            : (_issues.isNotEmpty
                ? "No errors — just warnings below."
                : "Looks good — no issues found.");
      });
      widget.onRevalidated?.call(
        ExtractionResult(
            invoice: result.invoice,
            meta: widget.result.meta,
            issues: result.issues),
        hasErrors,
      );
      HapticFeedback.mediumImpact();
    } catch (e) {
      HapticFeedback.heavyImpact();
      if (mounted) setState(() => _error = 'Could not revalidate: $e');
    } finally {
      if (mounted) setState(() => _revalidating = false);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final invoice = _buildInvoiceData();
      final meta = widget.result.meta.reviewed();
      final id = await ApiClient.instance.saveInvoice(
        invoice,
        meta,
        overrideErrors: _overrideErrors,
        folderId: widget.folderId,
      );
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      // Nothing is asked first, so nothing else marks the save as done. Show
      // that it landed before leaving, or a one-tap save looks like a dropped tap.
      await showSavedTick(context);
      if (!mounted) return;
      Navigator.of(context).pop(id);
    } on ApiException catch (e) {
      HapticFeedback.heavyImpact();
      if (!mounted) return;
      if (e.detail is Map && e.detail['error'] == 'validation_failed') {
        final rawIssues = (e.detail['issues'] as List<dynamic>? ?? []);
        setState(() {
          _issues = rawIssues
              .map((j) => ValidationIssue.fromJson(j as Map<String, dynamic>))
              .toList();
          _indexIssues();
          _error =
              "Fix the flagged fields, or tick the box below to save anyway.";
        });
      } else {
        setState(() => _error = 'Save failed: $e');
      }
    } catch (e) {
      HapticFeedback.heavyImpact();
      if (mounted) setState(() => _error = 'Save failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Review & save')),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    Spacing.l, Spacing.s, Spacing.l, 0),
                child: _buildPhotoPane(context, box.maxHeight),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(Spacing.l),
                  children: [
                    AnimatedSize(
                      duration: const Duration(milliseconds: 200),
                      alignment: Alignment.topCenter,
                      child: _issues.isEmpty
                          ? const SizedBox.shrink()
                          : Padding(
                              padding: const EdgeInsets.only(bottom: Spacing.l),
                              child: Card(
                                color: _issues.any((i) => i.isError)
                                    ? colors.errorContainer
                                    : colors.surfaceContainerHighest,
                                child: Padding(
                                  padding: const EdgeInsets.all(Spacing.m),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(children: [
                                        Icon(
                                          _issues.any((i) => i.isError)
                                              ? Icons.error_outline
                                              : Icons.info_outline,
                                          size: 18,
                                          color: _issues.any((i) => i.isError)
                                              ? colors.error
                                              : AppColors.statusNeedsReview,
                                        ),
                                        const SizedBox(width: Spacing.xs),
                                        Text('Check before saving',
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleSmall),
                                      ]),
                                      const SizedBox(height: Spacing.xs),
                                      ..._issues.map((i) => Padding(
                                            padding:
                                                const EdgeInsets.only(top: 2),
                                            child: Text(
                                              '${i.isError ? '⚠' : '•'} ${i.message}',
                                              style: TextStyle(
                                                  color: i.isError
                                                      ? colors.error
                                                      : AppColors
                                                          .statusNeedsReview),
                                            ),
                                          )),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                    ),
                    _SectionCard(
                      title: 'Seller',
                      icon: Icons.storefront_outlined,
                      children: [
                        TextField(
                            controller: sellerName,
                            decoration:
                                _decoration('Seller name', 'seller_name')),
                        const SizedBox(height: Spacing.s),
                        TextField(
                            controller: sellerGstin,
                            maxLength: 15,
                            decoration:
                                _decoration('Seller GSTIN', 'seller_gstin')),
                        const SizedBox(height: Spacing.s),
                        TextField(
                            controller: sellerAddress,
                            decoration: _decoration(
                                'Seller address', 'seller_address')),
                        const SizedBox(height: Spacing.s),
                        TextField(
                            controller: sellerDlNo,
                            decoration:
                                _decoration('Seller D.L. no.', 'seller_dl_no')),
                      ],
                    ),
                    const SizedBox(height: Spacing.l),
                    _SectionCard(
                      title: 'Invoice details',
                      icon: Icons.description_outlined,
                      children: [
                        Row(children: [
                          Expanded(
                              child: TextField(
                                  controller: buyerName,
                                  decoration:
                                      _decoration('Buyer name', 'buyer_name'))),
                          const SizedBox(width: Spacing.s),
                          Expanded(
                              child: TextField(
                                  controller: buyerDlNo,
                                  decoration: _decoration(
                                      'Buyer D.L. no.', 'buyer_dl_no'))),
                        ]),
                        const SizedBox(height: Spacing.s),
                        TextField(
                            controller: invoiceNo,
                            decoration:
                                _decoration('Invoice number', 'invoice_no')),
                        const SizedBox(height: Spacing.s),
                        TextField(
                          controller: invoiceDate,
                          readOnly: true,
                          onTap: _pickDate,
                          decoration: _decoration(
                                  'Invoice date', 'invoice_date')
                              .copyWith(
                                  suffixIcon: const Icon(Icons.calendar_today)),
                        ),
                        const SizedBox(height: Spacing.s),
                        DropdownButtonFormField<String?>(
                          initialValue: invoiceType,
                          decoration:
                              const InputDecoration(labelText: 'Invoice type'),
                          items: const [
                            DropdownMenuItem(value: null, child: Text('—')),
                            DropdownMenuItem(
                                value: 'cash', child: Text('cash')),
                            DropdownMenuItem(
                                value: 'credit', child: Text('credit')),
                          ],
                          onChanged: (v) => setState(() => invoiceType = v),
                        ),
                        const SizedBox(height: Spacing.s),
                        TextField(
                            controller: placeOfSupply,
                            decoration: _decoration(
                                'Place of supply', 'place_of_supply')),
                      ],
                    ),
                    const SizedBox(height: Spacing.l),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Line items',
                            style: Theme.of(context).textTheme.titleMedium),
                        TextButton.icon(
                            onPressed: _addItem,
                            icon: const Icon(Icons.add),
                            label: const Text('Add item')),
                      ],
                    ),
                    const SizedBox(height: Spacing.s),
                    ...List.generate(
                      items.length,
                      (i) => _LineItemCard(
                          form: items[i],
                          issues: _issuesForLineItem(i),
                          onRemove: () => _removeItem(i)),
                    ),
                    const SizedBox(height: Spacing.l),
                    _SectionCard(
                      title: 'Totals',
                      icon: Icons.calculate_outlined,
                      children: [
                        _numRow('Subtotal', subtotal, 'totals.subtotal',
                            'Discount', totalDiscount, 'totals.total_discount'),
                        _numRow('CGST', totalCgst, 'totals.total_cgst', 'SGST',
                            totalSgst, 'totals.total_sgst'),
                        _numRow('IGST', totalIgst, 'totals.total_igst',
                            'Round off', roundOff, 'totals.round_off'),
                        const Divider(height: Spacing.l),
                        TextField(
                          controller: grandTotal,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          style: amountTextStyle(context, emphasized: true),
                          decoration:
                              _decoration('Grand total', 'totals.grand_total'),
                        ),
                      ],
                    ),
                    const SizedBox(height: Spacing.l),
                    if (_issues.any((i) => i.isError))
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _overrideErrors,
                        onChanged: (v) =>
                            setState(() => _overrideErrors = v ?? false),
                        title: const Text(
                            "I've checked the flagged fields — save anyway"),
                      ),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      child: _error == null
                          ? const SizedBox.shrink()
                          : Padding(
                              key: ValueKey(_error),
                              padding: const EdgeInsets.only(bottom: Spacing.m),
                              child: Text(_error!,
                                  style: TextStyle(color: colors.error)),
                            ),
                    ),
                    BusyOutlinedButton(
                      busy: _revalidating,
                      onPressed: _revalidate,
                      icon: Icons.fact_check_outlined,
                      label: 'Revalidate',
                    ),
                    const SizedBox(height: Spacing.s),
                    BusyFilledButton(
                      busy: _saving,
                      onPressed: _save,
                      icon: Icons.check_circle_outline,
                      label: 'Save invoice',
                      busyLabel: 'Saving…',
                    ),
                    const SizedBox(height: Spacing.xl),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The bill photo, pinned above the form. Pinch and drag zoom it in place
  /// (double-tap resets); the handle under it sets its height, up to half the
  /// screen, and dragging it up past the top collapses it to a strip. It also
  /// folds while the keyboard is up, so the field being typed is never under it.
  Widget _buildPhotoPane(BuildContext context, double available) {
    final colors = Theme.of(context).colorScheme;
    // Read above the Scaffold: it takes the keyboard out of its body's insets.
    final keyboardUp = MediaQuery.viewInsetsOf(this.context).bottom > 0;
    final decoration = BoxDecoration(
      color: colors.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(AppRadius.card),
    );
    if (_photoMinimized || keyboardUp) {
      return Container(
        height: 44,
        margin: const EdgeInsets.only(bottom: Spacing.s),
        decoration: decoration,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            FocusScope.of(context).unfocus();
            setState(() => _photoMinimized = false);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.m),
            child: Row(
              children: [
                Icon(Icons.image_outlined,
                    size: 18, color: colors.onSurfaceVariant),
                const SizedBox(width: Spacing.s),
                Text('Bill photo',
                    style: TextStyle(color: colors.onSurfaceVariant)),
                const Spacer(),
                Icon(Icons.expand_more, color: colors.onSurfaceVariant),
              ],
            ),
          ),
        ),
      );
    }

    final maxHeight =
        (available * _photoMaxShare).clamp(_photoMinHeight, double.infinity);
    final height = (_photoHeight ?? available * _photoDefaultShare)
        .clamp(_photoMinHeight, maxHeight);
    final bytes = _photoBytes;
    return Column(
      children: [
        Container(
          height: height,
          width: double.infinity,
          decoration: decoration,
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (bytes != null)
                LayoutBuilder(
                  // Decoded near twice the pane's width, never the camera's
                  // full size (DAS-19): sharp to about 2× zoom, and one bitmap
                  // of a few MB instead of the whole photo.
                  builder: (context, box) => GestureDetector(
                    onDoubleTap: () => _photoZoom.value = Matrix4.identity(),
                    child: InteractiveViewer(
                      transformationController: _photoZoom,
                      maxScale: 5,
                      child: Image.memory(
                        bytes,
                        fit: BoxFit.contain,
                        cacheWidth: (box.maxWidth *
                                MediaQuery.devicePixelRatioOf(context) *
                                2)
                            .round(),
                      ),
                    ),
                  ),
                )
              else if (_photoFailed)
                InkWell(
                  onTap: _loadPhoto,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.broken_image_outlined,
                            size: 32, color: colors.outline),
                        const SizedBox(height: Spacing.xs),
                        Text("Couldn't load the photo. Tap to retry.",
                            style: TextStyle(color: colors.onSurfaceVariant)),
                      ],
                    ),
                  ),
                )
              else
                const Center(child: CircularProgressIndicator()),
              Positioned(
                left: 6,
                top: 6,
                child: _PhotoButton(
                  icon: Icons.expand_less,
                  tooltip: 'Hide bill photo',
                  onTap: () => setState(() => _photoMinimized = true),
                ),
              ),
              if (bytes != null)
                Positioned(
                  right: 6,
                  bottom: 6,
                  child: _PhotoButton(
                    icon: Icons.open_in_full,
                    tooltip: 'Full screen',
                    onTap: _viewPhotoFullScreen,
                  ),
                ),
            ],
          ),
        ),
        Semantics(
          label: 'Resize bill photo',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: (_) => _dragHeight = height,
            onVerticalDragUpdate: (d) => setState(() {
              _dragHeight += d.delta.dy;
              _photoHeight = _dragHeight.clamp(_photoMinHeight, maxHeight);
            }),
            onVerticalDragEnd: (_) {
              if (_dragHeight < _photoMinHeight - 40) {
                setState(() {
                  _photoMinimized = true;
                  _photoHeight = null;
                });
              }
            },
            child: SizedBox(
              height: 24,
              width: double.infinity,
              child: Center(
                child: Container(
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(
                    color: colors.outline,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _numRow(
    String label1,
    TextEditingController c1,
    String field1,
    String label2,
    TextEditingController c2,
    String field2,
  ) {
    const numType = TextInputType.numberWithOptions(decimal: true);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        Expanded(
            child: TextField(
                controller: c1,
                keyboardType: numType,
                decoration: _decoration(label1, field1))),
        const SizedBox(width: 8),
        Expanded(
            child: TextField(
                controller: c2,
                keyboardType: numType,
                decoration: _decoration(label2, field2))),
      ]),
    );
  }
}

/// A small dark button laid over the bill photo.
class _PhotoButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _PhotoButton(
      {required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
              color: Colors.black45, borderRadius: BorderRadius.circular(6)),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }
}

/// Groups a chunk of the form under a titled card with a leading icon —
/// splits the review form into scannable sections (seller, invoice, totals)
/// instead of one long undifferentiated list of fields.
class _SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Widget> children;
  const _SectionCard(
      {required this.title, required this.icon, required this.children});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(icon,
                  size: 18, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: Spacing.xs),
              Text(title, style: Theme.of(context).textTheme.titleSmall),
            ]),
            const SizedBox(height: Spacing.m),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _LineItemCard extends StatefulWidget {
  final _LineItemForm form;
  final List<ValidationIssue> issues;
  final VoidCallback onRemove;
  const _LineItemCard(
      {required this.form, required this.issues, required this.onRemove});

  @override
  State<_LineItemCard> createState() => _LineItemCardState();
}

class _LineItemCardState extends State<_LineItemCard> {
  // Collapsed by default so a long bill doesn't force scrolling past every
  // clean row to find the one that needs attention — a row with an issue
  // starts open instead, since that's exactly the one the user came here
  // to look at.
  late bool _expanded = widget.issues.isNotEmpty;

  @override
  void didUpdateWidget(_LineItemCard old) {
    super.didUpdateWidget(old);
    // A fresh revalidate can put a NEW issue on a row that was clean (and
    // collapsed) before — force it open so the user sees it without having
    // to go hunting through every row again. A row the user already had
    // open, or already had open for a still-standing issue, is left alone
    // either way (including one they manually collapsed while it still has
    // an issue — that's their call, not something to fight every rebuild).
    if (old.issues.isEmpty && widget.issues.isNotEmpty) {
      _expanded = true;
    }
  }

  // issues here are already filtered to this row by the parent; strip the
  // "Line [N]." prefix so lookups are by plain field name (e.g. "qty").
  // Built once per build (seventeen fields ask), in [build].
  Map<String, ValidationIssue> _bySuffix = const {};

  InputDecoration _decoration(String label, String field) {
    var issue = _bySuffix[field];
    // "gross_amount doesn't add up" means qty, rate and the amount don't
    // reconcile together — the backend can only attach the issue to one
    // field, but the actual typo could just as easily be in qty or rate, so
    // flag all three rather than leaving two of them looking clean.
    if (issue == null && (field == 'qty' || field == 'rate')) {
      issue = _bySuffix['gross_amount'];
    }
    if (issue == null) return InputDecoration(labelText: label);
    if (issue.isError) {
      return InputDecoration(
          labelText: label, errorText: issue.message, errorMaxLines: 3);
    }
    return InputDecoration(
      labelText: label,
      helperText: issue.message,
      helperMaxLines: 3,
      helperStyle: const TextStyle(color: Color(0xFFB45309)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final form = widget.form;
    final hasError = widget.issues.any((i) => i.isError);
    final hasIssue = widget.issues.isNotEmpty;
    _bySuffix = {
      for (final i in widget.issues)
        _lineItemIssuePattern.firstMatch(i.field)!.group(2)!: i
    };

    return Card(
      margin: const EdgeInsets.only(top: Spacing.m),
      shape: hasError
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.card),
              side: BorderSide(
                  color: Theme.of(context).colorScheme.error, width: 1.5),
            )
          : null,
      child: Padding(
        padding: const EdgeInsets.all(Spacing.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Row(
                children: [
                  if (hasIssue)
                    Padding(
                      padding: const EdgeInsets.only(right: Spacing.xs),
                      child: Icon(
                        hasError
                            ? Icons.error_outline
                            : Icons.warning_amber_outlined,
                        color: hasError
                            ? Theme.of(context).colorScheme.error
                            : const Color(0xFFB45309),
                        size: 20,
                      ),
                    ),
                  Expanded(
                    child: ValueListenableBuilder<TextEditingValue>(
                      valueListenable: form.productName,
                      builder: (context, value, _) => Text(
                        value.text.isEmpty ? 'Line item' : value.text,
                        style: Theme.of(context).textTheme.titleSmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  IconButton(
                      onPressed: widget.onRemove,
                      icon: const Icon(Icons.delete_outline)),
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                ],
              ),
            ),
            if (_expanded) ...[
              const SizedBox(height: Spacing.xs),
              TextField(
                  controller: form.productName,
                  decoration: _decoration('Product name', 'product_name')),
              _pairRow(form.pack, 'Pack', 'pack', form.batchNo, 'Batch no.',
                  'batch_no'),
              _pairRow(form.expiry, 'Expiry (MM/YY)', 'expiry', form.qty, 'Qty',
                  'qty',
                  numeric: true),
              if (form.freeScheme.text.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: TextField(
                      controller: form.freeScheme,
                      decoration: _decoration('Free scheme', 'free_scheme')),
                ),
              _pairRow(form.mrp, 'MRP', 'mrp', form.rate, 'Rate', 'rate',
                  numeric: true),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: form.showDiscountAmount
                          ? TextField(
                              controller: form.discountAmount,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              decoration: _decoration(
                                  'Discount amt', 'discount_amount'),
                            )
                          : TextField(
                              controller: form.discountPct,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              decoration:
                                  _decoration('Discount %', 'discount_pct'),
                            ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: form.gstPct,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: _decoration('GST %', 'gst_pct'),
                      ),
                    ),
                  ],
                ),
              ),
              _pairRow(form.cgstAmount, 'CGST amt', 'cgst_amount',
                  form.sgstAmount, 'SGST amt', 'sgst_amount',
                  numeric: true),
              _pairRow(form.igstAmount, 'IGST amt', 'igst_amount',
                  form.grossAmount, 'Gross amount', 'gross_amount',
                  numeric: true),
            ],
          ],
        ),
      ),
    );
  }

  Widget _pairRow(
    TextEditingController c1,
    String l1,
    String f1,
    TextEditingController c2,
    String l2,
    String f2, {
    bool numeric = false,
  }) {
    final type = numeric
        ? const TextInputType.numberWithOptions(decimal: true)
        : TextInputType.text;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(children: [
        Expanded(
            child: TextField(
                controller: c1,
                keyboardType: type,
                decoration: _decoration(l1, f1))),
        const SizedBox(width: 8),
        Expanded(
            child: TextField(
                controller: c2,
                keyboardType: type,
                decoration: _decoration(l2, f2))),
      ]),
    );
  }
}
