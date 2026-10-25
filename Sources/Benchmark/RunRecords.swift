import Foundation

private func utcFormatter(_ pattern: String) -> DateFormatter {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = TimeZone(secondsFromGMT: 0)
  formatter.dateFormat = pattern
  return formatter
}

private let timestampFormatter = utcFormatter("yyyy-MM-dd'T'HH:mm:ss.")
private let runIdentifierFormatter = utcFormatter("yyyyMMdd'T'HHmmss")

private func utcDate(_ date: Date, formatter: DateFormatter) -> String {
  let seconds = floor(date.timeIntervalSince1970)
  let micros = Int((date.timeIntervalSince1970 - seconds) * 1_000_000)
  return formatter.string(from: Date(timeIntervalSince1970: seconds))
    + String(format: "%06dZ", micros)
}

func timestamp(_ date: Date = Date()) -> String { utcDate(date, formatter: timestampFormatter) }

func runIdentifier(host: String, date: Date = Date()) -> String {
  utcDate(date, formatter: runIdentifierFormatter) + "-" + host
}

func createRunDirectory(
  _ settings: RunSettings, runID: String, output: (String) -> Void = { standardOutput($0) }
) throws -> String {
  let directory = path(settings.resultsDir, runID)
  try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
  announceRunDirectory(directory, output: output)
  return directory
}

func repositoryState(_ directory: String) -> JSON {
  guard let root = commandOutput(["git", "rev-parse", "--show-toplevel"], directory: directory),
    (try? resolvePath(root)) == (try? resolvePath(directory))
  else { return ["revision": nil, "dirty": nil] }
  let paths = [":/", ":(top,exclude)Deliverables/Runs", ":(top,exclude)Deliverables/Comparisons"]
  let revision = commandOutput(
    ["git", "log", "-1", "--format=%H", "--"] + paths, directory: directory)
  let status = commandOutput(["git", "status", "--porcelain", "--"] + paths, directory: directory)
  return [
    "revision": .value(revision.flatMap { $0.isEmpty ? nil : $0 }),
    "dirty": status.map { .bool(!$0.isEmpty) } ?? .null,
  ]
}

func manifestRunSettings(_ settings: RunSettings, repeatCount: Int) -> JSON {
  [
    "workdir": ".", "repeat": .integer(Int64(repeatCount)),
    "request_timeout_seconds": .number(settings.requestTimeoutSeconds),
    "cooldown_seconds": .number(settings.cooldownSeconds),
    "max_output_tokens": .unsigned(settings.maxOutputTokens),
    "temperature": .number(settings.temperature),
    "seed": .unsigned(settings.seed), "shuffle_algorithm": .string(shuffleAlgorithm),
    "generation_seed_algorithm": "repeat-v1",
    "cache_conditions": .array(settings.cacheConditions.map(JSON.string)),
    "system_prompt": .string(settings.systemPrompt),
  ]
}

struct RunManifestContext {
  let runID: String
  let host: HostConfig
  let detected: JSON
  let digest: String
  let taskCount: Int
  let repeatCount: Int
}

func runManifest(
  _ config: BenchmarkConfig, context: RunManifestContext,
  targets: [TargetConfig], doctors: [String: DoctorResult]
) throws -> JSON {
  let publishedTargets = targets.map { target -> JSON in
    var value = target.json
    let doctor = doctors[target.id]!
    let keys =
      target.adapter == "ollama"
      ? ["digest", "size_bytes", "format", "family", "parameter_size", "quantization_level"]
      : [
        "command", "args", "isolation_product", "isolation_variables", "status_args",
        "event_schema",
      ]
    var publishedDoctor = doctor.json
    publishedDoctor["metadata"] = .object(doctor.metadata.filter { keys.contains($0.key) })
    publishedDoctor["message"] = .string(doctor.ok ? "ready" : "preflight failed")
    value["doctor"] = publishedDoctor
    value["args"] = .array(redactCLIArguments(target.args).map(JSON.string))
    if let product = products.first(where: { $0.eventSchema == target.eventSchema }) {
      value["isolation"] = [
        "policy_version": .integer(Int64(isolationPolicyVersion)), "product": .string(product.name),
        "profile_root": nil,
        "variables": .array(product.managedVariables.map(JSON.string)),
        "status_args": .array(product.statusArgs.map(JSON.string)),
        "fresh_working_directory_per_process": true,
      ]
    } else {
      value["isolation"] = .null
    }
    return value
  }
  func relative(_ value: String) -> JSON {
    if value == config.run.workdir { return "." }
    return isWithin(value, config.run.workdir)
      ? .string(String(value.dropFirst(config.run.workdir.count + 1))) : .null
  }
  return [
    "run_id": .string(context.runID), "status": "running", "started_at": .string(timestamp()),
    "completed_at": nil,
    "application": [
      "name": "benchmark", "version": .string(benchmarkVersion), "language": "swift",
    ],
    "repository": repositoryState(repositoryRoot),
    "config": ["path": relative(config.sourcePath), "sha256": .string(config.digest)],
    "suite": [
      "path": relative(config.run.suitesDir), "sha256": .string(context.digest),
      "task_count": .integer(Int64(context.taskCount)),
    ],
    "host_id": .string(context.host.id), "host": context.detected, "warnings": [],
    "run_settings": manifestRunSettings(config.run, repeatCount: context.repeatCount),
    "report_settings": ["language": .string(config.language.rawValue)],
    "selection": try .of(config.selection), "targets": .array(publishedTargets),
  ]
}

func targetFingerprint(_ target: TargetConfig, revision: String?, version: String?) -> String {
  let fields = [
    "adapter", "backend", "base_url", "context_window", "inference_location", "model",
    "process_match", "quantization", "command", "args", "prompt_delivery", "event_schema",
  ]
  var identity = JSON.object(target.json.object!.filter { fields.contains($0.key) })
  identity["model_revision"] = .value(revision)
  identity["backend_version"] = .value(version)
  if let product = products.first(where: { $0.eventSchema == target.eventSchema }) {
    identity["isolation_policy_version"] = .integer(Int64(isolationPolicyVersion))
    identity["isolation_product"] = .string(product.name)
  }
  return sha256(Data(identity.serialized().utf8))
}

struct TrialContext {
  let runID: String
  let hostID: String
  let memory: JSON
  let position: Int
  let total: Int
}

func trialIdentifier(
  position: Int, total: Int, target: TargetConfig, task: BenchmarkTask, item: ScheduleItem
) -> String {
  String(format: "%0*d", max(5, String(total).count), position)
    + "__\(task.id)__\(target.id)__\(item.condition)__r\(item.repeatNumber)"
}

func trialBase(
  context: TrialContext, target: TargetConfig, task: BenchmarkTask,
  item: ScheduleItem, doctor: DoctorResult
) -> JSON {
  let revision = doctor.metadata["digest"].flatMap { $0 == .null ? nil : $0.text }
  let trialID = trialIdentifier(
    position: context.position, total: context.total, target: target, task: task, item: item)
  let trial: JSON = [
    "run_id": .string(context.runID), "trial_id": .string(trialID),
    "started_at": .string(timestamp()), "completed_at": nil,
    "host_id": .string(context.hostID),
    "host_memory_bytes": context.memory,
    "target_id": .string(target.id),
    "target_fingerprint": .string(
      targetFingerprint(target, revision: revision, version: doctor.version)),
    "task_id": .string(task.id), "task_category": .string(task.category),
    "repeat": .integer(Int64(item.repeatNumber)),
    "generation_seed": target.adapter == "ollama" ? .integer(Int64(item.repeatNumber)) : .null,
    "adapter": .string(target.adapter), "backend": .value(target.backend),
    "backend_version": .value(doctor.version),
    "inference_location": .string(target.inferenceLocation),
    "model_requested": .string(target.model), "model_revision": .value(revision),
    "quantization": .value(target.quantization), "context_window": .value(target.contextWindow),
    "cache_condition": .string(item.condition),
    "passed": false, "memory_sample_count": 0,
    "model_resolved": nil, "status": nil, "failure_reason": nil, "error_message": nil,
    "score": nil, "score_detail": nil, "wall_time_ms": nil,
    "time_to_first_token_ms": nil, "prompt_eval_ms": nil, "generation_ms": nil, "load_ms": nil,
    "input_tokens": nil, "output_tokens": nil, "output_tokens_per_second": nil,
    "finish_reason": nil, "cost_usd": nil, "peak_backend_rss_bytes": nil,
    "baseline_swap_used_bytes": nil, "peak_swap_used_bytes": nil, "peak_swap_delta_bytes": nil,
    "model_memory_bytes": nil, "model_accelerator_memory_bytes": nil,
    "loaded_context_window": nil, "runtime_quantization": nil,
  ]
  return trial
}

func setFields(_ record: inout JSON, _ fields: JSON) {
  var object = record.object ?? [:]
  object.merge(fields.object ?? [:]) { _, new in new }
  record = .object(object)
}

func completionFields(_ result: GenerationResult, score: ScoreResult, threshold: Double) -> JSON {
  let passed = !result.text.trimmed.isEmpty && score.score >= threshold
  let fields: JSON = [
    "status": "completed", "passed": .bool(passed),
    "failure_reason": passed
      ? .null
      : .string(
        result.text.trimmed.isEmpty && isOutputTruncated(result.finishReason)
          ? "output_truncated" : "evaluation_failed"),
    "error_message": nil, "score": .number(score.score), "score_detail": .string(score.detail),
    "model_resolved": .value(result.resolvedModel),
    "wall_time_ms": .number(result.wallTimeMs),
    "time_to_first_token_ms": .value(result.timeToFirstTokenMs),
    "prompt_eval_ms": .value(result.promptEvalMs), "generation_ms": .value(result.generationMs),
    "load_ms": .value(result.loadMs),
    "input_tokens": .value(result.inputTokens), "output_tokens": .value(result.outputTokens),
    "output_tokens_per_second": .value(result.outputTokensPerSecond),
    "finish_reason": .value(result.finishReason),
    "model_memory_bytes": result.providerMetrics["model_memory_bytes"] ?? .null,
    "model_accelerator_memory_bytes": result.providerMetrics["model_accelerator_memory_bytes"]
      ?? .null,
    "loaded_context_window": result.providerMetrics["loaded_context_window"] ?? .null,
    "runtime_quantization": result.providerMetrics["runtime_quantization"] ?? .null,
  ]
  return fields
}
