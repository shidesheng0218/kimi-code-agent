import Foundation

public enum TerminalSSHAdapter {
  public static func command(for profile: SSHProfile, recovery: TerminalSSHRecovery = .none) -> String {
    var parts = ["/usr/bin/ssh", "-tt", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3", "-p", String(profile.port)]
    switch profile.hostKeyPolicy {
    case .ask: parts += ["-o", "StrictHostKeyChecking=ask"]
    case .strict: parts += ["-o", "StrictHostKeyChecking=yes"]
    case .acceptNew: parts += ["-o", "StrictHostKeyChecking=accept-new"]
    }
    if let knownHostsFile = profile.knownHostsFile, !knownHostsFile.isEmpty {
      parts += ["-o", "UserKnownHostsFile=\(shellQuote(knownHostsFile))"]
    }
    let referencedIdentityFile: String? = {
      if case .file(let path)? = profile.credentialReference { return path }
      return nil
    }()
    if let identityFile = profile.identityFile ?? referencedIdentityFile, !identityFile.isEmpty {
      parts += ["-i", shellQuote(identityFile)]
    }
    if let proxyJump = profile.proxyJump, !proxyJump.isEmpty {
      parts += ["-J", shellQuote(proxyJump)]
    }
    parts.append("\(shellQuote(profile.username))@\(shellQuote(profile.host))")
    var remoteCommand: String?
    if let directory = profile.workingDirectory, !directory.isEmpty {
      remoteCommand = "cd \(shellQuote(directory)) && exec \(shellQuote(profile.shellPath))"
    }
    switch recovery {
    case .none:
      break
    case .tmux(let sessionName):
      let safeSession = sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "kimi" : sessionName
      let command = remoteCommand ?? "exec \(shellQuote(profile.shellPath))"
      remoteCommand = "tmux new-session -A -s \(shellQuote(safeSession)) \(shellQuote(command))"
    }
    if let remoteCommand {
      parts += ["-t", remoteCommand]
    }
    return parts.joined(separator: " ")
  }

  public static func tmuxListCommand(for profile: SSHProfile) -> String {
    var connectionProfile = profile
    connectionProfile.workingDirectory = nil
    let connection = command(for: connectionProfile)
    let suffix = "tmux list-sessions -F '\\#{session_name}\\t\\#{session_windows}\\t\\#{session_activity_string}' 2>/dev/null || true"
    return "\(connection) \(shellQuote(suffix))"
  }

  private static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

public extension TerminalEnvironmentProfile {
  func resolvedEnvironment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
    base.merging(variables, uniquingKeysWith: { _, new in new })
  }
}
