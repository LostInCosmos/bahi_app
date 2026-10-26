import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerBackupExclusion(engineBridge.pluginRegistry)
  }

  /// `dastavez/backup` `exclude(path)`: marks a folder of shop data as excluded
  /// from iCloud backup (DAS-135) — bill photos waiting to upload and the
  /// capture batch. Apple: "isExcludedFromBackup … exists only to provide
  /// guidance to the system", so the app marks the folder on every run.
  private func registerBackupExclusion(_ registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "DastavezBackupExclusion") else { return }
    let channel = FlutterMethodChannel(name: "dastavez/backup", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      guard call.method == "exclude", let path = call.arguments as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      var url = URL(fileURLWithPath: path, isDirectory: true)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      do {
        try url.setResourceValues(values)
        result(true)
      } catch {
        result(FlutterError(code: "exclude_failed", message: error.localizedDescription, details: nil))
      }
    }
  }
}
