import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/config/legal_documents.dart';
import '../../../core/utils/share_file.dart';
import '../../../core/utils/snack.dart';
import '../../../core/widgets/qr_code_view.dart';

/// The shop's public stock page (DAS-80) on the Account screen: its link to
/// copy or share, and a QR code customers can scan. The page shows which
/// medicines are in stock, never prices or quantities. Our team publishes it
/// on request, so [url] is null for most shops: then this says how to ask.
class StockPageCard extends StatelessWidget {
  final String? url;
  final String shopName;
  const StockPageCard({super.key, required this.url, required this.shopName});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final link = url;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Your stock page', style: theme.textTheme.titleMedium),
        const SizedBox(height: Spacing.xs),
        if (link == null)
          Text(
            'A public page can show your customers which medicines you have in stock, without prices or '
            'quantities. You do not have one yet. To get one, ask us at $kSupportEmail.',
            style: muted,
          )
        else ...[
          Text('Customers scan this to see which medicines you have in stock. It shows no prices or quantities.',
              style: muted),
          const SizedBox(height: Spacing.m),
          Center(
            child: InkWell(
              key: const ValueKey('stock-qr'),
              onTap: () => _showFullScreen(context, link),
              child: QrCodeView(link, size: 168),
            ),
          ),
          const SizedBox(height: Spacing.xs),
          Center(child: Text('Tap the code to show it larger', style: muted)),
          const SizedBox(height: Spacing.m),
          SelectableText(link, key: const ValueKey('stock-url'), style: theme.textTheme.bodyMedium),
          const SizedBox(height: Spacing.s),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: link));
                    if (context.mounted) context.say('Link copied');
                  },
                  icon: const Icon(Icons.copy_rounded),
                  label: const Text('Copy'),
                ),
              ),
              const SizedBox(width: Spacing.s),
              Expanded(
                child: Builder(
                  // The share sheet points at this button (iPad).
                  builder: (anchor) => OutlinedButton.icon(
                    onPressed: () => SharePlus.instance.share(ShareParams(
                      text: 'See which medicines $shopName has in stock: $link',
                      sharePositionOrigin: shareOrigin(anchor),
                    )),
                    icon: const Icon(Icons.share_rounded),
                    label: const Text('Share'),
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// The code large enough for a customer to scan from across the counter.
  void _showFullScreen(BuildContext context, String link) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog.fullscreen(
        backgroundColor: Colors.white,
        child: SafeArea(
          child: Stack(
            children: [
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(Spacing.l),
                  child: LayoutBuilder(
                    builder: (ctx, box) => Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(shopName,
                            textAlign: TextAlign.center,
                            style: Theme.of(ctx).textTheme.headlineSmall?.copyWith(color: Colors.black)),
                        const SizedBox(height: Spacing.s),
                        const Text('Scan to see which medicines are in stock',
                            textAlign: TextAlign.center, style: TextStyle(color: Colors.black87)),
                        const SizedBox(height: Spacing.l),
                        QrCodeView(link, size: (box.maxWidth < box.maxHeight ? box.maxWidth : box.maxHeight) * 0.8),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                top: Spacing.s,
                right: Spacing.s,
                child: IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close, color: Colors.black),
                  onPressed: () => Navigator.of(ctx).pop(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
