import 'package:flutter/material.dart';
import '../../../core/widgets/dastavez_logo.dart';

import '../../../core/api/api_client.dart';
import '../../auth/presentation/account_screen.dart';
import '../../capture/presentation/capture_screen.dart';
import '../../inventory/presentation/inventory_screen.dart';
import '../../auth/presentation/login_screen.dart';
import '../../invoice/presentation/purchases_screen.dart';
import '../../sales/presentation/sales_history_screen.dart';
import '../../sales/presentation/sales_screen.dart';
import '../../voice/presentation/voice_command_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _titles = ['New bills', 'Purchases', 'Inventory', 'New sale', 'Sales'];

  int _tab = 0;
  final _captureKey = GlobalKey<CaptureScreenState>();
  final _purchasesKey = GlobalKey<PurchasesScreenState>();
  final _inventoryKey = GlobalKey<InventoryScreenState>();
  final _salesKey = GlobalKey<SalesScreenState>();
  final _salesHistoryKey = GlobalKey<SalesHistoryScreenState>();

  Future<void> _logout() async {
    await ApiClient.instance.logout();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  void _openAccount() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AccountScreen()));
  }

  void _openVoiceCommand() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const VoiceCommandScreen()));
  }

  void _goToPurchases() {
    setState(() => _tab = 1);
    _purchasesKey.currentState?.refresh();
  }

  void _selectTab(int i) {
    setState(() => _tab = i);
    switch (i) {
      case 0:
        _captureKey.currentState?.refreshFolders();
        break;
      case 1:
        _purchasesKey.currentState?.refresh();
        break;
      case 2:
        _inventoryKey.currentState?.refresh();
        break;
      case 3:
        _salesKey.currentState?.refresh();
        break;
      case 4:
        _salesHistoryKey.currentState?.refresh();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      CaptureScreen(key: _captureKey, onBatchFinished: _goToPurchases),
      PurchasesScreen(key: _purchasesKey),
      InventoryScreen(key: _inventoryKey),
      SalesScreen(key: _salesKey),
      SalesHistoryScreen(key: _salesHistoryKey),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const DastavezLogoTile(size: 30),
            const SizedBox(width: 10),
            Text(_titles[_tab]),
          ],
        ),
        actions: [
          IconButton(onPressed: _openVoiceCommand, icon: const Icon(Icons.record_voice_over_outlined), tooltip: 'Voice command'),
          IconButton(onPressed: _openAccount, icon: const Icon(Icons.storefront_outlined), tooltip: 'Account'),
          IconButton(onPressed: _logout, icon: const Icon(Icons.logout), tooltip: 'Log out'),
        ],
      ),
      body: IndexedStack(index: _tab, children: screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: _selectTab,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.camera_alt_outlined), selectedIcon: Icon(Icons.camera_alt), label: 'Capture'),
          NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: 'Purchases'),
          NavigationDestination(icon: Icon(Icons.inventory_2_outlined), selectedIcon: Icon(Icons.inventory_2), label: 'Inventory'),
          NavigationDestination(icon: Icon(Icons.shopping_cart_outlined), selectedIcon: Icon(Icons.shopping_cart), label: 'Sell'),
          NavigationDestination(icon: Icon(Icons.receipt_outlined), selectedIcon: Icon(Icons.receipt), label: 'Sales'),
        ],
      ),
    );
  }
}
