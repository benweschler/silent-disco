import Foundation
import Network

private final class AudioPeer {
  let id = UUID().uuidString
  let tcp: NWConnection
  var udp: NWConnection?
  var token = Data()
  var framer = AudioFramer()
  var name = "Listener"
  var hello = false
  var ready = false
  var wants = false
  var lastHeard: Double
  let created: Double
  var pendingTCP = 0
  var pendingUDP = 0
  var submitted = 0
  var sendErrors = 0
  var dropped = 0
  var stats = [String: Any]()
  var final = false
  var diagnosticHistory = ReceivedAudioDiagnostics()
  init(_ tcp: NWConnection, now: Double = AudioWire.now()) {
    self.tcp = tcp
    self.lastHeard = now
    self.created = now
    var uuid = UUID().uuid
    token = withUnsafeBytes(of: &uuid) { Data($0) }
  }
  var row: [String: Any] {
    [
      "id": id, "name": name, "ready": ready, "listening": wants, "submitted": submitted,
      "sendErrors": sendErrors, "queueDrops": dropped, "stats": stats, "finalCounters": final,
      "networkMissing": final
        ? max(0, submitted - (stats["received"] as? Int ?? 0)) as Any : NSNull(),
    ]
  }
}

private final class AudioTransmitter {
  let queue = DispatchQueue(label: "dev.silentdisco.audio.encode", qos: .userInitiated)
  var timer: DispatchSourceTimer?
  var onStart: ((Double, Int) -> Void)?
  var onFrame: ((UInt64, Double, Data, Int, @escaping () -> Void) -> Void)?
  private let deliverySlots = DispatchSemaphore(value: 2)
  var onEnd: ((String) -> Void)?
  var onDiagnostics: (([String: Any]) -> Void)?
  private var diagnostics = SenderDiagnostics()
  private var lastDiagnostics = 0.0
  func start(kind: AudioSource.Kind, url: URL?, lead: Double) {
    queue.async {
      do {
        self.timer?.cancel()
        self.diagnostics = SenderDiagnostics()
        self.lastDiagnostics = 0
        let source = try AudioSource(kind: kind, url: url)
        let codec = try AudioCodec()
        let start = AudioWire.now() + 0.15
        let anchor = start + lead
        var pacer = AudioPacer()
        var mailboxDrops = 0
        self.onStart?(anchor, codec.lookahead)
        let t = DispatchSource.makeTimerSource(queue: self.queue)
        t.schedule(deadline: .now() + 0.15, repeating: .milliseconds(20), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in
          guard let self = self else { return }
          let elapsed = AudioWire.now() - start
          guard elapsed < AudioWire.maxDuration else {
            self.timer?.cancel()
            self.timer = nil
            self.onDiagnostics?(self.diagnostics.json)
            self.onEnd?("completed")
            return
          }
          guard let slot = pacer.take(elapsed: elapsed) else { return }
          do {
            let sourceStart = AudioWire.now()
            let samples = try source.frame(at: slot * 960)
            let encodeStart = AudioWire.now()
            self.diagnostics.record("source", seconds: encodeStart - sourceStart)
            let payload = try codec.encode(samples)
            let encodedAt = AudioWire.now()
            self.diagnostics.record("encoding", seconds: encodedAt - encodeStart)
            self.diagnostics.record("handoffLateness", seconds: encodedAt - start - Double(slot) * 0.020)
            if encodedAt - self.lastDiagnostics >= 1 {
              self.lastDiagnostics = encodedAt
              self.onDiagnostics?(self.diagnostics.json)
            }
            if self.deliverySlots.wait(timeout: .now()) == .success {
              let slots = self.deliverySlots
              if let callback = self.onFrame {
                callback(
                  slot, anchor + Double(slot) * 0.020 - Double(codec.lookahead) / 48000, payload,
                  pacer.skipped + mailboxDrops, { slots.signal() })
              } else {
                slots.signal()
              }
            } else {
              mailboxDrops += 1
            }

          } catch {
            self.timer?.cancel()
            self.timer = nil
            self.onDiagnostics?(self.diagnostics.json)
            self.onEnd?(error.localizedDescription)
          }
        }
        self.timer = t
        t.resume()
      } catch { self.onEnd?(error.localizedDescription) }
    }
  }
  func stop() {
    queue.async {
      self.timer?.cancel()
      self.timer = nil
      self.onDiagnostics?(self.diagnostics.json)
    }
  }
  deinit { timer?.cancel() }
}

/// All session state is confined to queue. Public commands are asynchronous.
public final class AudioSession {
  public let isHost: Bool
  private let queue = DispatchQueue(label: "dev.silentdisco.audio.transport", qos: .userInitiated)
  public var onDiagnosticStreamStart: (() -> Void)?
  public var onSnapshot: (([String: Any]) -> Void)?
  public var onReport: (([String: Any]) -> Void)?
  public var onActivity: ((Bool) -> Void)?
  public var onListening: ((Bool) -> Void)?  // platform audio-session activation belongs to bridge
  private var listener: NWListener?
  private var udpListener: NWListener?
  private var browser: NWBrowser?
  private var services = [String: NWEndpoint]()
  private var peers = [String: AudioPeer]()
  private var candidates = [ObjectIdentifier: (NWConnection, Double)]()
  private var client: AudioPeer?
  private var ticker: DispatchSourceTimer?
  private var transmitter: AudioTransmitter?
  private let renderer = AudioRenderer()
  private var rendererRunning = false
  private var selected: NWEndpoint?
  private var selectedService: (String, String, String)?
  private var reconnect = true
  private var retryAt = 0.0
  private var retryIndex = 0
  private var active = false
  private var draining = false
  private var wants = false
  private var stream: UInt64 = 0
  private var anchor = 0.0
  private var started = 0.0
  private var startedDate = ""
  private var lead = 0.5
  private var lookahead = 312
  private var source: AudioSource.Kind = .clicks
  private var fileURL: URL?
  private var sourceName = "Click track (120 BPM)"
  private var notes = ""
  private var offline = false
  private var skipped = 0
  private var audibleReports = 0
  private var lastSequence: UInt64?
  private var clock = ClockEstimate()
  private var pendingClocks = [String: Double]()
  private var lastClock = 0.0
  private var lastPeriodic = 0.0
  private var lastRegister = 0.0
  private var lastStats = [String: Any]()
  private var diagnostics = AudioDiagnostics()
  private var transportOmissions = 0
  private var transportTimer = TransportTimerDiagnostics()
  private var buildInfo: [String: Any] = {
    #if DEBUG
      let configuration = "Debug"
    #else
      let configuration = "Release"
    #endif
    return ["configuration": configuration,
      "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
      "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
      "os": ProcessInfo.processInfo.operatingSystemVersionString]
  }()
  private var senderWork = [String: Any]()
  private var senderDelivery = SenderDiagnostics()
  private var appState = "unknown"
  private var protectedDataAvailable: Bool?
  private var testMarkers = [[String: Any]]()
  private var testMarkerOverflow = 0
  private var routeInfo = [String: Any]()
  private var lastClockGood = 0.0
  private var endedAt = 0.0
  private var gaps = GapStats()
  private var seen = Set<UInt64>()
  private var received = 0
  private var duplicates = 0
  private var events = [[String: Any]]()
  private var endedPeers = [[String: Any]]()
  private var latestReport: [String: Any]?
  private var status = "idle"
  private var errorText = ""
  private var renderAllowed = true
  private var clientStop: DispatchWorkItem?
  private let startListener: (NWListener, DispatchQueue) -> Void
  private let startConnection: (NWConnection, DispatchQueue) -> Void
  private let browsingEnabled: Bool
  private let now: () -> Double
  private let runPeriodicTicks: Bool
  public convenience init(isHost: Bool) {
    self.init(isHost: isHost, startListener: { $0.start(queue: $1) })
  }
  // Injectable transport startup and time support deterministic lifecycle tests without sockets.
  init(isHost: Bool, startListener: @escaping (NWListener, DispatchQueue) -> Void,
    startConnection: @escaping (NWConnection, DispatchQueue) -> Void = { $0.start(queue: $1) },
    browsingEnabled: Bool = true,
    now: @escaping () -> Double = { AudioWire.now() }, runPeriodicTicks: Bool = true) {
    self.startListener = startListener
    self.startConnection = startConnection
    self.browsingEnabled = browsingEnabled
    self.now = now
    self.runPeriodicTicks = runPeriodicTicks
    self.isHost = isHost
    #if os(iOS)
      renderAllowed = false
    #endif
    renderer.onStats = { [weak self] stats in
      self?.queue.async { [weak self] in
        guard let self = self, stats["generation"] as? String == String(self.stream) else { return }
        self.lastStats = stats
      }
    }
    renderer.onDiagnostic = { [weak self] generation, at, utc, fields in
      self?.queue.async { [weak self] in
        guard let self = self, self.stream == generation else { return }
        // Use the renderer's captured offset, not a newer session estimate.
        let offset = (fields["clockOffsetMs"] as? Double ?? self.clock.offset * 1000) / 1000
        var fields = fields
        fields["appState"] = self.appState
        fields["route"] = self.routeInfo
        let kind = fields["diagnosticKind"] as? String
          ?? (fields["reason"] as? String == "Renderer stopped or restarted"
            ? "rendererStopped" : "playbackReset")
        self.diagnostics.record(kind, at: at, utc: utc, offset: offset,
          origin: self.anchor, fields: fields)
      }
    }
    renderer.onEvent = { [weak self] message in
      self?.queue.async { [weak self] in self?.log(message) }
    }
    renderer.onError = { [weak self] message in
      self?.queue.async { [weak self] in
        guard let self = self else { return }
        self.errorText = message
        self.wants = false
        self.stopRenderer()
        if let p = self.client { self.send(["type": "listen", "enabled": false], to: p) }
        self.log(message)
        self.publish()
      }
    }
  }
  public func perform(_ command: String, args: [String: Any] = [:]) {
    var capturedArgs = args
    if command == "markTestTransition" {
      capturedArgs["monotonicSeconds"] = AudioWire.now()
      capturedArgs["at"] = ISO8601DateFormatter().string(from: Date())
    }
    let args = capturedArgs
    queue.async { [weak self] in
      guard let self = self else { return }
      do { try self.command(command, args) } catch {
        self.errorText = error.localizedDescription
        self.log(self.errorText)
      }
      self.publish()
    }
  }
  private func parameters(_ tcp: Bool) -> NWParameters {
    let p = tcp ? NWParameters.tcp : NWParameters.udp
    p.includePeerToPeer = false
    return p
  }
  private func command(_ command: String, _ args: [String: Any]) throws {
    switch command {
    case "snapshot": break
    case "diagnosticLifecycle":
      if let state = args["appState"] as? String { appState = state }
      if let value = args["protectedDataAvailable"] as? Bool { protectedDataAvailable = value }
      if active {
        recordDiagnostic(args["kind"] as? String ?? "lifecycle", args: args)
      }
    case "markTestTransition":
      guard isHost, active, let marker = args["marker"] as? String,
        let at = args["monotonicSeconds"] as? Double,
        let utc = args["at"] as? String,
        let event = AudioTestMarker.event(marker, at: at, utc: utc, origin: anchor) else { return }
      testMarkers.append(event)
      if testMarkers.count > 256 { testMarkers.removeFirst(); testMarkerOverflow += 1 }
      log("User-reported transition: \(event["message"] as? String ?? marker)")
    case "setRoute": routeInfo = args
    case "markAudibleInterruption":
      guard active else { return }
      if isHost {
        audibleReports += 1
        log("User reported an audible interruption (not an engine measurement)")
      } else if let p = client {
        send(["type": "audibleIssue"], to: p)
        log("Audible interruption marked by listener")
      }
    case "startHost":
      if isHost {
        do { try startHost() } catch {
          hostFailed("Audio host failed to start: \(error.localizedDescription)")
        }
      }
    case "stopHost", "sleep": shutdown(reason: command == "sleep" ? "Mac sleeping" : "Host stopped")
    case "browse":
      reconnect = true
      browse()
      ensureTicker()
    case "connect":
      reconnect = false
      disconnectClient("Changing hub")
      reconnect = true
      retryIndex = 0
      selectedService = nil
      if let id = args["id"] as? String, let endpoint = services[id] {
        selected = endpoint
        if case .service(let name, let type, let domain, _) = endpoint {
          selectedService = (name, type, domain)
        }
      } else {
        guard let host = args["host"] as? String,
          IPv4Address(host) != nil || IPv6Address(host) != nil,
          let port = args["port"] as? Int, port > 0, port <= 65535
        else { throw AudioFailure("Enter a numeric IP address and port") }
        selected = .hostPort(
          host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!)
      }
      connect()
      ensureTicker()
    case "disconnect":
      reconnect = false
      wants = false
      disconnectClient("Disconnected")
      browser?.cancel()
      browser = nil
    case "setSource":
      guard isHost, !active, !draining, let value = args["source"] as? String,
        let kind = AudioSource.Kind(rawValue: value), kind != .file
      else { throw AudioFailure("Stop streaming before changing source") }
      source = kind
      fileURL = nil
      sourceName = kind == .clicks ? "Click track (120 BPM)" : "440 Hz test tone"
    case "setFile":
      guard isHost, !active, !draining, let path = args["path"] as? String else {
        throw AudioFailure("Stop streaming before selecting a file")
      }
      // The picker validates the file off the transport queue before handing it here.
      fileURL = URL(fileURLWithPath: path)
      source = .file
      sourceName = fileURL!.lastPathComponent
    case "setBuffer":
      guard isHost, !active, !draining, let ms = args["milliseconds"] as? Int,
        [500, 750, 1000].contains(ms)
      else { throw AudioFailure("Choose 500, 750 or 1000 ms before starting") }
      lead = Double(ms) / 1000
    case "startStream":
      guard isHost, listener != nil, !active, !draining else {
        throw AudioFailure("Start the host and stop any current run first")
      }
      notes = String((args["notes"] as? String ?? "").prefix(2000))
      offline = args["offlineConfirmed"] as? Bool ?? false
      startStream()
    case "stopStream": if isHost { finish("stopped by user") }
    case "listen":
      guard !isHost else { return }
      wants = true
      errorText = ""
      onListening?(true)
      if let p = client { send(["type": "listen", "enabled": true], to: p) }
      maybeRender()
    case "stopListening":
      wants = false
      stopRenderer()
      if let p = client { send(["type": "listen", "enabled": false], to: p) }
    case "audioSessionReady":
      renderAllowed = true
      maybeRender()
    case "audioSessionFailed":
      wants = false
      renderAllowed = false
      errorText = args["message"] as? String ?? "Audio session failed"
      stopRenderer()
      if let p = client { send(["type": "listen", "enabled": false], to: p) }
    case "routeChanged":
      log("Audio output route changed")
      stopRenderer(deactivate: false)
      maybeRender()
    case "headphonesRemoved":
      log("Headphones disconnected; tap Listen to resume")
      wants = false
      stopRenderer()
      if let p = client { send(["type": "listen", "enabled": false], to: p) }
    case "interruptionBegan":
      renderAllowed = false
      stopRenderer(deactivate: false)
      log("Audio interruption")
    case "interruptionEnded":
      #if os(iOS)
        renderAllowed = false
      #else
        renderAllowed = true
      #endif
      if args["resume"] as? Bool != true { wants = false }
      if wants {
        onListening?(true)
        maybeRender()
      } else {
        stopRenderer()
      }
    case "mediaReset":
      #if os(iOS)
        renderAllowed = false
      #endif
      stopRenderer(deactivate: false)
      if wants { onListening?(true) }
      maybeRender()
    case "foreground":
      if !isHost {
        // Suspension can leave an apparently connected socket whose peer already timed out.
        if reconnect, let client = client, now() - client.lastHeard > 5 {
          disconnectClient("Connection stale after background suspension")
        }
        browse()
        if client == nil && reconnect {
          retryAt = 0
          if wants { onListening?(true) }
          connect()
        }
      }
    case "deactivate":
      shutdown(reason: "Switched mode")
      reconnect = false
      wants = false
      disconnectClient("Switched mode")
      browser?.cancel()
      browser = nil
      ticker?.cancel()
      ticker = nil
    default: throw AudioFailure("Unknown audio command")
    }
  }
  private func startHost(advertise: Bool = true) throws {
    guard listener == nil else { return }
    if advertise { errorText = "" }
    status = "starting"
    let u = try NWListener(using: parameters(false), on: .any)
    let t = try NWListener(using: parameters(true), on: .any)
    udpListener = u
    listener = t
    u.newConnectionHandler = { [weak self] c in self?.acceptUDP(c) }
    u.stateUpdateHandler = { [weak self, weak u] state in
      guard let self = self, self.udpListener === u else { return }
      if case .failed(let e) = state { self.hostFailed("UDP listener failed: \(e)") }
    }
    if advertise {
      t.service = NWListener.Service(
        name: "Silent Disco Audio", type: AudioWire.service,
        txtRecord: NWTXTRecord(["version": "1"]))
    }
    t.newConnectionHandler = { [weak self] c in
      guard let self = self else {
        c.cancel()
        return
      }
      guard self.peers.count < 10 else {
        c.cancel()
        self.log("Listener limit reached")
        return
      }
      let p = AudioPeer(c)
      self.peers[p.id] = p
      self.attach(p)
    }
    t.stateUpdateHandler = { [weak self, weak t] state in
      guard let self = self, self.listener === t else { return }
      if case .ready = state {
        self.status = "hosting"
        self.publish()
      }
      if case .failed(let e) = state {
        if advertise, case .dns = e {
          // Bonjour failure also kills its TCP listener. Recreate the transport once,
          // without advertising, so manual-address connections remain available.
          self.hostFailed(
            "Bonjour discovery unavailable: \(e). Retrying without discovery. Connect from iPhone using the Mac's LAN address and displayed TCP port. Check Local Network permission; if already enabled, quit and reopen the Mac app."
          )
          do { try self.startHost(advertise: false) } catch {
            self.hostFailed("Audio host retry failed: \(error.localizedDescription)")
          }
        } else {
          self.hostFailed("TCP listener failed: \(e)")
        }
      }
      if case .waiting(let e) = state {
        self.errorText = "Audio host waiting: \(e)"
        self.publish()
      }
    }
    startListener(u, queue)
    startListener(t, queue)
    ensureTicker()
  }
  private func hostFailed(_ message: String) {
    errorText = message
    log(message)
    NSLog("Silent Disco Audio: %@", message)
    shutdown(reason: message)
    publish()
  }
  private func browse() {
    guard !isHost, browsingEnabled else { return }
    browser?.cancel()
    let b = NWBrowser(for: .bonjour(type: AudioWire.service, domain: nil), using: parameters(true))
    browser = b
    b.browseResultsChangedHandler = { [weak self, weak b] results, _ in
      guard let self = self, self.browser === b else { return }
      self.services = Dictionary(
        uniqueKeysWithValues: results.map { ($0.endpoint.debugDescription, $0.endpoint) })
      if let saved = self.selectedService,
        let endpoint = self.services.values.first(where: {
          if case .service(let n, let t, let d, _) = ($0) {
            return n == saved.0 && t == saved.1 && d == saved.2
          }
          return false
        })
      {
        self.selected = endpoint
      }
      self.publish()
    }
    b.stateUpdateHandler = { [weak self] state in
      if case .failed(let e) = state {
        self?.errorText = "Discovery failed: \(e). Check Local Network permission."
        self?.publish()
      }
    }
    b.start(queue: queue)
  }
  private func connect() {
    guard !isHost, client == nil, let endpoint = selected else { return }
    status = "connecting"
    let p = AudioPeer(NWConnection(to: endpoint, using: parameters(true)), now: now())
    client = p
    attach(p)
  }
  private func valid(_ p: AudioPeer) -> Bool { isHost ? peers[p.id] === p : client === p }
  private func attach(_ p: AudioPeer) {
    p.tcp.stateUpdateHandler = { [weak self, weak p] state in
      guard let self = self, let p = p, self.valid(p) else { return }
      switch state {
      case .ready:
        if !self.isHost {
          self.send(
            ["type": "hello", "version": 1, "name": ProcessInfo.processInfo.hostName], to: p)
        }
        self.receiveTCP(p)
      case .failed(let e): self.drop(p, "Connection failed: \(e)")
      case .waiting(let e): self.errorText = "Connection waiting: \(e)"
      default: break
      }
    }
    startConnection(p.tcp, queue)
  }
  private func receiveTCP(_ p: AudioPeer) {
    p.tcp.receive(minimumIncompleteLength: 1, maximumLength: 16384) {
      [weak self, weak p] data, _, done, error in
      guard let self = self, let p = p, self.valid(p) else { return }
      do {
        if let data = data {
          for m in try p.framer.append(data) {
            p.lastHeard = AudioWire.now()
            try self.handle(m, p)
            if !self.valid(p) { return }
          }
        }
      } catch {
        self.drop(p, "Invalid control: \(error.localizedDescription)")
        return
      }
      if done || error != nil {
        self.drop(p, "Control connection closed")
      } else {
        self.receiveTCP(p)
      }
    }
  }
  private func recordDiagnostic(_ kind: String, args: [String: Any] = [:]) {
    var fields = args
    fields["appState"] = appState
    fields["protectedDataAvailable"] = protectedDataAvailable as Any? ?? NSNull()
    fields["route"] = routeInfo
    diagnostics.record(kind, at: args["monotonicSeconds"] as? Double ?? AudioWire.now(),
      utc: args["at"] as? String ?? ISO8601DateFormatter().string(from: Date()),
      offset: clock.offset, origin: anchor, fields: fields)
  }
  private func send(_ object: [String: Any], to p: AudioPeer) {
    let object = DiagnosticControlFrame.prepare(object, omissions: &transportOmissions)
    guard valid(p), p.pendingTCP < 8,
      var data = try? JSONSerialization.data(withJSONObject: object), data.count <= 16384
    else {
      if valid(p) { drop(p, "Control queue overflow") }
      return
    }
    data.append(10)
    p.pendingTCP += 1
    p.tcp.send(
      content: data,
      completion: .contentProcessed { [weak self, weak p] error in
        guard let self = self, let p = p, self.valid(p) else { return }
        p.pendingTCP = max(0, p.pendingTCP - 1)
        if error != nil { self.drop(p, "Control send failed") }
      })
  }
  private func handle(_ m: [String: Any], _ p: AudioPeer) throws {
    guard let type = m["type"] as? String else { return }
    switch type {
    case "hello" where isHost:
      guard !p.hello, m["version"] as? Int == 1, let port = udpListener?.port else {
        throw AudioFailure("Unsupported audio protocol")
      }
      p.hello = true
      p.name = String((m["name"] as? String ?? "Listener").prefix(80))
      send(
        [
          "type": "welcome", "version": 1, "token": p.token.base64EncodedString(),
          "udpPort": Int(port.rawValue),
        ], to: p)
    case "welcome" where !isHost:
      guard !p.hello, m["version"] as? Int == 1, let raw = m["token"] as? String,
        let token = Data(base64Encoded: raw), token.count == 16,
        let port = m["udpPort"] as? Int, port > 0, port <= 65535,
        let remote = p.tcp.currentPath?.remoteEndpoint, case .hostPort(let host, _) = remote
      else { throw AudioFailure("Invalid audio handshake") }
      p.hello = true
      p.token = token
      clock = ClockEstimate()
      pendingClocks.removeAll()
      lastClock = 0
      let c = NWConnection(
        host: host, port: NWEndpoint.Port(rawValue: UInt16(port))!, using: parameters(false))
      p.udp = c
      c.stateUpdateHandler = { [weak self, weak p] state in
        guard let self = self, let p = p, self.valid(p) else { return }
        if case .ready = state {
          self.register(p)
          self.receiveUDP(c, peer: p)
        }
        if case .failed(let e) = state { self.drop(p, "UDP failed: \(e)") }
      }
      c.start(queue: queue)
    case "ready" where isHost:
      guard p.hello, p.udp != nil else { throw AudioFailure("UDP not registered") }
      p.ready = true
      if active && anchor > 0 { send(configuration(), to: p) }
    case "listen" where isHost:
      p.wants = m["enabled"] as? Bool ?? false
      if active && anchor > 0 && p.ready { send(configuration(), to: p) }
    case "clock" where isHost:
      guard p.hello, let id = m["id"] as? String, let t1 = m["t1"] as? Double, t1.isFinite else {
        return
      }
      let t2 = AudioWire.now()
      send(["type": "clockReply", "id": id, "t1": t1, "t2": t2, "t3": AudioWire.now()], to: p)
    case "clockReply" where !isHost:
      guard let id = m["id"] as? String, let t1 = pendingClocks.removeValue(forKey: id),
        let t2 = m["t2"] as? Double, let t3 = m["t3"] as? Double
      else { return }
      if clock.add(t1: t1, t2: t2, t3: t3, t4: AudioWire.now()) { lastClockGood = AudioWire.now() }
      renderer.clock(clock.offset)
      maybeRender()
    case "stream" where !isHost:
      guard p.ready, let raw = m["generation"] as? String, let generation = UInt64(raw),
        generation > 0,
        let a = m["anchor"] as? Double, a.isFinite, let l = m["lead"] as? Double,
        [0.5, 0.75, 1.0].contains(l),
        let pre = m["lookahead"] as? Int, pre >= 0, pre < 960,
        m["rate"] as? Int == 48000, m["frames"] as? Int == 960
      else { throw AudioFailure("Invalid stream configuration") }
      if stream != generation {
        clientStop?.cancel()
        clientStop = nil
        stopRenderer(deactivate: false)
        stream = generation
        seen.removeAll()
        received = 0
        duplicates = 0
        gaps = GapStats()
        lastStats = [:]
        diagnostics.begin(generation)
        transportOmissions = 0
        transportTimer = TransportTimerDiagnostics()
      }
      let newDiagnosticRun = diagnostics.events.isEmpty
      anchor = a
      if newDiagnosticRun {
        recordDiagnostic("streamStarted")
        onDiagnosticStreamStart?()
      }
      lead = l
      lookahead = pre
      active = true
      sourceName = m["source"] as? String ?? "Audio"
      if wants { onListening?(true) }
      maybeRender()
    case "stop" where !isHost:
      guard m["generation"] as? String == String(stream) else { return }
      let old = stream
      let finalSequence = (m["lastSequence"] as? String).flatMap(UInt64.init)
      guard finalSequence == nil || finalSequence! < 30000 else {
        throw AudioFailure("Invalid final sequence")
      }
      renderer.finish(after: finalSequence)
      let work = DispatchWorkItem { [weak self, weak p] in
        guard let self = self, let p = p, self.stream == old else { return }
        self.active = false
        self.rendererRunning = false
        #if os(iOS)
          self.renderAllowed = false
        #endif
        self.renderer.stop { [weak self, weak p] in
          self?.queue.async { [weak self, weak p] in
            guard let self = self, let p = p, self.stream == old else { return }
            self.onListening?(false)
            self.send(
              [
                "type": "stats", "generation": String(old), "stats": self.clientStats(),
                "final": true,
              ], to: p)
            self.publish()
          }
        }
      }
      clientStop = work
      queue.asyncAfter(deadline: .now() + lead + 0.15, execute: work)
    case "audibleIssue" where isHost:
      if active {
        audibleReports += 1
        log("\(p.name) reported an audible interruption (not an engine measurement)")
      }
    case "stats" where isHost:
      guard m["generation"] as? String == String(stream), var stats = m["stats"] as? [String: Any]
      else { return }
      if let evidence = stats["diagnostics"] as? [String: Any] {
        p.diagnosticHistory.merge(evidence["events"] as? [[String: Any]] ?? [], generation: stream)
        stats["diagnostics"] = p.diagnosticHistory.json(evidence)
      }
      p.stats = stats
      p.final = m["final"] as? Bool ?? false
    case "heartbeat": break
    default: break
    }
  }
  private func configuration() -> [String: Any] {
    [
      "type": "stream", "generation": String(stream), "anchor": anchor, "lead": lead,
      "lookahead": lookahead,
      "rate": 48000, "frames": 960, "channels": 2, "codec": "opus", "source": sourceName,
    ]
  }
  private func register(_ p: AudioPeer) {
    guard let c = p.udp else { return }
    lastRegister = AudioWire.now()
    c.send(
      content: AudioPacket(kind: 0, token: p.token).encode(), completion: .contentProcessed { _ in }
    )
  }
  private func acceptUDP(_ c: NWConnection) {
    guard candidates.count < 20 else {
      c.cancel()
      return
    }
    candidates[ObjectIdentifier(c)] = (c, AudioWire.now())
    c.start(queue: queue)
    receiveUDP(c, peer: nil)
  }
  private func receiveUDP(_ c: NWConnection, peer: AudioPeer?) {
    c.receiveMessage { [weak self, weak c, weak peer] data, _, _, error in
      guard let self = self, let c = c else { return }
      guard
        self.isHost
          ? self.candidates[ObjectIdentifier(c)] != nil
            || self.peers.values.contains(where: { $0.udp === c })
          : peer != nil && self.client === peer && peer?.udp === c
      else { return }
      if error != nil {
        if let peer = peer {
          self.drop(peer, "UDP receive failed")
        } else {
          c.cancel()
          self.candidates.removeValue(forKey: ObjectIdentifier(c))
        }
        return
      }
      if let data = data, let packet = AudioPacket(data) {
        if self.isHost, packet.kind == 0,
          let p = self.peers.values.first(where: { $0.hello && $0.token == packet.token }),
          case .hostPort(let udpHost, _) = c.endpoint,
          let endpoint = p.tcp.currentPath?.remoteEndpoint,
          case .hostPort(let tcpHost, _) = endpoint, udpHost == tcpHost
        {
          if p.udp !== c {
            p.udp?.cancel()
            p.udp = c
          }
          self.candidates.removeValue(forKey: ObjectIdentifier(c))
          c.send(
            content: AudioPacket(kind: 1, token: p.token).encode(),
            completion: .contentProcessed { _ in })
        } else if !self.isHost, let p = peer, packet.token == p.token {
          if packet.kind == 1 && !p.ready {
            p.ready = true
            self.status = "connected"
            self.retryIndex = 0
            self.send(["type": "ready"], to: p)
            self.send(["type": "listen", "enabled": self.wants], to: p)
          } else if packet.kind == 2, self.active, packet.generation == self.stream {
            let expected =
              self.anchor + Double(packet.sequence) * 0.020 - Double(self.lookahead) / 48000
            if abs(packet.presentation - expected) < 0.00001 {
              if self.seen.insert(packet.sequence).inserted {
                self.received += 1
                self.gaps.arrival(AudioWire.now())
                if self.gaps.lastGap > 0.1 {
                  self.recordDiagnostic("receiveGap", args: ["gapMs": self.gaps.lastGap * 1000])
                  self.log("Receive gap: \(Int(self.gaps.lastGap*1000)) ms")
                }
                if self.rendererRunning { self.renderer.receive(packet) }
              } else {
                self.duplicates += 1
              }
            }
          }
        }
      }
      self.receiveUDP(c, peer: peer)
    }
  }
  private func startStream() {
    active = true
    draining = false
    endedAt = 0
    anchor = 0
    stream = UInt64.random(in: 1...UInt64.max)
    started = AudioWire.now()
    startedDate = ISO8601DateFormatter().string(from: Date())
    skipped = 0
    transportTimer = TransportTimerDiagnostics()
    senderWork = [:]
    senderDelivery = SenderDiagnostics()
    audibleReports = 0
    testMarkers = []
    testMarkerOverflow = 0
    lastSequence = nil
    endedPeers = []
    events = []
    errorText = ""
    for p in peers.values {
      p.submitted = 0
      p.dropped = 0
      p.sendErrors = 0
      p.stats = [:]
      p.diagnosticHistory = ReceivedAudioDiagnostics()
      p.final = false
    }
    let generation = stream
    let tx = AudioTransmitter()
    transmitter = tx
    tx.onStart = { [weak self] a, pre in
      self?.queue.async { [weak self] in
        guard let self = self, self.active, self.stream == generation else { return }
        self.anchor = a
        self.lookahead = pre
        for p in Array(self.peers.values) where p.ready { self.send(self.configuration(), to: p) }
        self.publish()
      }
    }
    tx.onDiagnostics = { [weak self] value in
      self?.queue.async { [weak self] in
        guard let self = self, self.stream == generation else { return }
        self.senderWork = value
      }
    }
    tx.onFrame = { [weak self] sequence, presentation, payload, skipped, complete in
      guard let self = self else {
        complete()
        return
      }
      self.queue.async { [weak self] in
        defer { complete() }
        guard let self = self, self.active, self.stream == generation else { return }
        self.skipped = skipped
        self.lastSequence = sequence
        self.senderDelivery.record("sendSlotLateness", seconds: AudioWire.now()
          - (presentation + Double(self.lookahead) / 48000 - self.lead))
        for p in Array(self.peers.values) where p.ready && p.wants {
          guard let c = p.udp, p.pendingUDP < 4, presentation > AudioWire.now() else {
            p.dropped += 1
            continue
          }
          let data = AudioPacket(
            token: p.token, generation: generation, sequence: sequence, sample: sequence * 960,
            presentation: presentation, payload: payload
          ).encode()
          p.pendingUDP += 1
          c.send(
            content: data,
            completion: .contentProcessed { [weak p] error in
              guard let p = p else { return }
              p.pendingUDP = max(0, p.pendingUDP - 1)
              if error == nil { p.submitted += 1 } else { p.sendErrors += 1 }
            })
        }
      }
    }
    tx.onEnd = { [weak self] reason in
      self?.queue.async { [weak self] in
        guard self?.stream == generation else { return }
        self?.finish(reason)
      }
    }
    tx.start(kind: source, url: fileURL, lead: lead)
    onActivity?(true)
    log("Audio run started")
  }
  private func finish(_ reason: String) {
    guard isHost, active else { return }
    active = false
    draining = true
    endedAt = AudioWire.now()
    transmitter?.stop()
    transmitter = nil
    let generation = stream
    for p in Array(peers.values) {
      send(
        [
          "type": "stop", "generation": String(generation),
          "lastSequence": lastSequence.map(String.init) ?? "",
        ], to: p)
    }
    queue.asyncAfter(deadline: .now() + lead + 1.0) { [weak self] in
      guard let self = self, self.stream == generation, self.draining else { return }
      self.makeReport(reason)
      self.draining = false
      self.onActivity?(false)
      self.publish()
    }
  }
  private func makeReport(_ reason: String) {
    let rows = endedPeers + peers.values.map(\.row)
    let completed = reason == "completed" || reason == "stopped by user"
    let allFinal = !rows.isEmpty && rows.allSatisfy { $0["finalCounters"] as? Bool == true }
    var review = !allFinal || skipped > 0 || audibleReports > 0
    for row in rows {
      let s = row["stats"] as? [String: Any] ?? [:]
      for key in ["underruns", "rebufferEvents", "latePackets", "missingAtDeadline"] {
        if (s[key] as? Int ?? 0) > 0 { review = true }
      }
      if !(s["renderError"] as? String ?? "").isEmpty { review = true }
      if (row["networkMissing"] as? Int ?? 0) > 0 || (s["received"] as? Int ?? 0) == 0 {
        review = true
      }
      if (row["sendErrors"] as? Int ?? 0) > 0 || (row["queueDrops"] as? Int ?? 0) > 0 {
        review = true
      }
    }
    let report: [String: Any] = [
      "schemaVersion": 2, "protocolVersion": 1, "generation": String(stream),
      "status": completed ? "completed" : "interrupted",
      "assessment": review ? "needs review" : "run completed",
      "acousticSynchronization": "unverified", "reason": reason,
      "startedAt": startedDate, "endedAt": ISO8601DateFormatter().string(from: Date()),
      "elapsedSeconds": min(600, max(0, (endedAt > 0 ? endedAt : AudioWire.now()) - started)),
      "source": sourceName, "leadMs": lead * 1000,
      "codec": "Opus 1.6.1 / 160 kbps CVBR / stereo 48 kHz / 20 ms",
      "lookaheadSamples": lookahead, "skippedSendSlots": skipped,
      "senderDiagnostics": ["work": senderWork, "delivery": senderDelivery.json],
      "transportTimerDiagnostics": transportTimer.json,
      "userReportedAudibleInterruptions": audibleReports, "listeners": rows,
      "completeCounters": allFinal,
      "notes": notes, "offlineSetupUserConfirmed": offline, "events": events,
      "testMarkers": testMarkers, "testMarkerRetentionOverflow": testMarkerOverflow,
      "os": ProcessInfo.processInfo.operatingSystemVersionString,
    ]
    latestReport = report
    onReport?(report)
  }
  private func shutdown(reason: String) {
    if isHost && (active || draining) {
      transmitter?.stop()
      transmitter = nil
      active = false
      draining = false
      makeReport(reason)
    }
    for p in Array(peers.values) {
      p.tcp.cancel()
      p.udp?.cancel()
    }
    peers.removeAll()
    for (c, _) in candidates.values { c.cancel() }
    candidates.removeAll()
    listener?.cancel()
    listener = nil
    udpListener?.cancel()
    udpListener = nil
    onActivity?(false)
    status = "idle"
  }
  private func drop(_ p: AudioPeer, _ reason: String) {
    guard valid(p) else { return }
    if isHost {
      if active || draining {
        var row = p.row
        row["disconnectReason"] = reason
        endedPeers.append(row)
        if endedPeers.count > 100 { endedPeers.removeFirst() }
      }
      peers.removeValue(forKey: p.id)
      p.tcp.cancel()
      p.udp?.cancel()
      log("\(p.name): \(reason)")
    } else {
      disconnectClient(reason)
    }
  }
  private func disconnectClient(_ reason: String) {
    client?.tcp.cancel()
    client?.udp?.cancel()
    client = nil
    active = false
    stream = 0
    stopRenderer()
    clock = ClockEstimate()
    pendingClocks.removeAll()
    status = "disconnected"
    log(reason)
    if reconnect && selected != nil {
      retryAt = AudioWire.now() + [1.0, 2, 4, 5][min(retryIndex, 3)]
      retryIndex += 1
      status = "reconnecting"
      browse()
    }
  }
  private func stopRenderer(deactivate: Bool = true) {
    rendererRunning = false
    if deactivate {
      #if os(iOS)
        renderAllowed = false
      #endif
    }
    renderer.stop { [weak self] in
      guard deactivate else { return }
      self?.queue.async { [weak self] in
        guard let self = self, !self.rendererRunning, !self.wants || !self.active else { return }
        self.onListening?(false)
      }
    }
  }
  private func maybeRender() {
    guard !isHost, wants, active, client?.ready == true, clock.ready, renderAllowed,
      !rendererRunning
    else { return }
    rendererRunning = true
    renderer.start(generation: stream, offset: clock.offset)
  }
  private func clientStats() -> [String: Any] {
    var s = lastStats
    s["diagnostics"] = diagnostics.json
    s["transportTimerDiagnostics"] = transportTimer.json
    s["buildInfo"] = buildInfo
    s["received"] = received
    s["networkDuplicates"] = duplicates
    s["arrivalGaps"] = gaps.json
    s["clockOffsetMs"] = clock.offset * 1000
    s["clockRttMs"] = clock.rtt * 1000
    s["clockSamples"] = clock.count
    s["clockReady"] = clock.ready
    s["route"] = routeInfo
    s["events"] = Array(events.suffix(20))
    s["renderError"] = errorText
    return s
  }
  private func ensureTicker() {
    guard runPeriodicTicks, ticker == nil else { return }
    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(10))
    t.setEventHandler { [weak self] in self?.tick() }
    ticker = t
    t.resume()
  }
  private func tick() {
    let now = now()
    if active { transportTimer.tick(now) }
    if !isHost, clock.ready, now - lastClockGood > 10 {
      clock = ClockEstimate()
      stopRenderer(deactivate: false)
      log("Clock estimate expired; resynchronizing")
    }
    if !isHost, let p = client, p.hello, now - lastClock >= (clock.ready ? 2 : 0.1) {
      pendingClocks = pendingClocks.filter { now - $0.value < 2 }
      let id = UUID().uuidString
      pendingClocks[id] = now
      lastClock = now
      send(["type": "clock", "id": id, "t1": now], to: p)
    }
    if !isHost, client == nil, reconnect, selected != nil, now >= retryAt { connect() }
    guard now - lastPeriodic >= 1 else { return }
    lastPeriodic = now
    for p in (isHost ? Array(peers.values) : client.map { [$0] } ?? []) {
      if now - p.lastHeard > 5 || (!p.ready && now - p.created > 10) {
        drop(p, "Connection timed out")
        continue
      }
      send(["type": "heartbeat"], to: p)
      if !isHost {
        if p.hello && !p.ready && now - lastRegister >= 1 { register(p) }
        if active {
          send(["type": "stats", "generation": String(stream), "stats": clientStats()], to: p)
        }
      }
    }
    for (key, (c, created)) in candidates where now - created > 10 {
      c.cancel()
      candidates.removeValue(forKey: key)
    }
    publish()
  }
  private func log(_ message: String) {
    events.append(["at": ISO8601DateFormatter().string(from: Date()), "message": message])
    if events.count > 100 { events.removeFirst() }
  }
  // Queue barrier used by deterministic native tests; no transport or timer work.
  func inspectSnapshot(_ completion: @escaping ([String: Any]) -> Void) {
    queue.async { completion(self.snapshotValue()) }
  }
  private func publish() { onSnapshot?(snapshotValue()) }
  private func snapshotValue() -> [String: Any] {
    var s: [String: Any] = [
      "status": status, "hosting": listener != nil, "active": active, "draining": draining,
      "listening": wants,
      "ready": client?.ready ?? false, "rendering": rendererRunning, "source": sourceName,
      "sourceKind": source.rawValue, "bufferMs": lead * 1000,
      "elapsed": active
        ? min(600, max(0, AudioWire.now() - (isHost ? started : anchor - lead))) : 0,
      "port": Int(listener?.port?.rawValue ?? 0), "listeners": peers.values.map(\.row),
      "stats": clientStats(), "skippedSendSlots": skipped,
      "services": services.keys.sorted().map {
        ["id": $0, "name": services[$0]!.debugDescription]
      }, "events": events, "error": errorText,
      "recoveryHint": "After a prolonged background outage, reopen the app to reconnect.",
    ]
    if let report = latestReport { s["report"] = report }
    return s
  }
  deinit {
    ticker?.cancel()
    transmitter?.stop()
    renderer.stop()
    listener?.cancel()
    udpListener?.cancel()
    browser?.cancel()
    client?.tcp.cancel()
    client?.udp?.cancel()
    for p in peers.values {
      p.tcp.cancel()
      p.udp?.cancel()
    }
  }
}
