import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../../../core/navigation/tab_screen.dart';
import '../../../core/widgets/dastavez_logo.dart';
import '../../auth/presentation/account_screen.dart';
import '../../auth/presentation/sign_out.dart';
import '../../voice/presentation/voice_command_screen.dart';
import 'home_tabs.dart';

/// The shell after login: an app bar, the bottom bar, and [kHomeTabs] in an
/// `IndexedStack` so every tab keeps its scroll position and its state while
/// another is in front (`test/core/tab_scroll_test.dart` pins that). Selecting
/// a tab calls its [TabScreen.refresh], since a tab kept alive does not
/// otherwise notice what the others changed.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> implements HomeTabHost {
  int _tab = 0;

  /// One stable key per tab, so a reselect reaches the same State.
  final List<GlobalKey> _keys = [for (final _ in kHomeTabs) GlobalKey()];

  late final List<Widget> _screens = [
    for (var i = 0; i < kHomeTabs.length; i++) kHomeTabs[i].build(_keys[i], this),
  ];

  void _push(Widget screen) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));

  @override
  void select(String id) => _selectTab(kHomeTabs.indexWhere((t) => t.id == id));

  void _selectTab(int i) {
    if (i < 0) return;
    setState(() => _tab = i);
    (_keys[i].currentState as TabScreen?)?.refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const DastavezLogoTile(size: 30),
            const SizedBox(width: 10),
            Text(kHomeTabs[_tab].title),
          ],
        ),
        actions: [
          // Hidden when the admin has voice off for this shop (DAS-112).
          ValueListenableBuilder<bool>(
            valueListenable: ApiClient.instance.voiceEnabledNotifier,
            builder: (context, voiceOn, _) => voiceOn
                ? IconButton(
                    onPressed: () => _push(const VoiceCommandScreen()),
                    icon: const Icon(Icons.record_voice_over_outlined),
                    tooltip: 'Voice command',
                  )
                : const SizedBox.shrink(),
          ),
          IconButton(
            onPressed: () => _push(const AccountScreen()),
            icon: const Icon(Icons.storefront_outlined),
            tooltip: 'Account',
          ),
          IconButton(onPressed: () => signOut(context), icon: const Icon(Icons.logout), tooltip: 'Log out'),
        ],
      ),
      body: IndexedStack(index: _tab, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: _selectTab,
        destinations: [
          for (final tab in kHomeTabs)
            NavigationDestination(icon: Icon(tab.icon), selectedIcon: Icon(tab.selectedIcon), label: tab.label),
        ],
      ),
    );
  }
}
