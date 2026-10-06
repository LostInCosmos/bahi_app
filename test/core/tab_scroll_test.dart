import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Why the web app needed a scroll fix and the phone did not.
///
/// A shopkeeper scrolls Capture, opens a bill, comes back — and must land
/// where they were. On the web that broke: each route is built fresh, so
/// the list started empty and at the top. Here it does not, and these
/// tests pin the two structural reasons so a refactor cannot quietly
/// remove them.
///
/// They exercise the PATTERN home_screen.dart uses (IndexedStack over
/// screens held by stable GlobalKeys, Navigator.push for detail), not the
/// real screens, which need an API, a token and a database to build.
/// A plain ListView makes its own controller and does not expose it, so
/// the position is read from the ScrollableState instead.
double offsetOf(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable).first).position.pixels;

void main() {
  Widget list(String label) => ListView(
        children: [for (var i = 0; i < 60; i++) SizedBox(height: 50, child: Text('$label $i'))],
      );

  testWidgets('a tab keeps its scroll position when you switch away and back', (tester) async {
    final key = GlobalKey();
    var tab = 0;

    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(
        builder: (context, setState) => Scaffold(
          body: IndexedStack(
            index: tab,
            children: [SizedBox(key: key, child: list('capture')), list('sales')],
          ),
          bottomNavigationBar: Row(children: [
            TextButton(onPressed: () => setState(() => tab = 0), child: const Text('Capture')),
            TextButton(onPressed: () => setState(() => tab = 1), child: const Text('Sales')),
          ]),
        ),
      ),
    ));

    await tester.drag(find.text('capture 0'), const Offset(0, -600));
    await tester.pumpAndSettle();
    final scrolled = offsetOf(tester);
    expect(scrolled, greaterThan(300), reason: 'the drag must actually scroll, or this proves nothing');

    await tester.tap(find.text('Sales'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Capture'));
    await tester.pumpAndSettle();

    // IndexedStack keeps both children alive, so the position is still there.
    expect(offsetOf(tester), scrolled);
  });

  testWidgets('a list keeps its scroll position while a detail screen is pushed over it', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Column(children: [
            ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => Scaffold(appBar: AppBar(), body: const Text('bill')),
                ),
              ),
              child: const Text('open'),
            ),
            Expanded(child: list('capture')),
          ]),
        ),
      ),
    ));

    await tester.drag(find.text('capture 1'), const Offset(0, -600));
    await tester.pumpAndSettle();
    final scrolled = offsetOf(tester);
    expect(scrolled, greaterThan(300));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('bill'), findsOneWidget);

    // push(), not pushReplacement(): the list stays mounted underneath.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(offsetOf(tester), scrolled);
  });
}
