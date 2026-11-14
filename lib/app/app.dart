import 'dart:async';

import 'package:flutter/material.dart';

import '../core/api/api_client.dart';
import '../core/config/legal_documents.dart' show kSupportEmail;
import '../core/utils/app_foreground.dart';
import '../core/utils/play_store.dart';
import '../core/utils/snack.dart';
import '../core/utils/share_file.dart';
import '../features/auth/data/auth_api.dart';
import '../features/auth/models/account.dart';
import '../core/navigation/app_routes.dart';
import '../features/auth/presentation/legal_acceptance_screen.dart';
import '../features/auth/presentation/sign_out.dart';
import '../features/auth/presentation/login_screen.dart';
import '../features/home/presentation/home_screen.dart';
import 'theme/app_theme.dart';

class GstBillApp extends StatefulWidget {
  const GstBillApp({super.key});

  @override
  State<GstBillApp> createState() => _GstBillAppState();
}

class _GstBillAppState extends State<GstBillApp> {
  final _navigator = GlobalKey<NavigatorState>();
  final _messenger = GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    // Whether the app is on screen: capture and voice pause their waits and
    // do not call an upload failed while it is away (DAS-131).
    AppForeground.start();
    ApiClient.instance.onSessionEnded = _onSessionEnded;
    ApiClient.instance.onVersionGate = _onVersionGate;
  }

  @override
  void dispose() {
    if (ApiClient.instance.onSessionEnded == _onSessionEnded) ApiClient.instance.onSessionEnded = null;
    if (ApiClient.instance.onVersionGate == _onVersionGate) ApiClient.instance.onVersionGate = null;
    super.dispose();
  }

  /// The server refused this device's token (signed out elsewhere). Back to
  /// the login screen, saying why — every open screen goes, so nothing keeps
  /// asking with a token that will only be refused again. Decoded bill
  /// images go too (DAS-90).
  void _onSessionEnded() {
    imageCache.clear();
    _navigator.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (_) => false,
    );
    _messenger.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('You were signed out. Please log in again.')));
  }

  /// This build has fallen behind what the server wants (DAS-74). `nudge` is
  /// a dismissible banner the shopkeeper can ignore; `hardBlock` takes over
  /// the whole screen. Nothing to do for `ok` — a dismissed nudge is not
  /// reshown, and a hard block is left only by logging out.
  void _onVersionGate(VersionGateLevel level) {
    switch (level) {
      case VersionGateLevel.ok:
        break;
      case VersionGateLevel.nudge:
        _showUpdateNudge();
        break;
      case VersionGateLevel.hardBlock:
        // The block says it all: a nudge shown earlier must not sit on top.
        _messenger.currentState?.hideCurrentMaterialBanner();
        _navigator.currentState?.pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const _UpdateRequiredScreen()),
          (_) => false,
        );
        break;
    }
  }

  Future<void> _showUpdateNudge() async {
    final message = await ApiClient.instance.versionInfo().catchError((_) => null);
    _messenger.currentState
      ?..hideCurrentMaterialBanner()
      ..showMaterialBanner(MaterialBanner(
        // The admin's reason first, then this build, then Update (DAS-189).
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message ?? 'A new version of Dastavez is ready.'),
            const SizedBox(height: 4),
            Text('Your version: ${ApiClient.instance.appVersionLabel}', style: const TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => _messenger.currentState?.hideCurrentMaterialBanner(),
            child: const Text('Later'),
          ),
          if (canOpenPlayStore)
            FilledButton(
              key: const ValueKey('update-nudge'),
              onPressed: () async {
                if (!await openPlayStore()) {
                  _messenger.currentState
                    ?..hideCurrentSnackBar()
                    ..showSnackBar(const SnackBar(content: Text('Could not open the Play Store.')));
                }
              },
              child: const Text('Update'),
            ),
        ],
      ));
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: ApiClient.instance.businessTypeNotifier,
      builder: (context, businessType, child) {
        final theme = buildAppTheme(brightness: Brightness.dark, businessType: businessType);
        return MaterialApp(
          navigatorKey: _navigator,
          scaffoldMessengerKey: _messenger,
          title: 'GST Bill Reconciliation',
          debugShowCheckedModeBanner: false,
          themeMode: ThemeMode.dark,
          theme: theme,
          darkTheme: theme,
          home: const _StartupGate(),
          routes: {AppRoutes.home: (_) => const HomeScreen()},
        );
      },
    );
  }
}

/// Loads the persisted API token/base URL before deciding whether to land
/// on the login screen or straight into the app.
class _StartupGate extends StatefulWidget {
  const _StartupGate();

  @override
  State<_StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<_StartupGate> {
  bool _ready = false;

  /// The server said the shop must accept the current documents (DAS-104);
  /// the app is covered until it does. Null until the account was asked.
  AccountInfo? _needsAcceptance;

  @override
  void initState() {
    super.initState();
    unawaited(sweepSharedFiles()); // exports shared yesterday or earlier
    Future.wait([ApiClient.instance.loadFromDisk(), ApiClient.instance.loadAppInfo()]).then((_) {
      if (mounted) setState(() => _ready = true);
      // Refreshes the persisted business type (used for theming immediately
      // on launch) against the server in case it changed on another device.
      if (ApiClient.instance.isLoggedIn) _refreshBusinessTypeSilently();
    });
  }

  Future<void> _refreshBusinessTypeSilently() async {
    try {
      final account = await ApiClient.instance.getAccount();
      // Also where a shop learns, on launch, that the documents changed
      // (DAS-104). Offline: nothing is asked; the next launch asks.
      if (mounted && account.needsLegalAcceptance) setState(() => _needsAcceptance = account);
    } catch (_) {
      // Best-effort — the persisted value from the last session is fine.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!ApiClient.instance.isLoggedIn) return const LoginScreen();
    final pending = _needsAcceptance;
    if (pending != null) {
      return LegalAcceptanceScreen(
        firstTime: pending.legal?.acceptedVersion == null,
        onAccept: (_) async {
          await ApiClient.instance.acceptLegal();
          if (mounted) setState(() => _needsAcceptance = null);
        },
      );
    }
    return const HomeScreen();
  }
}

/// A true breaking change (DAS-74) — set explicitly and separately from the
/// dismissible nudge, never the default just from being behind. Takes over
/// the whole screen: the admin's reason, this build, and Update on Play
/// Store (DAS-189); the only other way out is logging out.
class _UpdateRequiredScreen extends StatefulWidget {
  const _UpdateRequiredScreen();

  @override
  State<_UpdateRequiredScreen> createState() => _UpdateRequiredScreenState();
}

class _UpdateRequiredScreenState extends State<_UpdateRequiredScreen> {
  String? _message;

  @override
  void initState() {
    super.initState();
    ApiClient.instance.versionInfo().then((m) {
      if (mounted) setState(() => _message = m);
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.system_update_rounded, size: 48),
                const SizedBox(height: 16),
                Text(
                  _message ?? 'This version of Dastavez has stopped working. Please update to keep using it.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Your version: ${ApiClient.instance.appVersionLabel}',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
                if (canOpenPlayStore) ...[
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    key: const ValueKey('update-required'),
                    onPressed: () async {
                      if (!await openPlayStore() && context.mounted) context.say('Could not open the Play Store.');
                    },
                    icon: const Icon(Icons.shop_outlined),
                    label: const Text('Update on Play Store'),
                  ),
                  const SizedBox(height: 12),
                  // The listing is closed testing for now (2026-11-14).
                  Text(
                    "If the Play Store says Dastavez isn't found, email $kSupportEmail and we'll give you access.",
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
                const SizedBox(height: 24),
                TextButton(onPressed: () => signOut(context), child: const Text('Log out')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
