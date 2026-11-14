import 'package:flutter/widgets.dart';

/// What the home screen asks of each tab it hosts.
///
/// The tabs live in an `IndexedStack`, so a screen stays alive — and stale —
/// while another tab is in front. Every time a tab is selected the home screen
/// calls [refresh] on it, so it notices the stock a purchase added or the
/// bills another tab filed. A new tab is one entry in `home_tabs.dart` plus
/// this mixin on its State.
mixin TabScreen<T extends StatefulWidget> on State<T> {
  Future<void> refresh();
}

/// A tab that can be brought to the front with something to show — a filter
/// the Home tab's tile asks for (DAS-186). It replaces whatever the tab had
/// set; a tab without this mixin ignores the hand-off.
mixin TabHandoff<T extends StatefulWidget> on State<T> {
  void handoff(Object payload);
}
