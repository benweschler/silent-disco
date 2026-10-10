import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var diagnostics: DiagnosticBridge?
  private var audio: AudioBridge?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SilentDiscoDiagnostics") {
      diagnostics = DiagnosticBridge(messenger: registrar.messenger(), isHost: false)
      diagnostics?.setEnabled(false)
      audio = AudioBridge(messenger: registrar.messenger(), isHost: false)
      audio?.onSelectMode = { [weak self] useAudio in self?.diagnostics?.setEnabled(!useAudio) }
    }
  }
}
