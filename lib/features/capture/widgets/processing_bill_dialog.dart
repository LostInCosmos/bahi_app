import 'package:flutter/material.dart';

import '../../../core/utils/format.dart';
import '../../invoice/models/invoice.dart';

enum ProcessingBillAction { discard, edit }

/// Where a bill in Processing is, as the dialog draws it.
class ProcessingBillView {
  /// What was read; null while the bill is still being read.
  final InvoiceData? invoice;

  /// False once the bill has left Processing (it saved itself, or failed):
  /// the dialog then has nothing to offer and closes.
  final bool inProcessing;

  const ProcessingBillView({this.invoice, this.inProcessing = true});

  bool get reading => invoice == null;
}

/// The dialog for a bill in Processing (DAS-115). While it is being read it
/// offers Discard only; once read and flagged, Discard and Edit. Never Save
/// (DAS-180): a bill saves itself once it is clean, whether the shop, our
/// team or the agent made it so.
///
/// It follows the bill while open: [view] is asked again whenever [changes]
/// fires, so a read that finishes flagged brings Edit in, and one that saves
/// itself or fails closes the dialog. Returns null when dismissed.
Future<ProcessingBillAction?> showProcessingBillDialog(
  BuildContext context, {
  required String label,
  required ProcessingBillView Function() view,
  Listenable? changes,
}) {
  return showDialog<ProcessingBillAction>(
    context: context,
    builder: (_) => _ProcessingBillDialog(label: label, view: view, changes: changes),
  );
}

class _ProcessingBillDialog extends StatefulWidget {
  final String label;
  final ProcessingBillView Function() view;
  final Listenable? changes;

  const _ProcessingBillDialog({required this.label, required this.view, this.changes});

  @override
  State<_ProcessingBillDialog> createState() => _ProcessingBillDialogState();
}

class _ProcessingBillDialogState extends State<_ProcessingBillDialog> {
  late ProcessingBillView _view = widget.view();

  @override
  void initState() {
    super.initState();
    widget.changes?.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.changes?.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    final next = widget.view();
    if (!next.inProcessing) {
      // Only this dialog, and only while it is the top route.
      if (ModalRoute.of(context)?.isCurrent ?? false) Navigator.of(context).pop();
      return;
    }
    setState(() => _view = next);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final inv = _view.invoice;
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 12, 8, 0),
      title: Row(
        children: [
          Expanded(child: Text(widget.label)),
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            inv == null
                ? 'This bill is still being read.'
                : inv.sellerName.isEmpty && inv.invoiceNo.isEmpty
                    // DAS-180: the read failed (the blank form).
                    ? "We couldn't read this bill. Tap Edit to type it in, or leave it for our team."
                    : 'Our team is checking this bill. It will save itself once it is correct. '
                        'You can correct it yourself with Edit.',
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
          if (inv != null && (inv.sellerName.isNotEmpty || inv.invoiceNo.isNotEmpty)) ...[
            const SizedBox(height: 12),
            Text(inv.sellerName, style: const TextStyle(fontWeight: FontWeight.bold)),
            Text('Invoice ${inv.invoiceNo} • ${inv.invoiceDate}'),
            Text(plural(inv.lineItems.length, 'item')),
            const SizedBox(height: 8),
            Text(
              inv.totals.grandTotal == null ? 'Grand total: not read' : 'Grand total: ${rupees(inv.totals.grandTotal!)}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ],
      ),
      actions: [
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            foregroundColor: colors.error,
            side: BorderSide(color: colors.error),
          ),
          onPressed: () => Navigator.pop(context, ProcessingBillAction.discard),
          child: const Text('Discard'),
        ),
        if (!_view.reading)
          FilledButton(
            onPressed: () => Navigator.pop(context, ProcessingBillAction.edit),
            child: const Text('Edit'),
          ),
      ],
    );
  }
}
