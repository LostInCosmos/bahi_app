import 'package:flutter/material.dart';

import '../core/api/api_client.dart';
import '../features/auth/presentation/login_screen.dart';
import '../features/home/presentation/home_screen.dart';
import 'theme/app_theme.dart';

class GstBillApp extends StatelessWidget {
  const GstBillApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: ApiClient.instance.businessTypeNotifier,
      builder: (context, businessType, child) {
        final theme = buildAppTheme(brightness: Brightness.dark, businessType: businessType);
        return MaterialApp(
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
