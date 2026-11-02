import 'package:flutter/material.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/utils/format.dart';
import '../models/invoice.dart';

/// How a number is written into a field, and read back: see [numText]. A
/// whole number stays whole and a fraction keeps Dart's own spelling, so the
/// round trip through `double.tryParse` is exact.
/// A field's decoration under its validation issue: the red underline and
/// message for an error, an amber helper line for a warning, plain when
/// there is none. The header form and each line card look an issue up
/// differently and draw it the same.
InputDecoration issueDecoration(String label, ValidationIssue? issue) {
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

/// A bill doesn't always print a combined GST% — sometimes it only gives
/// CGST/SGST rates, or only the rupee amounts. Rather than leaving the
/// field blank (or hiding it) in those cases, derive it: CGST and SGST are
/// always equal for an intrastate sale, so whichever side is missing
/// mirrors the one that's present, and a rate not given at all is worked
/// back out of its amount (amount / (rate*qty) * 100).
double computeGstPct(LineItem item) {
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
final lineItemIssuePattern = RegExp(r'^Line \[(\d+)\]\.(.+)$');

/// Holds one line item's editable fields as controllers so the form can be
/// built/torn down per row without re-parsing on every keystroke.
class LineItemForm {
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

  LineItemForm.fromLineItem(LineItem item)
      : printedDiscount = item.discount,
        _origDiscountPct = numText(item.discountPct),
        _origDiscountAmount = numText(item.discountAmount),
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
        qty = TextEditingController(text: numText(item.qty)),
        freeQty = TextEditingController(text: numText(item.freeQty)),
        freeScheme = TextEditingController(text: item.freeScheme ?? ''),
        mrp = TextEditingController(text: numText(item.mrp)),
        rate = TextEditingController(text: numText(item.rate)),
        discountPct =
            TextEditingController(text: numText(item.discountPct)),
        discountAmount =
            TextEditingController(text: numText(item.discountAmount)),
        gstPct = TextEditingController(text: numText(computeGstPct(item))),
        cgstAmount = TextEditingController(text: numText(item.cgstAmount)),
        sgstAmount = TextEditingController(text: numText(item.sgstAmount)),
        igstAmount = TextEditingController(text: numText(item.igstAmount)),
        grossAmount = TextEditingController(text: numText(item.grossAmount));

  LineItemForm.empty() : this.fromLineItem(LineItem());

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


class LineItemCard extends StatefulWidget {
  final LineItemForm form;
  final List<ValidationIssue> issues;
  final VoidCallback onRemove;
  const LineItemCard({super.key, required this.form, required this.issues, required this.onRemove});

  @override
  State<LineItemCard> createState() => _LineItemCardState();
}

class _LineItemCardState extends State<LineItemCard> {
  // Collapsed by default so a long bill doesn't force scrolling past every
  // clean row to find the one that needs attention — a row with an issue
  // starts open instead, since that's exactly the one the user came here
  // to look at.
  late bool _expanded = widget.issues.isNotEmpty;

  @override
  void didUpdateWidget(LineItemCard old) {
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
    return issueDecoration(label, issue);
  }

  @override
  Widget build(BuildContext context) {
    final form = widget.form;
    final hasError = widget.issues.any((i) => i.isError);
    final hasIssue = widget.issues.isNotEmpty;
    _bySuffix = {
      for (final i in widget.issues)
        lineItemIssuePattern.firstMatch(i.field)!.group(2)!: i
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
                      tooltip: 'Remove item',
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
