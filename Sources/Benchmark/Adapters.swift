import Foundation

protocol Adapter {
  func doctor(cache: DoctorCache) throws -> DoctorResult
  func prepare(_ condition: String) throws
  func cleanup(_ condition: String) throws
  func generate(_ task: BenchmarkTask, repeatNumber: Int) throws
    -> GenerationResult
}

extension Adapter {
  func prepare(_ condition: String) throws {}
  func cleanup(_ condition: String) throws {}
}

final class DoctorCache {
  var cli: [String: DoctorResult] = [:]
  var ollama: [String: Result<(JSON, JSON), any Error>] = [:]
}

func createAdapter(
  _ target: TargetConfig, settings: RunSettings, cancellation: Cancellation? = nil,
  workspaceRoot: String? = nil
) throws -> any Adapter {
  try target.validate()
  if target.adapter == "ollama" {
    return OllamaAdapter(target: target, settings: settings, cancellation: cancellation)
  }
  let adapter = CLIAgentAdapter(target: target, settings: settings, cancellation: cancellation)
  adapter.workspaceOverride = workspaceRoot
  return adapter
}

final class CLIAgentAdapter: Adapter {
  let target: TargetConfig
  let settings: RunSettings
  let cancellation: Cancellation?
  var profilesOverride: String?
  var workspaceOverride: String?
  /// Tests supply the operator's environment here instead of mutating the shared process state.
  var inheritedEnvironmentOverride: [String: String]?
  init(target: TargetConfig, settings: RunSettings, cancellation: Cancellation? = nil) {
    self.target = target
    self.settings = settings
    self.cancellation = cancellation
  }
  var product: Product {
    get throws {
      guard let product = products.first(where: { $0.eventSchema == target.eventSchema }) else {
        throw ApiError("unsupported CLI event schema")
      }
      return product
    }
  }
  private func run(
    _ args: [String], input: String? = nil, onLine: ((String, Double) throws -> Void)? = nil
  ) throws -> ProcessResult {
    let product = try product
    let profiles = try profilesOverride ?? defaultProfilesDirectory()
    try product.createProfile(profiles, secureParent: profilesOverride == nil)
    let workspace = try Workspace(root: workspaceOverride ?? createWorkspaceRoot())
    defer { withExtendedLifetime(workspace) {} }
    return try runProcess(
      target.command ?? product.command, args: args, directory: workspace.directory,
      environment: product.environment(
        profiles, inherited: inheritedEnvironmentOverride ?? ProcessInfo.processInfo.environment),
      input: input,
      timeout: settings.requestTimeoutSeconds, cancellation: cancellation, onLine: onLine)
  }
  func doctor(cache: DoctorCache) throws -> DoctorResult {
    let product = try product
    let key = product.name + "\u{0}" + (target.command ?? product.command)
    if var result = cache.cli[key] {
      if result.resolvedModel != nil { result.resolvedModel = target.model }
      if result.metadata["args"] != nil {
        result.metadata["args"] = .array(redactCLIArguments(target.args).map(JSON.string))
      }
      return result
    }
    let result = try probe(product)
    cache.cli[key] = result
    return result
  }
  private func probe(_ product: Product) throws -> DoctorResult {
    let profiles = try profilesOverride ?? defaultProfilesDirectory()
    let existed = product.profileExists(profiles)
    let version: ProcessResult
    do { version = try run(["--version"]) } catch {
      return .unavailable(redactCLIText(String(describing: error)))
    }
    let checked = DoctorResult(
      ok: true,
      version: version.output.components(separatedBy: "\n").first(where: { !$0.trimmed.isEmpty })
        .map(redactCLIText), resolvedModel: target.model,
      metadata: [
        "command": .string(target.command ?? product.command),
        "args": .array(redactCLIArguments(target.args).map(JSON.string)),
        "isolation_product": .string(product.name),
        "isolation_variables": .array(product.managedVariables.map(JSON.string)),
        "status_args": .array(product.statusArgs.map(JSON.string)),
        "event_schema": .string(product.eventSchema),
      ], message: "ready")
    if !version.success {
      return checked.failed(
        version.output.isEmpty
          ? "CLI exited with status \(version.status)" : redactCLIText(version.output))
    }
    let signIn = "sign the benchmark profile in with `mise run execute login \(product.name)`"
    if !existed {
      return checked.failed(
        "no benchmark profile prepared under the current isolation policy for \(product.name); \(signIn)"
      )
    }
    let status: ProcessResult
    do { status = try run(product.statusArgs) } catch {
      return checked.failed(redactCLIText(String(describing: error)))
    }
    switch authenticationState(product, status: status) {
    case .authenticated: return checked
    case .checkFailed: return checked.failed("authentication check failed; \(signIn)")
    case .notAuthenticated:
      return checked.failed("benchmark profile is not authenticated; \(signIn)")
    case .unrecognized:
      return checked.failed(
        "authentication check did not report \(product.authenticatedField ?? "a status"); the pinned CLI version may have changed its status output"
      )
    }
  }
  func generate(_ task: BenchmarkTask, repeatNumber: Int) throws
    -> GenerationResult
  {
    let args = target.args.map { $0.replacingOccurrences(of: "{model}", with: target.model) }
    let input =
      settings.systemPrompt.isEmpty ? task.prompt : settings.systemPrompt + "\n\n" + task.prompt
    try require(target.promptDelivery == "stdin", "unsupported CLI prompt delivery")
    let parser = try EventAccumulator(schema: product.eventSchema, model: target.model)
    do {
      let process = try run(args, input: input) { try parser.handle($0, at: $1) }
      parser.metrics["cli_cleanup_ms"] = .number(process.cleanupMS)
      if !process.success {
        throw ApiError("CLI exited with status \(process.status): \(redactCLIText(process.stderr))")
      }
      try require(
        parser.hasResponse,
        "CLI completed without an assistant response"
          + (process.stderr.isEmpty ? "" : ": \(redactCLIText(process.stderr))"))
      return GenerationResult(
        text: parser.text, resolvedModel: parser.model,
        wallTimeMs: (process.ended - process.started) * 1000,
        timeToFirstTokenMs: parser.firstTextAt.map { ($0 - process.started) * 1000 },
        inputTokens: parser.inputTokens, outputTokens: parser.outputTokens,
        finishReason: parser.finishReason, providerMetrics: parser.metrics,
        rawEvents: parser.events)
    } catch {
      var api = error as? ApiError ?? ApiError(redactCLIText(String(describing: error)))
      api.providerMetrics.merge(parser.metrics) { _, new in new }
      throw api
    }
  }
}
