import Foundation

public enum WebResearchCapabilityState: Equatable, Sendable {
  case notTested
  case checking
  case available
  case unavailable(String)
}

public struct WebResearchConnectionPresentation: Equatable, Sendable {
  public let isReady: Bool
  public let statusText: String
  public let actionTitle: String

  public init(
    settings: WebResearchSettingsRecord,
    identity: KimiRuntimeIdentityRecord,
    capability: WebResearchCapabilityState = .notTested
  ) {
    guard settings.isEnabled else {
      isReady = false
      statusText = "联网研究已关闭"
      actionTitle = "启用联网研究"
      return
    }

    if settings.provider.usesKimiAPIKey {
      if identity.mode == .apiKey && identity.isAPIConfigured {
        switch capability {
        case .checking:
          isReady = false
          statusText = "正在检查 Kimi API 官方联网…"
          actionTitle = "检查中"
        case .available:
          isReady = true
          statusText = "Kimi API 官方联网可用"
          actionTitle = "重新测试"
        case let .unavailable(message):
          isReady = false
          statusText = "官方联网不可用：\(message)"
          actionTitle = "重新测试"
        case .notTested:
          isReady = true
          statusText = "已配置 Kimi API，等待首次联网测试"
          actionTitle = "测试官方联网"
        }
      } else {
        isReady = false
        statusText = "需要已保存的 Kimi API Key"
        actionTitle = "配置 Kimi API Key"
      }
      return
    }

    isReady = settings.isReady
    if isReady {
      statusText = "已启用 · \(settings.provider.title)"
      actionTitle = "测试连接"
    } else {
      statusText = "配置未完成"
      actionTitle = "完成配置"
    }
  }

  public static func bridgeFailureMessage(statusCode: Int, body: String) -> String {
    let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
    let extractedError: String
    if let data = trimmedBody.data(using: .utf8),
       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let error = object["error"] as? String,
       !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      extractedError = error.trimmingCharacters(in: .whitespacesAndNewlines)
    } else if !trimmedBody.isEmpty {
      extractedError = String(trimmedBody.prefix(240))
    } else {
      extractedError = "没有返回错误正文"
    }
    return "HTTP \(statusCode)：\(extractedError)"
  }
}
