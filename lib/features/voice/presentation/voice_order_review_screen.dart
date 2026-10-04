import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../models/voice.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/utils/poll.dart';
import '../../inventory/models/product.dart';
import '../../sales/presentation/sale_receipt_screen.dart';
import 'voice_sale_screen.dart';

/// Review/confirm screen for a voice-parsed sale draft. Every mutation
/// (candidate pick, skip toggle, prescription ref) round-trips through the
/// backend, which recomputes and returns the whole order — this screen just
/// replaces its local [_order] with whatever comes back, the same way
/// SaleReviewScreen treats the server as the source of truth for totals.
///
/// Pops with 'undone' if the sale was completed and then undone from the
/// post-confirm receipt, so the screen that pushed this (SalesScreen) can
/// show a "sale reversed" message; pops with null otherwise.
class VoiceOrderReviewScreen extends StatefulWidget {
  final VoiceOrder order;
  const VoiceOrderReviewScreen({super.key, required this.order});

  @override
  State<VoiceOrderReviewScreen> createState() => _VoiceOrderReviewScreenState();
}

class _VoiceOrderReviewScreenState extends State<VoiceOrderReviewScreen> {
  late VoiceOrder _order;
  String? _message;
  bool _confirming = false;
  bool _busy = false; // any in-flight line PATCH

  @override
  void initState() {
    super.initState();
    _order = widget.order;
  }

  Future<void> _applyLineUpdate(Future<VoiceOrder> Function() call) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final updated = await call();
      if (!mounted) return;
      setState(() => _order = updated);
    } on ApiException catch (e) {
      setState(() => _message = e.statusCode == 409
          ? 'This draft is no longer editable (already confirmed or cancelled).'
          : 'Could not update line: ${e.message}');
    } catch (e) {
      setState(() => _message = 'Could not update line: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickCandidate(VoiceOrderLine line, VoiceLineCandidate candidate) => _applyLineUpdate(
        () => ApiClient.instance.updateVoiceOrderLine(_order.id, line.id, productId: candidate.id),
      );

  // Same as _pickCandidate, but for a product found by searching the whole
  // catalog rather than picking from the LLM/phonetic-match suggestions —
  // the escape hatch for when none of those actually fit.
  Future<void> _pickProduct(VoiceOrderLine line, ProductSummary product) => _applyLineUpdate(
        () => ApiClient.instance.updateVoiceOrderLine(_order.id, line.id, productId: product.id),
      );

  Future<void> _toggleSkip(VoiceOrderLine line) => _applyLineUpdate(
        () => ApiClient.instance.updateVoiceOrderLine(_order.id, line.id, skip: !line.skip),
      );

  Future<void> _submitPrescriptionRef(VoiceOrderLine line, String value) => _applyLineUpdate(
        () => ApiClient.instance.updateVoiceOrderLine(_order.id, line.id, prescriptionRef: value.trim()),
      );

  Future<void> _submitQuantity(VoiceOrderLine line, String value) {
    final qty = double.tryParse(value.trim());
    if (qty == null || qty <= 0) return Future.value();
    return _applyLineUpdate(() => ApiClient.instance.updateVoiceOrderLine(_order.id, line.id, quantity: qty));
  }

  Future<void> _submitMrp(VoiceOrderLine line, String value) {
    final mrp = double.tryParse(value.trim());
    if (mrp == null || mrp < 0) return Future.value();
    return _applyLineUpdate(() => ApiClient.instance.updateVoiceOrderLine(_order.id, line.id, mrp: mrp));
  }

  /// Discount type and value always travel together — switching the toggle
  /// re-sends whatever value is already on screen (defaulting to 0, i.e. no
  /// discount yet) so the effective price recomputes immediately rather than
  /// waiting for the value field to also be edited.
  Future<void> _submitDiscount(VoiceOrderLine line, {String? type, String? valueText}) {
    final value = valueText != null ? double.tryParse(valueText.trim()) : line.discountValue;
    if (value == null || value < 0) return Future.value();
    return _applyLineUpdate(() => ApiClient.instance.updateVoiceOrderLine(
          _order.id,
          line.id,
          discountType: type ?? line.discountType ?? 'percentage',
          discountValue: value,
        ));
  }

  Future<void> _searchInventoryFor(VoiceOrderLine line) async {
    final picked = await showModalBottomSheet<_AddItemResult>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => const _AddItemSheet(),
    );
    if (picked == null || !mounted) return;
    await _pickProduct(line, picked.product);
  }

  void _openCandidates(VoiceOrderLine line) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _CandidatePickerSheet(
        line: line,
        onPick: (c) {
          Navigator.of(ctx).pop();
          _pickCandidate(line, c);
        },
        onSearch: () {
          Navigator.of(ctx).pop();
          _searchInventoryFor(line);
        },
        onSkip: () {
          Navigator.of(ctx).pop();
          _toggleSkip(line);
        },
      ),
    );
  }

  List<VoiceOrderLine> get _missingPrescriptionLines => _order.lines
      .where((l) => l.schedule == 'H1' && l.isSellable && (l.prescriptionRef == null || l.prescriptionRef!.trim().isEmpty))
      .toList();

  Future<void> _confirm() async {
    if (_confirming) return;
    final missing = _missingPrescriptionLines;
    if (missing.isNotEmpty) {
      setState(() => _message =
          'Add a prescription reference for ${missing.map((l) => l.productName ?? l.rawPhrase).join(', ')} before confirming.');
      return;
    }
    setState(() {
      _confirming = true;
      _message = null;
    });
    try {
      final result = await ApiClient.instance.confirmVoiceOrder(_order.id);
      if (!mounted) return;
      final saleId = result['sale_id'] as int;
      final popResult = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => _VoiceSaleReceiptWithUndo(saleId: saleId, voiceOrderId: _order.id)),
      );
      if (!mounted) return;
      Navigator.of(context).pop(popResult);
    } on ApiException catch (e) {
      await _handleConfirmError(e);
    } catch (e) {
      setState(() => _message = 'Could not confirm sale: $e');
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
  }

  Future<void> _handleConfirmError(ApiException e) async {
    final detail = e.detail;
    String msg;
    if (detail is Map) {
      switch (detail['error']) {
        case 'prescription_required':
          final ids = (detail['line_ids'] as List?)?.map((e) => e as int).toSet() ?? <int>{};
          final names = _order.lines.where((l) => ids.contains(l.id)).map((l) => l.productName ?? l.rawPhrase).join(', ');
          msg = 'Prescription reference required for: ${names.isEmpty ? 'one or more lines' : names}.';
          break;
        case 'stock_changed':
          final lines = (detail['lines'] as List?) ?? [];
          final parts = lines.map((l) {
            final m = l as Map;
            final why = m['status'] == 'no_stock' ? 'out of stock' : 'only expired stock left';
            return '${m['product_name']} ($why)';
          });
          msg = 'Stock changed since you spoke: ${parts.join(', ')}. Review those lines and try again.';
          break;
        case 'insufficient_stock':
          msg = 'Not enough stock for ${detail['product_name']}: requested ${detail['requested']}, '
              'available ${detail['available']}.';
          break;
        default:
          msg = (detail['message'] as String?) ?? e.message;
      }
    } else if (e.statusCode == 409) {
      msg = 'This draft is no longer editable (already confirmed or cancelled).';
    } else {
      // Plain-string 422, e.g. "nothing to confirm — every line is unresolved or skipped".
      msg = e.message;
    }
    setState(() => _message = msg);
    // The rejection may reflect stock/state that changed server-side —
    // refresh so the lines on screen match reality before the next attempt.
    try {
      final refreshed = await ApiClient.instance.getVoiceOrder(_order.id);
      if (mounted) setState(() => _order = refreshed);
    } catch (_) {
      // best-effort refresh; keep showing the message either way
    }
  }

  Future<void> _cancel() async {
    try {
      await ApiClient.instance.cancelVoiceOrder(_order.id);
    } catch (_) {
      // best-effort — still leave the review screen either way
    }
    if (mounted) Navigator.of(context).pop();
  }

  // VoiceSaleScreen now pops with a job id the moment the recording is
  // submitted, not once it's parsed — appending is polled locally here
  // (rather than handed off to a list like SalesScreen's fresh-sale jobs)
  // since the owner is already looking at exactly the one order this
  // addition belongs to and naturally expects to see it land here.
  Future<void> _addMore() async {
    final jobId = await Navigator.of(context).push<int>(
      MaterialPageRoute(builder: (_) => VoiceSaleScreen(appendToOrderId: _order.id)),
    );
    if (jobId == null || !mounted) return;
    setState(() {
      _busy = true;
      _message = 'Adding more…';
    });
    try {
      final job = await pollUntilTerminal<VoiceOrderJob>(
        fetch: () => ApiClient.instance.getVoiceOrderJob(jobId, wait: true),
        isTerminal: (j) => j.isTerminal,
        // 180s of being worked on, not 180s since the Add more was spoken —
        // see poll.dart. Same clock as the strip on SalesScreen.
        isStarted: (j) => j.isBeingWorkedOn,
        timeout: const Duration(seconds: 180),
      );
      if (!mounted) return;
      if (job.status == 'done') {
        setState(() {
          _order = job.order!;
          _message = null;
        });
      } else {
        setState(() => _message = job.errorMessage ?? 'Could not add that recording.');
      }
    } on TimeoutException {
      if (!mounted) return;
      setState(() => _message = 'This is taking longer than expected — please try again.');
    } catch (_) {
      if (!mounted) return;
      setState(() => _message = 'Could not reach the server.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Manually adding one item the voice parse missed — a search-and-pick
  /// sheet instead of "Add more"'s re-record, for the common case where
  /// only a single extra item needs adding.
  Future<void> _addItem() async {
    final picked = await showModalBottomSheet<_AddItemResult>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => const _AddItemSheet(),
    );
    if (picked == null || !mounted) return;
    await _applyLineUpdate(() => ApiClient.instance.addVoiceOrderLine(
          _order.id,
          productId: picked.product.id,
          quantity: picked.quantity,
          unit: picked.unit,
        ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Review voice sale'),
        actions: [
          TextButton(onPressed: _confirming ? null : _cancel, child: const Text('Cancel')),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(Spacing.l),
              children: [
                _Header(order: _order),
                const SizedBox(height: Spacing.l),
                ..._order.lines.map((l) => _VoiceLineCard(
                      line: l,
                      busy: _busy,
                      onTapUnresolved: () => _openCandidates(l),
                      onPickCandidate: (c) => _pickCandidate(l, c),
                      onToggleSkip: () => _toggleSkip(l),
                      onSubmitPrescriptionRef: (v) => _submitPrescriptionRef(l, v),
                      onSubmitQuantity: (v) => _submitQuantity(l, v),
                      onSubmitMrp: (v) => _submitMrp(l, v),
                      onSubmitDiscountType: (t) => _submitDiscount(l, type: t),
                      onSubmitDiscountValue: (v) => _submitDiscount(l, valueText: v),
                    )),
                if (_message != null)
                  Padding(
                    padding: const EdgeInsets.only(top: Spacing.m),
                    child: Text(_message!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ),
                const SizedBox(height: Spacing.l),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: (_confirming || _busy) ? null : _addItem,
                        icon: const Icon(Icons.playlist_add),
                        label: const Text('Add item'),
                      ),
                    ),
                    const SizedBox(width: Spacing.s),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: (_confirming || _busy) ? null : _addMore,
                        icon: _busy
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.mic),
                        label: const Text('Add more'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Spacing.l, Spacing.m, Spacing.l, Spacing.l),
              child: Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Total', style: Theme.of(context).textTheme.bodyMedium),
                      Text('₹${_order.totalAmount.toStringAsFixed(2)}', style: amountTextStyle(context, emphasized: true)),
                    ],
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _confirming ? null : _confirm,
                    child: _confirming
                        ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Confirm sale'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final VoiceOrder order;
  const _Header({required this.order});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${order.itemCountHeard} item${order.itemCountHeard == 1 ? '' : 's'} heard',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              'Check this matches what you said — a missing item is easier to '
              'catch by count than by reading the list below.',
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
            const SizedBox(height: Spacing.m),
            Text('"${order.transcript}"', style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
          ],
        ),
      ),
    );
  }
}

/// Color/label for a line's status. `resolved` reads as normal (no banner);
/// `ambiguous` reuses the app's amber "needs a decision" semantic; the three
/// hard-blocked statuses (`not_found`, `no_stock`, `expired_only`) reuse the
/// red "failed" semantic since none of them can be sold without either
/// fixing or skipping the line.
Color? _statusColor(String status) {
  switch (status) {
    case 'ambiguous':
      return AppColors.statusNeedsReview;
    case 'not_found':
    case 'no_stock':
    case 'expired_only':
      return AppColors.statusFailed;
    default:
      return null;
  }
}

String _statusLabel(String status) {
  switch (status) {
    case 'ambiguous':
      return 'Tap to pick the right product';
    case 'not_found':
      return 'No matching product — tap to search or skip';
    case 'no_stock':
      return 'Out of stock';
    case 'expired_only':
      return 'Only expired stock available';
    default:
      return '';
  }
}

class _VoiceLineCard extends StatefulWidget {
  final VoiceOrderLine line;
  final bool busy;
  final VoidCallback onTapUnresolved;
  final ValueChanged<VoiceLineCandidate> onPickCandidate;
  final VoidCallback onToggleSkip;
  final ValueChanged<String> onSubmitPrescriptionRef;
  final ValueChanged<String> onSubmitQuantity;
  final ValueChanged<String> onSubmitMrp;
  final ValueChanged<String> onSubmitDiscountType;
  final ValueChanged<String> onSubmitDiscountValue;

  const _VoiceLineCard({
    required this.line,
    required this.busy,
    required this.onTapUnresolved,
    required this.onPickCandidate,
    required this.onToggleSkip,
    required this.onSubmitPrescriptionRef,
    required this.onSubmitQuantity,
    required this.onSubmitMrp,
    required this.onSubmitDiscountType,
    required this.onSubmitDiscountValue,
  });

  @override
  State<_VoiceLineCard> createState() => _VoiceLineCardState();
}

/// Formats a number for a text field: whole numbers plain, fractional ones
/// with minimal decimals — the same shape numbers arrive in from the server,
/// so re-typing the same field back never nudges the cursor around.
String _numText(double? v) {
  if (v == null) return '';
  return v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();
}

class _VoiceLineCardState extends State<_VoiceLineCard> {
  late final TextEditingController _prescriptionController =
      TextEditingController(text: widget.line.prescriptionRef ?? '');
  late final TextEditingController _quantityController = TextEditingController(text: _numText(widget.line.quantity));
  late final TextEditingController _mrpController = TextEditingController(text: _numText(widget.line.mrp));
  late final TextEditingController _discountController = TextEditingController(text: _numText(widget.line.discountValue));

  @override
  void didUpdateWidget(covariant _VoiceLineCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.line.prescriptionRef != widget.line.prescriptionRef &&
        _prescriptionController.text != (widget.line.prescriptionRef ?? '')) {
      _prescriptionController.text = widget.line.prescriptionRef ?? '';
    }
    if (oldWidget.line.quantity != widget.line.quantity && _quantityController.text != _numText(widget.line.quantity)) {
      _quantityController.text = _numText(widget.line.quantity);
    }
    if (oldWidget.line.mrp != widget.line.mrp && _mrpController.text != _numText(widget.line.mrp)) {
      _mrpController.text = _numText(widget.line.mrp);
    }
    if (oldWidget.line.discountValue != widget.line.discountValue &&
        _discountController.text != _numText(widget.line.discountValue)) {
      _discountController.text = _numText(widget.line.discountValue);
    }
  }

  @override
  void dispose() {
    _prescriptionController.dispose();
    _quantityController.dispose();
    _mrpController.dispose();
    _discountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final line = widget.line;
    final color = _statusColor(line.status);
    final tappable = line.status == 'ambiguous' || line.status == 'not_found';
    final canSkip = line.status != 'resolved' || line.skip; // any unresolved line, or undo-skip a resolved one

    final card = Card(
      color: color?.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('"${line.rawPhrase}"',
                style: TextStyle(color: Theme.of(context).colorScheme.outline, fontStyle: FontStyle.italic, fontSize: 12)),
            const SizedBox(height: Spacing.xs),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${line.productName ?? '(unmatched)'}'
                        '${line.strengthSpoken != null ? ' ${line.strengthSpoken}' : ''}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (line.schedule != null) ...[
                        const SizedBox(height: Spacing.xs),
                        _ScheduleBadge(schedule: line.schedule!),
                      ],
                      if (line.batchAllocation.length <= 1 && line.batchAllocation.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: Spacing.xs),
                          child: _BatchLine(alloc: line.batchAllocation.first),
                        ),
                      if (line.batchAllocation.length > 1) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: Spacing.xs),
                          child: Text('Split across ${line.batchAllocation.length} batches:',
                              style: TextStyle(color: Theme.of(context).colorScheme.outline, fontSize: 12)),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(left: Spacing.m, top: 2),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: line.batchAllocation.map((a) => _BatchLine(alloc: a, indented: true)).toList(),
                          ),
                        ),
                      ],
                      if (color != null) ...[
                        const SizedBox(height: Spacing.xs),
                        Text(_statusLabel(line.status), style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12)),
                      ],
                      // Surfaces the same candidates the full picker sheet
                      // shows, right on the card — a shopkeeper shouldn't
                      // need an extra tap-to-open-a-sheet step to see the
                      // 2-3 likely products (e.g. two flavors of the same
                      // snack) the server already narrowed it down to.
                      if (tappable && line.candidates.isNotEmpty && !line.skip)
                        Padding(
                          padding: const EdgeInsets.only(top: Spacing.xs),
                          child: Wrap(
                            spacing: Spacing.xs,
                            runSpacing: Spacing.xs,
                            children: [
                              ...line.candidates.take(4).map((c) => ActionChip(
                                    label: Text(
                                      c.strength != null && c.strength!.isNotEmpty ? '${c.name} ${c.strength}' : c.name,
                                    ),
                                    onPressed: widget.busy ? null : () => widget.onPickCandidate(c),
                                  )),
                              if (line.candidates.length > 4)
                                ActionChip(
                                  label: const Text('More…'),
                                  onPressed: widget.busy ? null : widget.onTapUnresolved,
                                ),
                            ],
                          ),
                        ),
                      if (line.skip)
                        Padding(
                          padding: const EdgeInsets.only(top: Spacing.xs),
                          child: Chip(
                            label: const Text('Skipped'),
                            visualDensity: VisualDensity.compact,
                            backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: Spacing.s),
                Text('₹${(line.lineTotal ?? 0).toStringAsFixed(2)}', style: amountTextStyle(context)),
              ],
            ),
            if (line.status == 'resolved')
              Padding(
                padding: const EdgeInsets.only(top: Spacing.m),
                child: _PricingRow(
                  busy: widget.busy,
                  unit: line.unit,
                  quantityController: _quantityController,
                  mrpController: _mrpController,
                  discountController: _discountController,
                  discountType: line.discountType ?? 'percentage',
                  onSubmitQuantity: widget.onSubmitQuantity,
                  onSubmitMrp: widget.onSubmitMrp,
                  onSubmitDiscountType: widget.onSubmitDiscountType,
                  onSubmitDiscountValue: widget.onSubmitDiscountValue,
                ),
              ),
            if (line.schedule == 'H1' && line.isSellable)
              Padding(
                padding: const EdgeInsets.only(top: Spacing.m),
                child: TextField(
                  controller: _prescriptionController,
                  enabled: !widget.busy,
                  decoration: InputDecoration(
                    labelText: 'Prescription ref. (required for H1)',
                    isDense: true,
                    errorText: (line.prescriptionRef == null || line.prescriptionRef!.trim().isEmpty)
                        ? 'Required before confirming'
                        : null,
                  ),
                  textInputAction: TextInputAction.done,
                  onSubmitted: widget.onSubmitPrescriptionRef,
                  onEditingComplete: () => widget.onSubmitPrescriptionRef(_prescriptionController.text),
                ),
              ),
            if (canSkip)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: widget.busy ? null : widget.onToggleSkip,
                  child: Text(line.skip ? 'Include again' : 'Skip'),
                ),
              ),
          ],
        ),
      ),
    );

    if (!tappable) return card;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.card),
      onTap: widget.busy ? null : widget.onTapUnresolved,
      child: card,
    );
  }
}

/// Quantity + MRP + discount (percentage-of-MRP or a flat per-unit amount)
/// editor for a resolved line — every field round-trips through the same
/// PATCH the rest of this screen uses, so [VoiceOrderReviewScreen] stays the
/// single source of truth for the recomputed unit_price/line_total.
class _PricingRow extends StatelessWidget {
  final bool busy;
  final String? unit;
  final TextEditingController quantityController;
  final TextEditingController mrpController;
  final TextEditingController discountController;
  final String discountType;
  final ValueChanged<String> onSubmitQuantity;
  final ValueChanged<String> onSubmitMrp;
  final ValueChanged<String> onSubmitDiscountType;
  final ValueChanged<String> onSubmitDiscountValue;

  const _PricingRow({
    required this.busy,
    required this.unit,
    required this.quantityController,
    required this.mrpController,
    required this.discountController,
    required this.discountType,
    required this.onSubmitQuantity,
    required this.onSubmitMrp,
    required this.onSubmitDiscountType,
    required this.onSubmitDiscountValue,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 90,
              child: TextField(
                controller: quantityController,
                enabled: !busy,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: 'Qty', isDense: true, suffixText: unit),
                textInputAction: TextInputAction.done,
                onSubmitted: onSubmitQuantity,
                onEditingComplete: () => onSubmitQuantity(quantityController.text),
              ),
            ),
            const SizedBox(width: Spacing.s),
            Expanded(
              child: TextField(
                controller: mrpController,
                enabled: !busy,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'MRP', isDense: true, prefixText: '₹'),
                textInputAction: TextInputAction.done,
                onSubmitted: onSubmitMrp,
                onEditingComplete: () => onSubmitMrp(mrpController.text),
              ),
            ),
          ],
        ),
        const SizedBox(height: Spacing.s),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: discountController,
                enabled: !busy,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Discount',
                  isDense: true,
                  prefixText: discountType == 'amount' ? '₹' : null,
                  suffixText: discountType == 'percentage' ? '%' : null,
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: onSubmitDiscountValue,
                onEditingComplete: () => onSubmitDiscountValue(discountController.text),
              ),
            ),
            const SizedBox(width: Spacing.s),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'percentage', label: Text('%')),
                ButtonSegment(value: 'amount', label: Text('₹')),
              ],
              selected: {discountType},
              showSelectedIcon: false,
              onSelectionChanged: busy ? null : (s) => onSubmitDiscountType(s.first),
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
            ),
          ],
        ),
      ],
    );
  }
}

class _ScheduleBadge extends StatelessWidget {
  final String schedule;
  const _ScheduleBadge({required this.schedule});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.s, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.statusPendingConfirm.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      child: Text(
        'Schedule $schedule',
        style: const TextStyle(color: AppColors.statusPendingConfirm, fontWeight: FontWeight.w700, fontSize: 11),
      ),
    );
  }
}

class _BatchLine extends StatelessWidget {
  final BatchAllocation alloc;
  final bool indented;
  const _BatchLine({required this.alloc, this.indented = false});

  @override
  Widget build(BuildContext context) {
    final expiryColor = alloc.expiringSoon ? AppColors.statusNeedsReview : Theme.of(context).colorScheme.outline;
    return Padding(
      padding: EdgeInsets.only(top: indented ? 2 : 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Batch ${alloc.batchNo ?? "—"} · qty ${alloc.qty.toStringAsFixed(0)} · ₹${alloc.unitPrice.toStringAsFixed(2)}',
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline),
            ),
          ),
          if (alloc.expiringSoon) const Icon(Icons.warning_amber_rounded, size: 14, color: AppColors.statusNeedsReview),
          const SizedBox(width: 2),
          Text(alloc.expiryDate ?? '—', style: TextStyle(fontSize: 12, color: expiryColor)),
        ],
      ),
    );
  }
}

class _CandidatePickerSheet extends StatelessWidget {
  final VoiceOrderLine line;
  final void Function(VoiceLineCandidate) onPick;
  final VoidCallback onSearch;
  final VoidCallback onSkip;
  const _CandidatePickerSheet({required this.line, required this.onPick, required this.onSearch, required this.onSkip});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('"${line.rawPhrase}"', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Spacing.s),
            if (line.candidates.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: Spacing.m),
                child: Text('No matching products found for this line.'),
              )
            else
              ...line.candidates.map((c) => ListTile(
                    title: Text(c.name),
                    subtitle: (c.strength != null || c.unit != null)
                        ? Text([c.strength, c.unit].where((s) => s != null && s.isNotEmpty).join(' · '))
                        : null,
                    onTap: () => onPick(c),
                  )),
            const SizedBox(height: Spacing.s),
            // Escape hatch for when none of the above are actually right —
            // none of these candidates are guaranteed correct, they're the
            // LLM/phonetic-match's best guesses.
            OutlinedButton.icon(
              onPressed: onSearch,
              icon: const Icon(Icons.search),
              label: const Text('Search inventory instead'),
            ),
            const SizedBox(height: Spacing.s),
            OutlinedButton(onPressed: onSkip, child: const Text('Skip this line')),
          ],
        ),
      ),
    );
  }
}

class _AddItemResult {
  final ProductSummary product;
  final double quantity;
  final String unit;
  const _AddItemResult({required this.product, required this.quantity, required this.unit});
}

/// Search-and-pick sheet for "Add item" — a shopkeeper naming one product
/// the voice parse missed, rather than re-recording a whole note for it.
/// Pops an [_AddItemResult], or null if backed out.
class _AddItemSheet extends StatefulWidget {
  const _AddItemSheet();

  @override
  State<_AddItemSheet> createState() => _AddItemSheetState();
}

class _AddItemSheetState extends State<_AddItemSheet> {
  static const _units = ['tablet', 'strip', 'capsule', 'bottle', 'tube', 'vial', 'ampoule', 'sachet'];

  final _searchController = TextEditingController();
  final _qtyController = TextEditingController(text: '1');
  List<ProductSummary> _results = [];
  bool _loading = false;
  bool _searched = false;
  String? _error;
  ProductSummary? _selected;
  String _unit = 'tablet';

  // "Not in inventory" sub-flow — a small form to create the product (and
  // its first batch) right here, instead of leaving the shopkeeper stuck
  // with nothing to pick.
  bool _creatingNew = false;
  bool _creating = false;
  final _newNameController = TextEditingController();
  final _newMrpController = TextEditingController();
  final _newGstController = TextEditingController(text: '0');

  @override
  void dispose() {
    _searchController.dispose();
    _qtyController.dispose();
    _newNameController.dispose();
    _newMrpController.dispose();
    _newGstController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await ApiClient.instance.searchProducts(q: _searchController.text.trim());
      if (!mounted) return;
      setState(() {
        _results = results;
        _searched = true;
      });
    } catch (e) {
      setState(() => _error = 'Could not search: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _confirm() {
    final qty = double.tryParse(_qtyController.text.trim());
    if (qty == null || qty <= 0) {
      setState(() => _error = 'Enter a quantity greater than 0.');
      return;
    }
    Navigator.of(context).pop(_AddItemResult(product: _selected!, quantity: qty, unit: _unit));
  }

  void _startCreatingNew() {
    _newNameController.text = _searchController.text.trim();
    setState(() {
      _creatingNew = true;
      _error = null;
    });
  }

  Future<void> _createProduct() async {
    final name = _newNameController.text.trim();
    final mrp = double.tryParse(_newMrpController.text.trim());
    final qty = double.tryParse(_qtyController.text.trim());
    final gst = double.tryParse(_newGstController.text.trim()) ?? 0;
    if (name.isEmpty) {
      setState(() => _error = 'Enter a product name.');
      return;
    }
    if (mrp == null || mrp <= 0) {
      setState(() => _error = 'Enter an MRP greater than 0.');
      return;
    }
    if (qty == null || qty <= 0) {
      setState(() => _error = 'Enter a quantity in stock greater than 0.');
      return;
    }
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final created = await ApiClient.instance.createProduct(
        name: name,
        mrp: mrp,
        quantity: qty,
        unit: _unit,
        gstPct: gst,
      );
      if (!mounted) return;
      setState(() {
        _selected = created;
        _creatingNew = false;
      });
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Could not create product: $e');
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: Spacing.l,
          right: Spacing.l,
          top: Spacing.l,
          bottom: MediaQuery.of(context).viewInsets.bottom + Spacing.l,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_creatingNew ? 'Add new product' : 'Add item', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Spacing.m),
            if (_creatingNew) ...[
              TextField(
                controller: _newNameController,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Product name', isDense: true),
              ),
              const SizedBox(height: Spacing.s),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _newMrpController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'MRP', isDense: true, prefixText: '₹'),
                    ),
                  ),
                  const SizedBox(width: Spacing.s),
                  Expanded(
                    child: TextField(
                      controller: _newGstController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'GST %', isDense: true),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.s),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _qtyController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Quantity in stock', isDense: true),
                    ),
                  ),
                  const SizedBox(width: Spacing.s),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _unit,
                      decoration: const InputDecoration(labelText: 'Unit', isDense: true),
                      items: _units.map((u) => DropdownMenuItem(value: u, child: Text(u))).toList(),
                      onChanged: (v) {
                        if (v != null) setState(() => _unit = v);
                      },
                    ),
                  ),
                ],
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: Spacing.s),
                  child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              const SizedBox(height: Spacing.m),
              Row(
                children: [
                  TextButton(
                    onPressed: _creating ? null : () => setState(() => _creatingNew = false),
                    child: const Text('Back to search'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _creating ? null : _createProduct,
                    child: _creating
                        ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Create & continue'),
                  ),
                ],
              ),
            ] else if (selected == null) ...[
              TextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Search a medicine',
                  isDense: true,
                  suffixIcon: IconButton(icon: const Icon(Icons.search), onPressed: _search),
                ),
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
              ),
              const SizedBox(height: Spacing.s),
              if (_loading) const Center(child: Padding(padding: EdgeInsets.all(Spacing.m), child: CircularProgressIndicator())),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: Spacing.s),
                  child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: _results.map((p) => ListTile(
                        title: Text(p.name),
                        subtitle: Text('${p.quantityOnHand.toStringAsFixed(0)} in stock'),
                        enabled: p.quantityOnHand > 0,
                        onTap: () => setState(() => _selected = p),
                      )).toList(),
                ),
              ),
              if (_searched && !_loading)
                Padding(
                  padding: const EdgeInsets.only(top: Spacing.s),
                  child: TextButton.icon(
                    onPressed: _startCreatingNew,
                    icon: const Icon(Icons.add_circle_outline, size: 18),
                    label: const Text("Can't find it? Add as new product"),
                  ),
                ),
            ] else ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(selected.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text('${selected.quantityOnHand.toStringAsFixed(0)} in stock'),
                trailing: TextButton(onPressed: () => setState(() => _selected = null), child: const Text('Change')),
              ),
              const SizedBox(height: Spacing.s),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _qtyController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Qty', isDense: true),
                    ),
                  ),
                  const SizedBox(width: Spacing.s),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _unit,
                      decoration: const InputDecoration(labelText: 'Unit', isDense: true),
                      items: _units.map((u) => DropdownMenuItem(value: u, child: Text(u))).toList(),
                      onChanged: (v) {
                        if (v != null) setState(() => _unit = v);
                      },
                    ),
                  ),
                ],
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: Spacing.s),
                  child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              const SizedBox(height: Spacing.m),
              FilledButton(onPressed: _confirm, child: const Text('Add to order')),
            ],
          ],
        ),
      ),
    );
  }
}

/// Wraps the existing (unmodified) [SaleReceiptScreen] with a 30-second
/// "Undo" banner — voice sales are the one flow where a misheard line can
/// slip all the way to a confirmed sale, so a brief undo window matters more
/// here than on the manual sell flow.
class _VoiceSaleReceiptWithUndo extends StatefulWidget {
  final int saleId;
  final int voiceOrderId;
  const _VoiceSaleReceiptWithUndo({required this.saleId, required this.voiceOrderId});

  @override
  State<_VoiceSaleReceiptWithUndo> createState() => _VoiceSaleReceiptWithUndoState();
}

class _VoiceSaleReceiptWithUndoState extends State<_VoiceSaleReceiptWithUndo> {
  static const _undoWindow = 30;
  int _secondsLeft = _undoWindow;
  Timer? _timer;
  bool _undoing = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_secondsLeft <= 1) {
        t.cancel();
        setState(() => _secondsLeft = 0);
      } else {
        setState(() => _secondsLeft -= 1);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _undo() async {
    if (_undoing) return;
    setState(() => _undoing = true);
    try {
      await ApiClient.instance.undoVoiceOrder(widget.voiceOrderId);
      if (!mounted) return;
      Navigator.of(context).pop('undone');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not undo: $e')));
      setState(() => _undoing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        SaleReceiptScreen(saleId: widget.saleId),
        if (_secondsLeft > 0)
          Positioned(
            left: Spacing.l,
            right: Spacing.l,
            bottom: Spacing.l,
            child: SafeArea(
              top: false,
              child: Material(
                color: Theme.of(context).colorScheme.inverseSurface,
                borderRadius: BorderRadius.circular(AppRadius.control),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Spacing.l, vertical: Spacing.m),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Sale recorded · undo within ${_secondsLeft}s',
                          style: TextStyle(color: Theme.of(context).colorScheme.onInverseSurface),
                        ),
                      ),
                      TextButton(
                        onPressed: _undoing ? null : _undo,
                        child: _undoing
                            ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : Text('UNDO', style: TextStyle(color: Theme.of(context).colorScheme.inversePrimary)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
