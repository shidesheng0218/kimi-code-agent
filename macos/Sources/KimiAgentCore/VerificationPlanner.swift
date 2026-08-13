import Foundation

public enum VerificationPlanner {
  public static func defaultPlan(for directory: URL) -> VerificationPlan {
    var steps: [VerificationStep] = []
    let packageURL = directory.appendingPathComponent("package.json")

    if let data = try? Data(contentsOf: packageURL),
       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let scripts = object["scripts"] as? [String: Any] {
      if scripts["test"] != nil {
        steps.append(VerificationStep(kind: .test, command: "npm", arguments: ["test"], timeoutSeconds: 300))
      }
      if scripts["build"] != nil {
        steps.append(VerificationStep(kind: .build, command: "npm", arguments: ["run", "build"], timeoutSeconds: 300))
      }
    }

    if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
      steps.append(VerificationStep(kind: .test, command: "swift", arguments: ["test"], timeoutSeconds: 300))
    }

    if FileManager.default.fileExists(atPath: directory.appendingPathComponent("pyproject.toml").path)
      || FileManager.default.fileExists(atPath: directory.appendingPathComponent("pytest.ini").path) {
      steps.append(VerificationStep(kind: .test, command: "python3", arguments: ["-m", "pytest"], timeoutSeconds: 300))
    }

    if steps.isEmpty, FileManager.default.fileExists(atPath: directory.appendingPathComponent("Makefile").path) {
      steps.append(VerificationStep(kind: .test, command: "make", arguments: ["test"], timeoutSeconds: 300))
    }

    return VerificationPlan(steps: steps, stopOnFailure: true, maxRepairRounds: 3)
  }
}
