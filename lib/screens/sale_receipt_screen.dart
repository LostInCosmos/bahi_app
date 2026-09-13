import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../api_client.dart';
import '../models.dart';

/// Completing the sale is the one moment stock actually leaves inventory —
/// this screen only ever displays what already happened, nothing here is
/// still editable.
class SaleReceiptScreen extends StatefulWidget {
  final int saleId;
  /// Label for the bottom button — "New sale" right after checkout (the
  /// common case this screen was built for), "Close" when reached by tapping
  /// into a past sale from history, where "new sale" would be misleading.
  final String primaryActionLabel;
  const SaleReceiptScreen({super.key, required this.saleId, this.primaryActionLabel = 'New sale'});

  @override
  State<SaleReceiptScreen> createState() => _SaleReceiptScreenState();
}

class _SaleReceiptScreenState extends State<SaleReceiptScreen> {
  SaleDetail? _sale;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final sale = await ApiClient.instance.getSaleDetail(widget.saleId);
      if (!mounted) return;
      setState(() => _sale = sale);
    } catch (e) {
      setState(() => _error = 'Could not load receipt: $e');
    }
  }

  Future<void> _share() async {
    final s = _sale;
    if (s == null) return;
    final lines = [
      '${s.saleNo} • ${s.saleDate}',
      ...s.lineItems.map((li) => '${li.productName} × ${li.qty.toStringAsFixed(0)} — ₹${li.lineAmount.toStringAsFixed(2)}'),
      'Subtotal: ₹${s.subtotal.toStringAsFixed(2)}',
      'CGST + SGST: ₹${(s.totalCgst + s.totalSgst).toStringAsFixed(2)}',
      'Total: ₹${s.grandTotal.toStringAsFixed(2)}',
    ];
    await SharePlus.instance.share(ShareParams(text: lines.join('\n')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sale complete')),
      body: _sale == null
          ? Center(
              child: _error != null
                  ? Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))
                  : const CircularProgressIndicator(),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Center(
                  child: Column(children: [
                    Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary, size: 40),
                    const SizedBox(height: 8),
                    Text('${_sale!.saleNo} • ${_sale!.saleDate}'),
                  ]),
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: _sale!.lineItems
                          .map((li) => Padding(
                                padding: const EdgeInsets.symmetric(vertical: 4),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Expanded(child: Text('${li.productName} × ${li.qty.toStringAsFixed(0)}')),
                                    Text('₹${li.lineAmount.toStringAsFixed(2)}'),
                                  ],
                                ),
                              ))
                          .toList(),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                          const Text('Subtotal'),
                          Text('₹${_sale!.subtotal.toStringAsFixed(2)}'),
                        ]),
                        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                          const Text('CGST + SGST'),
                          Text('₹${(_sale!.totalCgst + _sale!.totalSgst).toStringAsFixed(2)}'),
                        ]),
                        const Divider(),
                        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                          const Text('Total paid', style: TextStyle(fontWeight: FontWeight.bold)),
                          Text('₹${_sale!.grandTotal.toStringAsFixed(2)}',
                              style: const TextStyle(fontWeight: FontWeight.bold)),
                        ]),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _share,
                  icon: const Icon(Icons.share),
                  label: const Text('Share receipt'),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(widget.primaryActionLabel),
                ),
              ],
            ),
    );
  }
}
