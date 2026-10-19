import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/api/api_client.dart';
import '../../../core/navigation/tab_screen.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/share_file.dart';
import '../../../core/widgets/busy_button.dart';
import '../../../core/widgets/date_range_buttons.dart';
import '../../../core/widgets/inline_message.dart';
import '../data/sale_api.dart';
import '../models/sale.dart';
import 'sale_receipt_screen.dart';

class SalesHistoryScreen extends StatefulWidget {
  const SalesHistoryScreen({super.key});

  @override
  State<SalesHistoryScreen> createState() => SalesHistoryScreenState();
}

class SalesHistoryScreenState extends State<SalesHistoryScreen> with TabScreen {
  DateTime? _startDate;
  DateTime? _endDate;

  List<SaleSummary> _sales = [];
  bool _loading = false;
  bool _exporting = false;
  String? _error;

  // Deliberately no fetch here — see the same note in purchases_screen.dart:
  // HomeScreen's tab switcher calls refresh() the first (and every) time
  // this tab is actually selected, so every tab doesn't fetch on app open.

  /// Called by HomeScreen when this tab is selected — IndexedStack keeps this
  /// widget's state alive across tab switches.
  @override
  Future<void> refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sales = await ApiClient.instance.listSales(startDate: isoDate(_startDate), endDate: isoDate(_endDate));
      if (!mounted) return;
      setState(() => _sales = sales);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load sales: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _export() async {
    if (_exporting) return;
    setState(() {
      _exporting = true;
      _error = null;
    });
    try {
      final bytes =
          await ApiClient.instance.exportSalesExcel(startDate: isoDate(_startDate), endDate: isoDate(_endDate));
      if (!mounted) return;
      await shareBytes(context, bytes,
          name: 'sales_${DateTime.now().millisecondsSinceEpoch}.xlsx', text: 'GST sales export');
    } catch (e) {
      if (mounted) setState(() => _error = 'Export failed: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final header = <Widget>[
      DateRangeButtons(
        start: _startDate,
        end: _endDate,
        onChanged: (start, end) => setState(() {
          _startDate = start;
          _endDate = end;
        }),
      ),
      const SizedBox(height: Spacing.m),
      Row(
        children: [
          Expanded(child: BusyOutlinedButton(busy: _loading, onPressed: refresh, label: 'Refresh')),
          const SizedBox(width: Spacing.s),
          Expanded(child: BusyFilledButton(busy: _exporting, onPressed: _export, label: 'Export', icon: Icons.ios_share)),
        ],
      ),
      ErrorText(_error),
      const SizedBox(height: Spacing.m),
      if (_sales.isEmpty && !_loading) const EmptyHint(icon: Icons.point_of_sale_outlined, text: 'No sales yet'),
    ];
    return RefreshIndicator(
      onRefresh: refresh,
      // Built as they scroll into view: a month of sales is hundreds of rows.
      child: ListView.builder(
        padding: const EdgeInsets.all(Spacing.l),
        itemCount: header.length + _sales.length,
        itemBuilder: (context, i) => i < header.length ? header[i] : _SaleRow(_sales[i - header.length]),
      ),
    );
  }
}

class _SaleRow extends StatelessWidget {
  final SaleSummary sale;
  const _SaleRow(this.sale);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final s = sale;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.s),
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.card),
          onTap: () {
            HapticFeedback.selectionClick();
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => SaleReceiptScreen(saleId: s.id, primaryActionLabel: 'Close')),
            );
          },
          child: Padding(
            padding: const EdgeInsets.all(Spacing.m),
            child: Row(children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: colors.secondaryContainer,
                child: Icon(Icons.receipt_outlined, size: 18, color: colors.onSecondaryContainer),
              ),
              const SizedBox(width: Spacing.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${s.saleNo}${s.buyerName != null ? ' — ${s.buyerName}' : ''}',
                        style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                    Text(s.saleDate, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
                  ],
                ),
              ),
              const SizedBox(width: Spacing.s),
              Text(rupees(s.grandTotal), style: amountTextStyle(context)),
            ]),
          ),
        ),
      ),
    );
  }
}
