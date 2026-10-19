import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/config/legal_documents.dart';
import '../../../core/widgets/busy_button.dart';
import '../../../core/widgets/dastavez_logo.dart';
import '../../../core/widgets/inline_message.dart';
import 'legal_screen.dart';

/// "We've updated our Terms and Privacy Policy": shown over the app when the
/// server says the shop's recorded acceptance is older than the documents
/// this build carries (DAS-104). The shop reads both documents from here,
/// ticks, and Accept records the version on the server through [onAccept];
/// until that succeeds there is no way past this screen. The same clear
/// affirmative action as signup (DPDP Act s.6).
///
/// Never shown on a build whose documents are older than the server's
/// current version — it could not show the text it would be recording.
class LegalAcceptanceScreen extends StatefulWidget {
  /// Records the acceptance of [kLegalVersion] and moves on; throws on
  /// failure, and the message is shown under the button. Given this
  /// screen's own context, since whoever pushed it may be gone by then.
  final Future<void> Function(BuildContext context) onAccept;

  /// True when the shop has never accepted (a signup from an old build),
  /// false when it accepted an earlier version — the wording differs.
  final bool firstTime;

  const LegalAcceptanceScreen({super.key, required this.onAccept, this.firstTime = false});

  @override
  State<LegalAcceptanceScreen> createState() => _LegalAcceptanceScreenState();
}

class _LegalAcceptanceScreenState extends State<LegalAcceptanceScreen> {
  bool _ticked = false;
  bool _busy = false;
  String? _error;

  Future<void> _accept() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onAccept(context);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not record your acceptance: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: false, // Back does not skip it
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: ListView(
                padding: const EdgeInsets.all(Spacing.xl),
                children: [
                  const SizedBox(height: Spacing.xl),
                  const Center(child: DastavezLogo(size: 56)),
                  const SizedBox(height: Spacing.xl),
                  Text(
                    widget.firstTime ? 'Please accept our terms' : "We've updated our terms",
                    style: theme.textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: Spacing.m),
                  Text(
                    widget.firstTime
                        ? 'To keep using Dastavez, please read and accept the Terms of Service and Privacy Policy '
                            '(version $kLegalVersion, effective $kLegalEffectiveDate).'
                        : 'The Terms of Service and Privacy Policy have changed (version $kLegalVersion, effective '
                            '$kLegalEffectiveDate). Please read them and accept to continue.',
                    style: theme.textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: Spacing.l),
                  for (final doc in legalDocuments)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.description_outlined),
                        title: Text(doc.title),
                        subtitle: Text(doc.summary, maxLines: 2, overflow: TextOverflow.ellipsis),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => LegalScreen.open(context, doc.id),
                      ),
                    ),
                  const SizedBox(height: Spacing.l),
                  CheckboxListTile(
                    key: const ValueKey('accept-legal-tick'),
                    value: _ticked,
                    onChanged: _busy ? null : (v) => setState(() => _ticked = v ?? false),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    title: const LegalLinksText(prefix: 'I have read and agree to the'),
                  ),
                  ErrorText(_error, padding: const EdgeInsets.only(top: Spacing.s)),
                  const SizedBox(height: Spacing.m),
                  BusyFilledButton(
                    key: const ValueKey('accept-legal'),
                    busy: _busy,
                    onPressed: _ticked ? _accept : null,
                    label: 'Accept and continue',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
