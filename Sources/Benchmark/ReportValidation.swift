import Foundation

struct ScheduleShape {
  var taskCount: Int
  var repeatCount: Int
  var conditions: [String: Set<String>]
  var total: Int
}

func isHexDigest(_ value: String) -> Bool {
  value.utf8.count == 64
    && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

func positiveInteger(_ value: JSON, _ name: String) throws -> Int {
  guard let unsigned = value.uint, unsigned > 0, let integer = Int(exactly: unsigned) else {
    throw BenchmarkError("manifest \(name) must be a positive integer")
  }
  return integer
}

func scheduleShape(_ manifest: JSON) throws -> ScheduleShape {
  let tasks = try positiveInteger(manifest["suite"]["task_count"], "task_count")
  let repeats = try positiveInteger(manifest["run_settings"]["repeat"], "repeat")
  let configured = try strings(
    manifest["run_settings"]["cache_conditions"], "manifest cache_conditions")
  try require(
    !configured.isEmpty && configured.allSatisfy { ["cold", "warm"].contains($0) }
      && Set(configured).count == configured.count,
    "manifest cache_conditions must contain distinct cold or warm strings")
  guard let targets = manifest["targets"].array, !targets.isEmpty else {
    throw BenchmarkError("manifest targets must be a non-empty array")
  }
  var conditions: [String: Set<String>] = [:]
  for target in targets {
    guard let id = target["id"].string, !id.isEmpty else {
      throw BenchmarkError("manifest target has no ID")
    }
    try require(conditions[id] == nil, "manifest has duplicate target ID \(id)")
    switch (target["adapter"].string, target["inference_location"].string) {
    case ("ollama", "local"):
      try requireLoopbackEndpoint(target["base_url"].string ?? "")
      conditions[id] = Set(configured)
    case ("cli-agent", "remote"): conditions[id] = ["provider-managed"]
    default:
      throw BenchmarkError(
        "manifest target \(id) has an unsupported inference_location/adapter combination")
    }
  }
  let count = conditions.values.reduce(0) { $0 + $1.count }
  let (repeatedTasks, repeatOverflow) = tasks.multipliedReportingOverflow(by: repeats)
  let (total, totalOverflow) = repeatedTasks.multipliedReportingOverflow(by: count)
  try require(!repeatOverflow && !totalOverflow, "manifest trial count is too large")
  return ScheduleShape(taskCount: tasks, repeatCount: repeats, conditions: conditions, total: total)
}

private struct RunValidationState {
  let manifest: JSON
  let shape: ScheduleShape
  let targets: [String: JSON]
  var trialIDs = Set<String>()
  var tuples = Set<[String]>()
  var taskIDs = Set<String>()
  var fingerprints: [String: String] = [:]

  init(manifest: JSON, shape: ScheduleShape) {
    self.manifest = manifest
    self.shape = shape
    targets = Dictionary(
      uniqueKeysWithValues: manifest["targets"].array!.map { ($0["id"].text, $0) })
  }
  /// Every identifying field is rejected when absent by the check that reads it: a missing value
  /// fails the manifest comparison, the target lookup, the digest, integer, or status checks.
  mutating func validate(_ trial: JSON) throws {
    try validateIdentity(trial)
    let (targetID, target) = try target(for: trial)
    try validateTargetFields(trial, target: target)
    try validateTrialID(trial)
    try validateFingerprint(trial, targetID: targetID)
    guard let taskID = trial["task_id"].string, !taskID.isEmpty else {
      throw BenchmarkError("trial has no task_id")
    }
    try validateSchedule(trial, targetID: targetID, taskID: taskID)
    taskIDs.insert(taskID)
    guard let passed = trial["passed"].bool else {
      throw BenchmarkError("trial passed field is not boolean")
    }
    try require(!passed || trial["status"].string == "completed", "non-completed trial cannot pass")
    try validateTrialMetrics(trial)
  }
  private func validateIdentity(_ trial: JSON) throws {
    try require(trial.object != nil, "trial must be a JSON object")
    try require(trial["run_id"] == manifest["run_id"], "trial run_id does not match manifest")
    try require(trial["host_id"] == manifest["host_id"], "trial host_id does not match manifest")
    try require(
      trial["host_memory_bytes"].equivalent(to: manifest["host"]["memory_bytes"]),
      "trial host memory does not match manifest")
  }
  private func target(for trial: JSON) throws -> (String, JSON) {
    guard let targetID = trial["target_id"].string, let target = targets[targetID] else {
      throw BenchmarkError("trial target_id is not declared by manifest")
    }
    return (targetID, target)
  }
  private func validateTargetFields(_ trial: JSON, target: JSON) throws {
    for (trialField, targetField) in [
      ("adapter", "adapter"), ("backend", "backend"), ("inference_location", "inference_location"),
      ("model_requested", "model"), ("quantization", "quantization"),
      ("context_window", "context_window"),
    ] {
      try require(
        trial[trialField].equivalent(to: target[targetField]),
        "trial \(trialField) does not match manifest target")
    }
  }
  private mutating func validateTrialID(_ trial: JSON) throws {
    guard let trialID = trial["trial_id"].string, !trialID.isEmpty else {
      throw BenchmarkError("trial has no trial_id")
    }
    try require(trialIDs.insert(trialID).inserted, "duplicate trial_id \(trialID)")
  }
  private mutating func validateFingerprint(_ trial: JSON, targetID: String) throws {
    let fingerprint = trial["target_fingerprint"].string ?? ""
    try require(
      isHexDigest(fingerprint),
      "trial target_fingerprint is not a 64-character lowercase hexadecimal string")
    try require(
      fingerprints[targetID] == nil || fingerprints[targetID] == fingerprint,
      "trials contain inconsistent target_fingerprint values")
    fingerprints[targetID] = fingerprint
  }
  private mutating func validateSchedule(
    _ trial: JSON, targetID: String, taskID: String
  ) throws {
    let repeatNumber = try positiveInteger(trial["repeat"], "trial repeat")
    try require(repeatNumber <= shape.repeatCount, "trial repeat exceeds manifest")
    try require(
      ["completed", "error", "skipped"].contains(trial["status"].string ?? ""),
      "invalid trial status")
    let condition = trial["cache_condition"].string ?? ""
    try require(
      shape.conditions[targetID]!.contains(condition),
      "cache_condition is not scheduled for target \(targetID)")
    try require(
      tuples.insert([targetID, taskID, String(repeatNumber), condition]).inserted,
      "duplicate scheduled trial tuple")
  }
  /// Tuples are unique and in range for repeat and cache condition, so with at most taskCount task
  /// IDs no target exceeds its schedule, and a completed run's `total` trials cover every tuple.
  func finish() throws {
    try require(
      taskIDs.count <= shape.taskCount, "run contains more task IDs than manifest declares")
  }
}

func validateRun(_ manifest: JSON, trials: [JSON]) throws {
  try validateManifest(manifest)
  let shape = try scheduleShape(manifest)
  let completed = manifest["status"].string == "completed"
  try require(
    completed ? trials.count == shape.total : trials.count <= shape.total,
    "run has \(trials.count) trials but manifest schedules \(shape.total)")
  var state = RunValidationState(manifest: manifest, shape: shape)
  for trial in trials { try state.validate(trial) }
  try state.finish()
}

func validateTrialMetrics(_ trial: JSON) throws {
  if trial["score"] != .null {
    try require(
      trial["score"].double.map { $0.isFinite && (0...1).contains($0) } ?? false,
      "trial score must be a number between 0 and 1")
  }
  for key in [
    "wall_time_ms", "time_to_first_token_ms", "prompt_eval_ms", "generation_ms", "load_ms",
    "output_tokens_per_second", "cost_usd",
  ] where trial[key] != .null {
    try require(nonnegative(trial[key]) != nil, "trial \(key) must be a non-negative number")
  }
  for key in [
    "host_memory_bytes", "context_window", "input_tokens", "output_tokens",
    "peak_backend_rss_bytes", "baseline_swap_used_bytes", "peak_swap_used_bytes",
    "peak_swap_delta_bytes", "model_memory_bytes", "model_accelerator_memory_bytes",
    "loaded_context_window",
  ] where trial[key] != .null {
    try require(trial[key].uint != nil, "trial \(key) must be a non-negative integer")
  }
  if let value = trial.object?["memory_sample_count"] {
    try require(value.uint != nil, "trial memory_sample_count must be a non-negative integer")
  }
}

private func trialTuple(_ trial: JSON) -> [String] {
  conditionKey(trial) + [trial["task_id"].text, trial["repeat"].text]
}

/// A target skipped in one run (for example before sign-in) may be measured by a later run;
/// keep the measurement, and keep one skip only while no run measured that tuple.
/// The fingerprint is left out: a skip records no model digest or backend version, so its
/// fingerprint rarely matches the later measurement.
func droppingSupersededSkips(_ trials: [JSON]) -> [JSON] {
  let skipped = { (trial: JSON) in trial["status"].string == "skipped" }
  let key = { (trial: JSON) in
    ["host_id", "target_id", "cache_condition", "task_id", "repeat"].map { trial[$0].text }
  }
  var seen = Set(trials.filter { !skipped($0) }.map(key))
  return trials.filter { !skipped($0) || seen.insert(key($0)).inserted }
}

func validateCombinedRuns(_ manifests: [JSON], trials: [JSON]) throws {
  try require(
    Set(manifests.map { $0["run_id"].text }).count == manifests.count,
    "run directories contain duplicate run IDs")
  func same(_ values: [JSON], _ message: String) throws {
    try require(Set(values.map { Data($0.serialized().utf8) }).count <= 1, message)
  }
  try same(
    manifests.map { $0["suite"]["sha256"] }, "run directories use different suite SHA-256 values")
  try same(
    manifests.map { $0["repository"]["revision"] },
    "run directories use different repository revisions")
  for key in [
    "request_timeout_seconds", "cooldown_seconds", "max_output_tokens", "temperature", "seed",
    "shuffle_algorithm", "generation_seed_algorithm", "system_prompt",
  ] {
    try same(
      manifests.map { $0["run_settings"][key] },
      "run directories use different request or generation settings: \(key)")
  }
  for key in ["selection", "application"] {
    try same(manifests.map { $0[key] }, "run directories use different \(key) settings")
  }
  for group in Dictionary(grouping: manifests, by: { $0["host_id"].text }).values {
    for key in ["chip", "memory_bytes", "hardware_model", "os_version", "architecture"] {
      try same(
        group.map { $0["host"][key] },
        "host ID maps to different hardware or macOS across runs: \(key)")
    }
  }
  // Each run checks its own tuples; the same repeat in two runs would be counted twice.
  var tuples = Set<[String]>()
  for trial in trials {
    try require(
      tuples.insert(trialTuple(trial)).inserted,
      "run directories measure the same host/target/task/repeat/cache tuple more than once")
  }
  for group in Dictionary(grouping: trials, by: conditionKey).values {
    for key in [
      "model_resolved", "model_revision", "runtime_quantization", "loaded_context_window",
    ] {
      let values = group.map { $0[key] }.filter { $0 != .null }
      try require(
        values.allSatisfy { key == "loaded_context_window" ? $0.uint != nil : $0.string != nil },
        "trial \(key) has an invalid type")
      try same(values, "trials contain mixed \(key)")
    }
  }
}

private func validateManifest(_ manifest: JSON) throws {
  try require(manifest.object != nil, "manifest must be a JSON object")
  try require(
    manifest["application"]["name"] == "benchmark"
      && manifest["application"]["language"] == "swift", "manifest must be produced by Benchmark")
  try require(
    ReportLanguage(rawValue: manifest["report_settings"]["language"].string ?? "") != nil,
    "manifest must declare a valid report language")
  for key in [
    "minimum_pass_rate", "minimum_median_tokens_per_second", "maximum_peak_swap_delta_gib",
    "maximum_backend_memory_fraction",
  ] {
    try require(manifest["selection"][key].double != nil, "manifest must declare selection.\(key)")
  }

  try require(
    ["completed", "failed", "interrupted", "running"].contains(manifest["status"].string ?? ""),
    "run has an invalid status")
  try require(
    !(manifest["run_id"].string ?? "").isEmpty && manifest["host_id"].string != nil,
    "manifest has no run_id or host_id")
  for key in ["repository", "suite", "host", "run_settings", "selection"] {
    try require(manifest[key].object != nil, "manifest field \(key) is not an object")
  }
  try require(
    isHexDigest(manifest["suite"]["sha256"].string ?? ""), "manifest has an invalid suite SHA-256")
}
