import CryptoKit
import Darwin
import Foundation

func loadTasks(at directory: String) throws -> ([BenchmarkTask], String) {
  let files = try FileManager.default.contentsOfDirectory(atPath: directory).sorted().filter {
    guard $0.hasSuffix(".jsonl") else { return false }
    var info = stat()
    return lstat(path(directory, $0), &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
  }
  var digest = SHA256()
  var tasks: [BenchmarkTask] = []
  var seen = Set<String>()
  for file in files {
    let source = path(directory, file)
    let data = try Data(contentsOf: URL(fileURLWithPath: source))
    guard let text = String(data: data, encoding: .utf8) else {
      throw BenchmarkError("suite is not valid UTF-8: \(source)")
    }
    for bytes in [Data(file.utf8), data] {
      var count = UInt64(bytes.count).bigEndian
      withUnsafeBytes(of: &count) { digest.update(data: $0) }
      digest.update(data: bytes)
    }
    for (offset, rawLine) in text.components(separatedBy: "\n").enumerated() {
      let line = rawLine.trimmed
      if line.isEmpty || line.hasPrefix("#") { continue }
      do {
        let task = try parseTask(JSON.parse(line))
        try require(seen.insert(task.id).inserted, "duplicate task ID \(task.id)")
        tasks.append(task)
      } catch { throw BenchmarkError("\(error) at \(source):\(offset + 1)") }
    }
  }
  try require(!tasks.isEmpty, "suite has no tasks: \(directory)")
  return (tasks, digest.finalize().map { String(format: "%02x", $0) }.joined())
}

func parseTask(_ value: JSON) throws -> BenchmarkTask {
  guard let object = value.object else { throw BenchmarkError("task must be an object") }
  try rejectUnknown(object, ["id", "category", "prompt", "scorer", "pass_threshold"], "task")
  guard let id = object["id"]?.string, let category = object["category"]?.string,
    let prompt = object["prompt"]?.string, let scorer = object["scorer"]?.object
  else { throw BenchmarkError("task requires id, category, prompt, and scorer") }
  try require(isValidID(id), "invalid task ID \(id)")
  try require(!category.trimmed.isEmpty, "category must not be empty")
  try require(!prompt.trimmed.isEmpty, "prompt must not be empty")
  try validateScorer(scorer)
  let threshold: Double
  if let value = object["pass_threshold"] {
    guard let number = value.double else { throw BenchmarkError("pass_threshold must be a number") }
    threshold = number
  } else {
    threshold = 1
  }
  try require(
    threshold.isFinite && (0...1).contains(threshold), "pass_threshold must be between 0 and 1")
  return BenchmarkTask(
    id: id, category: category, prompt: prompt, scorer: scorer, passThreshold: threshold)
}

private func allowedScorerFields(for type: String?) throws -> [String] {
  switch type {
  case "exact": return ["type", "expected", "case_sensitive", "normalize_whitespace"]
  case "contains_all": return ["type", "expected", "case_sensitive", "max_chars"]
  case "regex": return ["type", "pattern", "case_sensitive"]
  case "json_exact": return ["type", "expected", "allow_code_fence"]
  default: throw BenchmarkError("unsupported scorer or missing scorer.type")
  }
}

private func validateScorerBooleans(_ scorer: [String: JSON]) throws {
  for key in ["case_sensitive", "normalize_whitespace", "allow_code_fence"] {
    if let value = scorer[key] { try require(value.bool != nil, "scorer.\(key) must be boolean") }
  }
}

private func validateExactScorer(_ scorer: [String: JSON]) throws {
  guard let value = scorer["expected"] else {
    throw BenchmarkError("scorer.expected is required")
  }
  let alternatives = value.array ?? [value]
  try require(
    !alternatives.isEmpty && alternatives.allSatisfy { $0.string != nil || $0.double != nil },
    "exact expected must be a string, number, or non-empty array of strings and numbers")
  // The response is trimmed and an empty response scores zero, so a blank answer can never pass.
  try require(
    !alternatives.contains { $0.string?.trimmed.isEmpty == true },
    "exact expected must not contain blank strings")
}

private func validateContainsScorer(_ scorer: [String: JSON], caseSensitive: Bool) throws {
  try validateContains(scorer["expected"]?.array ?? [], caseSensitive: caseSensitive)
  if let limit = scorer["max_chars"] {
    try require(positiveInteger(limit) != nil, "scorer.max_chars must be a positive integer")
  }
}

private func validateRegexScorer(_ scorer: [String: JSON], caseSensitive: Bool) throws {
  guard let pattern = scorer["pattern"]?.string else {
    throw BenchmarkError("regex pattern is required")
  }
  _ = try compiledRegex(pattern, caseSensitive: caseSensitive)
}

func validateScorer(_ scorer: [String: JSON]) throws {
  let type = scorer["type"]?.string
  try rejectUnknown(scorer, allowedScorerFields(for: type), "scorer")
  try validateScorerBooleans(scorer)
  let caseSensitive = scorer["case_sensitive"]?.bool ?? true
  switch type {
  case "exact": try validateExactScorer(scorer)
  case "json_exact": try require(scorer["expected"] != nil, "scorer.expected is required")
  case "contains_all": try validateContainsScorer(scorer, caseSensitive: caseSensitive)
  case "regex": try validateRegexScorer(scorer, caseSensitive: caseSensitive)
  default: break
  }
}
