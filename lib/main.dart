import 'package:flutter/material.dart';

import 'api_client.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'theme.dart';

void main() {
  runApp(const GstBillApp());
}

class GstBillApp extends StatelessWidget {
  const GstBillApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GST Bill Reconciliation',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: buildAppTheme(brightness: Brightness.light),
      darkTheme: buildAppTheme(brightness: Brightness.dark),
      home: const _StartupGate(),
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
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return ApiClient.instance.isLoggedIn ? const HomeScreen() : const LoginScreen();
  }
}
