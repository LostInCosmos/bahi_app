import 'dart:async';

import 'package:flutter/material.dart';

import '../core/api/api_client.dart';
import '../core/utils/share_file.dart';
import '../features/auth/data/auth_api.dart';
import '../core/navigation/app_routes.dart';
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
        content: Text(message ?? 'A new version of this app is available.'),
        actions: [
          TextButton(
            onPressed: () => _messenger.currentState?.hideCurrentMaterialBanner(),
            child: const Text('Dismiss'),
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
      await ApiClient.instance.getAccount();
    } catch (_) {
      // Best-effort — the persisted value from the last session is fine.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return ApiClient.instance.isLoggedIn ? const HomeScreen() : const LoginScreen();
  }
}

/// A true breaking change (DAS-74) — set explicitly and separately from the
/// dismissible nudge, never the default just from being behind. Takes over
/// the whole screen; the only way out is logging out, since there is no
/// store listing to send anyone to (distribution is USB-connect install
/// only) — someone has to reconnect the device and reinstall.
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
                  _message ?? 'This app needs to be updated before it can be used. Please contact support.',
                  textAlign: TextAlign.center,
                ),
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
