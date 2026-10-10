import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../models/invoice.dart';

class InvoiceDetailScreen extends StatefulWidget {
  final int invoiceId;
  const InvoiceDetailScreen({super.key, required this.invoiceId});

  @override
  State<InvoiceDetailScreen> createState() => _InvoiceDetailScreenState();
}

class _InvoiceDetailScreenState extends State<InvoiceDetailScreen> {
  InvoiceDetail? _detail;
  final List<Uint8List> _photoPages = [];
  String? _error;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final detail = await ApiClient.instance.getInvoiceDetail(widget.invoiceId);
      final allPaths = [detail.sourceImagePath, ...detail.extraSourceImagePaths];
      final pages = <Uint8List>[];
      for (final path in allPaths) {
        try {
          pages.add(await ApiClient.instance.fetchImage(path));
        } catch (_) {
          // one page's image missing shouldn't block showing the rest
        }
      }
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _photoPages
          ..clear()
          ..addAll(pages);
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load invoice: $e');
    }
  }

  Future<void> _confirmDelete() async {
    if (_deleting) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this purchase?'),
        content: const Text(
          'This also removes the stock it added to inventory. This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Delete', style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _deleting = true);
    try {
      await ApiClient.instance.deleteInvoice(widget.invoiceId);
      if (!mounted) return;
      Navigator.of(context).pop(true); // tells PurchasesScreen to refresh
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _deleting = false);
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Could not delete'),
          content: Text(e.message),
          actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('OK'))],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _deleting = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return Scaffold(
      appBar: AppBar(title: Text(detail?.invoiceNo ?? 'Invoice')),
      body: SafeArea(
        child: _error != null
            ? Center(child: Padding(padding: const EdgeInsets.all(16), child: Text(_error!)))
            : detail == null
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      for (final page in _photoPages)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.memory(page),
                          ),
                        ),
                      if (_photoPages.length > 1)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text('${_photoPages.length} pages', style: Theme.of(context).textTheme.bodySmall),
                        ),
                      const SizedBox(height: 8),
                      _sectionTitle(context, 'Vendor'),
                      _kv('Name', detail.vendorName),
                      _kv('GSTIN', detail.vendorGstin),
                      if (detail.sellerDlNo != null) _kv('D.L. no.', detail.sellerDlNo!),
                      const SizedBox(height: 16),
                      _sectionTitle(context, 'Invoice'),
                      _kv('Invoice number', detail.invoiceNo),
                      _kv('Date', detail.invoiceDate),
                      if (detail.invoiceType != null) _kv('Type', detail.invoiceType!),
                      if (detail.placeOfSupply != null) _kv('Place of supply', detail.placeOfSupply!),
                      if (detail.buyerName != null) _kv('Buyer', detail.buyerName!),
                      if (detail.buyerDlNo != null) _kv('Buyer D.L. no.', detail.buyerDlNo!),
                      _kv('Extraction method', detail.extractionMethod),
                      _kv('Reviewed', detail.reviewed ? 'Yes' : 'No'),
                      if (detail.validationIssues.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        _sectionTitle(context, 'Flagged at save time'),
                        ...detail.validationIssues.map((i) => Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                '${i.isError ? '⚠' : '•'} ${i.message}',
                                style: TextStyle(
                                  color: i.isError ? Theme.of(context).colorScheme.error : const Color(0xFFB45309),
                                ),
                              ),
                            )),
                      ],
                      const SizedBox(height: 16),
                      _sectionTitle(context, 'Line items'),
                      ...detail.lineItems.map((item) => Card(
                            margin: const EdgeInsets.only(bottom: 8),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(item.productName, style: const TextStyle(fontWeight: FontWeight.bold)),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Qty ${_fmt(item.qty)} × ₹${_fmt(item.rate)}'
                                    '${item.hsnCode != null ? ' • HSN ${item.hsnCode}' : ''}'
                                    ' • GST ${_fmt(item.gstPct)}%',
                                    style: Theme.of(context).textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                          )),
                      const SizedBox(height: 16),
                      _sectionTitle(context, 'Totals'),
                      _kv('Subtotal', '₹${_fmt(detail.subtotal)}'),
                      if (detail.totalDiscount != null) _kv('Discount', '₹${_fmt(detail.totalDiscount!)}'),
                      _kv('CGST', '₹${_fmt(detail.totalCgst)}'),
                      _kv('SGST', '₹${_fmt(detail.totalSgst)}'),
                      if (detail.totalIgst != null) _kv('IGST', '₹${_fmt(detail.totalIgst!)}'),
                      if (detail.roundOff != null) _kv('Round off', '₹${_fmt(detail.roundOff!)}'),
                      _kv('Grand total', '₹${_fmt(detail.grandTotal)}', bold: true),
                      const SizedBox(height: 24),
                      OutlinedButton.icon(
                        onPressed: _deleting ? null : _confirmDelete,
                        icon: _deleting
                            ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.delete_outline),
                        label: Text(_deleting ? 'Deleting…' : 'Delete this purchase'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Theme.of(context).colorScheme.error,
                          side: BorderSide(color: Theme.of(context).colorScheme.error),
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );

  Widget _kv(String label, String value, {bool bold = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          children: [
            Expanded(child: Text(label, style: const TextStyle(color: Colors.grey))),
            Text(value, style: bold ? const TextStyle(fontWeight: FontWeight.bold) : null),
          ],
        ),
      );

  String _fmt(double v) => v == v.truncateToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);
}
