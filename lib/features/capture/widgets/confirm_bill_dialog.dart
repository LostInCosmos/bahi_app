import 'package:flutter/material.dart';

import '../../../core/utils/format.dart';
import '../../invoice/models/invoice.dart';

enum ConfirmBillAction { save, edit }

/// The manual-save summary for a bill that isn't saved. A clean bill saves
/// itself automatically now (DAS-79); this only shows for the bill whose own
/// save attempt failed (a duplicate invoice number, a FEFO surprise), or
/// one the shopkeeper deliberately moved back from Saved — not a routine
/// step any more. Returns null for "Not now" or a dismissed dialog. A flagged
/// bill has its own dialog, with no Save (`processing_bill_dialog.dart`).
Future<ConfirmBillAction?> showConfirmBillDialog(
  BuildContext context,
  String label,
  InvoiceData inv,
) {
  return showDialog<ConfirmBillAction>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(label),
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
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Not now')),
        OutlinedButton(onPressed: () => Navigator.pop(context, ConfirmBillAction.edit), child: const Text('Edit')),
        FilledButton(
          onPressed: () => Navigator.pop(context, ConfirmBillAction.save),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}
