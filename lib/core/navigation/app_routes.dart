/// Named routes, registered on the app's MaterialApp (`app/app.dart`).
///
/// Here, in core, rather than beside the screens: a screen that names where
/// to go next must not have to import that screen. Login importing home and
/// home importing login was an import cycle, and core imports no feature.
abstract final class AppRoutes {
  static const home = '/home';
}
