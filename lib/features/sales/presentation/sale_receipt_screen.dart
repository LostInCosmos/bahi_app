import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/api/api_client.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/share_file.dart';
import '../../../core/widgets/inline_message.dart';
import '../data/sale_api.dart';
import '../models/sale.dart';
import '../widgets/totals_card.dart';

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
      if (mounted) setState(() => _error = 'Could not load receipt: $e');
    }
  }

  Future<void> _share() async {
    final s = _sale;
    if (s == null) return;
    final lines = [
      '${s.saleNo} • ${s.saleDate}',
      for (final li in s.lineItems) ...[
        '${li.productName} × ${qty(li.qty)} — ${rupees(li.lineAmount)}',
        if (li.discountAmount > 0) '  Discount −${rupees(li.discountAmount)}',
      ],
      if (s.discountAmount > 0) 'Discount (whole sale): −${rupees(s.discountAmount)}',
      'Total: ${rupees(s.grandTotal)}',
      'Includes GST ${rupees(s.tax)} (CGST ${rupees(s.totalCgst)} + SGST ${rupees(s.totalSgst)})',
    ];
    await SharePlus.instance.share(ShareParams(text: lines.join('\n'), sharePositionOrigin: shareOrigin(context)));
  }

  @override
  Widget build(BuildContext context) {
    final sale = _sale;
    return Scaffold(
      appBar: AppBar(title: const Text('Sale complete')),
      body: sale == null
          ? Center(child: _error != null ? ErrorText(_error, padding: EdgeInsets.zero) : const CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(Spacing.l),
              children: [
                Center(
                  child: Column(children: [
                    Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary, size: 40),
                    const SizedBox(height: Spacing.s),
                    Text('${sale.saleNo} • ${sale.saleDate}'),
                  ]),
                ),
                const SizedBox(height: Spacing.l),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(Spacing.m),
                    child: Column(
                      children: [
                        for (final li in sale.lineItems) ...[
                          KeyValueRow('${li.productName} × ${qty(li.qty)}', rupees(li.lineAmount)),
                          if (li.discountAmount > 0)
                            Align(
                              alignment: Alignment.centerRight,
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: Spacing.xs),
                                child: Text('Discount −${rupees(li.discountAmount)}',
                                    style: Theme.of(context).textTheme.bodySmall),
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: Spacing.s),
                SaleTotalsCard(
                  items: sale.itemsTotal,
                  itemDiscounts: sale.lineItems.fold(0.0, (sum, li) => sum + li.discountAmount),
                  saleDiscount: sale.discountAmount,
                  tax: sale.tax,
                  cgst: sale.totalCgst,
                  sgst: sale.totalSgst,
                  total: sale.grandTotal,
                  totalLabel: 'Total paid',
                ),
                const SizedBox(height: Spacing.l),
                OutlinedButton.icon(
                  onPressed: _share,
                  icon: const Icon(Icons.share),
                  label: const Text('Share receipt'),
                ),
                const SizedBox(height: Spacing.s),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(widget.primaryActionLabel),
                ),
              ],
            ),
    );
  }
}
