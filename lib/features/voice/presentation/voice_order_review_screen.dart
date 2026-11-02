import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/api/api_client.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/poll.dart';
import '../../../core/widgets/busy_button.dart';
import '../../../core/widgets/inline_message.dart';
import '../../inventory/data/product_catalog.dart';
import '../../inventory/models/product.dart';
import '../data/voice_api.dart';
import '../models/voice.dart';
import '../widgets/add_item_sheet.dart';
import '../widgets/voice_line_card.dart';
import '../widgets/voice_sale_receipt.dart';
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
  bool _cancelling = false;

  @override
  void initState() {
    super.initState();
    _order = widget.order;
  }

  Future<void> _applyLineUpdate(Future<VoiceOrder> Function() call) async {
    // One change at a time: a second typed while the first is still being
    // sent is not queued, and saying nothing left the field showing a value
    // the server never got.
    if (_busy) {
      setState(() => _message = 'Still saving the last change. Try again in a moment.');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final updated = await call();
      if (!mounted) return;
      setState(() => _order = updated);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 404 && e.message == 'product not found') {
        // Merged into another by our team (DAS-93) since the list was loaded.
        ProductCatalog.instance.noteMergedAway();
        setState(() => _message = ProductCatalog.mergedAwayMessage);
        return;
      }
      setState(() => _message = e.statusCode == 409
          ? 'This draft is no longer editable (already confirmed or cancelled).'
          : 'Could not update line: ${e.message}');
    } catch (e) {
      if (mounted) setState(() => _message = 'Could not update line: $e');
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
    final picked = await showModalBottomSheet<AddItemResult>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => const AddItemSheet(),
    );
    if (picked == null || !mounted) return;
    await _pickProduct(line, picked.product);
  }

  void _openCandidates(VoiceOrderLine line) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => CandidatePickerSheet(
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
      .where(
          (l) => l.schedule == 'H1' && l.isSellable && (l.prescriptionRef == null || l.prescriptionRef!.trim().isEmpty))
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
        MaterialPageRoute(builder: (_) => VoiceSaleReceiptWithUndo(saleId: saleId, voiceOrderId: _order.id)),
      );
      if (!mounted) return;
      Navigator.of(context).pop(popResult);
    } on ApiException catch (e) {
      await _handleConfirmError(e);
    } catch (e) {
      if (mounted) setState(() => _message = 'Could not confirm sale: $e');
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
          final names =
              _order.lines.where((l) => ids.contains(l.id)).map((l) => l.productName ?? l.rawPhrase).join(', ');
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
    if (!mounted) return;
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

  /// Cancels the draft on the server, then leaves. A draft the server says is
  /// already confirmed or cancelled (409) or gone (404) needs no cancelling;
  /// any other failure keeps the screen, with the reason — leaving anyway
  /// used to look like a cancel while the order stayed open on the server.
  Future<void> _cancel() async {
    if (_cancelling) return;
    setState(() {
      _cancelling = true;
      _message = null;
    });
    try {
      await ApiClient.instance.cancelVoiceOrder(_order.id);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode != 409 && e.statusCode != 404) {
        setState(() {
          _cancelling = false;
          _message = 'Could not cancel: ${e.message}';
        });
        return;
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cancelling = false;
        _message = 'Could not cancel: $e';
      });
      return;
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
      // No time limit, as on SalesScreen: the server decides when a
      // recording has failed. The wait ends if this screen does.
      final job = await pollUntilTerminal<VoiceOrderJob>(
        fetch: () => ApiClient.instance.getVoiceOrderJob(jobId, wait: true),
        isTerminal: (j) => j.isTerminal,
        stillWanted: () => mounted,
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
    final picked = await showModalBottomSheet<AddItemResult>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => const AddItemSheet(),
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
          TextButton(onPressed: _confirming || _cancelling ? null : _cancel, child: const Text('Cancel')),
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
                ..._order.lines.map((l) => VoiceLineCard(
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
                ErrorText(_message),
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
                        icon: _busy ? const ButtonSpinner() : const Icon(Icons.mic),
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
                      Text(rupees(_order.totalAmount), style: amountTextStyle(context, emphasized: true)),
                    ],
                  ),
                  const Spacer(),
                  // Not while a line change is still being sent: the sale would
                  // confirm the lines the server held before it.
                  BusyFilledButton(
                      busy: _confirming, onPressed: _busy || _cancelling ? null : _confirm, label: 'Confirm sale'),
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
              '${plural(order.itemCountHeard, 'item')} heard',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              'Check this matches what you said — a missing item is easier to '
              'catch by count than by reading the list below.',
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
            const SizedBox(height: Spacing.m),
            Text('"${order.transcript}"',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
          ],
        ),
      ),
    );
  }
}
