import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Must match `PlatformStorage.channelName` on the Dart side.
  private static let storageChannelName = "com.surviveai.survive_ai/platform_storage"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerPlatformStorageChannel(with: engineBridge.binaryMessenger)
  }

  /// One method: mark a path as excluded from iCloud and iTunes backup.
  ///
  /// This has no Android counterpart by design. Android's backup is switched
  /// off wholesale in AndroidManifest.xml (`android:allowBackup="false"`), and
  /// there is nothing per-file to do. iOS has no such switch — everything under
  /// Documents is backed up by default, which for this app means a ~500 MB
  /// model file, a 175 MB encoder and a rebuildable SQLite index being pushed
  /// into a user's 5 GB free iCloud tier. Apple's storage guidelines call that
  /// out specifically, and it is a common review rejection.
  ///
  /// The alternative — keeping the model in Library/Caches, which is never
  /// backed up — is worse: iOS purges Caches under disk pressure, and an
  /// offline safety app that silently loses its model is the one failure this
  /// whole project exists to avoid.
  private func registerPlatformStorageChannel(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: AppDelegate.storageChannelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "excludeFromBackup" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let path = (call.arguments as? [String: Any])?["path"] as? String else {
        result(FlutterError(code: "bad_args", message: "path is required", details: nil))
        return
      }
      var url = URL(fileURLWithPath: path)
      guard FileManager.default.fileExists(atPath: path) else {
        // Not an error. The caller marks directories it is about to fill, and
        // a missing one simply means nothing has been downloaded yet.
        result(false)
        return
      }
      do {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        result(true)
      } catch {
        result(FlutterError(
          code: "exclude_failed",
          message: error.localizedDescription,
          details: path
        ))
      }
    }
  }
}
