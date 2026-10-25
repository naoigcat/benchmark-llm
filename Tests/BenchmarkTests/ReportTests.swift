import Foundation
import Testing

@testable import Benchmark

private func sampleReportRows(_ targets: [TargetConfig], settings: RunSettings) -> [JSON] {
  var rows: [JSON] = []
  for target in targets {
    for condition in target.cacheConditions(settings.cacheConditions) {
      for repeatNumber in 1...2 {
        for taskIndex in 0..<2 {
          var task = testTask()
          task.id = "task-\(taskIndex)"
          task.category = taskIndex == 0 ? "reasoning" : "coding"
          var row = trialBase(
            context: TrialContext(
              runID: "sample", hostID: "test", memory: .unsigned(16 * gibibyte),
              position: rows.count + 1, total: 12), target: target, task: task,
            item: ScheduleItem(
              target: 0, task: taskIndex, repeatNumber: repeatNumber, condition: condition),
            doctor: DoctorResult(ok: true, version: "fixture", message: "ready"))
          if target.adapter == "ollama" && condition == "cold" && repeatNumber == 2
            && taskIndex == 1
          {
            setFields(&row, ["status": "error", "passed": false, "failure_reason": "timeout"])
          } else {
            setFields(
              &row,
              completionFields(
                GenerationResult(
                  text: "ok", resolvedModel: target.model, wallTimeMs: 100,
                  timeToFirstTokenMs: 10, outputTokens: 5, generationMs: 100, finishReason: "stop"),
                score: ScoreResult(score: 1, detail: "exact match"), threshold: 1))
          }
          setFields(
            &row,
            [
              "peak_backend_rss_bytes": .unsigned(2 * gibibyte), "peak_swap_delta_bytes": 0,
              "memory_sample_count": 1,
            ])
          rows.append(row)
        }
      }
    }
  }
  return rows
}

func sampleReportInput(language: ReportLanguage = .ja) throws -> (JSON, [JSON]) {
  let targets = [
    localTarget("http://127.0.0.1:11434"),
    TargetConfig(
      id: "cloud", inferenceLocation: "remote", adapter: "cli-agent", model: "cloud-model"),
  ]
  let settings = testSettings()
  let manifest: JSON = [
    "run_id": "sample", "status": "completed", "host_id": "test",
    "application": [
      "name": "benchmark", "version": .string(benchmarkVersion), "language": "swift",
    ],
    "repository": ["revision": .string(String(repeating: "a", count: 40)), "dirty": false],
    "suite": [
      "path": "Resources/suites", "sha256": .string(String(repeating: "b", count: 64)),
      "task_count": 2,
    ],
    "host": ["chip": "test", "memory_bytes": .unsigned(16 * gibibyte)],
    "run_settings": manifestRunSettings(settings, repeatCount: 2),
    "report_settings": ["language": .string(language.rawValue)],
    "selection": try .of(SelectionSettings()), "targets": .array(targets.map(\.json)),
    "warnings": [],
  ]
  return (manifest, sampleReportRows(targets, settings: settings))
}

private func selectionGateRow(
  passRate: Double? = 0.8, speed: Double? = 10,
  swap: Double? = Double(gibibyte), rss: Double? = 16 * Double(gibibyte) * 0.7,
  memory: Double? = 16 * Double(gibibyte), timeouts: Int64 = 0
) -> JSON {
  [
    "pass_rate": .value(passRate), "median_output_tokens_per_second": .value(speed),
    "max_peak_swap_delta_bytes": .value(swap), "p90_peak_swap_delta_bytes": 0,
    "p90_peak_backend_rss_bytes": .value(rss), "host_memory_bytes": .value(memory),
    "timeout_trials": .integer(timeouts),
  ]
}

@Test(arguments: [-1, 0, 1, 2])
func unreadableSwapSampleExcludesTheCandidate(_ failedReading: Int) throws {
  var reading = 0
  let sampler = MemorySampler(matching: nil) {
    defer { reading += 1 }
    return reading == failedReading ? nil : 0
  }
  sampler.start()
  let metrics = sampler.stop().json
  let expected: JSON = failedReading < 0 ? 0 : .null
  #expect(metrics["baseline_swap_used_bytes"] == (failedReading == 0 ? .null : 0))
  #expect(metrics["peak_swap_used_bytes"] == expected)
  #expect(metrics["peak_swap_delta_bytes"] == expected)

  let (_, records) = try sampleReportInput()
  var warm = records.filter { $0["cache_condition"] == "warm" }
  #expect(passesGates(try #require(summarize(warm).first), SelectionSettings()))
  warm[0]["peak_swap_delta_bytes"] = metrics["peak_swap_delta_bytes"]
  let summary = try #require(summarize(warm).first)
  #expect(summary["max_peak_swap_delta_bytes"] == expected)
  #expect(summary["p90_peak_swap_delta_bytes"] == expected)
  #expect(passesGates(summary, SelectionSettings()) == (failedReading < 0))

  sampler.start()
  let recovered = sampler.stop().json
  #expect(recovered["peak_swap_used_bytes"] == 0)
  #expect(recovered["peak_swap_delta_bytes"] == 0)
}

@Test func selectionGatesCoverThresholdsAndMissingMetrics() {
  let selection = SelectionSettings()
  #expect(passesGates(selectionGateRow(), selection))
  #expect(
    !passesGates(
      selectionGateRow(swap: Double(gibibyte) + 1), selection))
  #expect(
    !passesGates(
      selectionGateRow(rss: 16 * Double(gibibyte) * 0.7 + 1), selection))
  #expect(!passesGates(selectionGateRow(passRate: nil), selection))
  #expect(!passesGates(selectionGateRow(swap: nil), selection))
  #expect(!passesGates(selectionGateRow(timeouts: 1), selection))
  #expect(percentile([10, 20, 30], 0.5) == 20)
  #expect(percentile([], 0.5) == nil)
}

@Test(arguments: [ReportLanguage.ja, .en])
func reportsUseRecordedLanguageAndAggregateFailures(_ language: ReportLanguage) throws {
  let temp = try TemporaryDirectory()
  let (manifest, records) = try sampleReportInput(language: language)
  try writeJSON(manifest, to: temp.file("manifest.json"))
  try temp.write("trials.jsonl", records.map { $0.serialized() + "\n" }.joined())
  let rows = try generateReport(runs: [temp.directory], output: temp.directory)
  #expect(rows.count == 3)
  let cold = try #require(rows.first { $0["cache_condition"] == "cold" })
  #expect(cold["scheduled_trials"] == 4)
  #expect(cold["attempted_trials"] == 4)
  #expect(cold["passed_trials"] == 3)
  #expect(cold["timeout_trials"] == 1)
  #expect(cold["pass_rate"].double == 0.75)
  #expect(cold["mean_score"].double == 1)
  #expect(cold["median_output_tokens_per_second"].double == 40)
  let report = try String(contentsOfFile: temp.file("report.md"), encoding: .utf8)
  #expect(report.contains(language == .ja ? "比較結果" : "Comparison"))
  #expect(report.contains("timeout"))
  #expect(report.contains("- `test`: `local-model`"))
  #expect(report.contains(language == .ja ? "合格率 100.0%" : "Pass rate 100.0%"))
  let summary = try String(contentsOfFile: temp.file("summary.csv"), encoding: .utf8)
  #expect(summary.components(separatedBy: "\r\n").count == 5)
}

@Test func reportsRequireCurrentApplicationAndSettings() throws {
  let (original, rows) = try sampleReportInput()
  for field in ["application", "report_settings", "selection"] {
    var manifest = original
    manifest[field] = [:]
    #expect(throws: (any Error).self) { try validateRun(manifest, trials: rows) }
  }
}

@Test func reportsIgnoreOnlyAMalformedFinalTrialRecord() throws {
  let temp = try TemporaryDirectory()
  let (original, rows) = try sampleReportInput()
  var interrupted = original
  interrupted["status"] = "interrupted"
  try writeJSON(interrupted, to: temp.file("manifest.json"))
  let prefix = rows.prefix(1).map { $0.serialized() }.joined(separator: "\n")
  try temp.write("trials.jsonl", prefix + "\n{\"incomplete\"")
  #expect(!(try generateReport(runs: [temp.directory], output: temp.directory)).isEmpty)
  try (Data((prefix + "\n{\"category\":\"").utf8) + Data([0xE3, 0x81])).write(
    to: URL(fileURLWithPath: temp.file("trials.jsonl")))
  #expect(!(try generateReport(runs: [temp.directory], output: temp.directory)).isEmpty)

  try temp.write(
    "trials.jsonl", prefix + "\n{\"incomplete\"}\n" + rows[1].serialized() + "\n")
  #expect(throws: (any Error).self) {
    try generateReport(runs: [temp.directory], output: temp.directory)
  }
}

@Test func progressCountsSkipsSupersededByALaterRun() throws {
  let temp = try TemporaryDirectory()
  let (manifest, rows) = try sampleReportInput(language: .en)
  let skipped = rows.map { row -> JSON in
    var row = row
    row["status"] = "skipped"
    row["passed"] = false
    row["score"] = .null
    row["failure_reason"] = "preflight_failed"
    return row
  }
  var later = manifest
  later["run_id"] = "later"
  let laterRows = rows.map { row -> JSON in
    var row = row
    row["run_id"] = "later"
    return row
  }
  for (name, run, records) in [("a", manifest, skipped), ("b", later, laterRows)] {
    try temp.write("\(name)/trials.jsonl", records.map { $0.serialized() + "\n" }.joined())
    try writeJSON(run, to: temp.file("\(name)/manifest.json"))
  }
  try FileManager.default.createDirectory(
    atPath: temp.file("out"), withIntermediateDirectories: true)
  _ = try generateReport(runs: [temp.file("a"), temp.file("b")], output: temp.file("out"))
  let report = try String(contentsOfFile: temp.file("out/report.md"), encoding: .utf8)
  #expect(report.contains("| sample | completed | \(rows.count) | \(rows.count) | 0 |"))
}
