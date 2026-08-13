import Foundation

/// Normalizes the read-only web tools into a small, safe approval surface.
/// Search is scoped to the configured provider; fetch is scoped to the target
/// host so every URL on the same site does not trigger another prompt.
public enum WebToolApprovalPolicy {
  public static func isReadOnly(toolID: String) -> Bool {
    switch toolID.lowercased() {
    case "web.search", "web_search", "websearch", "web.fetch", "web_fetch", "network.fetch", "fetchurl":
      return true
    default:
      return false
    }
  }

  public static func approvalKey(toolID: String, input: [String: String]) -> String? {
    switch toolID.lowercased() {
    case "web.search", "web_search", "websearch":
      return "web.search"
    case "web.fetch", "web_fetch", "network.fetch", "fetchurl":
      guard let host = host(in: input) else { return nil }
      return "web.fetch:\(host)"
    default:
      return nil
    }
  }

  public static func host(in input: [String: String]) -> String? {
    let aliases = ["url", "href", "uri", "link", "sourceid", "source_id"]
    for key in aliases {
      guard let raw = input[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
            let url = URL(string: raw),
            let host = url.host?.lowercased(), !host.isEmpty else { continue }
      return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    return nil
  }

  public static func matchesConfiguredDomain(host: String, domains: [String]) -> Bool {
    let normalizedHost = host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host.lowercased()
    return domains.contains { rawDomain in
      let domain = rawDomain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "."))
      guard !domain.isEmpty else { return false }
      return normalizedHost == domain || normalizedHost.hasSuffix(".\(domain)")
    }
  }
}
