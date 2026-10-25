import Darwin
import Foundation
import Testing

@testable import Benchmark

@Test(arguments: ["é", "日", "😀"])
func boundedDiagnosticsKeepCompleteUTF8(_ character: String) throws {
  let repeated = String(repeating: character, count: 40_000)
  for limit in 1...8 {
    let result = try runProcess(
      "/bin/echo", args: [repeated], timeout: 2, captureLimit: limit)
    #expect(result.stdoutTruncated)
    #expect(result.stdout == String(repeating: character, count: limit / character.utf8.count))
  }
  let stderr = try runProcess(
    "/bin/sh", args: ["-c", "printf '%s' \"$1\" >&2", "test", repeated], timeout: 2)
  let expected = String(repeating: character, count: 65536 / character.utf8.count)
  #expect(stderr.stderr == expected)
  let combined = ProcessResult(
    status: 0, stdout: repeated, stderr: "diagnostic", started: 0, ended: 1, cleanupMS: 0)
  #expect(combined.output == expected)
}

private struct TimestampAdapter: Adapter {
  let failure: String
  func doctor(cache: DoctorCache) throws -> DoctorResult { .unavailable("unused") }
  func prepare(_ condition: String) throws {
    if failure == "prepare" { throw ApiError("prepare failed") }
  }
  func generate(_ task: BenchmarkTask, repeatNumber: Int) throws
    -> GenerationResult
  {
    if failure == "generate" { throw ApiError("generation failed") }
    if failure == "interrupted" { throw ApiError("interrupted", interrupted: true) }
    return GenerationResult(text: "ok", wallTimeMs: 1)
  }
  func cleanup(_ condition: String) throws {
    if failure == "cleanup" { throw ApiError("cleanup failed") }
  }
}

@Test(arguments: ["none", "prepare", "generate", "cleanup", "interrupted"])
func trialTimestampsCoverEveryOutcome(_ failure: String) throws {
  let target = TargetConfig(id: "cloud", inferenceLocation: "remote", adapter: "cli-agent")
  let before = timestamp()
  let base = trialBase(
    context: TrialContext(runID: "test", hostID: "test", memory: nil, position: 1, total: 1),
    target: target, task: testTask(),
    item: ScheduleItem(target: 0, task: 0, repeatNumber: 1, condition: "provider-managed"),
    doctor: .unavailable("unused"))
  let (trial, _) = executeTrial(
    base, target: target, task: testTask(), condition: "provider-managed",
    adapter: TimestampAdapter(failure: failure))
  let start = try #require(trial["started_at"].string)
  let end = try #require(trial["completed_at"].string)
  #expect(before <= start && start <= end && end <= timestamp())
  #expect(trial["status"] == (failure == "none" ? "completed" : "error"))
}

@Test func scalarLimitDiagnosticUsesCodePoints() throws {
  let task = testTask(["type": "contains_all", "expected": ["e"], "max_chars": 1])
  let result = try scoreResponse(task, response: "e\u{301}")
  #expect(result.score == 0)
  #expect(result.detail == "response exceeded 1 code points")
  #expect(try scoreResponse(task, response: "e").score == 1)
}

@Test(arguments: ["http://127.0.0.1", "http://[::1]", "https://127.0.0.1"])
func ollamaTargetsRequireAnExplicitPort(_ endpoint: String) {
  #expect(throws: (any Error).self) { try localTarget(endpoint).validate() }
}

@Test func profilePermissionsDoNotDependOnPathSpelling() throws {
  let temp = try TemporaryDirectory()
  let parent = temp.file("benchmark")
  try privateDirectory(parent)
  #expect(chmod(parent, 0o755) == 0)
  try products[0].createProfile(path(parent, "profiles"))
  var info = stat()
  #expect(stat(parent, &info) == 0 && info.st_mode & 0o777 == 0o755)
  try products[0].createProfile(path(parent, "custom"), secureParent: true)
  #expect(stat(parent, &info) == 0 && info.st_mode & 0o777 == 0o700)
}

@Test func containsValidationFollowsScorerMutation() throws {
  var task = try parseTask([
    "id": "task", "category": "test", "prompt": "answer",
    "scorer": ["type": "contains_all", "expected": ["A", "a"], "max_chars": 20.0],
  ])
  #expect(try scoreResponse(task, response: "A a").score == 1)
  task.scorer["case_sensitive"] = false
  #expect(throws: (any Error).self) { try scoreResponse(task, response: "A a") }
  #expect(throws: (any Error).self) {
    try scoreResponse(testTask(["type": "contains_all", "expected": []]), response: "ok")
  }
}

@Test func unpassableExpectedValuesAreRejected() throws {
  let schema = try readJSON(path(repositoryRoot, "Resources/schemas/task.schema.json"))
  for scorer: JSON in [
    ["type": "contains_all", "expected": ["a", ""]],
    ["type": "exact", "expected": " "],
    ["type": "exact", "expected": ["ok", "\u{3000}"]],
  ] {
    let task: JSON = ["id": "task", "category": "test", "prompt": "answer", "scorer": scorer]
    #expect(throws: (any Error).self) { try parseTask(task) }
    #expect(throws: (any Error).self) { try validateJSONSchema(task, against: schema) }
  }
  // Whitespace inside a contains_all value is still a matchable string.
  #expect(throws: Never.self) {
    try parseTask([
      "id": "task", "category": "test", "prompt": "answer",
      "scorer": ["type": "contains_all", "expected": ["a b", " "]],
    ])
  }
}

func expectTrialTimestamps(_ record: JSON) throws {
  let start = try #require(record["started_at"].string)
  let end = try #require(record["completed_at"].string)
  #expect(start <= end)
}

@Test func diagnosticDecodingRetainsMalformedOutput() {
  #expect(diagnosticText(Data()) == "")
  #expect(diagnosticText(Data([65, 255, 66, 67, 68])) == "A�BCD")
  #expect(diagnosticText(Data("日本語".utf8)) == "日本語")
}

extension RuntimeTests {
  @Test func skippedTrialsStillRecordTimestamps() throws {
    let temp = try TemporaryDirectory()
    try temp.write(
      "Resources/suites/one.jsonl",
      #"{"id":"task","category":"test","prompt":"ok","scorer":{"type":"exact","expected":"ok"}}"#)
    var target = localTarget("http://127.0.0.1:11434")
    target.eligibleHosts = ["another-host"]
    let config = BenchmarkConfig(
      sourcePath: temp.file("Resources/benchmark.json"), digest: String(repeating: "a", count: 64),
      run: testSettings(temp.directory),
      hosts: [HostConfig(id: "test", chip: "test", memoryGib: 16)],
      targets: [target])
    let directory = try #require(
      try runBenchmark(
        config, detectedHost: ["chip": "test", "memory_bytes": .unsigned(16 * gibibyte)]))
    let records = try String(contentsOfFile: path(directory, "trials.jsonl"), encoding: .utf8)
      .split(separator: "\n").map { try JSON.parse(String($0)) }
    #expect(records.count == 2)
    for record in records {
      #expect(record["status"] == "skipped")
      try expectTrialTimestamps(record)
    }
  }

  @Test func interruptionDuringSetupLeavesAReportableRun() throws {
    let temp = try TemporaryDirectory()
    try temp.write(
      "Resources/suites/one.jsonl",
      #"{"id":"task","category":"test","prompt":"ok","scorer":{"type":"exact","expected":"ok"}}"#)
    // A private cancellation: the global one is read by tests running in parallel.
    let cancellation = Cancellation()
    let server = try FixtureServer { request in
      if request.path == "/api/version" { cancellation.cancel() }
      return FixtureResponse(["version": "1.0", "models": []])
    }
    defer { server.stop() }
    let config = BenchmarkConfig(
      sourcePath: temp.file("Resources/benchmark.json"), digest: String(repeating: "a", count: 64),
      run: testSettings(temp.directory),
      hosts: [HostConfig(id: "test", chip: "test", memoryGib: 16)],
      targets: [localTarget(server.baseURL)])
    do {
      _ = try runBenchmark(
        config, detectedHost: ["chip": "test", "memory_bytes": .unsigned(16 * gibibyte)],
        cancellation: cancellation)
      Issue.record("expected interruption")
    } catch let error as ApiError {
      #expect(error.isInterrupted)
    }
    let runs = try FileManager.default.contentsOfDirectory(atPath: config.run.resultsDir)
      .filter { !$0.hasPrefix(".") }
    let directory = path(config.run.resultsDir, try #require(runs.first))
    #expect(try readJSON(path(directory, "manifest.json"))["status"] == "interrupted")
    _ = try generateReport(runs: [directory], output: directory)
  }
}

@Test func failedOwnedServerKeepsItsDiagnosticLog() throws {
  let temp = try TemporaryDirectory()
  let child = try OwnedServer(
    command: "/bin/sh", arguments: ["-c", "printf 'startup failed' >&2; exit 1"],
    address: "127.0.0.1:11434", logDirectory: temp.file("logs"))
  defer { child.stop() }
  let deadline = monotonicTime() + 2
  while !child.hasExited && monotonicTime() < deadline { usleep(1000) }
  #expect(child.hasExited)
  child.stop()
  #expect(try String(contentsOfFile: child.logPath, encoding: .utf8) == "startup failed")
}

@Test func missingOllamaExecutableLeavesNoLog() throws {
  let temp = try TemporaryDirectory()
  #expect(throws: (any Error).self) {
    try OwnedServer(
      command: temp.file("missing-ollama"), address: "127.0.0.1:11434",
      logDirectory: temp.file("logs"))
  }
  #expect((try? FileManager.default.contentsOfDirectory(atPath: temp.file("logs"))) ?? [] == [])
}

@Test func scoringFailureKeepsTheResponse() {
  let target = TargetConfig(id: "cloud", inferenceLocation: "remote", adapter: "cli-agent")
  let (trial, raw) = executeTrial(
    ["trial_id": "test", "repeat": 1], target: target, task: testTask(["type": "exact"]),
    condition: "provider-managed", adapter: TimestampAdapter(failure: "none"))
  #expect(trial["failure_reason"] == "runner_error")
  #expect(raw["response"] == "ok")
}
