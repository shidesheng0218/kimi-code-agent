import Foundation

/// Retries only provider failures that happen before the first model event.
/// Retrying a partially emitted stream would duplicate assistant text or tool
/// deltas, so once a response has started the original error is propagated.
public struct RetryingHarnessModelProvider: HarnessModelProvider {
  public let base: any HarnessModelProvider
  public let maxAttempts: Int
  public let backoffNanoseconds: UInt64

  public init(
    base: any HarnessModelProvider,
    maxAttempts: Int = 3,
    backoffNanoseconds: UInt64 = 100_000_000
  ) {
    self.base = base
    self.maxAttempts = max(1, maxAttempts)
    self.backoffNanoseconds = backoffNanoseconds
  }

  public func stream(
    context: HarnessProviderContext,
    tools: [ToolDefinition],
    signal: AsyncStream<Void>?
  ) async throws -> AsyncThrowingStream<HarnessModelEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        var attempt = 0
        while attempt < maxAttempts {
          attempt += 1
          var emitted = false
          do {
            let source = try await base.stream(context: context, tools: tools, signal: signal)
            for try await event in source {
              emitted = true
              continuation.yield(event)
            }
            continuation.finish()
            return
          } catch {
            if emitted || attempt >= maxAttempts || error is CancellationError {
              continuation.finish(throwing: error)
              return
            }
            if backoffNanoseconds > 0 {
              try? await Task.sleep(nanoseconds: backoffNanoseconds * UInt64(attempt))
            }
          }
        }
        continuation.finish(throwing: CancellationError())
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

public struct RetryingHarnessConversationProvider: HarnessConversationProvider {
  public let base: any HarnessConversationProvider
  public let maxAttempts: Int
  public let backoffNanoseconds: UInt64

  public init(
    base: any HarnessConversationProvider,
    maxAttempts: Int = 3,
    backoffNanoseconds: UInt64 = 100_000_000
  ) {
    self.base = base
    self.maxAttempts = max(1, maxAttempts)
    self.backoffNanoseconds = backoffNanoseconds
  }

  public func stream(
    request: HarnessConversationRequest,
    tools: [ToolDefinition],
    signal: AsyncStream<Void>?
  ) async throws -> AsyncThrowingStream<HarnessConversationEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        var attempt = 0
        while attempt < maxAttempts {
          attempt += 1
          var emitted = false
          do {
            let source = try await base.stream(request: request, tools: tools, signal: signal)
            for try await event in source {
              emitted = true
              continuation.yield(event)
            }
            continuation.finish()
            return
          } catch {
            if emitted || attempt >= maxAttempts || error is CancellationError {
              continuation.finish(throwing: error)
              return
            }
            if backoffNanoseconds > 0 {
              try? await Task.sleep(nanoseconds: backoffNanoseconds * UInt64(attempt))
            }
          }
        }
        continuation.finish(throwing: CancellationError())
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
