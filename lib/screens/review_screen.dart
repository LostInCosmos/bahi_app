import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_client.dart';
import '../models.dart';
import '../theme.dart';

String _fmt(double v) => v == v.truncateToDouble() ? v.toInt().toString() : v.toString();
String _fmtNullable(double? v) => v == null ? '' : _fmt(v);

/// Holds one line item's editable fields as controllers so the form can be
/// built/torn down per row without re-parsing on every keystroke.
class _LineItemForm {
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
  final TextEditingController gstPct;
  final TextEditingController cgstAmount;
  final TextEditingController sgstAmount;
  final TextEditingController igstAmount;
  final TextEditingController lineAmount;

  _LineItemForm.fromLineItem(LineItem item)
      : productName = TextEditingController(text: item.productName),
        pack = TextEditingController(text: item.pack ?? ''),
        batchNo = TextEditingController(text: item.batchNo ?? ''),
        expiry = TextEditingController(text: item.expiry ?? ''),
        hsnCode = TextEditingController(text: item.hsnCode ?? ''),
        qty = TextEditingController(text: _fmt(item.qty)),
        freeQty = TextEditingController(text: _fmtNullable(item.freeQty)),
        freeScheme = TextEditingController(text: item.freeScheme ?? ''),
        mrp = TextEditingController(text: _fmtNullable(item.mrp)),
        rate = TextEditingController(text: _fmt(item.rate)),
        discountPct = TextEditingController(text: _fmtNullable(item.discountPct)),
        gstPct = TextEditingController(text: _fmt(item.gstPct)),
        cgstAmount = TextEditingController(text: _fmtNullable(item.cgstAmount)),
        sgstAmount = TextEditingController(text: _fmtNullable(item.sgstAmount)),
        igstAmount = TextEditingController(text: _fmtNullable(item.igstAmount)),
        lineAmount = TextEditingController(text: _fmt(item.lineAmount));

  _LineItemForm.empty() : this.fromLineItem(LineItem());

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
        discountPct: double.tryParse(discountPct.text),
        gstPct: double.tryParse(gstPct.text) ?? 0,
        cgstAmount: double.tryParse(cgstAmount.text),
        sgstAmount: double.tryParse(sgstAmount.text),
        igstAmount: double.tryParse(igstAmount.text),
        lineAmount: double.tryParse(lineAmount.text) ?? 0,
      );

  void dispose() {
    for (final c in [
      productName, pack, batchNo, expiry, hsnCode, qty, freeQty, freeScheme, mrp, rate,
      discountPct, gstPct, cgstAmount, sgstAmount, igstAmount, lineAmount,
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
  final void Function(ExtractionResult updatedResult, bool hasErrors)? onRevalidated;
  const ReviewScreen({super.key, required this.result, this.onRevalidated});

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

  Map<String, ValidationIssue> get _headerIssues => {
        for (final i in _issues)
          if (!i.field.startsWith('line_items[')) i.field: i,
      };

  List<ValidationIssue> _issuesForLineItem(int index) {
    final prefix = 'line_items[$index].';
    return _issues.where((i) => i.field.startsWith(prefix)).toList();
  }

  InputDecoration _decoration(String label, String field) {
    final issue = _headerIssues[field];
    if (issue == null) return InputDecoration(labelText: label);
    if (issue.isError) {
      return InputDecoration(labelText: label, errorText: issue.message, errorMaxLines: 3);
    }
    return InputDecoration(
      labelText: label,
      helperText: issue.message,
      helperMaxLines: 3,
      helperStyle: const TextStyle(color: Color(0xFFB45309)),
    );
  }

  /// A misread GSTIN character can itself land on a checksum-valid GSTIN, so
  /// the backend can't always tell two OCR readings apart on its own (see
  /// validation.resolve_gstin_candidates) — rather than making the
  /// shopkeeper retype all 15 characters, this offers every reading that
  /// actually passed validation as a tap-to-fill chip.
  Widget _gstinCandidatePicker() {
    final candidates = _headerIssues['seller_gstin']?.candidates;
    if (candidates == null || candidates.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: Spacing.xs, bottom: Spacing.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Which GSTIN is correct?', style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: Spacing.xs),
          Wrap(
            spacing: Spacing.xs,
            runSpacing: Spacing.xs,
            children: candidates.map((candidate) {
              final selected = sellerGstin.text.toUpperCase() == candidate.toUpperCase();
              return ChoiceChip(
                label: Text(candidate),
                selected: selected,
                onSelected: (_) {
                  setState(() => sellerGstin.text = candidate);
                  _revalidate();
                },
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _issues = List<ValidationIssue>.from(widget.result.issues);
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
    items = inv.lineItems.map((i) => _LineItemForm.fromLineItem(i)).toList();

    subtotal = TextEditingController(text: _fmt(inv.totals.subtotal));
    totalDiscount = TextEditingController(text: _fmtNullable(inv.totals.totalDiscount));
    totalCgst = TextEditingController(text: _fmt(inv.totals.totalCgst));
    totalSgst = TextEditingController(text: _fmt(inv.totals.totalSgst));
    totalIgst = TextEditingController(text: _fmtNullable(inv.totals.totalIgst));
    roundOff = TextEditingController(text: _fmtNullable(inv.totals.roundOff));
    grandTotal = TextEditingController(text: _fmt(inv.totals.grandTotal));
  }

  @override
  void dispose() {
    for (final c in [
      sellerName, sellerGstin, sellerAddress, sellerDlNo, buyerName, buyerDlNo,
      invoiceNo, invoiceDate, placeOfSupply,
      subtotal, totalDiscount, totalCgst, totalSgst, totalIgst, roundOff, grandTotal,
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
      setState(() => invoiceDate.text = picked.toIso8601String().split('T').first);
    }
  }

  InvoiceData _buildInvoiceData({bool forceRederiveTax = false}) {
    final lineItems = items.map((f) {
      final li = f.toLineItem();
      if (forceRederiveTax) {
        // Revalidate is "recompute from my current inputs" — a cgst_amount
        // (or discount_amount) derived on a *previous* click would look
        // identical to a value genuinely printed on the bill, and the
        // "only fill if empty" server-side derivation would leave it stale
        // instead of recomputing it against whatever line_amount/
        // discount_pct/gst_pct was just edited.
        li.discountAmount = null;
        li.cgstAmount = null;
        li.sgstAmount = null;
        li.igstAmount = null;
      }
      return li;
    }).toList();

    return InvoiceData(
      sellerName: sellerName.text,
      sellerGstin: sellerGstin.text,
      sellerAddress: sellerAddress.text.isEmpty ? null : sellerAddress.text,
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
      form.gstPct.text = _fmt(item.gstPct);
      form.cgstAmount.text = _fmtNullable(item.cgstAmount);
      form.sgstAmount.text = _fmtNullable(item.sgstAmount);
      form.igstAmount.text = _fmtNullable(item.igstAmount);
      form.lineAmount.text = _fmt(item.lineAmount);
    }
  }

  Future<void> _revalidate() async {
    if (_revalidating) return;
    setState(() {
      _revalidating = true;
      _error = null;
    });
    try {
      final result = await ApiClient.instance.revalidateInvoice(_buildInvoiceData(forceRederiveTax: true));
      if (!mounted) return;
      final hasErrors = result.issues.any((i) => i.isError);
      setState(() {
        _issues = result.issues;
        _applyInvoiceToControllers(result.invoice);
        _error = hasErrors
            ? "Still has flagged fields below — fix and revalidate again, or tick the box to save anyway."
            : (_issues.isNotEmpty ? "No errors — just warnings below." : "Looks good — no issues found.");
      });
      widget.onRevalidated?.call(
        ExtractionResult(invoice: result.invoice, meta: widget.result.meta, issues: result.issues),
        hasErrors,
      );
      HapticFeedback.mediumImpact();
    } catch (e) {
      HapticFeedback.heavyImpact();
      setState(() => _error = 'Could not revalidate: $e');
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
      final meta = ExtractionMeta(
        sourceImage: widget.result.meta.sourceImage,
        extraSourceImages: widget.result.meta.extraSourceImages,
        method: widget.result.meta.method,
        templateId: widget.result.meta.templateId,
        confidence: widget.result.meta.confidence,
        reviewedByUser: true,
      );
      final id = await ApiClient.instance.saveInvoice(invoice, meta, overrideErrors: _overrideErrors);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      Navigator.of(context).pop(id);
    } on ApiException catch (e) {
      HapticFeedback.heavyImpact();
      if (e.detail is Map && e.detail['error'] == 'validation_failed') {
        final rawIssues = (e.detail['issues'] as List<dynamic>? ?? []);
        setState(() {
          _issues = rawIssues.map((j) => ValidationIssue.fromJson(j as Map<String, dynamic>)).toList();
          _error = "Fix the flagged fields, or tick the box below to save anyway.";
        });
      } else {
        setState(() => _error = 'Save failed: $e');
      }
    } catch (e) {
      HapticFeedback.heavyImpact();
      setState(() => _error = 'Save failed: $e');
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
                        color: _issues.any((i) => i.isError) ? colors.errorContainer : colors.surfaceContainerHighest,
                        child: Padding(
                          padding: const EdgeInsets.all(Spacing.m),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Icon(
                                  _issues.any((i) => i.isError) ? Icons.error_outline : Icons.info_outline,
                                  size: 18,
                                  color: _issues.any((i) => i.isError) ? colors.error : AppColors.statusNeedsReview,
                                ),
                                const SizedBox(width: Spacing.xs),
                                Text('Check before saving', style: Theme.of(context).textTheme.titleSmall),
                              ]),
                              const SizedBox(height: Spacing.xs),
                              ..._issues.map((i) => Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(
                                      '${i.isError ? '⚠' : '•'} ${i.message}',
                                      style: TextStyle(color: i.isError ? colors.error : AppColors.statusNeedsReview),
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
                TextField(controller: sellerName, decoration: _decoration('Seller name', 'seller_name')),
                const SizedBox(height: Spacing.s),
                TextField(controller: sellerGstin, maxLength: 15, decoration: _decoration('Seller GSTIN', 'seller_gstin')),
                _gstinCandidatePicker(),
                const SizedBox(height: Spacing.s),
                TextField(controller: sellerAddress, decoration: _decoration('Seller address', 'seller_address')),
                const SizedBox(height: Spacing.s),
                TextField(controller: sellerDlNo, decoration: _decoration('Seller D.L. no.', 'seller_dl_no')),
              ],
            ),
            const SizedBox(height: Spacing.l),
            _SectionCard(
              title: 'Invoice details',
              icon: Icons.description_outlined,
              children: [
                Row(children: [
                  Expanded(child: TextField(controller: buyerName, decoration: _decoration('Buyer name', 'buyer_name'))),
                  const SizedBox(width: Spacing.s),
                  Expanded(child: TextField(controller: buyerDlNo, decoration: _decoration('Buyer D.L. no.', 'buyer_dl_no'))),
                ]),
                const SizedBox(height: Spacing.s),
                TextField(controller: invoiceNo, decoration: _decoration('Invoice number', 'invoice_no')),
                const SizedBox(height: Spacing.s),
                TextField(
                  controller: invoiceDate,
                  readOnly: true,
                  onTap: _pickDate,
                  decoration: _decoration('Invoice date', 'invoice_date').copyWith(suffixIcon: const Icon(Icons.calendar_today)),
                ),
                const SizedBox(height: Spacing.s),
                DropdownButtonFormField<String?>(
                  initialValue: invoiceType,
                  decoration: const InputDecoration(labelText: 'Invoice type'),
                  items: const [
                    DropdownMenuItem(value: null, child: Text('—')),
                    DropdownMenuItem(value: 'cash', child: Text('cash')),
                    DropdownMenuItem(value: 'credit', child: Text('credit')),
                  ],
                  onChanged: (v) => setState(() => invoiceType = v),
                ),
                const SizedBox(height: Spacing.s),
                TextField(controller: placeOfSupply, decoration: _decoration('Place of supply', 'place_of_supply')),
              ],
            ),
            const SizedBox(height: Spacing.l),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Line items', style: Theme.of(context).textTheme.titleMedium),
                TextButton.icon(onPressed: _addItem, icon: const Icon(Icons.add), label: const Text('Add item')),
              ],
            ),
            const SizedBox(height: Spacing.s),
            ...List.generate(
              items.length,
              (i) => _LineItemCard(form: items[i], issues: _issuesForLineItem(i), onRemove: () => _removeItem(i)),
            ),
            const SizedBox(height: Spacing.l),
            _SectionCard(
              title: 'Totals',
              icon: Icons.calculate_outlined,
              children: [
                _numRow('Subtotal', subtotal, 'totals.subtotal', 'Discount', totalDiscount, 'totals.total_discount'),
                _numRow('CGST', totalCgst, 'totals.total_cgst', 'SGST', totalSgst, 'totals.total_sgst'),
                _numRow('IGST', totalIgst, 'totals.total_igst', 'Round off', roundOff, 'totals.round_off'),
                const Divider(height: Spacing.l),
                TextField(
                  controller: grandTotal,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  style: amountTextStyle(context, emphasized: true),
                  decoration: _decoration('Grand total', 'totals.grand_total'),
                ),
              ],
            ),
            const SizedBox(height: Spacing.l),
            if (_issues.any((i) => i.isError))
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _overrideErrors,
                onChanged: (v) => setState(() => _overrideErrors = v ?? false),
                title: const Text("I've checked the flagged fields — save anyway"),
              ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: _error == null
                  ? const SizedBox.shrink()
                  : Padding(
                      key: ValueKey(_error),
                      padding: const EdgeInsets.only(bottom: Spacing.m),
                      child: Text(_error!, style: TextStyle(color: colors.error)),
                    ),
            ),
            OutlinedButton.icon(
              onPressed: _revalidating ? null : _revalidate,
              icon: _revalidating
                  ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.fact_check_outlined, size: 18),
              label: const Text('Revalidate'),
            ),
            const SizedBox(height: Spacing.s),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.check_circle_outline),
              label: Text(_saving ? 'Saving…' : 'Save invoice'),
            ),
            const SizedBox(height: Spacing.xl),
          ],
        ),
      ),
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
        Expanded(child: TextField(controller: c1, keyboardType: numType, decoration: _decoration(label1, field1))),
        const SizedBox(width: 8),
        Expanded(child: TextField(controller: c2, keyboardType: numType, decoration: _decoration(label2, field2))),
      ]),
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
  const _SectionCard({required this.title, required this.icon, required this.children});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
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

class _LineItemCard extends StatelessWidget {
  final _LineItemForm form;
  final List<ValidationIssue> issues;
  final VoidCallback onRemove;
  const _LineItemCard({required this.form, required this.issues, required this.onRemove});

  // issues here are already filtered to this row by the parent; strip the
  // "line_items[N]." prefix so lookups are by plain field name (e.g. "qty").
  Map<String, ValidationIssue> get _bySuffix => {
        for (final i in issues) i.field.split('.').skip(1).join('.'): i,
      };

  InputDecoration _decoration(String label, String field) {
    final issue = _bySuffix[field];
    if (issue == null) return InputDecoration(labelText: label);
    if (issue.isError) {
      return InputDecoration(labelText: label, errorText: issue.message, errorMaxLines: 3);
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
    return Card(
      margin: const EdgeInsets.only(top: Spacing.m),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: TextField(controller: form.productName, decoration: _decoration('Product name', 'product_name'))),
                IconButton(onPressed: onRemove, icon: const Icon(Icons.delete_outline)),
              ],
            ),
            _pairRow(form.pack, 'Pack', 'pack', form.batchNo, 'Batch no.', 'batch_no'),
            _pairRow(form.expiry, 'Expiry (MM/YY)', 'expiry', form.hsnCode, 'HSN code', 'hsn_code'),
            _pairRow(form.qty, 'Qty', 'qty', form.freeQty, 'Free qty', 'free_qty', numeric: true),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextField(
                controller: form.freeScheme,
                decoration: _decoration('Free scheme (e.g. 10+1) — leave blank unless printed as a ratio', 'free_scheme'),
              ),
            ),
            _pairRow(form.mrp, 'MRP', 'mrp', form.rate, 'Rate', 'rate', numeric: true),
            _pairRow(form.discountPct, 'Discount %', 'discount_pct', form.gstPct, 'GST %', 'gst_pct', numeric: true),
            _pairRow(form.cgstAmount, 'CGST amt', 'cgst_amount', form.sgstAmount, 'SGST amt', 'sgst_amount', numeric: true),
            _pairRow(form.igstAmount, 'IGST amt', 'igst_amount', form.lineAmount, 'Line amount', 'line_amount', numeric: true),
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
    final type = numeric ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(children: [
        Expanded(child: TextField(controller: c1, keyboardType: type, decoration: _decoration(l1, f1))),
        const SizedBox(width: 8),
        Expanded(child: TextField(controller: c2, keyboardType: type, decoration: _decoration(l2, f2))),
      ]),
    );
  }
}
