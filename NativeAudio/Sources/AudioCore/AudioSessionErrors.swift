import Foundation

// Clear a fault only after evidence for its own subsystem; keep unrelated failures.
struct AudioSessionErrors {
  enum Kind: CaseIterable { case command, renderer, audioSession, hostTransport, hostDiscovery, connection, discovery }
  private var messages = [Kind: String]()
  mutating func set(_ kind: Kind, _ message: String) { messages[kind] = message }
  mutating func clear(_ kind: Kind) { messages.removeValue(forKey: kind) }
  func visible(connected: Bool) -> String {
    for kind in Kind.allCases {
      // Discovery does not block an established listener connection, including manual connections.
      if kind == .discovery && connected { continue }
      if let message = messages[kind] { return message }
    }
    return ""
  }
  mutating func rendererStats(state: String?, listening: Bool, running: Bool) {
    if state == "playing" && listening && running { clear(.renderer) }
  }
  var renderingError: String { messages[.renderer] ?? messages[.audioSession] ?? "" }
}
