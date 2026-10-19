import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/config/legal_documents.dart';

/// Shows one of the legal documents (`core/config/legal_documents.dart`):
/// title, version and date, then every section. Reachable before signing in
/// (the signup checkbox and the login screen's footer) and from Account, so
/// the policy is "easily accessible within the app" as the store rules ask.
class LegalScreen extends StatelessWidget {
  final LegalDocument document;
  const LegalScreen({super.key, required this.document});

  /// Opens the document with this id (`terms` or `privacy`).
  static Future<void> open(BuildContext context, String id) => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => LegalScreen(document: legalDocumentById(id))),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final d = document;
    // One flat list of rows, built as they scroll: a policy is long, and a
    // Column would lay out every paragraph on open.
    final rows = <Widget>[
      Text(d.title, style: theme.textTheme.headlineSmall),
      const SizedBox(height: Spacing.xs),
      Text('Version ${d.version} · Effective ${d.effectiveDate}',
          style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
      const SizedBox(height: Spacing.m),
      Text(d.summary, style: theme.textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant)),
      const SizedBox(height: Spacing.l),
      for (final s in d.sections) ...[
        Padding(
          padding: const EdgeInsets.only(top: Spacing.m, bottom: Spacing.xs),
          child: Text(s.heading, style: theme.textTheme.titleMedium),
        ),
        for (final p in s.paragraphs) _Paragraph(p),
        for (final b in s.bullets) _Bullet(b),
        for (final p in s.after) _Paragraph(p),
      ],
      const SizedBox(height: Spacing.xl),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(d.title)),
      body: SafeArea(
        child: ListView.builder(
          padding: const EdgeInsets.all(Spacing.l),
          itemCount: rows.length,
          itemBuilder: (context, i) => rows[i],
        ),
      ),
    );
  }
}

class _Paragraph extends StatelessWidget {
  final String text;
  const _Paragraph(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: Spacing.s),
        child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
      );
}

class _Bullet extends StatelessWidget {
  final String text;
  const _Bullet(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: Spacing.s, bottom: Spacing.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('•  '),
            Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyMedium)),
          ],
        ),
      );
}

/// "By creating an account you agree to the Terms of Service and Privacy
/// Policy", with both names tappable. Used under the signup form and on the
/// login screen's footer; [prefix] is the sentence before the two names.
class LegalLinksText extends StatelessWidget {
  final String prefix;
  final TextAlign textAlign;
  const LegalLinksText({super.key, this.prefix = '', this.textAlign = TextAlign.start});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final link = base?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w600);
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          if (prefix.isNotEmpty) TextSpan(text: '$prefix '),
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: _LinkText(kTermsOfService.title, style: link, onTap: () => LegalScreen.open(context, 'terms')),
          ),
          const TextSpan(text: ' and '),
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: _LinkText(kPrivacyPolicy.title, style: link, onTap: () => LegalScreen.open(context, 'privacy')),
          ),
          const TextSpan(text: '.'),
        ],
      ),
      textAlign: textAlign,
    );
  }
}

/// A tappable word inside running text. A real widget rather than a
/// `TapGestureRecognizer`, so it needs no disposing and a test can tap it by
/// its text.
class _LinkText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final VoidCallback onTap;
  const _LinkText(this.text, {required this.style, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Text(text, style: style),
      );
}
