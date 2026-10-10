import AVFoundation
import AudioCore
import Foundation

#if os(macOS)
  import Cocoa
  import FlutterMacOS
#else
  import UIKit
  import Flutter
  import MediaPlayer
#endif

final class AudioBridge: NSObject, FlutterStreamHandler {
  private let session: AudioSession
  private let methods: FlutterMethodChannel
  private let events: FlutterEventChannel
  private let io = DispatchQueue(label: "dev.silentdisco.audio.files", qos: .utility)
  private var sink: FlutterEventSink?
  private var observers = [NSObjectProtocol]()
  private var lastReport: [String: Any]?
  private var snapshot = [String: Any]()
  private var enabled = true
  var onSelectMode: ((Bool) -> Void)?
  #if os(macOS)
    private var activity: NSObjectProtocol?
    private var scopedURL: URL?
  #else
    private var remoteTargets = [(MPRemoteCommand, Any)]()
  #endif
  init(messenger: FlutterBinaryMessenger, isHost: Bool) {
    session = AudioSession(isHost: isHost)
    methods = FlutterMethodChannel(name: "silent_disco/audio", binaryMessenger: messenger)
    events = FlutterEventChannel(name: "silent_disco/audio/events", binaryMessenger: messenger)
    super.init()
    session.onSnapshot = { [weak self] value in
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.snapshot = value
        self.publish()
      }
    }
    session.onReport = { [weak self] report in
      guard let self = self else { return }
      self.io.async {
        do { try Self.save(report) } catch {
          DispatchQueue.main.async {
            self.sink?(
              FlutterError(code: "report_save", message: error.localizedDescription, details: nil))
          }
        }
      }
      DispatchQueue.main.async {
        self.lastReport = report
        self.publish()
      }
    }
    io.async { [weak self] in
      let report = try? Self.load()
      DispatchQueue.main.async {
        self?.lastReport = report
        self?.publish()
      }
    }
    #if os(macOS)
      session.onActivity = { [weak self] active in
        DispatchQueue.main.async {
          guard let self = self else { return }
          if active, self.activity == nil {
            self.activity = ProcessInfo.processInfo.beginActivity(
              options: [.idleSystemSleepDisabled, .userInitiated],
              reason: "Streaming Silent Disco audio")
          } else if !active, let old = self.activity {
            ProcessInfo.processInfo.endActivity(old)
            self.activity = nil
          }
        }
      }
      observers.append(
        NSWorkspace.shared.notificationCenter.addObserver(
          forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.session.perform("sleep") })
    #else
      session.onListening = { [weak self] active in
        DispatchQueue.main.async { self?.audioSession(active) }
      }
      observe(UIApplication.willEnterForegroundNotification) { [weak self] _ in
        if self?.enabled == true { self?.session.perform("foreground") }
      }
      observe(AVAudioSession.routeChangeNotification) { [weak self] note in
        guard let self = self, self.enabled else { return }
        let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
        let audio = AVAudioSession.sharedInstance()
        self.session.perform(
          "setRoute",
          args: [
            "outputs": audio.currentRoute.outputs.map(\.portName), "sampleRate": audio.sampleRate,
            "reportedOutputLatencyMs": audio.outputLatency * 1000,
          ])
        self.session.perform(
          reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            ? "headphonesRemoved" : "routeChanged")
      }
      observe(AVAudioSession.interruptionNotification) { [weak self] note in
        guard let self = self, self.enabled else { return }
        let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
        if type == AVAudioSession.InterruptionType.began.rawValue {
          self.session.perform("interruptionBegan")
        } else {
          let raw =
            (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
          self.session.perform(
            "interruptionEnded",
            args: [
              "resume": AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume)
            ])
        }
      }
      observe(AVAudioSession.mediaServicesWereResetNotification) { [weak self] _ in
        if self?.enabled == true { self?.session.perform("mediaReset") }
      }
      let center = MPRemoteCommandCenter.shared()
      for (command, name) in [
        (center.playCommand, "listen"), (center.pauseCommand, "stopListening"),
        (center.stopCommand, "stopListening"),
      ] {
        let target = command.addTarget { [weak self] _ in
          guard let self = self, self.enabled else { return .commandFailed }
          self.session.perform(name)
          return .success
        }
        remoteTargets.append((command, target))
      }
    #endif
    methods.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "selectMode":
        self.enabled = args["audio"] as? Bool ?? true
        if !self.enabled { self.session.perform("deactivate") }
        self.onSelectMode?(self.enabled)
        result(nil)
      case "pickFile": self.pickFile(result)
      case "exportReport": self.export(result)
      default:
        guard self.enabled || call.method == "snapshot" else {
          result(FlutterError(code: "inactive", message: "Select audio mode first", details: nil))
          return
        }
        self.session.perform(call.method, args: args)
        result(nil)
      }
    }
    events.setStreamHandler(self)
  }
  private func publish() {
    var value = snapshot
    if let report = lastReport { value["report"] = report }
    #if os(iOS)
      value["route"] = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName).joined(
        separator: ", ")
    #endif
    sink?(value)
  }
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    session.perform("snapshot")
    return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }
  #if os(iOS)
    private func observe(_ name: Notification.Name, _ block: @escaping (Notification) -> Void) {
      observers.append(
        NotificationCenter.default.addObserver(
          forName: name, object: nil, queue: .main, using: block))
    }
    private func audioSession(_ active: Bool) {
      do {
        let audio = AVAudioSession.sharedInstance()
        if active && enabled {
          try audio.setCategory(.playback, mode: .default, options: [])
          try audio.setPreferredSampleRate(48000)
          try audio.setActive(true)
          MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Silent Disco", MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
          ]
          session.perform(
            "setRoute",
            args: [
              "outputs": audio.currentRoute.outputs.map(\.portName), "sampleRate": audio.sampleRate,
              "reportedOutputLatencyMs": audio.outputLatency * 1000,
            ])
          session.perform("audioSessionReady")
        } else {
          try audio.setActive(false, options: .notifyOthersOnDeactivation)
          if enabled && snapshot["ready"] as? Bool == true {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [
              MPMediaItemPropertyTitle: "Silent Disco", MPNowPlayingInfoPropertyIsLiveStream: true,
              MPNowPlayingInfoPropertyPlaybackRate: 0.0,
            ]
          } else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
          }
        }
      } catch {
        if active {
          session.perform("audioSessionFailed", args: ["message": error.localizedDescription])
        }
      }
    }
  #endif
  private func pickFile(_ result: @escaping FlutterResult) {
    #if os(macOS)
      guard enabled, snapshot["active"] as? Bool != true, snapshot["draining"] as? Bool != true
      else {
        result(
          FlutterError(code: "busy", message: "Stop streaming before choosing a file", details: nil)
        )
        return
      }
      let panel = NSOpenPanel()
      panel.allowedFileTypes = ["wav", "aif", "aiff", "mp3", "aac", "m4a"]
      panel.allowsMultipleSelection = false
      panel.canChooseDirectories = false
      panel.begin { [weak self] response in
        guard let self = self, response == .OK, let url = panel.url else {
          result(nil)
          return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        self.io.async {
          do {
            let source = try AudioSource(kind: .file, url: url)
            _ = try source.frame(at: 0)
            DispatchQueue.main.async {
              self.scopedURL?.stopAccessingSecurityScopedResource()
              self.scopedURL = scoped ? url : nil
              self.session.perform("setFile", args: ["path": url.path])
              result(url.lastPathComponent)
            }
          } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async {
              result(
                FlutterError(
                  code: "file",
                  message:
                    "Unsupported, protected, or unreadable audio: \(error.localizedDescription)",
                  details: nil))
            }
          }
        }
      }
    #else
      result(FlutterMethodNotImplemented)
    #endif
  }
  private static func directory() throws -> URL {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let dir = base.appendingPathComponent("SilentDiscoAudio/Reports", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }
  private static func files() throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: directory(), includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
  }
  private static func save(_ report: [String: Any]) throws {
    let url = try directory().appendingPathComponent(
      "\(Int(Date().timeIntervalSince1970*1000))-\(report["generation"] ?? "run").json")
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: url, options: .atomic)
    for file in try files().dropFirst(20) { try FileManager.default.removeItem(at: file) }
  }
  private static func load() throws -> [String: Any]? {
    guard let file = try files().first else { return nil }
    return try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
  }
  private func export(_ result: @escaping FlutterResult) {
    #if os(macOS)
      guard let report = lastReport else {
        result(FlutterError(code: "report", message: "Run an audio test first", details: nil))
        return
      }
      let panel = NSSavePanel()
      panel.allowedFileTypes = ["json"]
      panel.nameFieldStringValue = "silent-disco-audio.json"
      panel.begin { response in
        guard response == .OK, let url = panel.url else {
          result(nil)
          return
        }
        self.io.async {
          do {
            try JSONSerialization.data(
              withJSONObject: report, options: [.prettyPrinted, .sortedKeys]
            ).write(to: url, options: .atomic)
            DispatchQueue.main.async { result(url.path) }
          } catch {
            DispatchQueue.main.async {
              result(
                FlutterError(code: "export", message: error.localizedDescription, details: nil))
            }
          }
        }
      }
    #else
      result(FlutterError(code: "host", message: "Export the report from the Mac", details: nil))
    #endif
  }
  deinit {
    session.perform("deactivate")
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
      #if os(macOS)
        NSWorkspace.shared.notificationCenter.removeObserver(observer)
      #endif
    }
    #if os(macOS)
      if let activity = activity { ProcessInfo.processInfo.endActivity(activity) }
      scopedURL?.stopAccessingSecurityScopedResource()
    #else
      for (command, target) in remoteTargets { command.removeTarget(target) }
    #endif
  }
}
