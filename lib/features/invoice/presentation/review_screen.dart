import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/api/api_client.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/busy_button.dart';
import '../data/invoice_api.dart';
import '../models/invoice.dart';
import '../widgets/line_item_card.dart';
import '../widgets/saved_tick.dart';
import '../widgets/section_card.dart';
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

  /// The read this form corrects (DAS-153). With it, the shop's corrections
  /// are kept on the server as a draft — every Revalidate writes it, and so
  /// does leaving the form or the app with changes not yet sent — and the
  /// save names the read. Null for a bill with no read behind it.
  final int? jobId;

  /// The corrections to open with instead of [result]'s read: the server's
  /// draft, or this phone's copy that has not reached the server yet.
  final BillDraft? draft;

  /// A draft write landed, at revision `rev`.
  final void Function(int rev)? onDraftSent;

  /// Leaving with changes the server did not get (offline): the caller keeps
  /// them and sends them later, from `baseRev`.
  final void Function(ExtractionResult corrected, int? baseRev)? onDraftUnsent;

  /// Changes made on leaving were not kept: another phone had written a
  /// newer draft first.
  final VoidCallback? onDraftLost;

  /// The shop took our team's version over its stale corrections.
  final VoidCallback? onDraftDropped;

  const ReviewScreen({
    super.key,
    required this.result,
    this.onRevalidated,
    this.folderId,
    this.jobId,
    this.draft,
    this.onDraftSent,
    this.onDraftUnsent,
    this.onDraftLost,
    this.onDraftDropped,
  });

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

  late List<LineItemForm> items;

  late final TextEditingController subtotal;
  late final TextEditingController totalDiscount;
  late final TextEditingController totalCgst;
  late final TextEditingController totalSgst;
  late final TextEditingController totalIgst;
  late final TextEditingController roundOff;
  late final TextEditingController grandTotal;

  bool _saving = false;
  bool _revalidating = false;

  /// The draft revision this form builds on (DAS-153); null when the server
  /// holds none.
  int? _draftRev;

  /// The draft predates our team's change to the read; see [BillDraft.stale].
  bool _stale = false;

  /// The next draft write keeps the stale corrections, chosen on the banner.
  bool _rebase = false;

  /// What the server last got (or the form opened with), to tell whether
  /// leaving has anything to send.
  String _sent = '';
  late final AppLifecycleListener _lifecycle;
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
      final m = lineItemIssuePattern.firstMatch(i.field);
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
    return issueDecoration(label, field == 'seller_gstin' ? null : _headerIssues[field]);
  }

  @override
  void initState() {
    super.initState();
    final draft = widget.draft;
    _draftRev = draft?.rev;
    _stale = draft?.stale ?? false;
    _issues = List<ValidationIssue>.from(draft?.issues ?? widget.result.issues);
    _indexIssues();
    final inv = draft?.invoice ?? widget.result.invoice;
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
    items = inv.lineItems.map((i) => LineItemForm.fromLineItem(i)).toList();

    subtotal = TextEditingController(text: numText(inv.totals.subtotal));
    totalDiscount =
        TextEditingController(text: numText(inv.totals.totalDiscount));
    totalCgst = TextEditingController(text: numText(inv.totals.totalCgst));
    totalSgst = TextEditingController(text: numText(inv.totals.totalSgst));
    totalIgst = TextEditingController(text: numText(inv.totals.totalIgst));
    roundOff = TextEditingController(text: numText(inv.totals.roundOff));
    grandTotal = TextEditingController(text: numText(inv.totals.grandTotal));
    _sent = _snapshot();
    // Android may end a hidden app without warning: what is typed goes to the
    // server when the app is put away, not only when the form is left.
    _lifecycle = AppLifecycleListener(onHide: () => unawaited(_sendIfChanged()));
    _loadPhoto();
  }

  String _snapshot() => jsonEncode(_buildInvoiceData().toJson());

  /// Writes the draft if the form holds changes the server has not got.
  /// Runs on leaving the form, so it must not need the form afterwards: the
  /// callbacks are taken first.
  Future<void> _sendIfChanged() async {
    final jobId = widget.jobId;
    if (jobId == null || _saving || _revalidating) return;
    final now = _snapshot();
    if (now == _sent) return;
    final corrected = ExtractionResult(invoice: _buildInvoiceData(), meta: widget.result.meta, issues: _issues);
    final baseRev = _draftRev;
    final rebase = _rebase;
    final onSent = widget.onDraftSent, onUnsent = widget.onDraftUnsent, onLost = widget.onDraftLost;
    final onRevalidated = widget.onRevalidated;
    final meta = widget.result.meta;
    _sent = now;
    try {
      final reply = await ApiClient.instance
          .putDraft(jobId, _buildInvoiceData(forceRederiveTax: true), baseRev: baseRev, rebase: rebase);
      _draftRev = reply.rev;
      _stale = reply.stale;
      _rebase = false;
      onRevalidated?.call(
        ExtractionResult(invoice: reply.result.invoice, meta: meta, issues: reply.result.issues),
        reply.result.issues.any((i) => i.isError),
      );
      onSent?.call(reply.rev);
    } on ApiException catch (e) {
      if (e.statusCode == 409 && e.field == 'draft_rev') {
        onLost?.call();
      } else if (e.statusCode >= 500) {
        _sent = '';
        onUnsent?.call(corrected, baseRev);
      }
      // Any other refusal (saved meanwhile, not this shop's) leaves nothing
      // to keep.
    } catch (_) {
      _sent = '';
      onUnsent?.call(corrected, baseRev);
    }
  }

  /// Fills the form with another version of the bill — the other phone's
  /// draft, or our team's read — line rows and all.
  void _replaceInvoice(InvoiceData inv, List<ValidationIssue> issues) {
    for (final item in items) {
      item.dispose();
    }
    items = inv.lineItems.map((i) => LineItemForm.fromLineItem(i)).toList();
    _applyInvoiceToControllers(inv);
    _issues = List<ValidationIssue>.from(issues);
    _indexIssues();
    _sent = _snapshot();
  }

  /// One of the stale banner's two answers is being sent: both its buttons
  /// are off meanwhile, so a second tap cannot delete the draft twice or
  /// write it twice.
  bool _resolvingStale = false;

  /// "Use their version" on a stale draft: the corrections go, the read is
  /// shown.
  Future<void> _useTeamVersion() async {
    final jobId = widget.jobId;
    if (jobId == null || _resolvingStale) return;
    setState(() => _resolvingStale = true);
    try {
      await ApiClient.instance.deleteDraft(jobId);
    } catch (e) {
      if (mounted) {
        setState(() {
          _resolvingStale = false;
          _error = "Couldn't drop your corrections: $e";
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _replaceInvoice(widget.result.invoice, widget.result.issues);
      _draftRev = null;
      _stale = false;
      _rebase = false;
      _error = null;
      _resolvingStale = false;
    });
    widget.onDraftDropped?.call();
  }

  /// "Keep my corrections": written at once, over our team's change.
  Future<void> _keepMine() async {
    setState(() {
      _rebase = true;
      _stale = false;
    });
    await _revalidate();
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
    _lifecycle.dispose();
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

  void _addItem() => setState(() => items.add(LineItemForm.empty()));

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
          () => invoiceDate.text = isoDate(picked)!);
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

    subtotal.text = numText(inv.totals.subtotal);
    totalDiscount.text = numText(inv.totals.totalDiscount);
    totalCgst.text = numText(inv.totals.totalCgst);
    totalSgst.text = numText(inv.totals.totalSgst);
    totalIgst.text = numText(inv.totals.totalIgst);
    roundOff.text = numText(inv.totals.roundOff);
    grandTotal.text = numText(inv.totals.grandTotal);

    for (var i = 0; i < items.length && i < inv.lineItems.length; i++) {
      final item = inv.lineItems[i];
      final form = items[i];
      form.productName.text = item.productName;
      form.pack.text = item.pack ?? '';
      form.batchNo.text = item.batchNo ?? '';
      form.expiry.text = item.expiry ?? '';
      form.hsnCode.text = item.hsnCode ?? '';
      form.qty.text = numText(item.qty);
      form.freeQty.text = numText(item.freeQty);
      form.freeScheme.text = item.freeScheme ?? '';
      form.mrp.text = numText(item.mrp);
      form.rate.text = numText(item.rate);
      form.discountPct.text = numText(item.discountPct);
      form.discountAmount.text = numText(item.discountAmount);
      form.gstPct.text = numText(computeGstPct(item));
      form.cgstAmount.text = numText(item.cgstAmount);
      form.sgstAmount.text = numText(item.sgstAmount);
      form.igstAmount.text = numText(item.igstAmount);
      form.grossAmount.text = numText(item.grossAmount);
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
      final jobId = widget.jobId;
      final RevalidateResult result;
      if (jobId == null) {
        result = await ApiClient.instance.revalidateInvoice(_buildInvoiceData(forceRederiveTax: true));
      } else {
        final DraftReply reply;
        try {
          reply = await ApiClient.instance
              .putDraft(jobId, _buildInvoiceData(forceRederiveTax: true), baseRev: _draftRev, rebase: _rebase);
        } on ApiException catch (e) {
          if (e.statusCode == 409 && e.field == 'draft_rev') {
            await _showOtherPhonesDraft(jobId);
            return;
          }
          rethrow;
        }
        result = reply.result;
        _draftRev = reply.rev;
        _stale = reply.stale;
        _rebase = false;
        widget.onDraftSent?.call(reply.rev);
      }
      if (!mounted) return;
      final hasErrors = result.issues.any((i) => i.isError);
      setState(() {
        _issues = result.issues;
        _indexIssues();
        _applyInvoiceToControllers(result.invoice);
        _sent = _snapshot();
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
      unawaited(HapticFeedback.mediumImpact());
    } catch (e) {
      unawaited(HapticFeedback.heavyImpact());
      if (mounted) setState(() => _error = 'Could not revalidate: $e');
    } finally {
      if (mounted) setState(() => _revalidating = false);
    }
  }

  /// Another phone wrote a newer draft: show it, and say so. What this form
  /// held is not kept — visibly, rather than either phone's work silently
  /// overwriting the other's.
  Future<void> _showOtherPhonesDraft(int jobId) async {
    final job = await ApiClient.instance.getExtractionJob(jobId);
    if (!mounted) return;
    final draft = job.draft;
    setState(() {
      if (draft != null) {
        _replaceInvoice(draft.invoice, draft.issues);
        _draftRev = draft.rev;
        _stale = draft.stale;
      } else {
        _draftRev = null;
      }
      _rebase = false;
      _error = 'This bill was corrected on another phone. Showing those corrections.';
    });
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
        jobId: widget.jobId,
      );
      if (!mounted) return;
      _sent = _snapshot(); // saved: nothing left to send on the way out
      unawaited(HapticFeedback.mediumImpact());
      // Nothing is asked first, so nothing else marks the save as done. Show
      // that it landed before leaving, or a one-tap save looks like a dropped tap.
      await showSavedTick(context);
      if (!mounted) return;
      Navigator.of(context).pop(id);
    } on ApiException catch (e) {
      unawaited(HapticFeedback.heavyImpact());
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
      unawaited(HapticFeedback.heavyImpact());
      if (mounted) setState(() => _error = 'Save failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return PopScope(
      // Leaving keeps what was typed (DAS-153). A pop that carries the saved
      // bill's id has nothing left to send.
      onPopInvokedWithResult: (didPop, result) {
        if (didPop && result == null) unawaited(_sendIfChanged());
      },
      child: _buildScaffold(context, colors),
    );
  }

  /// Our team changed the read after the shop corrected it (DAS-153).
  Widget _staleBanner(ColorScheme colors) => Padding(
        padding: const EdgeInsets.only(bottom: Spacing.l),
        child: Card(
          key: const ValueKey('stale-draft'),
          color: colors.tertiaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(Spacing.m),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Our team updated this bill after you corrected it. Your corrections are kept.'),
              const SizedBox(height: Spacing.s),
              Wrap(spacing: Spacing.s, children: [
                OutlinedButton(onPressed: _resolvingStale ? null : _useTeamVersion, child: const Text('Use their version')),
                FilledButton(onPressed: _resolvingStale ? null : _keepMine, child: const Text('Keep my corrections')),
              ]),
            ]),
          ),
        ),
      );

  Widget _buildScaffold(BuildContext context, ColorScheme colors) {
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
                    if (_stale) _staleBanner(colors),
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
                    SectionCard(
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
                    SectionCard(
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
                      (i) => LineItemCard(
                          form: items[i],
                          issues: _issuesForLineItem(i),
                          onRemove: () => _removeItem(i)),
                    ),
                    const SizedBox(height: Spacing.l),
                    SectionCard(
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
