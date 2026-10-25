import Foundation

struct UsageError: Error { let message: String }

/// Runs the `benchmark` command with its arguments, excluding the executable name, and returns
/// its exit status; usage errors return 2 and interruptions return 130.
public func cliMain(_ arguments: [String]) -> Int32 {
  openStandardDescriptors()
  do { return try executeCLI(arguments) } catch let error as UsageError {
    standardError("error: \(error.message)\n\nFor more information, try '--help'.")
    return 2
  } catch let error as ApiError where error.isInterrupted {
    standardError("interrupted")
    return 130
  } catch {
    standardError("error: \(error)")
    return 1
  }
}

/// A closed 0–2 would be reused by the next `open` or `pipe`: a child's stdin pipe would then be
/// closed on exec, and output meant for the terminal would land in a lock or record file.
func openStandardDescriptors() {
  for descriptor in STDIN_FILENO...STDERR_FILENO where fcntl(descriptor, F_GETFD) == -1 {
    // `open` returns the lowest free descriptor, which is this one.
    _ = open("/dev/null", O_RDWR)
  }
}

private let help = """
  Benchmark local and cloud LLMs on Apple Silicon Macs.

  Usage: benchmark [COMMAND]

  Commands:
    doctor     Validate configuration, host, and endpoints
    run        Run benchmark trials
    login      Sign a reference agent CLI in to its benchmark profile
    report     Combine one or more recorded runs
    modelfile  Print a target's custom Ollama Modelfile to standard output
    help       Print this message or the help of the given subcommand(s)

  Options:
    -h, --help     Print help
    -V, --version  Print version
  """

private func commandHelp(_ command: String) -> String {
  switch command {
  case "doctor":
    """
    Validate configuration, host, and endpoints\n\nUsage: benchmark doctor [OPTIONS]\n\nOptions:\n      \
    --smoke  Generate one suite task per ready reference CLI product (uses subscription allowance)\n  \
    -h, --help   Print help
    """
  case "run":
    """
    Run benchmark trials\n\nUsage: benchmark run [OPTIONS]\n\nOptions:\n      --target <TARGETS>  \
    Select a target ID listed in Resources/benchmark.json (repeatable)\n      --repeat <REPEAT>   \
    Override run.repeat for this run only\n      --dry-run           Print the schedule without \
    sending requests\n  -h, --help              Print help
    """
  case "login":
    """
    Sign a reference agent CLI in to its benchmark profile\n\nUsage: benchmark login [OPTIONS] \
    [PRODUCT]\n\nArguments:\n  [PRODUCT]  Product to sign in: cursor, codex, claude, or \
    antigravity\n\nOptions:\n      --status  Report the profile's authentication state instead of \
    signing in\n  -h, --help    Print help
    """
  case "report":
    """
    Combine one or more recorded runs\n\nUsage: benchmark report <RUNS>...\n\nArguments:\n  <RUNS>...  \
    One or more run directories, including interrupted or failed runs; write reports inside a single run or to \
    Deliverables/Comparisons/ for multiple runs\n\nOptions:\n  -h, --help  Print help
    """
  case "modelfile":
    """
    Print a target's custom Ollama Modelfile to standard output\n\nUsage: benchmark modelfile \
    <TARGET>\n\nArguments:\n  <TARGET>  Target ID with a custom Modelfile\n\nOptions:\n  -h, --help  \
    Print help
    """
  default: help
  }
}

func executeCLI(_ arguments: [String]) throws -> Int32 {
  guard let command = arguments.first else {
    standardError(help)
    return 2
  }
  if ["--version", "-V"].contains(command) {
    guard arguments.count == 1 else {
      throw UsageError(message: "unexpected argument '\(arguments[1])'")
    }
    standardOutput("benchmark \(benchmarkVersion)")
    return 0
  }
  if ["--help", "-h"].contains(command) {
    guard arguments.count == 1 else {
      throw UsageError(message: "unexpected argument '\(arguments[1])'")
    }
    standardOutput(help)
    return 0
  }
  let commands = ["doctor", "run", "login", "report", "modelfile", "help"]
  if command == "help" {
    guard arguments.count <= 2 else {
      throw UsageError(message: "unexpected argument '\(arguments[2])'")
    }
    if let name = arguments.dropFirst().first, !commands.contains(name) {
      throw UsageError(message: "unrecognized subcommand '\(name)'")
    }
    standardOutput(arguments.count > 1 ? commandHelp(arguments[1]) : help)
    return 0
  }
  guard commands.contains(command) else {
    throw UsageError(message: "unrecognized subcommand '\(command)'")
  }
  let options = arguments.dropFirst().prefix(while: { $0 != "--" })
  if options.contains(where: { ["--help", "-h"].contains($0) }) {
    standardOutput(commandHelp(command))
    return 0
  }
  let parsed = try CLIArguments.parse(arguments, command: command)
  return try executeCommand(command, parsed: parsed)
}

private func executeDoctorCommand(_ parsed: CLIArguments) throws -> Int32 {
  guard parsed.positional.isEmpty else {
    throw UsageError(message: "unexpected argument '\(parsed.positional[0])'")
  }
  return try doctor(loadConfig(), smoke: parsed.flags.contains("--smoke"))
}

private func executeRunCommand(_ parsed: CLIArguments) throws -> Int32 {
  guard parsed.positional.isEmpty else {
    throw UsageError(message: "unexpected argument '\(parsed.positional[0])'")
  }
  if let directory = try runBenchmark(
    loadConfig(), requested: parsed.targets, repeatOverride: parsed.repeatCount,
    dryRun: parsed.flags.contains("--dry-run"))
  {
    standardOutput("report: \(path(directory, "report.md"))")
  }
  return 0
}

private func executeLoginCommand(_ parsed: CLIArguments) throws -> Int32 {
  guard parsed.positional.count <= 1 else {
    throw UsageError(message: "unexpected login argument")
  }
  // Status checks run in their own process group, so Ctrl-C must cancel them rather than kill us.
  installSignalHandlers()
  return try login(parsed.positional.first, status: parsed.flags.contains("--status"))
}

private func executeReportCommand(_ parsed: CLIArguments) throws -> Int32 {
  guard !parsed.positional.isEmpty else {
    throw UsageError(message: "the following required arguments were not provided: <RUNS>...")
  }
  return try reportInRepository(parsed.positional, repository: repositoryRoot)
}

private func executeModelfileCommand(_ parsed: CLIArguments) throws -> Int32 {
  guard parsed.positional.count == 1 else {
    throw UsageError(message: "expected one required <TARGET>")
  }
  let id = parsed.positional[0]
  guard targetDefinitions().contains(where: { $0.id == id }) else {
    throw UsageError(message: "unknown target \(id)")
  }
  guard let content = modelfile(for: id) else {
    throw BenchmarkError("no custom Modelfile is defined for target \(id)")
  }
  try FileHandle.standardOutput.write(contentsOf: Data(content.utf8))
  return 0
}

private func executeCommand(_ command: String, parsed: CLIArguments) throws -> Int32 {
  switch command {
  case "doctor": return try executeDoctorCommand(parsed)
  case "run": return try executeRunCommand(parsed)
  case "login": return try executeLoginCommand(parsed)
  case "report": return try executeReportCommand(parsed)
  case "modelfile": return try executeModelfileCommand(parsed)
  default: throw UsageError(message: "unrecognized subcommand '\(command)'")
  }
}

private func runDoctorChecks(
  _ config: BenchmarkConfig, tasks: [BenchmarkTask], host: HostConfig, servers: OllamaServers,
  smoke: Bool
) throws -> Bool {
  let workspaceRoot = try createWorkspaceRoot(for: config.targets)
  let cache = DoctorCache()
  var smoked = Set<String>()
  var allReady = true
  for target in config.targets {
    try checkInterrupted()
    if !target.eligible(on: host.id) {
      standardOutput("target \(target.id): SKIP (not eligible for \(host.id))")
      continue
    }
    if let error = servers.startupError(target) {
      standardOutput("target \(target.id): SKIP (\(error))")
      allReady = false
      continue
    }
    do {
      let adapter = try createAdapter(
        target, settings: config.run, cancellation: interruption, workspaceRoot: workspaceRoot)
      var result = try adapter.doctor(cache: cache)
      if smoke && result.ok && target.adapter == "cli-agent"
        && smoked.insert((target.eventSchema ?? "") + "\u{0}" + (target.command ?? "")).inserted
      {
        let task = tasks[0]
        standardOutput("smoke target \(target.id): generating task \(task.id)")
        do {
          _ = try adapter.generate(task, repeatNumber: 1)
          standardOutput("smoke target \(target.id): OK (assistant response parsed)")
        } catch { result = result.failed("generation smoke check failed: \(error)") }
      }
      standardOutput(
        """
        target \(target.id): \(result.ok ? "OK" : "SKIP") \
        (\(result.message)\(result.version.map { ", backend version=" + $0 } ?? ""))
        """
      )
      allReady = allReady && result.ok
    } catch {
      standardOutput(
        "target \(target.id): SKIP (doctor failed: \(redactCLIText(String(describing: error))))")
      allReady = false
    }
  }
  return allReady
}

func doctor(_ config: BenchmarkConfig, smoke: Bool, detectedHost: JSON? = nil) throws -> Int32 {
  let (tasks, digest) = try loadTasks(at: config.run.suitesDir)
  let detected = detectedHost ?? detectHost()
  let host = try selectHost(config.hosts, detected: detected)
  standardOutput(
    """
    config: \(config.sourcePath) (\(config.digest.prefix(12)))\nsuite: \(config.run.suitesDir) \
    (\(tasks.count) tasks, \(digest.prefix(12)))\nhost: \(host.id) | detected \
    chip=\(detected["chip"].string ?? "-") memory=\(gib(detected["memory_bytes"])) \
    macOS=\(detected["os_version"].string ?? "-")
    """
  )
  let lock = try RunLock(config.run.resultsDir)
  let profileLock = try lockProfiles(for: config.targets)
  defer { withExtendedLifetime((lock, profileLock)) {} }
  installSignalHandlers()
  for warning in memoryPreflightWarnings(config.targets, host: host.id) {
    standardError("warning: \(warning)")
  }
  let servers = try OllamaServers.ensure(config.targets, host: host.id)
  defer { withExtendedLifetime(servers) {} }
  for warning in servers.warnings { standardError("warning: \(warning)") }
  let allReady = try runDoctorChecks(
    config, tasks: tasks, host: host, servers: servers, smoke: smoke)
  try checkInterrupted()
  return allReady ? 0 : 1
}

func profileState(_ product: Product, profiles: String, secureParent: Bool = false) throws -> String
{
  guard product.profileExists(profiles) else {
    return
      """
      no benchmark profile prepared under the current isolation policy; run `mise run \
      execute login \(product.name)`
      """
  }
  try product.createProfile(profiles, secureParent: secureParent)
  let check = try runProcess(
    product.command, args: product.statusArgs, directory: product.scratch(profiles),
    environment: product.environment(profiles), timeout: 60, cancellation: interruption)
  switch authenticationState(product, status: check) {
  case .authenticated: return "authenticated"
  case .checkFailed, .notAuthenticated: return "not authenticated"
  case .unrecognized: return "status output not understood; the CLI version may have changed it"
  }
}

private func login(_ name: String?, status: Bool) throws -> Int32 {
  let profiles = try defaultProfilesDirectory()
  guard let name else {
    standardOutput("profiles: \(profiles)")
    for product in products {
      let state =
        status
        ? ((try? profileState(product, profiles: profiles, secureParent: true)) ?? "unavailable")
        : product.profileExists(profiles) ? "profile present" : "not signed in"
      try checkInterrupted()
      standardOutput(
        """
          \(product.name.padding(toLength: 12, withPad: " ", startingAt: 0)) \
        \(product.command.padding(toLength: 14, withPad: " ", startingAt: 0)) \(state)
        """
      )
    }
    standardOutput("\nSign in with: mise run execute login <product>")
    return 0
  }
  guard let product = products.first(where: { $0.name == name }) else {
    throw UsageError(
      message: "unknown product \(name); expected one of cursor, codex, claude, antigravity")
  }
  if status {
    standardOutput(
      "\(product.name): \(try profileState(product, profiles: profiles, secureParent: true))")
    return 0
  }
  let lock = try lockProfiles()
  defer { withExtendedLifetime(lock) {} }
  try product.createProfile(profiles, secureParent: true)
  standardOutput(
    "profile: \(product.root(profiles))\nrunning: \(([product.command] + product.loginArgs).joined(separator: " "))"
  )
  let exitStatus = try runInteractiveProcess(
    product.command, args: product.loginArgs, directory: product.scratch(profiles),
    environment: product.environment(profiles))
  // SIGINT is ignored during login, so only a forwarded SIGTERM or SIGHUP lands here; the CLI may
  // still exit 0 and must not get a marker.
  try checkInterrupted()
  try verifyInteractiveLogin(product, profiles: profiles, exitStatus: exitStatus)
  try product.writeMarker(profiles)
  standardOutput(
    "\(product.name): \(try profileState(product, profiles: profiles, secureParent: true))")
  return 0
}

func reportInRepository(_ inputs: [String], repository: String) throws -> Int32 {
  let runs = try inputs.map { try resolvePath($0) }
  var directories = Set<String>()
  for run in runs {
    let manifestPath = path(run, "manifest.json")
    var isDirectory = ObjCBool(false)
    let manifestExists = FileManager.default.fileExists(
      atPath: manifestPath, isDirectory: &isDirectory)
    try require(manifestExists, "invalid run directory \(run): manifest.json not found")
    try require(!isDirectory.boolValue, "invalid run directory \(run): manifest.json is not a file")
    directories.insert(URL(fileURLWithPath: run).deletingLastPathComponent().path)
  }
  let output: String
  if runs.count == 1 {
    output = runs[0]
  } else {
    output = try resolvePath(path(repository, "Deliverables/Comparisons"))
    directories.insert(output)
  }
  let locks = try directories.sorted().map(RunLock.init)
  defer { withExtendedLifetime(locks) {} }
  let summary = try generateReport(runs: runs, output: output)
  standardOutput(
    "runs: \(runs.count)\nsummary rows: \(summary.count)\nreport: \(path(output, "report.md"))")
  return 0
}

private struct CLIArguments {
  let arguments: [String]
  let command: String
  var positional: [String] = []
  var targets: [String] = []
  var repeatCount: Int?
  var flags = Set<String>()
  var index = 1
  var positionalOnly = false

  static func parse(_ arguments: [String], command: String) throws -> CLIArguments {
    var parsed = CLIArguments(arguments: arguments, command: command)
    while parsed.index < arguments.count { try parsed.parseNext() }
    return parsed
  }
  private mutating func parseNext() throws {
    let argument = arguments[index]
    index += 1
    if argument == "--" && !positionalOnly {
      positionalOnly = true
      return
    }
    guard argument.hasPrefix("-") && !positionalOnly else {
      positional.append(argument)
      return
    }
    let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      .map(String.init)
    let flag = parts[0]
    if command == "run" && ["--target", "--repeat"].contains(flag) {
      try parseValueOption(flag, parts: parts)
    } else if parts.count == 1 && isBooleanFlag(flag) {
      guard flags.insert(flag).inserted else {
        throw UsageError(message: "argument '\(flag)' cannot be used multiple times")
      }
    } else {
      throw UsageError(message: "unexpected argument '\(argument)' found")
    }
  }
  private func isBooleanFlag(_ flag: String) -> Bool {
    (command == "run" && flag == "--dry-run") || (command == "doctor" && flag == "--smoke")
      || (command == "login" && flag == "--status")
  }
  private mutating func parseValueOption(_ flag: String, parts: [String]) throws {
    let value: String
    if parts.count == 2 {
      value = parts[1]
    } else {
      // A negative number is a value for the range check to reject, not a missing value.
      guard index < arguments.count,
        !arguments[index].hasPrefix("-") || Int(arguments[index]) != nil
      else {
        throw UsageError(message: "a value is required for '\(flag)'")
      }
      value = arguments[index]
      index += 1
    }
    if flag == "--target" {
      guard !targets.contains(value) else {
        throw UsageError(message: "duplicate --target values are not allowed")
      }
      targets.append(value)
    } else {
      guard repeatCount == nil, let value = Int(value), value >= 1 else {
        throw UsageError(message: "invalid or repeated value for --repeat")
      }
      repeatCount = value
    }
  }
}
