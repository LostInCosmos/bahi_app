import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/api/api_client.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/snack.dart';
import '../../../core/widgets/busy_button.dart';
import '../../../core/widgets/confirm_dialog.dart';
import '../../../core/widgets/inline_message.dart';
import '../data/invoice_api.dart';
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
      final pages = <Uint8List>[];
      for (final path in [detail.sourceImagePath, ...detail.extraSourceImagePaths]) {
        try {
          pages.add(await ApiClient.instance.fetchImage(path, imageRev: detail.imageRev));
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
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete this purchase?',
      message: 'This also removes the stock it added to inventory. This cannot be undone.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    setState(() => _deleting = true);
    try {
      await ApiClient.instance.deleteInvoice(widget.invoiceId);
      if (!mounted) return;
      Navigator.of(context).pop(true); // tells PurchasesScreen to refresh
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _deleting = false);
      showMessageDialog(context, title: 'Could not delete', message: e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _deleting = false);
      context.say('Delete failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return Scaffold(
      appBar: AppBar(title: Text(detail?.invoiceNo ?? 'Invoice')),
      body: SafeArea(
        child: _error != null
            ? Center(child: Padding(padding: const EdgeInsets.all(Spacing.l), child: Text(_error!)))
            : detail == null
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.all(Spacing.l),
                    children: [
                      for (final page in _photoPages)
                        Padding(
                          padding: const EdgeInsets.only(bottom: Spacing.s),
                          child: ClipRRect(borderRadius: BorderRadius.circular(Spacing.s), child: Image.memory(page)),
                        ),
                      if (_photoPages.length > 1)
                        Padding(
                          padding: const EdgeInsets.only(bottom: Spacing.s),
                          child: Text('${_photoPages.length} pages', style: Theme.of(context).textTheme.bodySmall),
                        ),
                      const SizedBox(height: Spacing.s),
                      const SectionTitle('Vendor'),
                      KeyValueRow('Name', detail.vendorName),
                      KeyValueRow('GSTIN', detail.vendorGstin),
                      if (detail.sellerDlNo != null) KeyValueRow('D.L. no.', detail.sellerDlNo!),
                      const SizedBox(height: Spacing.l),
                      const SectionTitle('Invoice'),
                      KeyValueRow('Invoice number', detail.invoiceNo),
                      KeyValueRow('Date', detail.invoiceDate),
                      if (detail.invoiceType != null) KeyValueRow('Type', detail.invoiceType!),
                      if (detail.placeOfSupply != null) KeyValueRow('Place of supply', detail.placeOfSupply!),
                      if (detail.buyerName != null) KeyValueRow('Buyer', detail.buyerName!),
                      if (detail.buyerDlNo != null) KeyValueRow('Buyer D.L. no.', detail.buyerDlNo!),
                      KeyValueRow('Extraction method', detail.extractionMethod),
                      KeyValueRow('Reviewed', detail.reviewed ? 'Yes' : 'No'),
                      // What the machine flagged is for our team, not the shop
                      // (DAS-71): shown only by a server that does not say who
                      // holds the bill, as it always was.
                      if (detail.validationIssues.isNotEmpty && detail.reviewState == null) ...[
                        const SizedBox(height: Spacing.l),
                        const SectionTitle('Flagged at save time'),
                        for (final i in detail.validationIssues)
                          Padding(
                            padding: const EdgeInsets.only(bottom: Spacing.xs),
                            child: Text(
                              '${i.isError ? '⚠' : '•'} ${i.message}',
                              style: TextStyle(
                                color: i.isError ? Theme.of(context).colorScheme.error : AppColors.statusNeedsReview,
                              ),
                            ),
                          ),
                      ],
                      const SizedBox(height: Spacing.l),
                      const SectionTitle('Line items'),
                      for (final item in detail.lineItems)
                        Card(
                          margin: const EdgeInsets.only(bottom: Spacing.s),
                          child: Padding(
                            padding: const EdgeInsets.all(Spacing.m),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(item.productName, style: const TextStyle(fontWeight: FontWeight.bold)),
                                const SizedBox(height: Spacing.xs),
                                Text(
                                  'Qty ${wholeOrFixed2(item.qty)} × ₹${wholeOrFixed2(item.rate)}'
                                  '${item.hsnCode != null ? ' • HSN ${item.hsnCode}' : ''}'
                                  ' • GST ${percent(item.gstPct)}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                        ),
                      const SizedBox(height: Spacing.l),
                      const SectionTitle('Totals'),
                      KeyValueRow('Subtotal', '₹${wholeOrFixed2(detail.subtotal)}'),
                      if (detail.totalDiscount != null) KeyValueRow('Discount', '₹${wholeOrFixed2(detail.totalDiscount!)}'),
                      KeyValueRow('CGST', '₹${wholeOrFixed2(detail.totalCgst)}'),
                      KeyValueRow('SGST', '₹${wholeOrFixed2(detail.totalSgst)}'),
                      if (detail.totalIgst != null) KeyValueRow('IGST', '₹${wholeOrFixed2(detail.totalIgst!)}'),
                      if (detail.roundOff != null) KeyValueRow('Round off', '₹${wholeOrFixed2(detail.roundOff!)}'),
                      KeyValueRow('Grand total', '₹${wholeOrFixed2(detail.grandTotal)}', bold: true),
                      const SizedBox(height: Spacing.xl),
                      BusyOutlinedButton(
                        busy: _deleting,
                        onPressed: _confirmDelete,
                        icon: Icons.delete_outline,
                        label: 'Delete this purchase',
                        busyLabel: 'Deleting…',
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
}
