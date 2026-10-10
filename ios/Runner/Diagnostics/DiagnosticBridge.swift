import Foundation

#if os(macOS)
  import Cocoa
  import FlutterMacOS
#else
  import UIKit
  import Flutter
#endif

final class DiagnosticBridge: NSObject, FlutterStreamHandler {
  private let engine: DiagnosticEngine
  private let methods: FlutterMethodChannel
  private let events: FlutterEventChannel
  private var sink: FlutterEventSink?
  private var lastReport: [String: Any]?
  private var observers = [NSObjectProtocol]()
  #if os(macOS)
    private var activity: NSObjectProtocol?
  #else
    private var previousIdleSetting: Bool?
  #endif

  init(messenger: FlutterBinaryMessenger, isHost: Bool) {
    engine = DiagnosticEngine(isHost: isHost)
    methods = FlutterMethodChannel(name: "silent_disco/diagnostics", binaryMessenger: messenger)
    events = FlutterEventChannel(
      name: "silent_disco/diagnostics/events", binaryMessenger: messenger)
    super.init()
    #if os(macOS)
      lastReport = loadLatestReport()
      observers.append(
        NSWorkspace.shared.notificationCenter.addObserver(
          forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.engine.perform("sleep") })
    #else
      observers.append(
        NotificationCenter.default.addObserver(
          forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.engine.perform("background") })
      observers.append(
        NotificationCenter.default.addObserver(
          forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.engine.perform("foreground") })
    #endif
    engine.onSnapshot = { [weak self] snapshot in
      DispatchQueue.main.async {
        guard let self = self else { return }
        var value = snapshot
        if value["report"] == nil, value["active"] as? Bool != true, let report = self.lastReport {
          value["report"] = report
        }
        self.sink?(value)
      }
    }
    engine.onReport = { [weak self] report in
      #if os(macOS)
        do { try Self.persist(report) } catch {
          DispatchQueue.main.async {
            self?.sink?(
              FlutterError(
                code: "report_save", message: "Could not save report: \(error)", details: nil))
          }
        }
      #endif
      DispatchQueue.main.async { self?.lastReport = report }
    }
    engine.onActivity = { [weak self] active in
      DispatchQueue.main.async { self?.setActive(active) }
    }
    methods.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "exportReport": self.exportReport(result)
      case "getReport": result(self.lastReport)
      default:
        let commands = [
          "snapshot", "startHost", "stopHost", "browse", "stopBrowse", "connect", "disconnect",
          "startTest", "stopTest",
        ]
        guard commands.contains(call.method) else {
          result(FlutterMethodNotImplemented)
          return
        }
        self.engine.perform(call.method, args: call.arguments as? [String: Any] ?? [:])
        result(nil)
      }
    }
    events.setStreamHandler(self)
  }
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    engine.perform("snapshot")
    return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }
  private func setActive(_ active: Bool) {
    #if os(macOS)
      if active, activity == nil {
        activity = ProcessInfo.processInfo.beginActivity(
          options: [.idleSystemSleepDisabled, .userInitiated],
          reason: "Silent Disco LAN diagnostics")
      } else if !active, let existing = activity {
        ProcessInfo.processInfo.endActivity(existing)
        activity = nil
      }
    #else
      if active, previousIdleSetting == nil {
        previousIdleSetting = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
      } else if !active, let previous = previousIdleSetting {
        UIApplication.shared.isIdleTimerDisabled = previous
        previousIdleSetting = nil
      }
    #endif
  }
  private func exportReport(_ result: @escaping FlutterResult) {
    #if os(macOS)
      guard let report = lastReport else {
        result(FlutterError(code: "no_report", message: "Run a test first.", details: nil))
        return
      }
      let panel = NSSavePanel()
      panel.allowedFileTypes = ["json"]
      panel.nameFieldStringValue = "silent-disco-\(report["run"] as? String ?? "report").json"
      panel.begin { response in
        guard response == .OK, let url = panel.url else {
          result(nil)
          return
        }
        do {
          try JSONSerialization.data(
            withJSONObject: report, options: [.prettyPrinted, .sortedKeys]
          ).write(to: url, options: .atomic)
          result(url.path)
        } catch { result(FlutterError(code: "export_failed", message: "\(error)", details: nil)) }
      }
    #else
      result(
        FlutterError(
          code: "host_export", message: "Export the complete report from the Mac.", details: nil))
    #endif
  }
  #if os(macOS)
    private static func reportDirectory() throws -> URL {
      let base = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      let directory = base.appendingPathComponent(
        "SilentDiscoDiagnostics/Reports", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      return directory
    }
    private static func reportFiles() throws -> [URL] {
      try FileManager.default.contentsOfDirectory(
        at: reportDirectory(), includingPropertiesForKeys: [.contentModificationDateKey]
      )
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
    private static func persist(_ report: [String: Any]) throws {
      let filename =
        "\(Int(Date().timeIntervalSince1970*1000))-\(report["run"] as? String ?? UUID().uuidString).json"
      let url = try reportDirectory().appendingPathComponent(filename)
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: url, options: .atomic)
      for old in try reportFiles().dropFirst(20) { try FileManager.default.removeItem(at: old) }
    }
    private func loadLatestReport() -> [String: Any]? {
      guard let file = try? Self.reportFiles().first, let data = try? Data(contentsOf: file) else {
        return nil
      }
      return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
  #endif
  deinit {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
      #if os(macOS)
        NSWorkspace.shared.notificationCenter.removeObserver(observer)
      #endif
    }
    #if os(macOS)
      if let activity = activity { ProcessInfo.processInfo.endActivity(activity) }
    #endif
  }
}
