import Foundation

func compiledRegex(_ pattern: String, caseSensitive: Bool) throws -> NSRegularExpression {
  try NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive])
}

func scoreBoolean(_ scorer: [String: JSON], _ key: String, default fallback: Bool) throws -> Bool {
  guard let value = scorer[key] else { return fallback }
  guard let boolean = value.bool else { throw BenchmarkError("scorer.\(key) must be boolean") }
  return boolean
}

func validateContains(_ values: [JSON], caseSensitive: Bool) throws {
  try require(
    !values.isEmpty && values.allSatisfy { $0.string != nil },
    "contains_all expected must be a non-empty string list")
  // An empty string never matches, which would cap the score below a full pass.
  try require(
    !values.contains { $0.text.isEmpty }, "contains_all expected must not contain empty strings")
  let comparable = values.map { caseSensitive ? $0.text : $0.text.caseFolded }
  try require(
    Set(comparable.map { Data($0.utf8) }).count == comparable.count,
    "contains_all expected must not contain duplicate values under case_sensitive")
}

private func comparableScoreText(_ value: String, caseSensitive: Bool) -> String {
  caseSensitive ? value : value.caseFolded
}

/// Literal search that ignores matches splitting a character, such as `か` inside `か` + U+3099.
private func containsWholeCharacters(_ text: String, _ part: String) -> Bool {
  var start = text.startIndex
  while let range = text.range(of: part, options: .literal, range: start..<text.endIndex) {
    if range.lowerBound.samePosition(in: text) != nil
      && range.upperBound.samePosition(in: text) != nil
      && !extendsNumber(text, range)
    {
      return true
    }
    start = text.unicodeScalars.index(after: range.lowerBound)
  }
  return false
}

// A number in `part` must not continue a longer number in `text`: "3時" is absent from "13時"
// and "0.3時". Only decimal digits count, so "東京3時" (京 has a numeric value) still matches.
private func extendsNumber(_ text: String, _ range: Range<String.Index>) -> Bool {
  let scalars = text.unicodeScalars
  guard !range.isEmpty else { return false }
  func isDigit(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.numericType == .decimal }
  // Up to two neighbouring scalars, nearest first.
  var before: [Unicode.Scalar] = []
  var index = range.lowerBound
  while before.count < 2, index > scalars.startIndex {
    index = scalars.index(before: index)
    before.append(scalars[index])
  }
  var after: [Unicode.Scalar] = []
  index = range.upperBound
  while after.count < 2, index < scalars.endIndex {
    after.append(scalars[index])
    index = scalars.index(after: index)
  }
  func continues(_ edge: Unicode.Scalar, _ near: [Unicode.Scalar]) -> Bool {
    guard isDigit(edge), let next = near.first else { return false }
    return isDigit(next) || (next == "." && near.count > 1 && isDigit(near[1]))
  }
  return continues(scalars[range.lowerBound], before)
    || continues(scalars[scalars.index(before: range.upperBound)], after)
}

private func normalizedScoreText(
  _ value: String, caseSensitive: Bool, normalizeWhitespace: Bool
) -> String {
  let trimmed = value.trimmed
  let normalized =
    normalizeWhitespace
    ? trimmed.unicodeScalars.split(whereSeparator: { $0.properties.isWhitespace }).map(String.init)
      .joined(separator: " ")
    : trimmed
  return comparableScoreText(normalized, caseSensitive: caseSensitive)
}

private func scoreExact(
  _ scorer: [String: JSON], response: String, caseSensitive: Bool
) throws -> ScoreResult {
  let normalizeWhitespace = try scoreBoolean(scorer, "normalize_whitespace", default: false)
  guard let expected = scorer["expected"] else {
    throw BenchmarkError("scorer.expected is required")
  }
  let normalizedResponse = normalizedScoreText(
    response, caseSensitive: caseSensitive, normalizeWhitespace: normalizeWhitespace)
  let matched = (expected.array ?? [expected]).contains {
    normalizedScoreText(
      $0.text, caseSensitive: caseSensitive, normalizeWhitespace: normalizeWhitespace
    ).utf8.elementsEqual(normalizedResponse.utf8)
  }
  return ScoreResult(score: matched ? 1 : 0, detail: matched ? "exact match" : "exact mismatch")
}

/// JSON Schema counts 20.0 as an integer, so accept integral numbers in either encoding.
func positiveInteger(_ value: JSON) -> UInt64? {
  countValue(value).flatMap { $0 > 0 ? $0 : nil }
}

private func scoreContainsAll(
  _ scorer: [String: JSON], response: String, caseSensitive: Bool
) throws -> ScoreResult {
  guard let values = scorer["expected"]?.array else {
    throw BenchmarkError("contains_all expected must be a non-empty string list")
  }
  try validateContains(values, caseSensitive: caseSensitive)
  if let limit = scorer["max_chars"] {
    guard let limit = positiveInteger(limit) else {
      throw BenchmarkError("max_chars must be a positive integer")
    }
    if response.trimmed.unicodeScalars.count > limit {
      return ScoreResult(score: 0, detail: "response exceeded \(limit) code points")
    }
  }
  let comparableResponse = comparableScoreText(response, caseSensitive: caseSensitive)
  let matched = values.filter {
    containsWholeCharacters(
      comparableResponse, comparableScoreText($0.text, caseSensitive: caseSensitive))
  }.count
  return ScoreResult(
    score: Double(matched) / Double(values.count),
    detail: "contained \(matched)/\(values.count) required values")
}

private func scoreRegex(
  _ scorer: [String: JSON], response: String, caseSensitive: Bool, cancellation: Cancellation
) throws -> ScoreResult {
  guard let pattern = scorer["pattern"]?.string else {
    throw BenchmarkError("regex pattern is required")
  }
  let matched = try regexMatches(
    pattern, response.trimmed, caseSensitive: caseSensitive, cancellation: cancellation)
  return ScoreResult(score: matched ? 1 : 0, detail: matched ? "regex matched" : "regex mismatch")
}

private func scoreJSON(_ scorer: [String: JSON], response: String) throws -> ScoreResult {
  guard let expected = scorer["expected"] else {
    throw BenchmarkError("scorer.expected is required")
  }
  var text = response.trimmed
  if try scoreBoolean(scorer, "allow_code_fence", default: false) {
    let fence = try NSRegularExpression(pattern: "(?is)^```(?:json)?\\s*(.*?)\\s*```$")
    if let match = fence.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let range = Range(match.range(at: 1), in: text)
    {
      text = String(text[range])
    }
  }
  do {
    let matched = try JSON.parse(text).equivalent(to: expected)
    return ScoreResult(score: matched ? 1 : 0, detail: matched ? "JSON matched" : "JSON mismatch")
  } catch {
    return ScoreResult(score: 0, detail: "invalid JSON: \(error.localizedDescription)")
  }
}

func scoreResponse(
  _ task: BenchmarkTask, response: String, cancellation: Cancellation = interruption
) throws -> ScoreResult {
  // Task loading validates scorer configuration, so an empty answer can fail uniformly without
  // invoking scorer-specific work. This intentionally also makes manually built invalid tasks
  // return the empty-answer result instead of raising a scorer error.
  if response.trimmed.isEmpty { return ScoreResult(score: 0, detail: "empty answer") }
  let scorer = task.scorer
  guard let type = scorer["type"]?.string else { throw BenchmarkError("scorer.type is required") }
  let caseSensitive = try scoreBoolean(scorer, "case_sensitive", default: true)
  let result: ScoreResult
  switch type {
  case "exact":
    result = try scoreExact(scorer, response: response, caseSensitive: caseSensitive)
  case "contains_all":
    result = try scoreContainsAll(scorer, response: response, caseSensitive: caseSensitive)
  case "regex":
    result = try scoreRegex(
      scorer, response: response, caseSensitive: caseSensitive, cancellation: cancellation)
  case "json_exact":
    result = try scoreJSON(scorer, response: response)
  default: throw BenchmarkError("unsupported scorer type: \(type)")
  }
  return result
}

func regexMatches(
  _ pattern: String, _ text: String, caseSensitive: Bool, cancellation: Cancellation = interruption
) throws -> Bool {
  let regex = try compiledRegex(pattern, caseSensitive: caseSensitive)
  let started = monotonicTime()
  var found = false
  var expired = false
  regex.enumerateMatches(
    in: text, options: [.reportProgress], range: NSRange(text.startIndex..., in: text)
  ) { match, _, stop in
    if match != nil {
      found = true
      stop.pointee = true
      return
    }
    if monotonicTime() - started > 1 || cancellation.isCancelled {
      expired = true
      stop.pointee = true
    }
  }
  if expired { try checkInterrupted(cancellation) }
  try require(!expired, "regex evaluation exceeded its time limit")
  return found
}
