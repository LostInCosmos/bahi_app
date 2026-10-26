import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/api/api_client.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/share_file.dart';
import '../../../core/utils/snack.dart';
import '../../../core/widgets/busy_button.dart';
import '../../../core/widgets/inline_message.dart';
import '../../auth/data/auth_api.dart';
import '../../auth/models/account.dart';
import '../../auth/presentation/account_screen.dart';
import '../data/sale_api.dart';
import '../data/sale_bill_pdf.dart';
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

  /// The shop as its bills print it (DAS-121); loaded with the sale, and
  /// again after the shopkeeper edits it from the nudge.
  AccountInfo? _shop;
  bool _nudgeDismissed = false;
  bool _making = false;

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
      await _loadShop();
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load receipt: $e');
    }
  }

  Future<void> _loadShop() async {
    try {
      final shop = await ApiClient.instance.getAccount();
      if (mounted) setState(() => _shop = shop);
    } catch (_) {
      // The bill waits for it; the receipt itself does not.
    }
  }

  /// The bill as a PDF, made on this phone from the server's sale.
  Future<List<int>?> _bill() async {
    final sale = _sale;
    if (sale == null) return null;
    if (_shop == null) await _loadShop();
    final shop = _shop;
    if (shop == null) {
      if (mounted) context.say("Couldn't load your shop's details for the bill. Check the connection and try again.");
      return null;
    }
    return buildSaleBillPdf(sale, shop, await BillFonts.load());
  }

  /// [anchor] is the tapped button's context: on iPad the share sheet is a
  /// popover pointing at it (DAS-135); elsewhere it is ignored.
  Future<void> _shareBill(BuildContext anchor) =>
      _withBill((bytes) => shareBytes(anchor, bytes, name: billFileName(_sale!)));

  /// The phone's own Save dialog (Downloads unless the shopkeeper picks
  /// another folder): no storage permission (see [savePdf]).
  Future<void> _downloadBill() => _withBill((bytes) async {
        final path = await savePdf(Uint8List.fromList(bytes), name: billFileName(_sale!));
        if (mounted && path != null) context.say('Saved ${billFileName(_sale!)}');
      });

  Future<void> _withBill(Future<void> Function(List<int> bytes) use) async {
    if (_making) return;
    setState(() => _making = true);
    try {
      final bytes = await _bill();
      if (bytes != null && mounted) await use(bytes);
    } catch (e) {
      if (mounted) context.say("Couldn't make the bill: $e");
    } finally {
      if (mounted) setState(() => _making = false);
    }
  }

  Future<void> _addShopDetails() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AccountScreen()));
    if (mounted) await _loadShop();
  }

  Future<void> _share(BuildContext anchor) async {
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
    await SharePlus.instance.share(ShareParams(text: lines.join('\n'), sharePositionOrigin: shareOrigin(anchor)));
  }

  bool get _missingShopDetails {
    final shop = _shop;
    return shop != null && ((shop.dlNo ?? '').isEmpty || (shop.phone ?? '').isEmpty);
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
                if (_missingShopDetails && !_nudgeDismissed) ...[
                  _ShopDetailsNudge(
                    onAdd: _addShopDetails,
                    onDismiss: () => setState(() => _nudgeDismissed = true),
                  ),
                  const SizedBox(height: Spacing.m),
                ],
                Builder(
                  builder: (anchor) => BusyFilledButton(
                    busy: _making,
                    onPressed: () => _shareBill(anchor),
                    icon: Icons.picture_as_pdf_outlined,
                    label: 'Share bill (PDF)',
                  ),
                ),
                const SizedBox(height: Spacing.s),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _making ? null : _downloadBill,
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('Download'),
                    ),
                  ),
                  const SizedBox(width: Spacing.s),
                  Expanded(
                    child: Builder(
                      builder: (anchor) => OutlinedButton.icon(
                        onPressed: () => _share(anchor),
                        icon: const Icon(Icons.share),
                        label: const Text('Share as text'),
                      ),
                    ),
                  ),
                ]),
                const SizedBox(height: Spacing.s),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(widget.primaryActionLabel),
                ),
              ],
            ),
    );
  }
}

/// Shown while the shop's drug licence number or phone is not set, so it can
/// be added before bills go out without them. Never blocks a share.
class _ShopDetailsNudge extends StatelessWidget {
  final VoidCallback onAdd;
  final VoidCallback onDismiss;
  const _ShopDetailsNudge({required this.onAdd, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      color: colors.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Spacing.m, Spacing.m, Spacing.s, Spacing.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Your drug licence no. and phone are not on your bills.',
                style: TextStyle(fontWeight: FontWeight.w600, color: colors.onTertiaryContainer)),
            Text('Add them in Account and every bill shows them.',
                style: TextStyle(color: colors.onTertiaryContainer)),
            // In the card's own text colour: the theme's primary is too close
            // to this card's background on the dark theme to read.
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(
                style: TextButton.styleFrom(foregroundColor: colors.onTertiaryContainer),
                onPressed: onDismiss,
                child: const Text('Not now'),
              ),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: colors.onTertiaryContainer),
                onPressed: onAdd,
                child: const Text('Add now', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
