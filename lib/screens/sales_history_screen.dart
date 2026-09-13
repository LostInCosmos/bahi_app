import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../api_client.dart';
import '../models.dart';
import '../theme.dart';
import 'sale_receipt_screen.dart';

class SalesHistoryScreen extends StatefulWidget {
  const SalesHistoryScreen({super.key});

  @override
  State<SalesHistoryScreen> createState() => SalesHistoryScreenState();
}

class SalesHistoryScreenState extends State<SalesHistoryScreen> {
  DateTime? _startDate;
  DateTime? _endDate;

  List<SaleSummary> _sales = [];
  bool _loading = false;
  bool _exporting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  String? _iso(DateTime? d) => d?.toIso8601String().split('T').first;

  Future<void> _pickDate({required bool isStart}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: (isStart ? _startDate : _endDate) ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _startDate = picked;
      } else {
        _endDate = picked;
      }
    });
  }

  /// Public so HomeScreen can trigger a reload when this tab is selected —
  /// IndexedStack keeps this widget's state alive across tab switches.
  Future<void> refresh() => _refresh();

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sales = await ApiClient.instance.listSales(startDate: _iso(_startDate), endDate: _iso(_endDate));
      if (!mounted) return;
      setState(() => _sales = sales);
    } catch (e) {
      setState(() => _error = 'Could not load sales: $e');
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
      final bytes = await ApiClient.instance.exportSalesExcel(startDate: _iso(_startDate), endDate: _iso(_endDate));
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/sales_${DateTime.now().millisecondsSinceEpoch}.xlsx');
      await file.writeAsBytes(bytes);
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], text: 'GST sales export'));
    } catch (e) {
      setState(() => _error = 'Export failed: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.all(Spacing.l),
        children: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _pickDate(isStart: true),
                  child: Text(_startDate == null ? 'From' : _iso(_startDate)!),
                ),
              ),
              const SizedBox(width: Spacing.s),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _pickDate(isStart: false),
                  child: Text(_endDate == null ? 'To' : _iso(_endDate)!),
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.m),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _loading ? null : _refresh,
                  child: _loading
                      ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Refresh'),
                ),
              ),
              const SizedBox(width: Spacing.s),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _exporting ? null : _export,
                  icon: _exporting
                      ? const SizedBox(
                          height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.ios_share, size: 18),
                  label: const Text('Export'),
                ),
              ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: Spacing.m),
              child: Text(_error!, style: TextStyle(color: colors.error)),
            ),
          const SizedBox(height: Spacing.m),
          if (_sales.isEmpty && !_loading)
            Padding(
              padding: const EdgeInsets.only(top: Spacing.xxl),
              child: Column(children: [
                Icon(Icons.point_of_sale_outlined, size: 48, color: colors.outline),
                const SizedBox(height: Spacing.s),
                Text('No sales yet', style: TextStyle(color: colors.onSurfaceVariant)),
              ]),
            ),
          ..._sales.map((s) => Padding(
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
                              Text(s.saleDate,
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
                            ],
                          ),
                        ),
                        const SizedBox(width: Spacing.s),
                        Text('₹${s.grandTotal.toStringAsFixed(2)}', style: amountTextStyle(context)),
                      ]),
                    ),
                  ),
                ),
              )),
        ],
      ),
    );
  }
}
