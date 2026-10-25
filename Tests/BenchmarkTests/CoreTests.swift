import Foundation
import Testing

@testable import Benchmark

@Test(arguments: ["ollama-gpt-oss-swallow-20b", "ollama-gpt-oss-swallow-120b"])
func swallowTemplatesDoNotDependOnTheMeasurementDate(_ target: String) throws {
  let recipe = try #require(modelfile(for: target))
  #expect(!recipe.contains("currentDate"))
  #expect(!recipe.contains("Current date:"))
}

@Test func configAndSuitesLoad() throws {
  let config = try loadConfig()
  let root = try resolvePath(repositoryRoot)
  #expect(config.run.seed == 42)
  let targetIDs = config.targets.map(\.id)
  #expect(!targetIDs.isEmpty && Set(targetIDs).count == targetIDs.count)
  #expect(targetIDs.allSatisfy(isValidID))
  #expect(Set(targetIDs).isSubset(of: targetDefinitions().map(\.id)))
  #expect(config.sourcePath == path(root, "Resources/benchmark.json"))
  #expect(config.run.suitesDir == path(root, "Resources/suites"))
  #expect(config.run.resultsDir == path(root, "Deliverables/Runs"))
  #expect(config.run.workdir == root)
  let (tasks, digest) = try loadTasks(at: config.run.suitesDir)
  let taskIDs = tasks.map(\.id)
  #expect(!taskIDs.isEmpty && Set(taskIDs).count == taskIDs.count)
  #expect(taskIDs.allSatisfy(isValidID))
  #expect(digest.count == 64)
  #expect(Set(targetDefinitions().map(\.id)).count == targetDefinitions().count)
  let sqlTask = try #require(tasks.first { $0.id == "code-003" })
  #expect(sqlTask.scorer["expected"] == "IS NULL")
  // A swapped date or a reversed change loses the fact it gets wrong.
  for (id, correct, swapped) in [
    ("japanese-006", "研修は6月8日にオンラインで新入社員対象、申込は6月1日まで。", "研修は6月1日にオンラインで新入社員対象、申込は6月8日まで。"),
    ("japanese-009", "7月1日から共用部の消灯を21時から20時へ変更、緊急時は守衛へ。", "7月1日から共用部の消灯を20時から21時へ変更、緊急時は守衛へ。"),
  ] {
    let task = try #require(tasks.first { $0.id == id })
    #expect(try scoreResponse(task, response: correct).score == 1)
    #expect(try scoreResponse(task, response: swapped).score < 1)
  }
}
@Test func exactJSONNumbersAndCaseFolding() throws {
  let huge = try JSON.parse("18446744073709551615")
  #expect(huge.uint == UInt64.max)
  #expect(!huge.equivalent(to: .number(Double(UInt64.max))))
  #expect(try JSON.parse("9007199254740993") != JSON.parse("9007199254740992"))
  #expect(JSON.integer(2).equivalent(to: .number(2)))
  #expect(!JSON.bool(true).equivalent(to: .integer(1)))
  #expect(try JSON.parse("\"\u{FEFF}a\"").string == "\u{FEFF}a")
}
@Test(arguments: [
  "http://localhost:11434", "https://example.com", "http://192.168.1.1", "file:///tmp/a",
  "http://[::ffff:127.0.0.1]",
])
func rejectsNonLoopback(_ endpoint: String) {
  #expect(throws: (any Error).self) { try requireLoopbackEndpoint(endpoint) }
}
@Test(arguments: ["http://127.0.0.1:11434", "http://127.2.3.4", "https://[::1]:443"])
func acceptsLiteralLoopback(_ endpoint: String) throws { try requireLoopbackEndpoint(endpoint) }
@Test func processDrainsAndTimesOut() throws {
  let result = try runProcess(
    "/bin/sh", args: ["-c", "cat; printf 'error' >&2"], input: "hello", timeout: 2)
  #expect(result.success)
  #expect(result.stdout == "hello")
  #expect(result.stderr == "error")
  #expect(throws: (any Error).self) {
    try runProcess("/bin/sh", args: ["-c", "sleep 10"], timeout: 0.05)
  }
}
@Test func stdoutFloodStillHonorsTimeout() throws {
  let started = monotonicTime()
  #expect(throws: (any Error).self) {
    try runProcess(
      "/bin/sh", args: ["-c", "yes"], timeout: 0.05, onLine: { _, _ in })
  }
  #expect(monotonicTime() - started < 5)
}

private func readmeTable(after header: String) throws -> [[String]] {
  let readme = try String(contentsOfFile: path(repositoryRoot, "README.md"), encoding: .utf8)
  let lines = readme.components(separatedBy: "\n")
  let start = try #require(lines.firstIndex { $0.hasPrefix(header) })
  return lines[(start + 2)...].prefix { $0.hasPrefix("|") }.map {
    $0.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
  }
}

private func backticked(_ cell: String) -> String? {
  let parts = cell.components(separatedBy: "`")
  return parts.count >= 3 ? parts[1] : nil
}

@Test func readmeTablesMatchCode() throws {
  let run = RunSettings(resultsDir: "", suitesDir: "", workdir: "", seed: 0)
  let defaults: [String: JSON] = [
    "repeat": .integer(Int64(run.repeatCount)),
    "request_timeout_seconds": .number(run.requestTimeoutSeconds),
    "cooldown_seconds": .number(run.cooldownSeconds),
    "max_output_tokens": .unsigned(run.maxOutputTokens), "temperature": .number(run.temperature),
    "cache_conditions": .array(run.cacheConditions.map(JSON.string)),
    "system_prompt": .string(run.systemPrompt),
  ]
  var documented: [String: JSON] = [:]
  for row in try readmeTable(after: "| Key                       | Default when omitted") {
    guard let key = backticked(row[0]), let value = backticked(row[1]) else { continue }
    documented[key] = try JSON.parse(value)
  }
  #expect(Set(documented.keys) == Set(defaults.keys))
  for (key, value) in defaults {
    #expect(documented[key]?.equivalent(to: value) == true, "README default for \(key)")
  }

  let limits = [
    "One reference CLI stdout line": referenceCLIStdoutLineLimit,
    "Reference CLI JSON events": streamEventLimit,
    "Reference CLI event bytes": referenceCLIEventByteLimit,
    "Ollama JSON events": streamEventLimit,
    "HTTP response body": httpResponseByteLimit,
    "Retained CLI stderr": processDiagnosticLimit,
  ]
  let limitRows = try readmeTable(
    after: "| Output                                                        | Limit")
  #expect(limitRows.count == limits.count)
  for row in limitRows {
    let words = row[1].replacingOccurrences(of: ",", with: "").split(separator: " ")
    let unit = words.count > 1 ? ["KiB": 1024, "MiB": 1024 * 1024][String(words[1])] ?? 1 : 1
    let limit = try #require(limits.first { row[0].hasPrefix($0.key) }?.value)
    #expect(Int(words[0]).map { $0 * unit } == limit, "README limit for \(row[0])")
  }

  let schema = try readJSON(path(repositoryRoot, "Resources/schemas/trial.schema.json"))
  let reasons = Set(
    try #require(schema["properties"]["failure_reason"]["enum"].array).compactMap(\.string))
  let rows = try readmeTable(after: "| Event ")
  #expect(Set(rows.compactMap { backticked($0[2]) }) == reasons)
}
