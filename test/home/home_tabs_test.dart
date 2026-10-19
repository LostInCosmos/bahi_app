import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/core/navigation/tab_screen.dart';
import 'package:gst_bill_app/features/home/presentation/home_screen.dart';
import 'package:gst_bill_app/features/home/presentation/home_tabs.dart';

/// The home screen is built from `kHomeTabs`. These pin that the config is
/// well formed and that every tab it builds can be refreshed on reselect —
/// a new tab that forgets the `TabScreen` mixin would otherwise silently
/// never refresh.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiClient.instance.token = null; // no token: every tab builds without a store or a request
  });

  test('tab ids are unique and the bar fits them', () {
    final ids = kHomeTabs.map((t) => t.id).toSet();
    expect(ids.length, kHomeTabs.length);
    expect(kHomeTabs.length, lessThanOrEqualTo(5), reason: 'Material\'s bottom bar fits five destinations');
  });

  testWidgets('every tab shows in the bar, and each screen is a TabScreen', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pump();
    for (final tab in kHomeTabs) {
      expect(find.descendant(of: find.byType(NavigationBar), matching: find.text(tab.label)), findsOneWidget);
    }
    // IndexedStack keeps every tab's State alive, so each can be inspected.
    final states = tester.allStates.whereType<TabScreen>().toList();
    expect(states.length, kHomeTabs.length, reason: 'every tab screen must mix in TabScreen');
  });

  testWidgets('selecting a tab changes the title', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pump();
    expect(find.text(kHomeTabs.first.title), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Inventory')));
    await tester.pump();
    expect(find.descendant(of: find.byType(AppBar), matching: find.text('Inventory')), findsOneWidget);
  });
}
