import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../api_client.dart';
import '../models.dart';
import '../theme.dart';
import 'invoice_detail_screen.dart';

class PurchasesScreen extends StatefulWidget {
  const PurchasesScreen({super.key});

  @override
  State<PurchasesScreen> createState() => PurchasesScreenState();
}

class PurchasesScreenState extends State<PurchasesScreen> {
  DateTime? _startDate;
  DateTime? _endDate;
  final _gstinController = TextEditingController();

  List<InvoiceSummary> _invoices = [];
  bool _loading = false;
  bool _exporting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _gstinController.dispose();
    super.dispose();
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
  /// IndexedStack keeps this widget's state alive across tab switches, so it
  /// won't otherwise notice invoices saved while a different tab was active.
  Future<void> refresh() => _refresh();

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final invoices = await ApiClient.instance.listInvoices(
        startDate: _iso(_startDate),
        endDate: _iso(_endDate),
        vendorGstin: _gstinController.text.trim(),
      );
      if (!mounted) return;
      setState(() => _invoices = invoices);
    } catch (e) {
      setState(() => _error = 'Could not load purchases: $e');
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
      final bytes = await ApiClient.instance.exportExcel(
        startDate: _iso(_startDate),
        endDate: _iso(_endDate),
        vendorGstin: _gstinController.text.trim(),
      );
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/purchases_${DateTime.now().millisecondsSinceEpoch}.xlsx');
      await file.writeAsBytes(bytes);
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], text: 'GST purchase export'));
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
          const SizedBox(height: Spacing.s),
          TextField(
            controller: _gstinController,
            decoration: const InputDecoration(labelText: 'Vendor GSTIN (optional)', prefixIcon: Icon(Icons.search)),
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
          if (_invoices.isEmpty && !_loading)
            Padding(
              padding: const EdgeInsets.only(top: Spacing.xxl),
              child: Column(children: [
                Icon(Icons.inbox_outlined, size: 48, color: colors.outline),
                const SizedBox(height: Spacing.s),
                Text('No purchases yet', style: TextStyle(color: colors.onSurfaceVariant)),
              ]),
            ),
          ..._invoices.map((inv) => Padding(
                padding: const EdgeInsets.only(bottom: Spacing.s),
                child: Card(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(AppRadius.card),
                    onTap: () async {
                      HapticFeedback.selectionClick();
                      final deleted = await Navigator.of(context).push<bool>(
                        MaterialPageRoute(builder: (_) => InvoiceDetailScreen(invoiceId: inv.id)),
                      );
                      if (deleted == true) _refresh();
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(Spacing.m),
                      child: Row(children: [
                        CircleAvatar(
                          radius: 20,
                          backgroundColor: colors.primaryContainer,
                          child: Text(
                            inv.vendorName.isNotEmpty ? inv.vendorName[0].toUpperCase() : '?',
                            style: TextStyle(color: colors.onPrimaryContainer, fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(width: Spacing.m),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${inv.vendorName} — ${inv.invoiceNo}',
                                  style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                              const SizedBox(height: 2),
                              Text(
                                '${inv.invoiceDate} • ${inv.extractionMethod}${inv.reviewed ? '' : ' • not reviewed'}',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: Spacing.s),
                        Text('₹${inv.grandTotal.toStringAsFixed(2)}', style: amountTextStyle(context)),
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
