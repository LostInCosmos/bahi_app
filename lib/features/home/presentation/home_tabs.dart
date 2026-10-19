import 'package:flutter/material.dart';

import '../../capture/presentation/capture_screen.dart';
import '../../inventory/presentation/inventory_screen.dart';
import '../../invoice/presentation/purchases_screen.dart';
import '../../sales/presentation/sales_history_screen.dart';
import '../../sales/presentation/sales_screen.dart';

/// What a tab can ask of the screen hosting it.
abstract interface class HomeTabHost {
  /// Bring the tab with this [HomeTab.id] to the front, refreshing it.
  void select(String id);
}

/// One tab of the home screen: its titles, its icons and how to build it.
///
/// The home screen is driven from [kHomeTabs], so adding a tab is one entry
/// here and a `TabScreen` mixin on the new screen's State — nothing in
/// `home_screen.dart` changes. Material's bottom bar fits five; a sixth would
/// need a different navigation pattern, not a sixth entry.
class HomeTab {
  /// Stable name other tabs can [HomeTabHost.select] by.
  final String id;

  /// The app bar title while this tab is in front.
  final String title;

  /// The word under the icon in the bottom bar.
  final String label;
  final IconData icon;
  final IconData selectedIcon;

  /// Builds the screen. [key] must be passed to it: the home screen keeps it
  /// to call `refresh()` on the screen's State when the tab is reselected.
  final Widget Function(Key key, HomeTabHost host) build;

  const HomeTab({
    required this.id,
    required this.title,
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.build,
  });
}

Widget _capture(Key key, HomeTabHost host) =>
    CaptureScreen(key: key, onBatchFinished: () => host.select('purchases'));
Widget _purchases(Key key, HomeTabHost host) => PurchasesScreen(key: key);
Widget _inventory(Key key, HomeTabHost host) => InventoryScreen(key: key);
Widget _sell(Key key, HomeTabHost host) => SalesScreen(key: key);
Widget _sales(Key key, HomeTabHost host) => SalesHistoryScreen(key: key);

/// In bottom-bar order.
const kHomeTabs = [
  HomeTab(
    id: 'capture',
    title: 'New bills',
    label: 'Capture',
    icon: Icons.camera_alt_outlined,
    selectedIcon: Icons.camera_alt,
    build: _capture,
  ),
  HomeTab(
    id: 'purchases',
    title: 'Purchases',
    label: 'Purchases',
    icon: Icons.receipt_long_outlined,
    selectedIcon: Icons.receipt_long,
    build: _purchases,
  ),
  HomeTab(
    id: 'inventory',
    title: 'Inventory',
    label: 'Inventory',
    icon: Icons.inventory_2_outlined,
    selectedIcon: Icons.inventory_2,
    build: _inventory,
  ),
  HomeTab(
    id: 'sell',
    title: 'New sale',
    label: 'Sell',
    icon: Icons.shopping_cart_outlined,
    selectedIcon: Icons.shopping_cart,
    build: _sell,
  ),
  HomeTab(
    id: 'sales',
    title: 'Sales',
    label: 'Sales',
    icon: Icons.receipt_outlined,
    selectedIcon: Icons.receipt,
    build: _sales,
  ),
];
