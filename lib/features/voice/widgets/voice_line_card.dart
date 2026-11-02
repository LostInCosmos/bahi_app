import 'package:flutter/material.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/utils/format.dart';
import '../../inventory/data/product_catalog.dart';
import '../../inventory/widgets/product_name.dart';
import '../models/voice.dart';

/// Color/label for a line's status. `resolved` reads as normal (no banner);
/// `ambiguous` reuses the app's amber "needs a decision" semantic; the three
/// hard-blocked statuses (`not_found`, `no_stock`, `expired_only`) reuse the
/// red "failed" semantic since none of them can be sold without either
/// fixing or skipping the line.
Color? statusColor(String status) {
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

String statusLabel(String status) {
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

class VoiceLineCard extends StatefulWidget {
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

  const VoiceLineCard({
    super.key,
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
  State<VoiceLineCard> createState() => _VoiceLineCardState();
}

class _VoiceLineCardState extends State<VoiceLineCard> {
  late final TextEditingController _prescriptionController =
      TextEditingController(text: widget.line.prescriptionRef ?? '');
  late final TextEditingController _quantityController = TextEditingController(text: numText(widget.line.quantity));
  late final TextEditingController _mrpController = TextEditingController(text: numText(widget.line.mrp));
  late final TextEditingController _discountController =
      TextEditingController(text: numText(widget.line.discountValue));

  @override
  void didUpdateWidget(covariant VoiceLineCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.line.prescriptionRef != widget.line.prescriptionRef &&
        _prescriptionController.text != (widget.line.prescriptionRef ?? '')) {
      _prescriptionController.text = widget.line.prescriptionRef ?? '';
    }
    if (oldWidget.line.quantity != widget.line.quantity && _quantityController.text != numText(widget.line.quantity)) {
      _quantityController.text = numText(widget.line.quantity);
    }
    if (oldWidget.line.mrp != widget.line.mrp && _mrpController.text != numText(widget.line.mrp)) {
      _mrpController.text = numText(widget.line.mrp);
    }
    if (oldWidget.line.discountValue != widget.line.discountValue &&
        _discountController.text != numText(widget.line.discountValue)) {
      _discountController.text = numText(widget.line.discountValue);
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
    final color = statusColor(line.status);
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
                style:
                    TextStyle(color: Theme.of(context).colorScheme.outline, fontStyle: FontStyle.italic, fontSize: 12)),
            const SizedBox(height: Spacing.xs),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ProductName(
                        '${line.productName ?? '(unmatched)'}'
                        '${line.strengthSpoken != null ? ' ${line.strengthSpoken}' : ''}',
                        qualifier:
                            line.productId == null ? null : ProductCatalog.instance.index?.qualifier(line.productId!),
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
                        Text(statusLabel(line.status),
                            style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12)),
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
                                    label: ProductName(
                                      c.strength != null && c.strength!.isNotEmpty ? '${c.name} ${c.strength}' : c.name,
                                      qualifier: ProductCatalog.instance.index?.qualifier(c.id),
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
                Text(rupees(line.lineTotal ?? 0), style: amountTextStyle(context)),
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
              '${batchLabel(alloc.batchNo)} · qty ${qty(alloc.qty)} · ${rupees(alloc.unitPrice)}',
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

class CandidatePickerSheet extends StatelessWidget {
  final VoiceOrderLine line;
  final void Function(VoiceLineCandidate) onPick;
  final VoidCallback onSearch;
  final VoidCallback onSkip;
  const CandidatePickerSheet({super.key, required this.line, required this.onPick, required this.onSearch, required this.onSkip});

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
                    title: ProductName(c.name, qualifier: ProductCatalog.instance.index?.qualifier(c.id)),
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
