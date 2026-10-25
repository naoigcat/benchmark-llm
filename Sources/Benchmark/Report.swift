import Darwin
import Foundation

// Lines stay bytes so a final record cut inside a multibyte character is still the ignored tail.
private func readTrialRecords(_ data: Data, source: String) throws -> [JSON] {
  let lines = data.split(separator: 10, omittingEmptySubsequences: true).filter {
    !String(decoding: $0, as: UTF8.self).trimmed.isEmpty
  }
  var records: [JSON] = []
  for (index, line) in lines.enumerated() {
    do {
      records.append(try JSON.parse(Data(line)))
    } catch {
      guard index == lines.count - 1 else { throw error }
      standardError("warning: ignoring malformed final trial record in \(source)")
      break
    }
  }
  return records
}

func generateReport(runs: [String], output: String) throws -> [JSON] {
  try require(!runs.isEmpty, "at least one run directory is required")
  var manifests: [JSON] = []
  var trials: [JSON] = []
  for directory in runs {
    do {
      let manifest = try readJSON(path(directory, "manifest.json"))
      let data = try Data(contentsOf: URL(fileURLWithPath: path(directory, "trials.jsonl")))
      let recorded = try readTrialRecords(data, source: path(directory, "trials.jsonl"))
      try validateRun(manifest, trials: recorded)
      manifests.append(manifest)
      trials += recorded
    } catch { throw BenchmarkError("invalid run directory \(directory): \(error)") }
  }
  // Count before dropping superseded skips: those trials were still recorded by their run.
  let recordedTrials = Dictionary(trials.map { ($0["run_id"].text, 1) }, uniquingKeysWith: +)
  trials = droppingSupersededSkips(trials)
  try validateCombinedRuns(manifests, trials: trials)
  let first = manifests[0]
  guard let rawLanguage = first["report_settings"]["language"].string,
    let selectedLanguage = ReportLanguage(rawValue: rawLanguage)
  else { throw BenchmarkError("run manifest has an invalid report language") }
  let settings = first["selection"]
  guard let minimumPassRate = settings["minimum_pass_rate"].double,
    let minimumMedianTokensPerSecond = settings["minimum_median_tokens_per_second"].double,
    let maximumPeakSwapDeltaGib = settings["maximum_peak_swap_delta_gib"].double,
    let maximumBackendMemoryFraction = settings["maximum_backend_memory_fraction"].double
  else { throw BenchmarkError("run manifest has incomplete selection settings") }
  let criteria = SelectionSettings(
    minimumPassRate: minimumPassRate,
    minimumMedianTokensPerSecond: minimumMedianTokensPerSecond,
    maximumPeakSwapDeltaGib: maximumPeakSwapDeltaGib,
    maximumBackendMemoryFraction: maximumBackendMemoryFraction)
  try validateSelection(criteria)
  let summary = summarize(trials)
  let categories = summarize(trials, byCategory: true)
  try publishReportFiles(
    [
      "summary.csv": csv(summary, fields: summaryFields),
      "category-summary.csv": csv(categories, fields: categoryFields),
      "report.md": reportMarkdown(
        ReportMarkdownInput(
          manifests: manifests, summary: summary, categories: categories, trials: trials,
          recordedTrials: recordedTrials, selection: criteria, language: selectedLanguage)),
    ], output: output)
  return summary
}

func csvValue(_ value: JSON) -> String {
  if value == .null { return "" }
  if let text = value.string, let first = text.unicodeScalars.first,
    "\t\r\n".unicodeScalars.contains(first)
      || text.unicodeScalars.drop(while: { $0.properties.isWhitespace }).first.map({
        "=+-@".unicodeScalars.contains($0)
      }) == true
  {
    return "'" + text
  }
  return value.text
}

func csv(_ rows: [JSON], fields: [String]) -> String {
  func line(_ values: [String]) -> String {
    values.map { text in
      text.unicodeScalars.contains(where: { ",\"\r\n".unicodeScalars.contains($0) })
        ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"", options: .literal) + "\"" : text
    }.joined(separator: ",") + "\r\n"
  }
  return line(fields) + rows.map { row in line(fields.map { csvValue(row[$0]) }) }.joined()
}

/// Stage all outputs, retain prior files, then publish with rollback on any failed replacement.
private func stageReportFiles(
  _ files: [String: String], output: String, staging: String, previous: String, names: [String]
) throws -> Set<String> {
  var backedUp = Set<String>()
  for name in names {
    let destination = path(output, name)
    var info = stat()
    var mode: mode_t = 0o644
    if lstat(destination, &info) == 0 {
      try require(
        (info.st_mode & S_IFMT) == S_IFREG, "report output is not a regular file: \(destination)")
      guard link(destination, path(previous, name)) == 0 else { throw posixError("backup report") }
      backedUp.insert(name)
      mode = info.st_mode & 0o777
    } else if errno != ENOENT {
      throw posixError("inspect report")
    }
    // `names` are the sorted keys of `files`.
    try atomicWrite(Data(files[name]!.utf8), to: path(staging, name), mode: mode)
  }
  return backedUp
}

private func publishStagedReportFiles(
  staging: String, output: String, names: [String], replace: (String, String) -> Int32,
  published: inout [String]
) throws {
  try syncDirectory(output)
  for name in names {
    guard replace(path(staging, name), path(output, name)) == 0 else {
      throw posixError("publish report \(name)")
    }
    published.append(name)
  }
  try syncDirectory(output)
}

private func rollbackReportFiles(
  _ published: [String], backedUp: Set<String>, previous: String, output: String
) -> Bool {
  var failed = false
  for name in published.reversed() {
    let result =
      backedUp.contains(name)
      ? rename(path(previous, name), path(output, name)) : unlink(path(output, name))
    if result != 0 { failed = true }
  }
  do { try syncDirectory(output) } catch { failed = true }
  return failed
}

func publishReportFiles(
  _ files: [String: String], output: String, replace: (String, String) -> Int32 = { rename($0, $1) }
) throws {
  try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
  cleanupStaleDirectories(output, prefix: ".report-staging-")
  var staging = path(output, ".report-staging-" + UUID().uuidString)
  try privateDirectory(staging)
  let lock = try FileLock(staging, directory: true)
  var retainRecovery = false
  defer {
    if !retainRecovery { try? FileManager.default.removeItem(atPath: staging) }
    withExtendedLifetime(lock) {}
  }
  var previous = path(staging, "previous")
  try privateDirectory(previous)
  let names = files.keys.sorted()
  try require(!names.isEmpty, "at least one report file is required")
  for name in names {
    try require(
      !name.isEmpty && name != "." && name != ".." && !name.contains("/"),
      "report file name must be a single path component: \(name)")
  }
  let backedUp = try stageReportFiles(
    files, output: output, staging: staging, previous: previous, names: names)
  try syncDirectory(previous)
  try syncDirectory(staging)
  let recovery = path(output, ".report-recovery-" + UUID().uuidString)
  guard rename(staging, recovery) == 0 else { throw posixError("retain report backups") }
  staging = recovery
  previous = path(recovery, "previous")
  retainRecovery = true
  var published: [String] = []
  do {
    try publishStagedReportFiles(
      staging: staging, output: output, names: names, replace: replace, published: &published)
    retainRecovery = false
  } catch {
    retainRecovery = rollbackReportFiles(
      published, backedUp: backedUp, previous: previous, output: output)
    throw BenchmarkError(
      "cannot publish report files: \(error)"
        + (retainRecovery ? "; rollback failed; recovery files kept at \(staging)" : ""))
  }
}
