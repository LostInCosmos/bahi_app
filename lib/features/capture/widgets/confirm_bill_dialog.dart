import 'package:flutter/material.dart';

import '../../invoice/models/invoice.dart';

enum ConfirmBillAction { save, edit }

/// The one-tap summary shown for a bill whose extraction came back with no
/// validation issues. Clean numbers are still not proof the bill was read
/// correctly, so it is the user who confirms — nothing saves on its own.
/// Returns null for "Not now" or a dismissed dialog.
///
/// [allowEdit] is false for a bill the machine flagged (DAS-71): it is with our
/// team, so the shopkeeper can save what was read but not correct it.
Future<ConfirmBillAction?> showConfirmBillDialog(
  BuildContext context,
  String label,
  InvoiceData inv, {
  bool allowEdit = true,
}) {
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
          Text('${inv.lineItems.length} item(s)'),
          const SizedBox(height: 8),
          Text(
            'Grand total: ₹${inv.totals.grandTotal.toStringAsFixed(2)}',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Not now')),
        if (allowEdit)
          OutlinedButton(onPressed: () => Navigator.pop(context, ConfirmBillAction.edit), child: const Text('Edit')),
        FilledButton(
          onPressed: () => Navigator.pop(context, ConfirmBillAction.save),
          child: Text(allowEdit ? 'Looks good — save' : 'Save'),
        ),
      ],
    ),
  );
}
