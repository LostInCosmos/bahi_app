import 'dart:async';

import 'package:flutter/widgets.dart';

/// Whether this app is on screen, for work that must not run, or must not be
/// called failed, while it is away (DAS-131).
///
/// Measured on Android 15 (the DAS-126 experiment): five seconds after the
/// app leaves the screen the OS destroys its sockets and refuses new ones
/// until it is back, and iOS suspends it within seconds. A request cut that
/// way is the platform's doing, not the server's and not the shopkeeper's.
///
/// One listener for the whole app, installed by `GstBillApp` — not one per
/// screen: the home tabs live in an `IndexedStack`, so a screen-level
/// listener on a tab that is not in front would still be the right object,
/// but there is no reason to have five. `inactive` (a call banner, the
/// control centre, the app switcher opening) still counts as visible: the
/// network works there and nothing should pause for it.
class AppForeground {
  AppForeground._();

  /// True while the app is on screen. Starts true, so code that never sees a
  /// lifecycle event (tests, a platform without one) behaves as before.
  static final ValueNotifier<bool> visible = ValueNotifier<bool>(true);

  /// Bumped each time the app leaves the screen. Work that started at one
  /// value and fails at another was interrupted by the platform, even if the
  /// failure only arrives after the app is back (iOS reports a socket it
  /// closed during suspension on the first read after resume).
  static int get awayCount => _awayCount;
  static int _awayCount = 0;

  static AppLifecycleListener? _listener;

  /// Installs the listener once; later calls do nothing.
  static void start() {
    _listener ??= AppLifecycleListener(onStateChange: applyState);
  }

  /// Folds one lifecycle state in. Public so a test can drive it without a
  /// platform; the listener calls it in the app.
  static void applyState(AppLifecycleState state) {
    final onScreen = state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
    if (!onScreen && visible.value) _awayCount++;
    visible.value = onScreen;
  }

  /// Completes when the app is on screen; at once if it already is.
  static Future<void> untilVisible() {
    if (visible.value) return Future.value();
    final done = Completer<void>();
    void check() {
      if (!visible.value || done.isCompleted) return;
      visible.removeListener(check);
      done.complete();
    }

    visible.addListener(check);
    return done.future;
  }

  /// Back to the starting state, for tests.
  @visibleForTesting
  static void reset() {
    _listener?.dispose();
    _listener = null;
    _awayCount = 0;
    visible.value = true;
  }
}
