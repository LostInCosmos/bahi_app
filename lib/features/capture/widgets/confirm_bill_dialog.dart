import 'package:flutter/material.dart';

import '../../../core/utils/format.dart';
import '../../invoice/models/invoice.dart';

enum ConfirmBillAction { save, edit, discard }

/// The summary for a clean bill that isn't saved: one the shop moved back
/// from Saved, or whose own save failed. A clean bill otherwise saves itself
/// (DAS-79). Discard, Edit or Save (DAS-180; Edit came back on 2026-11-13,
/// a shopkeeper asking to open a Not saved bill); the ✕ in the corner closes
/// it, returning null. A flagged bill has its own dialog, with no Save
/// (`processing_bill_dialog.dart`).
Future<ConfirmBillAction?> showConfirmBillDialog(
  BuildContext context,
  String label,
  InvoiceData inv,
) {
  return showDialog<ConfirmBillAction>(
    context: context,
    builder: (context) => AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 12, 8, 0),
      title: Row(
        children: [
          Expanded(child: Text(label)),
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
          Text(inv.sellerName, style: const TextStyle(fontWeight: FontWeight.bold)),
          if (inv.sellerGstin.isNotEmpty) Text('GSTIN ${inv.sellerGstin}'),
          const SizedBox(height: 8),
          Text('Invoice ${inv.invoiceNo} • ${inv.invoiceDate}'),
          Text(plural(inv.lineItems.length, 'item')),
          const SizedBox(height: 8),
          Text(
            'Grand total: ${rupees(inv.totals.grandTotal)}',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ],
      ),
      actions: [
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
            side: BorderSide(color: Theme.of(context).colorScheme.error),
          ),
          onPressed: () => Navigator.pop(context, ConfirmBillAction.discard),
          child: const Text('Discard'),
        ),
        OutlinedButton(
          onPressed: () => Navigator.pop(context, ConfirmBillAction.edit),
          child: const Text('Edit'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, ConfirmBillAction.save),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}
