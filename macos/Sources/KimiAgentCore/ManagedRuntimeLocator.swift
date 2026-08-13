import Foundation

public enum ManagedRuntimeLocator {
  public static func nodePath(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    candidates: [String] = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"],
    fileManager: FileManager = .default
  ) -> String? {
    if let configured = environment["KIMI_NODE_PATH"], fileManager.isExecutableFile(atPath: configured) {
      return configured
    }
    return candidates.first { fileManager.isExecutableFile(atPath: $0) }
  }

  public static func runtimeURL(in resourceDirectories: [URL], fileManager: FileManager = .default) -> URL? {
    resourceURL(named: "kimi.mjs", in: resourceDirectories, fileManager: fileManager)
  }

  public static func resourceURL(
    named name: String,
    in resourceDirectories: [URL],
    fileManager: FileManager = .default
  ) -> URL? {
    for resourceDirectory in resourceDirectories {
      let directResource = resourceDirectory.appendingPathComponent(name)
      if fileManager.fileExists(atPath: directResource.path) {
        return directResource
      }

      guard let contents = try? fileManager.contentsOfDirectory(
        at: resourceDirectory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      ) else {
        continue
      }

      for item in contents where item.pathExtension == "bundle" {
        let candidates = [
          item.appendingPathComponent(name),
          item.appendingPathComponent("Resources", isDirectory: true).appendingPathComponent(name),
          item.appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(name),
          item.appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(name)
        ]
        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
          return candidate
        }
      }
    }

    return nil
  }
}
