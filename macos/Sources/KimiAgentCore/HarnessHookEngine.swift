import Foundation

public struct HarnessHookRequest: Sendable {
  public let event: HookEvent
  public let toolID: String?
  public let arguments: [String: String]

  public init(event: HookEvent, toolID: String? = nil, arguments: [String: String] = [:]) {
    self.event = event
    self.toolID = toolID
    self.arguments = arguments
  }
}

public enum HarnessHookDecision: Sendable {
  case allow
  case deny(reason: String)
  case modify(arguments: [String: String])
  case injectContext([String])
  case askUser(reason: String)
  case retry(reason: String)
  case skip(reason: String)
  case asynchronous(context: [String] = [])
}

public enum HarnessHookAction: String, Codable, Sendable {
  case allow
  case deny
  case modify
  case injectContext
  case askUser
  case retry
  case skip
  case asynchronous
}

public struct HarnessHookDefinition: @unchecked Sendable, Identifiable {
  public let id: UUID
  public let event: HookEvent
  public let priority: Int
  public let handler: @Sendable (HarnessHookRequest) -> HarnessHookDecision

  public init(id: UUID = UUID(), event: HookEvent, priority: Int = 0, handler: @escaping @Sendable (HarnessHookRequest) -> HarnessHookDecision) {
    self.id = id
    self.event = event
    self.priority = priority
    self.handler = handler
  }
}

public struct HarnessHookResolution: Sendable {
  public let action: HarnessHookAction
  public let isAllowed: Bool
  public let denialReason: String?
  public let arguments: [String: String]
  public let context: [String]
  public let auditHookIDs: [UUID]

  public init(isAllowed: Bool, denialReason: String? = nil, arguments: [String: String], context: [String], auditHookIDs: [UUID]) {
    self.action = isAllowed ? .allow : .deny
    self.isAllowed = isAllowed
    self.denialReason = denialReason
    self.arguments = arguments
    self.context = context
    self.auditHookIDs = auditHookIDs
  }

  public init(action: HarnessHookAction, isAllowed: Bool, denialReason: String? = nil, arguments: [String: String], context: [String], auditHookIDs: [UUID]) {
    self.action = action
    self.isAllowed = isAllowed
    self.denialReason = denialReason
    self.arguments = arguments
    self.context = context
    self.auditHookIDs = auditHookIDs
  }
}

/// Pure decision hook layer. Process/HTTP hooks should be adapted into these
/// closures by a worker, which prevents them from directly bypassing the
/// harness permission and effect journal boundaries.
public actor HarnessHookEngine {
  private let hooks: [HarnessHookDefinition]

  public init(hooks: [HarnessHookDefinition]) {
    self.hooks = hooks
  }

  public func evaluate(_ request: HarnessHookRequest) -> HarnessHookResolution {
    let matched = hooks.enumerated()
      .filter { $0.element.event == request.event }
      .sorted { lhs, rhs in
        lhs.element.priority == rhs.element.priority ? lhs.offset < rhs.offset : lhs.element.priority > rhs.element.priority
      }
      .map(\.element)
    var arguments = request.arguments
    var context: [String] = []
    var audit: [UUID] = []
    var action: HarnessHookAction = .allow
    for hook in matched {
      audit.append(hook.id)
      switch hook.handler(HarnessHookRequest(event: request.event, toolID: request.toolID, arguments: arguments)) {
      case .allow:
        continue
      case let .deny(reason):
        return HarnessHookResolution(action: .deny, isAllowed: false, denialReason: reason, arguments: arguments, context: context, auditHookIDs: audit)
      case let .modify(replacement):
        action = .modify
        arguments = replacement
      case let .injectContext(additions):
        action = .injectContext
        context.append(contentsOf: additions.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
      case let .askUser(reason):
        return HarnessHookResolution(action: .askUser, isAllowed: false, denialReason: reason, arguments: arguments, context: context, auditHookIDs: audit)
      case let .retry(reason):
        action = .retry
        context.append("Hook 请求重试：\(reason)")
      case let .skip(reason):
        return HarnessHookResolution(action: .skip, isAllowed: true, denialReason: reason, arguments: arguments, context: context, auditHookIDs: audit)
      case let .asynchronous(additions):
        action = .asynchronous
        context.append(contentsOf: additions)
      }
    }
    return HarnessHookResolution(action: action, isAllowed: true, arguments: arguments, context: context, auditHookIDs: audit)
  }
}
