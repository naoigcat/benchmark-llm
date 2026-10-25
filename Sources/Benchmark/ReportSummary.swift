import Foundation

func conditionKey(_ trial: JSON) -> [String] {
  [
    trial["host_id"].text, trial["target_id"].text,
    trial["target_fingerprint"].string ?? "", trial["cache_condition"].text,
  ]
}

func percentile(_ values: [Double], _ percentile: Double) -> Double? {
  let values = values.sorted()
  guard !values.isEmpty else { return nil }
  let position = Double(values.count - 1) * percentile
  let lower = Int(position.rounded(.down))
  let upper = Int(position.rounded(.up))
  return values[lower] + (values[upper] - values[lower]) * (position - Double(lower))
}

func single(_ values: [JSON]) -> JSON {
  let values = values.filter { $0 != .null }
  return values.first ?? .null
}

private struct SummaryGroup {
  let key: [String]
  let recorded: [JSON]
  let first: JSON
  let attempted: [JSON]
  let completed: [JSON]
  let passed: Int
}

private func baseSummaryRow(_ group: SummaryGroup) -> JSON {
  [
    "host_id": .string(group.key[0]), "target_id": .string(group.key[1]),
    "target_fingerprint": .string(group.key[2]), "cache_condition": .string(group.key[3]),
    "model_requested": group.first["model_requested"], "adapter": group.first["adapter"],
    "scheduled_trials": .integer(Int64(group.recorded.count)),
    "attempted_trials": .integer(Int64(group.attempted.count)),
    "completed_trials": .integer(Int64(group.completed.count)),
    "passed_trials": .integer(Int64(group.passed)),
    "truncated_trials": .integer(
      Int64(group.attempted.filter { isOutputTruncated($0["finish_reason"].string) }.count)),
    "timeout_trials": .integer(
      Int64(group.attempted.filter { $0["failure_reason"].string == "timeout" }.count)),
    "pass_rate": group.attempted.isEmpty
      ? .null : .number(Double(group.passed) / Double(group.attempted.count)),
  ]
}

private func addBasicSummaryMetrics(_ row: inout JSON, group: SummaryGroup) {
  let scores = group.completed.compactMap { $0["score"].double }
  row["mean_score"] = scores.isEmpty ? .null : .number(scores.reduce(0, +) / Double(scores.count))
  for (name, source) in [
    ("median_wall_time_ms", "wall_time_ms"),
    ("median_output_tokens_per_second", "output_tokens_per_second"),
  ] {
    row[name] = .value(percentile(group.completed.compactMap { $0[source].double }, 0.5))
  }
}

/// An unknown peak in any attempt may have been the largest, so the row's peak becomes unknown.
private func knownPeaks(_ group: SummaryGroup, _ source: String) -> [UInt64]? {
  let peaks = group.attempted.map { $0[source].uint }
  return peaks.contains(nil) ? nil : peaks.compactMap { $0 }
}

private func addDetailedSummaryMetrics(_ row: inout JSON, group: SummaryGroup) {
  row["completion_rate"] =
    group.attempted.isEmpty
    ? .null : .number(Double(group.completed.count) / Double(group.attempted.count))
  for (name, source, fraction) in [
    ("median_ttft_ms", "time_to_first_token_ms", 0.5), ("median_load_ms", "load_ms", 0.5),
    ("p90_wall_time_ms", "wall_time_ms", 0.9),
  ] {
    row[name] = .value(percentile(group.completed.compactMap { $0[source].double }, fraction))
  }
  for (name, source) in [
    ("p90_peak_backend_rss_bytes", "peak_backend_rss_bytes"),
    ("p90_peak_swap_delta_bytes", "peak_swap_delta_bytes"),
  ] {
    row[name] = .value(
      knownPeaks(group, source).flatMap { percentile($0.map(Double.init), 0.9) }.map {
        UInt64(exactly: $0.rounded()) ?? .max
      })
  }
  for (name, source) in [
    ("max_peak_backend_rss_bytes", "peak_backend_rss_bytes"),
    ("max_peak_swap_delta_bytes", "peak_swap_delta_bytes"),
  ] { row[name] = .value(knownPeaks(group, source)?.max()) }
  for (name, source) in [
    ("max_model_memory_bytes", "model_memory_bytes"),
    ("max_model_accelerator_memory_bytes", "model_accelerator_memory_bytes"),
  ] { row[name] = .value(group.completed.compactMap { $0[source].uint }.max()) }
}

private func addSummaryMetadata(_ row: inout JSON, group: SummaryGroup) {
  for name in [
    "host_memory_bytes", "model_revision", "inference_location", "backend", "backend_version",
  ] { row[name] = group.first[name] }
  row["model_resolved"] = single(group.completed.map { $0["model_resolved"] })
  for (name, source) in [
    ("quantization", "runtime_quantization"), ("context_window", "loaded_context_window"),
  ] {
    let actual = single(group.completed.map { $0[source] })
    row[name] = actual == .null ? group.first[name] : actual
  }
}

private func summaryRow(_ group: SummaryGroup, byCategory: Bool) -> JSON {
  var row = baseSummaryRow(group)
  addBasicSummaryMetrics(&row, group: group)
  if byCategory {
    row["task_category"] = .string(group.key[4])
    return row
  }
  addDetailedSummaryMetrics(&row, group: group)
  addSummaryMetadata(&row, group: group)
  return row
}

func summarize(_ trials: [JSON], byCategory: Bool = false) -> [JSON] {
  let groups = Dictionary(grouping: trials) { trial in
    let category = trial["task_category"].truthy ? trial["task_category"].text : "unknown"
    return (conditionKey(trial) + (byCategory ? [category] : [])).map { Data($0.utf8) }
  }
  return groups.keys.sorted {
    $0.lexicographicallyPrecedes($1, by: { $0.lexicographicallyPrecedes($1) })
  }.map { byteKey in
    let key = byteKey.map { String(bytes: $0, encoding: .utf8) ?? "" }
    let recorded = groups[byteKey]!
    let first = recorded[0]
    let attempted = recorded.filter { $0["status"].string != "skipped" }
    let completed = attempted.filter { $0["status"].string == "completed" }
    let passed = attempted.filter { $0["passed"].bool == true }.count
    return summaryRow(
      SummaryGroup(
        key: key, recorded: recorded, first: first, attempted: attempted, completed: completed,
        passed: passed),
      byCategory: byCategory)
  }
}

/// Leftover skips keep their own fingerprint, so they form a separate row; any row of the same
/// host, target, and cache condition with unattempted trials makes the schedule incomplete.
func hasCompleteSchedule(_ row: JSON, manifests: [JSON], summary: [JSON]) -> Bool {
  let relevant = manifests.filter {
    $0["host_id"] == row["host_id"]
      && ($0["targets"].array ?? []).contains { $0["id"] == row["target_id"] }
  }
  let siblings = summary.filter { other in
    ["host_id", "target_id", "cache_condition"].allSatisfy { other[$0] == row[$0] }
  }
  return !relevant.isEmpty && relevant.allSatisfy { $0["status"].string == "completed" }
    // `row` comes from `summary`, so it is one of its own siblings.
    && siblings.allSatisfy { $0["attempted_trials"] == $0["scheduled_trials"] }
}

func passesGates(_ row: JSON, _ selection: SelectionSettings) -> Bool {
  guard let pass = row["pass_rate"].double,
    let speed = row["median_output_tokens_per_second"].double,
    // Swap pushed out once stays out, so later trials show no growth; p90 would hide it.
    let swap = row["max_peak_swap_delta_bytes"].double,
    let rss = row["p90_peak_backend_rss_bytes"].double,
    let memory = row["host_memory_bytes"].double, memory > 0,
    // The speed median covers completed trials only, so a timed-out trial would flatter it.
    row["timeout_trials"].uint == 0
  else { return false }
  return pass >= selection.minimumPassRate && speed >= selection.minimumMedianTokensPerSecond
    && swap / Double(gibibyte) <= selection.maximumPeakSwapDeltaGib
    && rss / memory <= selection.maximumBackendMemoryFraction
}

func rankedBefore(_ left: JSON, _ right: JSON, cloud: Bool = false) -> Bool {
  for name in cloud
    ? ["pass_rate", "mean_score"] : ["pass_rate", "mean_score", "median_output_tokens_per_second"]
  {
    let leftValue = left[name].double ?? 0
    let rightValue = right[name].double ?? 0
    if leftValue != rightValue { return leftValue > rightValue }
  }
  return false
}
