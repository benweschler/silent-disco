import Foundation

/// Xcode writes this bundle resource at build time, including dirty-worktree provenance.
/// Swift package tests have no app bundle; missing provenance is explicitly unknown.
enum AudioBuildInfo {
  static let policyVersion = 4
  private static let resource: [String: Any] = {
    guard let url = Bundle.main.url(forResource: "SilentDiscoAudioBuild", withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return value
  }()
  static var revision: String { resource["revision"] as? String ?? "unknown" }
  static var fingerprint: String { resource["sourceFingerprint"] as? String ?? "unknown" }
}
