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

  /// The native WebRuntime only supports anonymous public HTTP(S) GET for
  /// these tools. It is therefore safe to auto-authorize the first request as
  /// well as later ones; private-network and credential-bearing URLs fail this
  /// predicate before a network connection is attempted.
  public static func canAutoApprovePublicRead(toolID: String, input: [String: String]) -> Bool {
    switch toolID.lowercased() {
    case "web.search", "web_search", "websearch":
      return input["query"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    case "web.fetch", "web_fetch", "network.fetch", "fetchurl":
      let rawURL = ["url", "href", "uri", "link"]
        .compactMap { input[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty })
      guard let rawURL, let url = try? WebFetchPolicy.validate(url: rawURL), let host = url.host else { return false }
      return !isPrivateTargetHost(host)
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

  /// True when the host is a loopback/private literal or localhost name that
  /// must never be auto-approved for read-only web effects.
  public static func isPrivateTargetHost(_ host: String) -> Bool {
    var normalized = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.hasPrefix("["), normalized.hasSuffix("]") {
      normalized = String(normalized.dropFirst().dropLast())
    }
    if normalized == "localhost" || normalized == "ip6-localhost" || normalized.hasSuffix(".localhost") || normalized == "::" || normalized == "::1" {
      return true
    }
    if normalized.contains(":") {
      return isUnsafeIPv6Literal(normalized)
    }
    let parts = normalized.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 4 else { return false }
    let first = parts[0]
    let second = parts[1]
    return first == 10
      || first == 127
      || first == 0
      || (first == 100 && second >= 64 && second <= 127)
      || (first == 169 && second == 254)
      || (first == 172 && second >= 16 && second <= 31)
      || (first == 192 && second == 168)
  }

  private static func isUnsafeIPv6Literal(_ host: String) -> Bool {
    let pieces = host.split(separator: "::", omittingEmptySubsequences: false)
    guard pieces.count <= 2 else { return true }
    func groups(_ part: Substring) -> [Int]? {
      guard !part.isEmpty else { return [] }
      var result: [Int] = []
      for raw in part.split(separator: ":") {
        if raw.contains(".") {
          let octets = raw.split(separator: ".").compactMap { Int($0) }
          guard octets.count == 4, octets.allSatisfy({ $0 >= 0 && $0 <= 255 }) else { return nil }
          result.append((octets[0] << 8) | octets[1])
          result.append((octets[2] << 8) | octets[3])
        } else {
          guard let value = Int(raw, radix: 16), (0...0xffff).contains(value) else { return nil }
          result.append(value)
        }
      }
      return result
    }
    var expanded: [Int]
    if pieces.count == 1 {
      guard let parsed = groups(pieces[0]), parsed.count == 8 else { return true }
      expanded = parsed
    } else {
      guard let head = groups(pieces[0]), let tail = groups(pieces[1]) else { return true }
      let missing = 8 - head.count - tail.count
      guard missing >= 1 else { return true }
      expanded = head + Array(repeating: 0, count: missing) + tail
    }
    if expanded.allSatisfy({ $0 == 0 }) { return true }
    if expanded.dropLast().allSatisfy({ $0 == 0 }) && expanded[7] == 1 { return true }
    let v4Mapped = expanded.prefix(5).allSatisfy { $0 == 0 } && expanded[5] == 0xffff
    let v4Compatible = expanded.prefix(6).allSatisfy { $0 == 0 }
    if v4Mapped || v4Compatible {
      let hi = expanded[6]
      let lo = expanded[7]
      return privateIPv4(hi >> 8, hi & 0xff, lo >> 8, lo & 0xff)
    }
    if (expanded[0] & 0xffc0) == 0xfe80 { return true }
    if (expanded[0] & 0xfe00) == 0xfc00 { return true }
    if (expanded[0] & 0xff00) == 0xff00 { return true }
    return false
  }

  private static func privateIPv4(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> Bool {
    a == 0 || a == 10 || a == 127
      || (a == 100 && b >= 64 && b <= 127)
      || (a == 169 && b == 254)
      || (a == 172 && b >= 16 && b <= 31)
      || (a == 192 && b == 168)
  }
}
