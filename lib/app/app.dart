import 'package:flutter/material.dart';

import '../core/api/api_client.dart';
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
  }

  @override
  void dispose() {
    if (ApiClient.instance.onSessionEnded == _onSessionEnded) ApiClient.instance.onSessionEnded = null;
    super.dispose();
  }

  /// The server refused this device's token (signed out elsewhere). Back to
  /// the login screen, saying why — every open screen goes, so nothing keeps
  /// asking with a token that will only be refused again.
  void _onSessionEnded() {
    _navigator.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (_) => false,
    );
    _messenger.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('You were signed out. Please log in again.')));
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
    ApiClient.instance.loadFromDisk().then((_) {
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
