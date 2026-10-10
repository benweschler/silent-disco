import Darwin
import Foundation
import Network

// All mutable transport state is confined to queue. Callbacks execute on queue.
final class DiagnosticEngine {
  let isHost: Bool
  let queue = DispatchQueue(label: "dev.silentdisco.diagnostics")
  var onSnapshot: (([String: Any]) -> Void)?
  var onReport: (([String: Any]) -> Void)?
  var onActivity: ((Bool) -> Void)?
  private var listener: NWListener?
  private var udpListener: NWListener?
  private var browser: NWBrowser?
  private var discovered: [String: NWEndpoint] = [:]
  private var tcp: NWConnection?
  private var udp: NWConnection?
  private var candidates: [ObjectIdentifier: NWConnection] = [:]
  private var framer = ControlFramer()
  private var ticker: DispatchSourceTimer?
  private var sender: DispatchSourceTimer?
  private var lastHeard = DiagnosticProtocol.now()
  private var connectedAt = DiagnosticProtocol.now()
  private var disconnectedAt: Double?
  private var retry = RetrySchedule()
  private var retryWork: DispatchWorkItem?
  private var desiredEndpoint: NWEndpoint?
  private var shouldReconnect = false
  private var foreground = true
  private var token = Data()
  private var sessionID = ""
  private var peerInfo: [String: Any] = [:]
  private var ready = false
  private var status = "idle"
  private var errorText = ""
  private var events = [[String: Any]]()
  private var latestReport: [String: Any]?
  private var addresses = [String]()
  private var run: UInt64 = 0
  private var profile: TestProfile?
  private var phase = "idle"
  private var runStarted: Double = 0
  private var runDate = ""
  private var elapsed: Double = 0
  private var pacer: PacketPacer?
  private var sequence: UInt64 = 0
  private var sent = 0
  private var sendErrors = 0
  private var skipped = 0
  private var received = PacketCounter()
  private var remoteStats: [String: Any] = [:]
  private var pendingPackets: [UInt64: UInt64] = [:]
  private var rtts = [Double]()
  private var notes = ""
  private var offlineConfirmed = false
  private var drainScheduled = false
  private var runGeneration: UInt64 = 0
  private var finalReason = "completed"

  init(isHost: Bool) { self.isHost = isHost }

  deinit {
    ticker?.cancel()
    sender?.cancel()
    retryWork?.cancel()
    browser?.cancel()
    listener?.cancel()
    udpListener?.cancel()
    tcp?.cancel()
    udp?.cancel()
    for candidate in candidates.values { candidate.cancel() }
  }

  func perform(_ command: String, args: [String: Any] = [:]) {
    queue.async { [weak self] in
      guard let self = self else { return }
      do {
        switch command {
        case "snapshot": break
        case "startHost": if self.isHost { try self.startHost() }
        case "stopHost": self.stopHost()
        case "browse": self.startBrowse()
        case "stopBrowse":
          self.browser?.cancel()
          self.browser = nil
          self.discovered = [:]
        case "connect":
          guard !self.isHost else { break }
          let endpoint: NWEndpoint
          if let id = args["id"] as? String, let found = self.discovered[id] {
            endpoint = found
          } else {
            guard let ip = args["host"] as? String,
              IPv4Address(ip) != nil || IPv6Address(ip) != nil,
              let raw = args["port"] as? Int, raw > 0, raw <= 65535,
              let port = NWEndpoint.Port(rawValue: UInt16(raw))
            else {
              self.fail("Enter a numeric IPv4/IPv6 address and a port from 1 to 65535.")
              return
            }
            endpoint = .hostPort(host: NWEndpoint.Host(ip), port: port)
          }
          self.shouldReconnect = false
          self.disconnect("Changed connection", reconnect: false)
          self.desiredEndpoint = endpoint
          self.shouldReconnect = true
          self.connect(endpoint)
        case "disconnect":
          self.shouldReconnect = false
          self.desiredEndpoint = nil
          self.disconnect("Disconnected by user", reconnect: false)
        case "startTest":
          guard let name = args["profile"] as? String, let p = TestProfile(rawValue: name),
            self.ready, self.profile == nil
          else {
            self.fail("Connect and wait for UDP readiness before starting a test.")
            return
          }
          self.notes = String((args["notes"] as? String ?? "").prefix(2000))
          self.offlineConfirmed = args["offlineConfirmed"] as? Bool ?? false
          if self.isHost {
            self.prepare(p)
          } else {
            self.send([
              "type": "requestStart", "profile": name, "notes": self.notes,
              "offlineConfirmed": self.offlineConfirmed,
            ])
          }
        case "stopTest":
          if self.isHost {
            self.stopRun("stopped by user")
          } else {
            self.send(["type": "requestStop"])
          }
        case "background":
          self.foreground = false
          self.browser?.cancel()
          self.browser = nil
          self.disconnect("App backgrounded or phone locked", reconnect: false)
        case "foreground":
          self.foreground = true
          self.startBrowse()
          if self.shouldReconnect { self.scheduleReconnect() }
        case "sleep": self.disconnect("Mac sleeping", reconnect: false)
        default: break
        }
      } catch { self.fail("\(error)") }
      self.publish()
    }
  }

  private func fail(_ message: String) {
    errorText = message
    log(message)
    publish()
  }
  private func log(_ message: String) {
    events.append(["at": ISO8601DateFormatter().string(from: Date()), "message": message])
    if events.count > 100 { events.removeFirst(events.count - 100) }
  }
  private func makeParameters(_ transport: String) -> NWParameters {
    let p = transport == "tcp" ? NWParameters.tcp : NWParameters.udp
    p.includePeerToPeer = false
    return p
  }
  private func startHost() throws {
    guard listener == nil else { return }
    errorText = ""
    status = "starting"
    addresses = Self.localAddresses()
    let u = try NWListener(using: makeParameters("udp"), on: .any)
    udpListener = u
    u.newConnectionHandler = { [weak self] c in self?.acceptUDP(c) }
    u.stateUpdateHandler = { [weak self, weak u] state in
      guard let self = self, self.udpListener === u else { return }
      if case .failed(let error) = state { self.hostFailed("UDP listener failed: \(error)") }
      self.publish()
    }
    u.start(queue: queue)
    let t = try NWListener(using: makeParameters("tcp"), on: .any)
    listener = t
    t.service = NWListener.Service(
      name: "Silent Disco Diagnostics", type: DiagnosticProtocol.service,
      txtRecord: NWTXTRecord(["version": "1"]))
    t.newConnectionHandler = { [weak self] c in self?.acceptTCP(c) }
    t.stateUpdateHandler = { [weak self, weak t] state in
      guard let self = self, self.listener === t else { return }
      switch state {
      case .ready:
        self.status = "listening"
        self.log("Server listening; offline hotspot setup is not verified by this status.")
      case .failed(let error): self.hostFailed("TCP listener failed: \(error)")
      default: break
      }
      self.publish()
    }
    t.start(queue: queue)
    ensureTicker()
  }
  private func hostFailed(_ message: String) {
    stopHost()
    fail(message)
  }
  private func stopHost() {
    disconnect("Server stopped", reconnect: false)
    listener?.cancel()
    listener = nil
    udpListener?.cancel()
    udpListener = nil
    ticker?.cancel()
    ticker = nil
    status = "idle"
  }
  private func acceptTCP(_ c: NWConnection) {
    guard tcp == nil else {
      c.start(queue: queue)
      let data = Data("{\"type\":\"error\",\"message\":\"Hub is busy with another phone.\"}\n".utf8)
      c.send(content: data, completion: .contentProcessed { _ in c.cancel() })
      queue.asyncAfter(deadline: .now() + 2) { c.cancel() }
      return
    }
    token = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    sessionID = UUID().uuidString
    attachTCP(c)
  }
  private func startBrowse() {
    guard !isHost, foreground else { return }
    browser?.cancel()
    discovered = [:]
    errorText = ""
    if tcp == nil { status = "discovering" }
    let b = NWBrowser(
      for: .bonjour(type: DiagnosticProtocol.service, domain: nil), using: makeParameters("tcp"))
    browser = b
    b.browseResultsChangedHandler = { [weak self, weak b] results, _ in
      guard let self = self, self.browser === b else { return }
      self.discovered = Dictionary(
        uniqueKeysWithValues: results.map { ($0.endpoint.debugDescription, $0.endpoint) })
      self.publish()
    }
    b.stateUpdateHandler = { [weak self, weak b] state in
      guard let self = self, self.browser === b else { return }
      if case .failed(let error) = state {
        self.fail(
          "Discovery failed: \(error). Check Local Network permission and retry, or use manual IP/port."
        )
      }
      if case .waiting(let error) = state {
        self.fail("Discovery waiting: \(error). Check Wi-Fi and Local Network permission.")
      }
    }
    b.start(queue: queue)
  }
  private func connect(_ endpoint: NWEndpoint) {
    guard tcp == nil, foreground else { return }
    errorText = ""
    status = "connecting"
    attachTCP(NWConnection(to: endpoint, using: makeParameters("tcp")))
    ensureTicker()
  }
  private func attachTCP(_ c: NWConnection) {
    tcp = c
    framer = ControlFramer()
    ready = false
    lastHeard = DiagnosticProtocol.now()
    connectedAt = lastHeard
    c.stateUpdateHandler = { [weak self, weak c] state in
      guard let self = self, let c = c, self.tcp === c else { return }
      switch state {
      case .ready:
        self.status = "handshaking"
        if !self.isHost { self.send(["type": "hello", "version": 1, "device": Self.deviceInfo()]) }
        self.receiveTCP(c)
      case .failed(let error): self.disconnect("Connection failed: \(error)", reconnect: true)
      case .waiting(let error):
        self.errorText =
          "Connection waiting: \(error). Check Wi-Fi, firewall, and Local Network permission."
      default: break
      }
      self.publish()
    }
    c.start(queue: queue)
  }
  private func receiveTCP(_ c: NWConnection) {
    c.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
      [weak self, weak c] data, _, complete, error in
      guard let self = self, let c = c, self.tcp === c else { return }
      do {
        if let data = data {
          for message in try self.framer.append(data) {
            self.lastHeard = DiagnosticProtocol.now()
            self.handle(message)
            if self.tcp !== c { return }
          }
        }
      } catch {
        self.disconnect("Invalid or oversized control message", reconnect: true)
        return
      }
      if complete || error != nil {
        self.disconnect(
          "Control connection closed\(error.map { ": \($0)" } ?? "")", reconnect: true)
      } else {
        self.receiveTCP(c)
      }
    }
  }
  private func send(_ message: [String: Any]) {
    guard let c = tcp, var data = try? JSONSerialization.data(withJSONObject: message),
      data.count <= DiagnosticProtocol.maxFrame
    else { return }
    data.append(10)
    c.send(
      content: data,
      completion: .contentProcessed { [weak self, weak c] error in
        guard let self = self, self.tcp === c else { return }
        if let error = error { self.disconnect("Control send failed: \(error)", reconnect: true) }
      })
  }
  private func handle(_ m: [String: Any]) {
    switch m["type"] as? String {
    case "hello" where isHost:
      guard m["version"] as? Int == 1, token.count == 16, let port = udpListener?.port else {
        disconnect("Protocol version mismatch or UDP listener unavailable", reconnect: false)
        return
      }
      peerInfo = m["device"] as? [String: Any] ?? [:]
      send([
        "type": "welcome", "version": 1, "session": sessionID, "token": token.base64EncodedString(),
        "udpPort": Int(port.rawValue), "device": Self.deviceInfo(),
      ])
    case "welcome" where !isHost:
      guard m["version"] as? Int == 1, let encoded = m["token"] as? String,
        let token = Data(base64Encoded: encoded), token.count == 16,
        let session = m["session"] as? String, let raw = m["udpPort"] as? Int, raw > 0,
        raw <= 65535,
        let endpoint = tcp?.currentPath?.remoteEndpoint, case .hostPort(let host, _) = endpoint
      else {
        disconnect("Invalid welcome or unresolved hub address", reconnect: false)
        return
      }
      self.token = token
      sessionID = session
      peerInfo = m["device"] as? [String: Any] ?? [:]
      let c = NWConnection(
        host: host, port: NWEndpoint.Port(rawValue: UInt16(raw))!, using: makeParameters("udp"))
      udp?.cancel()
      udp = c
      c.stateUpdateHandler = { [weak self, weak c] state in
        guard let self = self, let c = c, self.udp === c else { return }
        if case .ready = state {
          self.registerUDP()
          self.receiveUDP(c)
        }
        if case .failed(let error) = state {
          self.disconnect("UDP failed: \(error)", reconnect: true)
        }
      }
      c.start(queue: queue)
    case "heartbeat": break
    case "udpReady" where isHost:
      if udp != nil { becameReady() }
    case "requestStart" where isHost:
      guard ready, profile == nil, let name = m["profile"] as? String,
        let p = TestProfile(rawValue: name)
      else { return }
      notes = String((m["notes"] as? String ?? "").prefix(2000))
      offlineConfirmed = m["offlineConfirmed"] as? Bool ?? false
      prepare(p)
    case "prepare" where !isHost:
      guard ready, profile == nil, let name = m["profile"] as? String,
        let p = TestProfile(rawValue: name),
        let id = m["run"] as? String, let run = UInt64(id), run != 0
      else { return }
      resetRun(p, id: run)
      send(["type": "prepared", "run": id])
    case "prepared" where isHost:
      guard phase == "preparing", m["run"] as? String == String(run) else { return }
      beginSending()
    case "begun" where !isHost:
      guard phase == "preparing", m["run"] as? String == String(run) else { return }
      phase = "running"
      runStarted = DiagnosticProtocol.now()
      onActivity?(true)
    case "stats" where isHost:
      if m["run"] as? String == String(run) { remoteStats = m["stats"] as? [String: Any] ?? [:] }
    case "requestStop" where isHost: stopRun("stopped by user")
    case "stopping" where !isHost:
      guard profile != nil, m["run"] as? String == String(run) else { return }
      elapsed = m["elapsed"] as? Double ?? elapsed
      phase = "draining"
    case "finalRequest" where !isHost:
      guard profile != nil, m["run"] as? String == String(run) else { return }
      send(["type": "finalStats", "run": String(run), "stats": localStats()])
    case "finalStats" where isHost:
      guard phase == "draining", m["run"] as? String == String(run) else { return }
      remoteStats = m["stats"] as? [String: Any] ?? [:]
      completeRun(finalReason, completeCounters: true)
    case "report" where !isHost:
      guard let report = m["report"] as? [String: Any], report["run"] as? String == String(run)
      else { return }
      latestReport = report
      phase = report["status"] as? String ?? "completed"
      profile = nil
      onActivity?(false)
      onReport?(report)
    case "error":
      shouldReconnect = false
      disconnect(m["message"] as? String ?? "Hub rejected connection", reconnect: false)
    default: break
    }
    publish()
  }
  private func acceptUDP(_ c: NWConnection) {
    guard tcp != nil, candidates.count < 4 else {
      c.cancel()
      return
    }
    // NWListener delivers concrete host/port endpoints; the UDP peer must match TCP.
    guard case .hostPort(let host, _) = c.endpoint,
      let endpoint = tcp?.endpoint, case .hostPort(let tcpHost, _) = endpoint, host == tcpHost
    else {
      c.cancel()
      return
    }
    candidates[ObjectIdentifier(c)] = c
    c.start(queue: queue)
    receiveUDP(c)
    queue.asyncAfter(deadline: .now() + 5) { [weak self, weak c] in
      guard let self = self, let c = c else { return }
      if self.udp !== c {
        self.candidates.removeValue(forKey: ObjectIdentifier(c))
        c.cancel()
      }
    }
  }
  private func registerUDP() {
    guard !isHost, token.count == 16 else { return }
    sendUDP(DiagnosticPacket(kind: 0, token: token).encode(), on: udp)
  }
  private func sendUDP(_ data: Data, on connection: NWConnection?) {
    connection?.send(content: data, completion: .contentProcessed { _ in })
  }
  private func receiveUDP(_ c: NWConnection) {
    c.receiveMessage { [weak self, weak c] data, _, _, error in
      guard let self = self, let c = c,
        self.udp === c || self.candidates[ObjectIdentifier(c)] != nil
      else { return }
      if let data = data, let packet = DiagnosticPacket(data), packet.token == self.token {
        self.handlePacket(packet, connection: c)
      }
      if let error = error {
        self.candidates.removeValue(forKey: ObjectIdentifier(c))
        if self.udp === c {
          self.disconnect("UDP receive failed: \(error)", reconnect: true)
        } else {
          c.cancel()
        }
      } else {
        self.receiveUDP(c)
      }
    }
  }
  private func handlePacket(_ packet: DiagnosticPacket, connection c: NWConnection) {
    if packet.kind == 0, isHost, udp == nil || udp === c {
      udp = c
      candidates.removeValue(forKey: ObjectIdentifier(c))
      sendUDP(DiagnosticPacket(kind: 1, token: token).encode(), on: c)
      return
    }
    if packet.kind == 1, !isHost {
      becameReady()
      return
    }
    guard let p = profile, packet.run == run, packet.stream < p.streams,
      packet.sequence < 100_000, phase == "running" || phase == "draining"
    else { return }
    let now = DiagnosticProtocol.now()
    if packet.kind == 2, !isHost {
      guard
        received.record(
          sequence: packet.sequence, stream: packet.stream, at: now, interval: p.interval)
      else { return }
      var echo = packet
      echo.kind = 3
      let generation = runGeneration
      c.send(
        content: echo.encode(),
        completion: .contentProcessed { [weak self] error in
          guard let self = self, self.runGeneration == generation, self.profile != nil else {
            return
          }
          if error == nil { self.sent += 1 } else { self.sendErrors += 1 }
        })
    } else if packet.kind == 3, isHost, pendingPackets[packet.sequence] == packet.timestamp {
      if received.record(
        sequence: packet.sequence, stream: packet.stream, at: now, interval: p.interval)
      {
        let ns = DispatchTime.now().uptimeNanoseconds
        if ns >= packet.timestamp { rtts.append(Double(ns - packet.timestamp) / 1_000_000) }
      }
    }
  }
  private func becameReady() {
    guard !ready else { return }
    ready = true
    status = "connected"
    errorText = ""
    retry.reset()
    if !isHost { send(["type": "udpReady"]) }
    if let since = disconnectedAt {
      log(
        String(
          format: "Reconnected after %.2f seconds; start a new test explicitly.",
          DiagnosticProtocol.now() - since))
      disconnectedAt = nil
    } else {
      log("TCP and UDP ready")
    }
    publish()
  }
  private func ensureTicker() {
    guard ticker == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    ticker = timer
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler { [weak self] in self?.tick() }
    timer.resume()
  }
  private func tick() {
    let now = DiagnosticProtocol.now()
    if tcp != nil {
      if ConnectionDeadline.expired(
        now: now, lastHeard: lastHeard, connectedAt: connectedAt, ready: ready)
      {
        disconnect(
          "Connection timed out. Check Wi-Fi, firewall, and Local Network permission.",
          reconnect: true)
      } else {
        send(["type": "heartbeat"])
        if !ready && !isHost { registerUDP() }
      }
    }
    if let p = profile {
      if phase == "running" { elapsed = p.elapsed(since: runStarted, at: now) }
      if !isHost { send(["type": "stats", "run": String(run), "stats": localStats()]) }
      if phase == "preparing", now - runStarted > 5 { interruptRun("Test handshake timed out") }
      // No client run may survive an unresponsive/misbehaving sender beyond the cap + final exchange.
      if !isHost, now - runStarted > p.duration + 7 { interruptRun("Final report timed out") }
    }
    publish()
  }
  private func resetRun(_ p: TestProfile, id: UInt64) {
    runGeneration &+= 1
    run = id
    profile = p
    phase = "preparing"
    runStarted = DiagnosticProtocol.now()
    runDate = ISO8601DateFormatter().string(from: Date())
    elapsed = 0
    sequence = 0
    sent = 0
    sendErrors = 0
    skipped = 0
    received = PacketCounter()
    remoteStats = [:]
    pendingPackets = [:]
    rtts = []
    drainScheduled = false
    finalReason = "completed"
    latestReport = nil
    log("Preparing \(p.rawValue); maximum \(Int(p.duration)) seconds")
  }
  private func prepare(_ p: TestProfile) {
    resetRun(p, id: UInt64.random(in: 1...UInt64.max))
    send(["type": "prepare", "profile": p.rawValue, "run": String(run)])
  }
  private func beginSending() {
    guard let p = profile else { return }
    runStarted = DiagnosticProtocol.now()
    phase = "running"
    pacer = PacketPacer(nextDeadline: runStarted + 0.1, interval: p.interval)
    send(["type": "begun", "run": String(run)])
    onActivity?(true)
    let timer = DispatchSource.makeTimerSource(queue: queue)
    sender = timer
    timer.schedule(deadline: .now() + 0.1, repeating: .milliseconds(5), leeway: .milliseconds(1))
    timer.setEventHandler { [weak self] in self?.sendBatch() }
    timer.resume()
  }
  private func sendBatch() {
    guard let p = profile, phase == "running", let connection = udp else { return }
    let now = DiagnosticProtocol.now()
    elapsed = p.elapsed(since: runStarted, at: now)
    guard !p.expired(since: runStarted, at: now) else {
      stopRun("completed")
      return
    }
    guard let due = pacer?.due(at: now), due.send else { return }
    skipped += due.skipped * p.streams
    for stream in 0..<p.streams {
      let seq = sequence
      sequence += 1
      let stamp = DispatchTime.now().uptimeNanoseconds
      pendingPackets[seq] = stamp
      let data = DiagnosticPacket(
        kind: 2, stream: UInt16(stream), token: token,
        run: run, sequence: seq, timestamp: stamp
      ).encode()
      let generation = runGeneration
      connection.send(
        content: data,
        completion: .contentProcessed { [weak self] error in
          guard let self = self, self.runGeneration == generation, self.profile != nil else {
            return
          }
          if error == nil {
            self.sent += 1
          } else {
            self.sendErrors += 1
            self.pendingPackets.removeValue(forKey: seq)
          }
        })
    }
  }
  private func stopRun(_ reason: String) {
    guard isHost, let p = profile, !drainScheduled else { return }
    drainScheduled = true
    sender?.cancel()
    sender = nil
    elapsed = p.elapsed(since: runStarted, at: DiagnosticProtocol.now())
    finalReason = reason
    phase = "draining"
    send(["type": "stopping", "run": String(run), "elapsed": elapsed])
    let generation = runGeneration
    queue.asyncAfter(deadline: .now() + 2) { [weak self] in
      guard let self = self, self.profile != nil, self.runGeneration == generation else { return }
      self.send(["type": "finalRequest", "run": String(self.run)])
      self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
        guard let self = self, self.profile != nil, self.runGeneration == generation else { return }
        self.completeRun("Final counters unavailable", completeCounters: false)
      }
    }
    publish()
  }
  private func localStats() -> [String: Any] {
    var stats = received.snapshot(elapsed: elapsed)
    stats["submitted"] = sent
    stats["sendErrors"] = sendErrors
    stats["skippedSendSlots"] = skipped
    stats["submittedKbps"] = Double(sent * 400 * 8) / max(elapsed, 0.001) / 1000
    if isHost {
      let sorted = rtts.sorted()
      func percentile(_ p: Double) -> Double {
        sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
      }
      stats["rttSamples"] = sorted.count
      stats["rttMedianMs"] = percentile(0.5)
      stats["rttP95Ms"] = percentile(0.95)
      stats["rttP99Ms"] = percentile(0.99)
      stats["rttMaxMs"] = sorted.last ?? 0
    }
    return stats
  }
  private func completeRun(_ reason: String, completeCounters: Bool) {
    guard let p = profile else { return }
    sender?.cancel()
    sender = nil
    onActivity?(false)
    let local = localStats()
    let downReceived = remoteStats["unique"] as? Int ?? 0
    let upSent = remoteStats["submitted"] as? Int ?? 0
    let downLoss = max(0, sent - downReceived)
    let upLoss = max(0, upSent - received.unique)
    let completed = reason == "completed" && completeCounters
    let passes =
      completed && sent > 0 && upSent > 0 && Double(downLoss) / Double(sent) < 0.001
      && Double(upLoss) / Double(upSent) < 0.001 && (local["rttP95Ms"] as? Double ?? 999) < 50
      && max(received.maxGapMs, remoteStats["maxGapMs"] as? Double ?? 999) <= 250 && sendErrors == 0
      && (remoteStats["sendErrors"] as? Int ?? 1) == 0
    let report: [String: Any] = [
      "protocolVersion": 1, "session": sessionID, "run": String(run), "profile": p.rawValue,
      "status": completed ? "completed" : "interrupted", "reason": reason,
      "completeCounters": completeCounters,
      "networkGate": completeCounters ? (passes ? "pass" : "review") : "incomplete",
      "startedAt": runDate, "endedAt": ISO8601DateFormatter().string(from: Date()),
      "durationSeconds": elapsed, "maximumDurationSeconds": p.duration,
      "host": Self.deviceInfo(), "phone": peerInfo,
      "endpoint": tcp?.endpoint.debugDescription ?? "disconnected",
      "localAddresses": addresses, "hostMetrics": local, "phoneMetrics": remoteStats,
      "downstreamMissing": completeCounters ? downLoss as Any : NSNull(),
      "upstreamMissing": completeCounters ? upLoss as Any : NSNull(),
      "offlineSetupUserConfirmed": offlineConfirmed, "setupNotes": notes,
      "limitations":
        "One phone; foreground operation; synthetic traffic. Offline setup is user-confirmed, not automatically verified. No audio, clock-sync, or multi-listener claims.",
      "events": Array(events.suffix(20)),
    ]
    latestReport = report
    phase = completed ? "completed" : "interrupted"
    send(["type": "report", "report": report])
    profile = nil
    pendingPackets = [:]
    onReport?(report)
    log("Run \(phase): \(reason)")
    publish()
  }
  private func interruptRun(_ reason: String) {
    guard profile != nil else { return }
    if isHost {
      completeRun(reason, completeCounters: false)
    } else {
      sender?.cancel()
      sender = nil
      profile = nil
      phase = "interrupted"
      onActivity?(false)
      latestReport = [
        "run": String(run), "status": "interrupted", "reason": reason,
        "completeCounters": false, "phoneMetrics": localStats(),
      ]
      log(reason)
    }
  }
  private func disconnect(_ reason: String, reconnect: Bool) {
    interruptRun(reason)
    retryWork?.cancel()
    retryWork = nil
    let wasConnected = tcp != nil
    let old = tcp
    tcp = nil
    old?.cancel()
    udp?.cancel()
    udp = nil
    for c in candidates.values { c.cancel() }
    candidates = [:]
    token = Data()
    ready = false
    peerInfo = [:]
    framer = ControlFramer()
    if !isHost {
      ticker?.cancel()
      ticker = nil
    }
    status = isHost && listener != nil ? "listening" : "disconnected"
    if wasConnected {
      log(reason)
      errorText = reason
      if disconnectedAt == nil { disconnectedAt = DiagnosticProtocol.now() }
    }
    if reconnect && !isHost && shouldReconnect && foreground { scheduleReconnect() }
    publish()
  }
  private func scheduleReconnect() {
    guard retryWork == nil, tcp == nil, shouldReconnect, foreground, let endpoint = desiredEndpoint
    else { return }
    let delay = retry.next()
    let work = DispatchWorkItem { [weak self] in
      guard let self = self, self.foreground, self.shouldReconnect else { return }
      self.retryWork = nil
      self.connect(endpoint)
    }
    retryWork = work
    queue.asyncAfter(deadline: .now() + delay, execute: work)
  }
  private func publish() {
    let serviceRows: [[String: Any]] = discovered.keys.sorted().map { ["id": $0, "name": $0] }
    var snapshot: [String: Any] = [
      "status": status, "phase": phase, "ready": ready, "error": errorText,
      "hosting": listener != nil, "services": serviceRows, "events": Array(events.suffix(12)),
      "addresses": addresses, "tcpPort": Int(listener?.port?.rawValue ?? 0),
      "udpPort": Int(udpListener?.port?.rawValue ?? 0),
      "endpoint": tcp?.endpoint.debugDescription ?? "",
      "elapsed": elapsed, "duration": profile?.duration ?? 0, "profile": profile?.rawValue ?? "",
      "metrics": localStats(), "remoteMetrics": remoteStats, "active": profile != nil,
    ]
    if let report = latestReport { snapshot["report"] = report }
    onSnapshot?(snapshot)
  }
  static func deviceInfo() -> [String: Any] {
    var info = utsname()
    uname(&info)
    let machine = withUnsafePointer(to: &info.machine) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
    }
    return [
      "modelIdentifier": machine, "os": ProcessInfo.processInfo.operatingSystemVersionString,
      "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        as? String ?? "unknown",
      "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
    ]
  }
  static func localAddresses() -> [String] {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return [] }
    defer { freeifaddrs(list) }
    var result = [String]()
    var current: UnsafeMutablePointer<ifaddrs>? = first
    while let entry = current {
      defer { current = entry.pointee.ifa_next }
      guard let addr = entry.pointee.ifa_addr, (Int32(entry.pointee.ifa_flags) & IFF_UP) != 0,
        addr.pointee.sa_family == UInt8(AF_INET) || addr.pointee.sa_family == UInt8(AF_INET6)
      else { continue }
      var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      if getnameinfo(
        addr, socklen_t(addr.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0,
        NI_NUMERICHOST) == 0
      {
        result.append("\(String(cString: entry.pointee.ifa_name)): \(String(cString: buffer))")
      }
    }
    return result.sorted()
  }
}
