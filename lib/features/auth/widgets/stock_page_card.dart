import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/utils/share_file.dart';
import '../../../core/utils/snack.dart';
import '../../../core/widgets/qr_code_view.dart';

/// The shop's public stock page (DAS-80) on the Account screen: a QR code
/// customers can scan, and the two links the site serves for it, the stock
/// page and the printable QR poster, each to copy, share or open. The page
/// shows which medicines are in stock, never prices or quantities. Shown
/// only while the page is live: a shop without one sees nothing (the user,
/// 2026-10-27).
class StockPageCard extends StatelessWidget {
  final String url;
  final String? posterUrl;
  final String shopName;
  const StockPageCard({super.key, required this.url, this.posterUrl, required this.shopName});

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
        _LinkRow(
          key: const ValueKey('stock-url'),
          title: 'Stock page',
          url: link,
          shareText: 'See which medicines $shopName has in stock: $link',
        ),
        if (posterUrl != null)
          _LinkRow(
            key: const ValueKey('poster-url'),
            title: 'QR poster to print',
            url: posterUrl!,
            shareText: 'QR poster for $shopName: $posterUrl',
          ),
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

/// One link with its three actions: copy it, share it, open it in the browser.
class _LinkRow extends StatelessWidget {
  final String title;
  final String url;
  final String shareText;
  const _LinkRow({super.key, required this.title, required this.url, required this.shareText});

  Future<void> _open(BuildContext context) async {
    final opened = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!opened && context.mounted) context.say('Could not open the link');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.labelLarge),
          SelectableText(url, style: theme.textTheme.bodyMedium),
          const SizedBox(height: Spacing.xs),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: url));
                    if (context.mounted) context.say('Link copied');
                  },
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: const Text('Copy'),
                ),
              ),
              const SizedBox(width: Spacing.s),
              Expanded(
                child: Builder(
                  // The share sheet points at this button (iPad).
                  builder: (anchor) => OutlinedButton.icon(
                    onPressed: () => SharePlus.instance
                        .share(ShareParams(text: shareText, sharePositionOrigin: shareOrigin(anchor))),
                    icon: const Icon(Icons.share_rounded, size: 18),
                    label: const Text('Share'),
                  ),
                ),
              ),
              const SizedBox(width: Spacing.s),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _open(context),
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: const Text('Open'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
