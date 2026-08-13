import Foundation

public enum KimiRuntimeConnectionGuidance {
  public static func apiKeyHint() -> String {
    "填写你在 Moonshot / Kimi 控制台创建的 API Key；如果已经保存过，可以留空。"
  }

  public static func apiKeyExample() -> String {
    "例如：sk-xxxxxxxxxxxxxxxx；不要填写账号密码，也不要填浏览器登录码。"
  }

  public static func baseURLHint(defaultBaseURL: String = KimiRuntimeIdentityStore.defaultBaseURL) -> String {
    "通常保持默认 \(defaultBaseURL)；只有你使用代理、私有网关或官方文档要求时才修改。"
  }

  public static func baseURLExample(defaultBaseURL: String = KimiRuntimeIdentityStore.defaultBaseURL) -> String {
    "例如：\(defaultBaseURL)"
  }

  public static func modelHint(defaultModelID: String = KimiRuntimeIdentityStore.defaultModelID) -> String {
    "先选一个当前账号可用的模型；不确定时先保留 \(defaultModelID)，或者先用默认的 kimi-k2.7-code / kimi-k3，再点击刷新模型列表。"
  }

  public static func modelExample(defaultModelID: String = KimiRuntimeIdentityStore.defaultModelID) -> String {
    "例如：\(defaultModelID)；如果列表暂时为空，也会先提供 kimi-k2.7-code 和 kimi-k3。"
  }

  public static func codeModeHint() -> String {
    "按 device-code 指引在浏览器完成登录；如果你只有 API 额度，请切回 API Key 模式。"
  }

  public static func codeModeExample() -> String {
    "例如：点击“开始 Kimi Code 登录”，在浏览器里完成 device-code 授权，返回后会自动保存。"
  }
}
