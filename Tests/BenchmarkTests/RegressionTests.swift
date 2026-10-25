import Darwin
import Foundation
import Testing

@testable import Benchmark

private func configurationText(_ run: String) -> String {
  """
  {
    "run": {
      "seed": 42,
      \(run)
    },
    "hosts": [
      {
        "id": "test",
        "chip": "test",
        "memory_gib": 16
      }
    ],
    "targets": [
      {
        "id": "local-model"
      }
    ]
  }
  """
}
@Test(arguments: [
  "\"repeat\": 0", "\"repeat\": 1.0", "\"temperature\": true", "\"temperature\": 3",
  "\"request_timeout_seconds\": 0", "\"cooldown_seconds\": -1",
  "\"max_output_tokens\": 0", "\"system_prompt\": false", "\"cache_conditions\": []",
  "\"cache_conditions\": [\"cold\", \"cold\"]", "\"cache_conditions\": [\"provider-managed\"]",
  "\"unknown\": 1", "\"cooldown_seconds\": 9007199254740993",
])
func invalidConfigurationIsRejected(_ setting: String) throws {
  let temp = try TemporaryDirectory()
  try temp.write("Resources/benchmark.json", configurationText(setting))
  #expect(throws: (any Error).self) {
    try loadConfig(
      at: temp.file("Resources/benchmark.json"),
      definitions: [localTarget("http://127.0.0.1:11434")])
  }
}
@Test func pathsStayRelativeToConfig() throws {
  let temp = try TemporaryDirectory()
  try temp.write("Resources/benchmark.json", configurationText("\"repeat\": 1"))
  let config = try loadConfig(
    at: temp.file("Resources/benchmark.json"), definitions: [localTarget("http://127.0.0.1:11434")])
  // Missing directories still resolve the temporary root's /var -> /private/var link.
  let root = try resolvePath(temp.directory)
  #expect(config.run.suitesDir == path(root, "Resources/suites"))
  #expect(config.run.resultsDir == path(root, "Deliverables/Runs"))
}
@Test func tasksRejectDuplicateIDsAndDoNotFollowSuiteLinks() throws {
  let temp = try TemporaryDirectory()
  let task =
    #"{"id":"task","category":"reasoning","prompt":"ok","scorer":{"type":"exact","expected":"ok"}}"#
  try temp.write("Resources/suites/a.jsonl", task + "\n")
  try temp.write("outside.jsonl", task)
  #expect(symlink(temp.file("outside.jsonl"), temp.file("Resources/suites/b.jsonl")) == 0)
  let (tasks, digest) = try loadTasks(at: temp.file("Resources/suites"))
  #expect(tasks.count == 1)
  try temp.write("Resources/suites/nested/c.jsonl", task)
  #expect(try loadTasks(at: temp.file("Resources/suites")).1 == digest)
  try temp.write("Resources/suites/d.jsonl", task)
  #expect(throws: (any Error).self) { try loadTasks(at: temp.file("Resources/suites")) }
}
@Test func scalarWhitespaceAndObjectMutationStayExact() throws {
  #expect("ok\u{200B}".trimmed == "ok\u{200B}")
  #expect(try scoreResponse(testTask(), response: "ok\u{200B}").score == 0)
  #expect(
    try scoreResponse(
      testTask(["type": "exact", "expected": "a b", "normalize_whitespace": true]),
      response: "a \u{301}b"
    ).score == 0)
  var value = try JSON.parse(#"{"é":1,"e\u0301":2}"#)
  value["new"] = 3
  value["é"] = 4
  #expect(value.members?.count == 3)
  #expect(value["e\u{301}"] == 2)
  #expect(value["é"] == 4)
  #expect(try JSON.parse(#"{"é":1}"#)["e\u{301}"] == .null)
  let first = Date(timeIntervalSince1970: 1_000_000.0001)
  let second = Date(timeIntervalSince1970: 1_000_000.0002)
  #expect(runIdentifier(host: "host", date: first) != runIdentifier(host: "host", date: second))
}
@Test func jsonStringsUseFastAndCompleteEscaping() throws {
  let value = JSON.string(
    "quote\" slash\\ controls\u{0008}\u{0009}\u{000A}\u{000C}\u{000D}\u{0001}\u{2028}\u{2029}日本語")
  let serialized = value.serialized()
  #expect(serialized.contains("\\\""))
  #expect(serialized.contains("\\\\"))
  #expect(serialized.contains("\\b"))
  #expect(serialized.contains("\\t"))
  #expect(serialized.contains("\\n"))
  #expect(serialized.contains("\\f"))
  #expect(serialized.contains("\\r"))
  #expect(serialized.contains("\\u0001"))
  #expect(serialized.contains("\\u2028"))
  #expect(serialized.contains("\\u2029"))
  #expect(try JSON.parse(serialized) == value)
}
@Test func distinctUnicodeCategoriesAreNotMerged() throws {
  let (_, rows) = try sampleReportInput()
  var first = rows[0]
  var second = first
  first["task_category"] = "é"
  second["task_category"] = "e\u{301}"
  #expect(summarize([first, second], byCategory: true).count == 2)
}
@Test(arguments: [
  "run_id", "host_id", "target_id", "adapter", "model_requested", "target_fingerprint", "repeat",
  "cache_condition", "status", "passed", "score", "input_tokens", "wall_time_ms",
])
func reportRejectsTamperedRecords(_ field: String) throws {
  let (manifest, original) = try sampleReportInput()
  var rows = original
  rows[0][field] = "invalid"
  #expect(throws: (any Error).self) { try validateRun(manifest, trials: rows) }
}
@Test func reportCoverageAndGenerationConditionsRemainStrict() throws {
  let (manifest, rows) = try sampleReportInput()
  #expect(throws: (any Error).self) { try validateRun(manifest, trials: Array(rows.dropLast())) }
  var duplicate = rows
  duplicate[1] = rows[0]
  #expect(throws: (any Error).self) { try validateRun(manifest, trials: duplicate) }
  var composed = manifest
  var decomposed = manifest
  composed["run_settings"]["system_prompt"] = "é"
  decomposed["run_settings"]["system_prompt"] = "e\u{301}"
  decomposed["run_id"] = "other"
  #expect(throws: (any Error).self) {
    try validateCombinedRuns([composed, decomposed], trials: [])
  }
  #expect(single(["é", "e\u{301}"]) == "é")
  composed["status"] = "interrupted"
  try validateRun(composed, trials: Array(rows.prefix(1)))
  let summary = summarize(Array(rows.prefix(1)))
  #expect(
    summary.allSatisfy { !hasCompleteSchedule($0, manifests: [composed], summary: summary) })
  let measured: JSON = [
    "host_id": "h", "target_id": "t", "target_fingerprint": "new", "cache_condition": "warm",
    "scheduled_trials": 1, "attempted_trials": 1,
  ]
  var leftover = measured
  leftover["target_fingerprint"] = "skip"
  leftover["attempted_trials"] = 0
  let completed: JSON = ["host_id": "h", "status": "completed", "targets": [["id": "t"]]]
  #expect(hasCompleteSchedule(measured, manifests: [completed], summary: [measured]))
  #expect(!hasCompleteSchedule(measured, manifests: [completed], summary: [measured, leftover]))
}
@Test func combinedRunsRejectRemeasuredTrials() throws {
  let (manifest, rows) = try sampleReportInput()
  var remeasured = manifest
  remeasured["run_id"] = "remeasured"
  let repeated = rows.map { row -> JSON in
    var row = row
    row["run_id"] = "remeasured"
    row["trial_id"] = .string("remeasured-\(row["trial_id"].text)")
    return row
  }
  try validateCombinedRuns([manifest], trials: rows)
  #expect(throws: (any Error).self) {
    try validateCombinedRuns([manifest, remeasured], trials: rows + repeated)
  }
  let otherHost = repeated.map { row -> JSON in
    var row = row
    row["host_id"] = "other"
    return row
  }
  try validateCombinedRuns([manifest, remeasured], trials: rows + otherHost)
}
@Test func skippedTrialsYieldToLaterMeasurements() throws {
  let (manifest, rows) = try sampleReportInput()
  let skipped = rows.map { row -> JSON in
    var row = row
    row["status"] = "skipped"
    return row
  }
  var remeasured = manifest
  remeasured["run_id"] = "remeasured"
  let combined = droppingSupersededSkips(skipped + skipped + rows)
  #expect(combined == rows)
  try validateCombinedRuns([manifest, remeasured], trials: combined)
  #expect(droppingSupersededSkips(skipped + skipped) == skipped)
  let unfingerprinted = skipped.map { row -> JSON in
    var row = row
    row["target_fingerprint"] = "skipped-before-install"
    return row
  }
  #expect(droppingSupersededSkips(unfingerprinted + rows) == rows)
}
@Test func reportEscapesCombiningDelimitersAndFormulas() {
  let text = "model,\u{301}name\"\u{301}"
  #expect(
    csv([["value": .string(text)]], fields: ["value"])
      == "value\r\n\"model,\u{301}name\"\"\u{301}\"\r\n")
  #expect(csvValue("=\u{301}1") == "'=\u{301}1")
  #expect(csvValue(.integer(-1)) == "-1")
  #expect(markdownEscape("x|\u{301}<\u{301}y") == "x\\|\u{301}&lt;\u{301}y")
  #expect(markdownCode("`\u{301}").hasPrefix("`` "))
}
@Test func reportPublicationUsesProvidedFileNames() throws {
  let temp = try TemporaryDirectory()
  try publishReportFiles(["custom.txt": "custom report"], output: temp.directory)
  #expect(try String(contentsOfFile: temp.file("custom.txt"), encoding: .utf8) == "custom report")
}
@Test func runAnnouncementNamesCreatedDirectory() throws {
  let temp = try TemporaryDirectory()
  let settings = testSettings(temp.directory)
  try privateDirectory(settings.resultsDir)
  var messages: [String] = []
  let directory = try createRunDirectory(
    settings, runID: "run", output: { messages.append($0) })
  #expect(messages == ["run: \(directory)"])
  #expect(FileManager.default.fileExists(atPath: directory))
}
@Test func failedManifestKeepsRecoveryAndPreservesExecutionError() throws {
  let temp = try TemporaryDirectory()
  let destination = temp.file("manifest.json")
  try privateDirectory(destination)
  var manifest: JSON = [:]
  do {
    try finalizeManifest(
      &manifest, at: destination, executionError: ApiError("interrupted", interrupted: true))
    Issue.record("expected interruption")
  } catch let error as ApiError { #expect(error.isInterrupted) }
  #expect(manifest["status"] == "interrupted")
  let recovery = try FileManager.default.contentsOfDirectory(atPath: temp.directory).filter {
    $0.hasPrefix(".tmp-")
  }
  #expect(recovery.count == 1)
  #expect(try readJSON(temp.file(recovery[0]))["status"] == "interrupted")
  #expect(throws: (any Error).self) {
    try finalizeManifest(&manifest, at: destination, executionError: nil)
  }
}
@Test func reportPublicationRollsBackAndRetainsUnrecoverableBackups() throws {
  let names = ["summary.csv", "category-summary.csv", "report.md"]
  let publicationOrder = names.sorted()
  for blockRollback in [false, true] {
    let temp = try TemporaryDirectory()
    for name in names { try temp.write(name, "old " + name) }
    var replacements = 0
    #expect(throws: (any Error).self) {
      try publishReportFiles(
        Dictionary(uniqueKeysWithValues: names.map { ($0, "new " + $0) }), output: temp.directory
      ) { source, destination in
        replacements += 1
        if replacements == 2 {
          if blockRollback {
            _ = unlink(temp.file(publicationOrder[0]))
            _ = mkdir(temp.file(publicationOrder[0]), 0o700)
          }
          errno = EACCES
          return -1
        }
        return rename(source, destination)
      }
    }
    if blockRollback {
      let recovery = try #require(
        try FileManager.default.contentsOfDirectory(atPath: temp.directory).first {
          $0.hasPrefix(".report-recovery-")
        })
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: -90_000)], ofItemAtPath: temp.file(recovery))
      // A later publication reclaims stale staging directories but must keep recovery copies.
      try publishReportFiles(["custom.txt": "custom report"], output: temp.directory)
      #expect(
        try String(contentsOfFile: temp.file(recovery + "/previous/summary.csv"), encoding: .utf8)
          == "old summary.csv")
    } else {
      for name in names {
        #expect(try String(contentsOfFile: temp.file(name), encoding: .utf8) == "old " + name)
      }
    }
  }
}
@Test func preflightInterruptionStillFinalizesEveryTarget() throws {
  let cancellation = Cancellation()
  var first = localTarget("http://127.0.0.1:11434")
  var second = first
  first.id = "first"
  second.id = "second"
  var calls = 0
  let doctors = runPreflights([first, second], host: "test", cancellation: cancellation) { _ in
    calls += 1
    cancellation.cancel()
    throw ApiError("interrupted", interrupted: true)
  }
  #expect(calls == 1)
  #expect(doctors.count == 2)
  #expect(doctors.values.allSatisfy { !$0.ok })
  let temp = try TemporaryDirectory()
  let config = BenchmarkConfig(
    sourcePath: temp.file("Resources/benchmark.json"), digest: String(repeating: "a", count: 64),
    run: testSettings(temp.directory), hosts: [], targets: [first, second])
  var manifest = try runManifest(
    config,
    context: RunManifestContext(
      runID: "interrupted", host: HostConfig(id: "test", chip: "test", memoryGib: 16),
      detected: ["memory_bytes": .unsigned(16 * gibibyte)],
      digest: String(repeating: "a", count: 64),
      taskCount: 1, repeatCount: 1), targets: [first, second], doctors: doctors)
  #expect(throws: ApiError.self) {
    try finalizeManifest(
      &manifest, at: temp.file("manifest.json"),
      executionError: ApiError("interrupted", interrupted: true))
  }
  try temp.write("trials.jsonl", "")
  _ = try generateReport(runs: [temp.directory], output: temp.directory)
}
private struct FailingAdapter: Adapter {
  func doctor(cache: DoctorCache) throws -> DoctorResult { .unavailable("unused") }
  func generate(_ task: BenchmarkTask, repeatNumber: Int) throws
    -> GenerationResult
  { throw ApiError("scoring failed: provider error") }
}
@Test func providerTextCannotChangeFailureClassification() {
  let target = TargetConfig(id: "cloud", inferenceLocation: "remote", adapter: "cli-agent")
  let (trial, raw) = executeTrial(
    ["trial_id": "test", "repeat": 1], target: target, task: testTask(),
    condition: "provider-managed", adapter: FailingAdapter())
  #expect(trial["failure_reason"] == "request_error")
  #expect(raw["error"]["type"] == "ApiError")
}
