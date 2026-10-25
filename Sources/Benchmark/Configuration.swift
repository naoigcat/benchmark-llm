import Foundation

/// The checkout this executable was built from; independent of the invocation directory.
let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .deletingLastPathComponent().deletingLastPathComponent().path

func path(_ base: String, _ child: String) -> String {
  URL(fileURLWithPath: base).appendingPathComponent(child).path
}

func resolvePath(
  _ value: String, relativeTo base: String = FileManager.default.currentDirectoryPath
) throws -> String {
  var value = value
  if value == "~" || value.hasPrefix("~/") {
    guard let home = ProcessInfo.processInfo.environment["HOME"] else {
      throw BenchmarkError("cannot expand '~' because HOME is not set")
    }
    value = path(home, value == "~" ? "" : String(value.dropFirst(2)))
  }
  // resolvingSymlinksInPath leaves missing paths untouched, so resolve the deepest existing ancestor
  // and append the rest; otherwise a link above a not-yet-created directory escapes containment checks.
  var existing = URL(fileURLWithPath: value.hasPrefix("/") ? value : path(base, value))
    .standardizedFileURL.path
  var missing: [String] = []
  while true {
    if let resolved = realpath(existing, nil) {
      defer { free(resolved) }
      return missing.reduce(String(cString: resolved)) { path($0, $1) }
    }
    guard errno == ENOENT, existing != "/" else { throw posixError("resolve \(value)") }
    missing.insert((existing as NSString).lastPathComponent, at: 0)
    existing = (existing as NSString).deletingLastPathComponent
  }
}

func loadConfig() throws -> BenchmarkConfig {
  let root = try resolvePath(repositoryRoot)
  let source = try resolvePath(path(root, "Resources/benchmark.json"))
  try require(
    URL(fileURLWithPath: source).deletingLastPathComponent().path == path(root, "Resources"),
    "config must remain in the project Resources directory")
  return try loadConfig(at: source, definitions: targetDefinitions())
}

private func loadHosts(_ root: [String: JSON]) throws -> [HostConfig] {
  guard let hostItems = root["hosts"]?.array, !hostItems.isEmpty else {
    throw BenchmarkError("at least one hosts entry is required")
  }
  return try hostItems.map { entry -> HostConfig in
    guard let fields = entry.object else { throw BenchmarkError("host must be an object") }
    try rejectUnknown(fields, ["id", "chip", "memory_gib"], "host")
    let id = try configString(fields, "id", "host")
    try require(isValidID(id), "invalid host ID: \(id)")
    let memory = try configInteger(fields, "memory_gib", "host")
    try require(memory > 0, "host.memory_gib must be at least 1")
    return try HostConfig(
      id: id, chip: configString(fields, "chip", "host"), memoryGib: UInt64(memory))
  }
}

private func loadTargets(
  _ root: [String: JSON], definitions: [TargetConfig], hosts: [HostConfig]
) throws -> [TargetConfig] {
  guard let targetItems = root["targets"]?.array, !targetItems.isEmpty else {
    throw BenchmarkError("at least one targets entry is required")
  }
  return try targetItems.map { entry -> TargetConfig in
    guard let fields = entry.object else { throw BenchmarkError("target must be an object") }
    try rejectUnknown(fields, ["id", "eligible_hosts"], "target")
    let id = try configString(fields, "id", "target")
    guard var target = definitions.first(where: { $0.id == id }) else {
      throw BenchmarkError("unknown target \(id); define it in Sources/Benchmark/Targets.swift")
    }
    if let value = fields["eligible_hosts"] {
      target.eligibleHosts = try strings(value, "target.eligible_hosts")
    }
    try require(
      target.eligibleHosts.allSatisfy { hostID in hosts.contains { $0.id == hostID } },
      "target \(id) references unknown eligible_hosts")
    try target.validate()
    return target
  }
}

func loadConfig(at source: String, definitions: [TargetConfig]) throws -> BenchmarkConfig {
  let source = try resolvePath(source)
  let payload = try Data(contentsOf: URL(fileURLWithPath: source))
  let document = try JSON.parse(payload)
  guard let root = document.object else {
    throw BenchmarkError("configuration root must be an object")
  }
  try rejectUnknown(root, ["run", "report", "selection", "hosts", "targets"], "configuration root")
  func object(_ key: String) throws -> [String: JSON] {
    guard let value = root[key] else { return [:] }
    guard let result = value.object else { throw BenchmarkError("\(key) must be an object") }
    return result
  }
  let base = URL(fileURLWithPath: source).deletingLastPathComponent().path
  let project = URL(fileURLWithPath: base).deletingLastPathComponent().path
  let run = try loadRunSettings(object("run"), base: base, project: project)
  let report = try object("report")
  try rejectUnknown(report, ["language"], "report")
  guard
    let language = ReportLanguage(rawValue: try configString(report, "language", "report", "ja"))
  else { throw BenchmarkError("report.language must be 'ja' or 'en'") }
  let settings = try object("selection")
  let selectionFields = [
    "minimum_pass_rate", "minimum_median_tokens_per_second", "maximum_peak_swap_delta_gib",
    "maximum_backend_memory_fraction",
  ]
  try rejectUnknown(settings, selectionFields, "selection")
  let defaults = SelectionSettings()
  let selection = try SelectionSettings(
    minimumPassRate: configNumber(
      settings, selectionFields[0], "selection", defaults.minimumPassRate),
    minimumMedianTokensPerSecond: configNumber(
      settings, selectionFields[1], "selection", defaults.minimumMedianTokensPerSecond),
    maximumPeakSwapDeltaGib: configNumber(
      settings, selectionFields[2], "selection", defaults.maximumPeakSwapDeltaGib),
    maximumBackendMemoryFraction: configNumber(
      settings, selectionFields[3], "selection", defaults.maximumBackendMemoryFraction))
  try validateSelection(selection)
  let hosts = try loadHosts(root)
  let targets = try loadTargets(root, definitions: definitions, hosts: hosts)
  try require(Set(hosts.map(\.id)).count == hosts.count, "duplicate host IDs")
  try require(Set(targets.map(\.id)).count == targets.count, "duplicate target IDs")
  return BenchmarkConfig(
    sourcePath: source, digest: sha256(payload), run: run, language: language,
    selection: selection, hosts: hosts, targets: targets)
}

func validateSelection(_ settings: SelectionSettings) throws {
  try require(
    settings.minimumPassRate.isFinite && (0...1).contains(settings.minimumPassRate),
    "selection.minimum_pass_rate must be between 0 and 1")
  try require(
    settings.minimumMedianTokensPerSecond.isFinite && settings.minimumMedianTokensPerSecond >= 0,
    "selection.minimum_median_tokens_per_second must not be negative")
  try require(
    settings.maximumPeakSwapDeltaGib.isFinite && settings.maximumPeakSwapDeltaGib >= 0,
    "selection.maximum_peak_swap_delta_gib must not be negative")
  try require(
    settings.maximumBackendMemoryFraction.isFinite && settings.maximumBackendMemoryFraction > 0
      && settings.maximumBackendMemoryFraction <= 1,
    "selection.maximum_backend_memory_fraction must be greater than 0 and at most 1")
}

private func configInteger(
  _ fields: [String: JSON], _ key: String, _ context: String, _ fallback: Int64? = nil
)
  throws -> Int64
{
  guard let value = fields[key] else {
    if let fallback { return fallback }
    throw BenchmarkError("\(context).\(key) is required")
  }
  guard let integer = value.int else {
    throw BenchmarkError("\(context).\(key) must be an integer")
  }
  return integer
}

private func configNumber(
  _ fields: [String: JSON], _ key: String, _ context: String, _ fallback: Double
) throws
  -> Double
{
  guard let value = fields[key] else { return fallback }
  guard let number = value.double else {
    throw BenchmarkError("\(context).\(key) must be a number")
  }
  if let integer = value.int {
    try require(
      Int64(exactly: number) == integer,
      "\(context).\(key) cannot be represented as a number without losing precision")
  }
  return number
}

private func configString(
  _ fields: [String: JSON], _ key: String, _ context: String, _ fallback: String? = nil
)
  throws -> String
{
  guard let value = fields[key] else {
    if let fallback { return fallback }
    throw BenchmarkError("\(context).\(key) is required")
  }
  guard let text = value.string else { throw BenchmarkError("\(context).\(key) must be a string") }
  return text
}

private func loadRunSettings(_ runFields: [String: JSON], base: String, project: String) throws
  -> RunSettings
{
  try rejectUnknown(
    runFields,
    [
      "repeat", "request_timeout_seconds", "cooldown_seconds", "max_output_tokens", "temperature",
      "seed", "cache_conditions", "system_prompt",
    ], "run")
  let seed = try configInteger(runFields, "seed", "run")
  try require(seed >= 0, "run.seed must not be negative")
  // Omitted keys keep the RunSettings defaults, which README's defaults table is checked against.
  var run = RunSettings(
    resultsDir: try resolvePath("Deliverables/Runs", relativeTo: project),
    suitesDir: try resolvePath("suites", relativeTo: base), workdir: project, seed: UInt64(seed))
  let repeatCount = try configInteger(runFields, "repeat", "run", Int64(run.repeatCount))
  let tokens = try configInteger(
    runFields, "max_output_tokens", "run", Int64(run.maxOutputTokens))
  try require(repeatCount >= 1, "run.repeat must be at least 1")
  try require(tokens >= 1, "run.max_output_tokens must be at least 1")
  run.repeatCount = Int(repeatCount)
  run.maxOutputTokens = UInt64(tokens)
  run.requestTimeoutSeconds = try configNumber(
    runFields, "request_timeout_seconds", "run", run.requestTimeoutSeconds)
  run.cooldownSeconds = try configNumber(runFields, "cooldown_seconds", "run", run.cooldownSeconds)
  run.temperature = try configNumber(runFields, "temperature", "run", run.temperature)
  try require(
    run.requestTimeoutSeconds.isFinite && run.requestTimeoutSeconds > 0
      && run.requestTimeoutSeconds < Double(UInt64.max),
    "run.request_timeout_seconds must be positive and representable")
  try require(
    run.cooldownSeconds.isFinite && run.cooldownSeconds >= 0
      && run.cooldownSeconds < Double(UInt64.max),
    "run.cooldown_seconds must not be negative and must be representable")
  try require(
    run.temperature.isFinite && (0...2).contains(run.temperature),
    "run.temperature must be a finite number between 0 and 2")
  run.systemPrompt = try configString(runFields, "system_prompt", "run", run.systemPrompt)
  if let conditions = runFields["cache_conditions"] {
    run.cacheConditions = try strings(conditions, "run.cache_conditions")
  }
  try require(
    !run.cacheConditions.isEmpty
      && run.cacheConditions.allSatisfy { ["cold", "warm"].contains($0) },
    "run.cache_conditions must contain cold and/or warm")
  try require(
    Set(run.cacheConditions).count == run.cacheConditions.count,
    "run.cache_conditions must not contain duplicates")
  return run
}
