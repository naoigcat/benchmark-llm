import Darwin
import Foundation

func selectedTargets(_ config: BenchmarkConfig, requested: [String]) throws -> [TargetConfig] {
  if requested.isEmpty { return config.targets }
  return try requested.map { id in
    guard let target = config.targets.first(where: { $0.id == id }) else {
      throw UsageError(
        message: """
          unknown target ID \(id); --target only accepts IDs listed in Resources/benchmark.json; \
          add the desired catalog IDs there first
          """
      )
    }
    return target
  }
}

private struct TrialExecutionContext {
  let schedule: [ScheduleItem]
  let targets: [TargetConfig]
  let tasks: [BenchmarkTask]
  let doctors: [String: DoctorResult]
  let adapters: [String: any Adapter]
  let runID: String
  let hostID: String
  let memory: JSON
  let cancellation: Cancellation
}

private func executeSchedule(
  _ context: TrialExecutionContext, descriptor: Int32, rawDirectory: String,
  cooldownSeconds: Double
) throws {
  for (index, item) in context.schedule.enumerated() {
    try checkInterrupted(context.cancellation)
    let target = context.targets[item.target]
    let task = context.tasks[item.task]
    let doctor = context.doctors[target.id]!
    var trial = trialBase(
      context: TrialContext(
        runID: context.runID, hostID: context.hostID, memory: context.memory, position: index + 1,
        total: context.schedule.count), target: target, task: task, item: item, doctor: doctor)
    var raw: JSON?
    if doctor.ok {
      (trial, raw) = executeTrial(
        trial, target: target, task: task, condition: item.condition,
        adapter: context.adapters[target.id]!, cancellation: context.cancellation)
    } else {
      setFields(
        &trial,
        [
          "status": "skipped", "passed": false, "failure_reason": "preflight_failed",
          "completed_at": .string(timestamp()),
          "error_message": .string(doctor.message),
        ])
    }
    try recordTrial(trial, raw: raw, descriptor: descriptor, rawDirectory: rawDirectory)
    standardOutput(
      "[\(index + 1)/\(context.schedule.count)] \(target.id) \(task.id) \(item.condition): \(trial["status"].text)"
    )
    try checkInterrupted(context.cancellation)
    try require(
      trial["failure_reason"].string != "cleanup_error",
      "cleanup failed for \(target.id); stopping before the next measurement (see raw records)")
    if doctor.ok && index + 1 < context.schedule.count {
      try cooldown(cooldownSeconds, cancellation: context.cancellation)
    }
  }
}

private struct RunPreparationInput {
  let config: BenchmarkConfig
  let detected: JSON
  let host: HostConfig
  let tasks: [BenchmarkTask]
  let digest: String
  let repeatCount: Int
  let targets: [TargetConfig]
  let servers: OllamaServers
  let warnings: [String]
  let runID: String
  let workspaceRoot: String?
  let cancellation: Cancellation
}

private struct PreparedRun {
  let directory: String
  let rawDirectory: String
  let manifestPath: String
  let fileDescriptor: Int32
  let manifest: JSON
  let adapters: [String: any Adapter]
  let doctors: [String: DoctorResult]
}

func announceRunDirectory(_ directory: String, output: (String) -> Void = { standardOutput($0) }) {
  output("run: \(directory)")
}

private func prepareRun(_ input: RunPreparationInput) throws -> PreparedRun {
  let directory = path(input.config.run.resultsDir, input.runID)
  let rawDirectory = path(directory, "raw")
  var adapters: [String: any Adapter] = [:]
  let cache = DoctorCache()
  let doctors = runPreflights(
    input.targets, host: input.host.id, cancellation: input.cancellation
  ) { target in
    let adapter = try createAdapter(
      target, settings: input.config.run, cancellation: input.cancellation,
      workspaceRoot: input.workspaceRoot)
    adapters[target.id] = adapter
    if let error = input.servers.startupError(target) { return .unavailable(error) }
    return try adapter.doctor(cache: cache)
  }
  try writeJSON(
    .object(doctors.mapValues(\.json)), to: path(rawDirectory, "preflight.json"), mode: 0o600)
  var manifest = try runManifest(
    input.config,
    context: RunManifestContext(
      runID: input.runID, host: input.host, detected: input.detected, digest: input.digest,
      taskCount: input.tasks.count, repeatCount: input.repeatCount),
    targets: input.targets, doctors: doctors)
  manifest["run_settings"]["ollama_server_environment"] = .object(input.servers.environments)
  manifest["warnings"] = .array(input.warnings.map(JSON.string))
  let manifestPath = path(directory, "manifest.json")
  try writeJSON(manifest, to: manifestPath)
  let trialPath = path(directory, "trials.jsonl")
  let fileDescriptor = open(trialPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
  guard fileDescriptor >= 0 else { throw posixError("create trials.jsonl") }
  do {
    guard fsync(fileDescriptor) == 0 else { throw posixError("sync trials.jsonl") }
    try syncDirectory(directory)
  } catch {
    close(fileDescriptor)
    throw error
  }
  return PreparedRun(
    directory: directory, rawDirectory: rawDirectory, manifestPath: manifestPath,
    fileDescriptor: fileDescriptor, manifest: manifest, adapters: adapters, doctors: doctors)
}

/// Keeps a run that stopped during setup reportable: its manifest gets a final status and
/// trials.jsonl exists even though no trial ran.
private func recordSetupFailure(
  _ error: any Error, config: BenchmarkConfig, context: RunManifestContext,
  targets: [TargetConfig], warnings: [String], serverEnvironments: [String: JSON],
  directory: String, cancellation: Cancellation
) {
  let manifestPath = path(directory, "manifest.json")
  var manifest: JSON
  if let published = try? readJSON(manifestPath) {
    manifest = published
  } else {
    let doctors = Dictionary(
      uniqueKeysWithValues: targets.map { ($0.id, DoctorResult.unavailable("run setup failed")) })
    guard
      let created = try? runManifest(config, context: context, targets: targets, doctors: doctors)
    else { return }
    manifest = created
    manifest["run_settings"]["ollama_server_environment"] = .object(serverEnvironments)
    manifest["warnings"] = .array(warnings.map(JSON.string))
  }
  let trials = open(
    path(directory, "trials.jsonl"), O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
  if trials >= 0 { close(trials) }
  let reason = cancellation.isCancelled ? ApiError("interrupted", interrupted: true) : error
  try? finalizeManifest(&manifest, at: manifestPath, executionError: reason)
}

func runBenchmark(
  _ config: BenchmarkConfig, requested: [String] = [], repeatOverride: Int? = nil,
  dryRun: Bool = false, detectedHost: JSON? = nil, cancellation: Cancellation = interruption
) throws -> String? {
  let detected = detectedHost ?? detectHost()
  let host = try selectHost(config.hosts, detected: detected)
  let (tasks, digest) = try loadTasks(at: config.run.suitesDir)
  let targets = try selectedTargets(config, requested: requested)
  let repeatCount = repeatOverride ?? config.run.repeatCount
  let schedule = try buildSchedule(
    targets: targets, taskCount: tasks.count, repeatCount: repeatCount,
    conditions: config.run.cacheConditions, seed: config.run.seed)
  for (index, item) in schedule.enumerated() {
    let filename =
      trialIdentifier(
        position: index + 1, total: schedule.count, target: targets[item.target],
        task: tasks[item.task], item: item) + ".json"
    try require(
      filename.utf8.count <= Int(NAME_MAX),
      "raw filename exceeds \(NAME_MAX) bytes; shorten task ID \(tasks[item.task].id) or target ID \(targets[item.target].id)"
    )
  }
  if dryRun {
    printSchedule(
      schedule, targets: targets, host: host, taskCount: tasks.count, settings: config.run)
    return nil
  }
  let lock = try RunLock(config.run.resultsDir)
  let profileLock = try lockProfiles(for: targets)
  defer { withExtendedLifetime((lock, profileLock)) {} }
  // Signals cancel only the global flag; a caller's own cancellation keeps the handlers as they are.
  if cancellation === interruption { installSignalHandlers() }
  var warnings = memoryPreflightWarnings(targets, host: host.id)
  let runID = runIdentifier(host: host.id)
  let directory = try createRunDirectory(config.run, runID: runID)
  let servers: OllamaServers
  let preparation: PreparedRun
  var serverEnvironments: [String: JSON] = [:]
  do {
    // Inside the setup failure handling, so a failure here still leaves a reportable manifest.
    try syncDirectory(config.run.resultsDir)
    try privateDirectory(path(directory, "raw"))
    servers = try OllamaServers.ensure(
      targets, host: host.id, cancellation: cancellation, logDirectory: path(directory, "raw"))
    serverEnvironments = servers.environments
    warnings += servers.warnings
    for warning in warnings { standardError("warning: \(warning)") }
    let workspaceRoot = try createWorkspaceRoot(for: targets)
    preparation = try prepareRun(
      RunPreparationInput(
        config: config, detected: detected, host: host, tasks: tasks, digest: digest,
        repeatCount: repeatCount, targets: targets,
        servers: servers, warnings: warnings, runID: runID, workspaceRoot: workspaceRoot,
        cancellation: cancellation))
  } catch {
    recordSetupFailure(
      error, config: config,
      context: RunManifestContext(
        runID: runID, host: host, detected: detected, digest: digest,
        taskCount: tasks.count, repeatCount: repeatCount),
      targets: targets, warnings: warnings, serverEnvironments: serverEnvironments,
      directory: directory, cancellation: cancellation)
    // Match the manifest, which recordSetupFailure marks interrupted after a cancellation.
    throw cancellation.isCancelled ? ApiError("interrupted", interrupted: true) : error
  }
  defer { withExtendedLifetime(servers) {} }
  defer { close(preparation.fileDescriptor) }
  var executionError: (any Error)?
  do {
    try executeSchedule(
      TrialExecutionContext(
        schedule: schedule, targets: targets, tasks: tasks, doctors: preparation.doctors,
        adapters: preparation.adapters,
        runID: runID, hostID: host.id, memory: detected["memory_bytes"],
        cancellation: cancellation),
      descriptor: preparation.fileDescriptor, rawDirectory: preparation.rawDirectory,
      cooldownSeconds: config.run.cooldownSeconds)
  } catch { executionError = error }
  var manifest = preparation.manifest
  let cleanupErrors = cleanupAdapters(
    targets, doctors: preparation.doctors, adapters: preparation.adapters,
    cancellation: cancellation)
  if !cleanupErrors.isEmpty {
    recordCleanupErrors(
      cleanupErrors, rawDirectory: preparation.rawDirectory, warnings: &warnings)
    manifest["warnings"] = .array(warnings.map(JSON.string))
  }
  // Keep an earlier failure: an interruption during final cleanup did not cause it.
  if cancellation.isCancelled && executionError == nil {
    executionError = ApiError("interrupted", interrupted: true)
  }
  try finalizeManifest(&manifest, at: preparation.manifestPath, executionError: executionError)
  _ = try generateReport(runs: [preparation.directory], output: preparation.directory)
  return preparation.directory
}

private func recordGeneration(
  _ result: GenerationResult, task: BenchmarkTask, trial: inout JSON, raw: inout JSON,
  cancellation: Cancellation
) throws {
  // Keep the response before scoring so a scorer failure still leaves it to re-score.
  setFields(
    &raw,
    [
      "response": .string(result.text), "provider_metrics": .object(result.providerMetrics),
      "events": .array(result.rawEvents),
    ])
  let score = try scoreResponse(task, response: result.text, cancellation: cancellation)
  setFields(&trial, completionFields(result, score: score, threshold: task.passThreshold))
  raw["score"] = try .of(score)
}

private func recordTrialFailure(_ error: Error, trial: inout JSON, raw: inout JSON) {
  let api = error as? ApiError ?? ApiError(String(describing: error))
  let reason = error is ScoringFailure ? "runner_error" : api.reason
  setFields(
    &trial,
    [
      "status": "error", "passed": false, "failure_reason": .string(reason),
      "error_message": .string(api.description),
    ])
  raw["error"] = [
    "type": .string(reason == "runner_error" ? "ScoringError" : "ApiError"),
    "message": .string(api.description),
  ]
  if !api.providerMetrics.isEmpty { raw["provider_metrics"] = .object(api.providerMetrics) }
}

private func recordCleanupFailure(
  _ error: Error, trial: inout JSON, raw: inout JSON
) {
  let api = error as? ApiError ?? ApiError(String(describing: error))
  if trial["failure_reason"].string != "interrupted" {
    setFields(
      &trial,
      [
        "status": "error", "passed": false,
        "failure_reason": .string(api.isInterrupted ? "interrupted" : "cleanup_error"),
        "error_message": .string(api.description),
      ])
  }
  raw["cleanup_error"] = ["type": "ApiError", "message": .string(api.description)]
}

func executeTrial(
  _ base: JSON, target: TargetConfig, task: BenchmarkTask, condition: String, adapter: any Adapter,
  cancellation: Cancellation = interruption
) -> (JSON, JSON) {
  var trial = base
  var raw: JSON = ["trial_id": trial["trial_id"], "prompt": .string(task.prompt)]
  let sampler = target.adapter == "ollama" ? MemorySampler(matching: target.processMatch) : nil
  sampler?.start()
  let result = Result {
    try adapter.prepare(condition)
    return try adapter.generate(
      task, repeatNumber: Int(trial["repeat"].uint ?? 1))
  }
  let memory = sampler?.stop() ?? MemoryMetrics()
  setFields(&trial, memory.json)
  do {
    let result = try result.get()
    do {
      try recordGeneration(
        result, task: task, trial: &trial, raw: &raw, cancellation: cancellation)
    } catch let error as ApiError where error.isInterrupted {
      throw error
    } catch { throw ScoringFailure(message: "scoring failed: \(error)") }
  } catch {
    recordTrialFailure(error, trial: &trial, raw: &raw)
  }
  do { try adapter.cleanup(condition) } catch {
    recordCleanupFailure(error, trial: &trial, raw: &raw)
  }
  trial["completed_at"] = .string(timestamp())
  return (trial, raw)
}

func cooldown(_ seconds: Double, cancellation: Cancellation = interruption) throws {
  let deadline = monotonicTime() + seconds
  while monotonicTime() < deadline {
    try checkInterrupted(cancellation)
    Thread.sleep(forTimeInterval: min(0.1, max(0, deadline - monotonicTime())))
  }
}

private struct ScoringFailure: Error, CustomStringConvertible {
  let message: String
  var description: String { message }
}

func finalizeManifest(_ manifest: inout JSON, at destination: String, executionError: (any Error)?)
  throws
{
  manifest["status"] = .string(
    (executionError as? ApiError)?.isInterrupted == true
      ? "interrupted" : executionError == nil ? "completed" : "failed")
  manifest["completed_at"] = .string(timestamp())
  let publication = Result { try writeJSON(manifest, to: destination) }
  if let executionError {
    if case .failure(let error) = publication {
      standardError("warning: could not finalize \(destination): \(error)")
    }
    throw executionError
  }
  try publication.get()
}

func runPreflights(
  _ targets: [TargetConfig], host: String, cancellation: Cancellation,
  check: (TargetConfig) throws -> DoctorResult
) -> [String: DoctorResult] {
  var doctors: [String: DoctorResult] = [:]
  for target in targets {
    if cancellation.isCancelled {
      doctors[target.id] = .unavailable("preflight interrupted")
    } else if !target.eligible(on: host) {
      doctors[target.id] = .unavailable("target is not eligible for host \(host)")
    } else {
      do { doctors[target.id] = try check(target) } catch {
        doctors[target.id] = .unavailable(
          "doctor failed: \(redactCLIText(String(describing: error)))")
      }
    }
    if doctors[target.id]?.ok != true {
      standardOutput("target \(target.id): SKIP (preflight failed; see raw/preflight.json)")
    }
  }
  return doctors
}

private func printSchedule(
  _ schedule: [ScheduleItem], targets: [TargetConfig], host: HostConfig, taskCount: Int,
  settings: RunSettings
) {
  standardOutput(
    """
    host: \(host.id)\ntasks: \(taskCount)\ntargets: \(targets.count)\nscheduled trials: \
    \(schedule.count) (\(schedule.filter { targets[$0.target].eligible(on: host.id) }.count) \
    eligible)\ntrial-order seed: \(settings.seed)
    """
  )
  for target in targets {
    standardOutput(
      """
      - \(target.id): \(target.cacheConditions(settings.cacheConditions).joined(separator: ", ")) \
      (\(target.eligible(on: host.id) ? "eligible" : "skipped"))
      """
    )
  }
}

private func recordTrial(_ trial: JSON, raw: JSON?, descriptor: Int32, rawDirectory: String) throws
{
  var shared = trial
  shared["error_message"] = .null
  shared["score_detail"] = .null
  let data = Data((shared.serialized() + "\n").utf8)
  try writeAll(data, to: descriptor, label: "trial")
  guard fsync(descriptor) == 0 else { throw posixError("sync trial") }
  if let raw {
    try writeJSON(raw, to: path(rawDirectory, trial["trial_id"].text + ".json"), mode: 0o600)
  }
}

private func cleanupAdapters(
  _ targets: [TargetConfig], doctors: [String: DoctorResult], adapters: [String: any Adapter],
  cancellation: Cancellation
) -> [JSON] {
  var cleanupErrors: [JSON] = []
  for target in targets where target.adapter == "ollama" && doctors[target.id]?.ok == true {
    if cancellation.isCancelled { break }
    do { try adapters[target.id]!.cleanup("cold") } catch {
      cleanupErrors.append(.string("final cleanup failed for \(target.id): \(error)"))
    }
  }
  return cleanupErrors
}

private func recordCleanupErrors(
  _ cleanupErrors: [JSON], rawDirectory: String, warnings: inout [String]
) {
  warnings.append(
    "\(cleanupErrors.count) final cleanup failures; details are in the local raw/cleanup.json")
  do {
    try writeJSON(.array(cleanupErrors), to: path(rawDirectory, "cleanup.json"), mode: 0o600)
  } catch {
    warnings.append("Final cleanup diagnostics could not be saved to the local raw/cleanup.json")
  }
}
