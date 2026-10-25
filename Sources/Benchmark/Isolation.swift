import Darwin
import Foundation

let isolationPolicyVersion = 3
let launchEnvironment = [
  "PATH", "LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES", "TERM", "SSL_CERT_FILE", "SSL_CERT_DIR",
  "NODE_EXTRA_CA_CERTS", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy",
  "https_proxy", "all_proxy", "no_proxy", "REQUESTS_CA_BUNDLE",
]

struct Product: Sendable {
  let name: String
  let eventSchema: String
  let command: String
  let configVariable: String?
  var fixedEnvironment: [String: String] = [:]
  let statusArgs: [String]
  let authenticatedField: String?
  let loginArgs: [String]
  func root(_ profiles: String) -> String { path(profiles, name) }
  func scratch(_ profiles: String) -> String { path(root(profiles), "tmp") }
  func marker(_ profiles: String) -> String { path(root(profiles), "benchmark-profile.json") }
  func profileExists(_ profiles: String) -> Bool {
    (try? readJSON(marker(profiles))["isolation_policy_version"].int)
      == Int64(isolationPolicyVersion)
  }
  func createProfile(_ profiles: String, secureParent: Bool = false) throws {
    if secureParent {
      try privateDirectory(URL(fileURLWithPath: profiles).deletingLastPathComponent().path)
    }
    try privateDirectory(profiles)
    try privateDirectory(root(profiles))
    if configVariable != nil { try privateDirectory(path(root(profiles), name)) }
    try privateDirectory(scratch(profiles))
  }
  var managedVariables: [String] {
    (["HOME", "TMPDIR", "NO_COLOR"] + (configVariable.map { [$0] } ?? []) + fixedEnvironment.keys)
      .sorted()
  }
  func writeMarker(_ profiles: String) throws {
    try writeJSON(
      [
        "product": .string(name),
        "isolation_policy_version": .integer(Int64(isolationPolicyVersion)),
        "variables": .array(managedVariables.map(JSON.string)),
      ], to: marker(profiles), mode: 0o600)
  }
  func environment(
    _ profiles: String, inherited: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    var env = inherited.filter { launchEnvironment.contains($0.key) }
    env["HOME"] = root(profiles)
    env["TMPDIR"] = scratch(profiles)
    env["NO_COLOR"] = "1"
    if let configVariable { env[configVariable] = path(root(profiles), name) }
    env.merge(fixedEnvironment) { _, new in new }
    return env
  }
}

let products: [Product] = [
  Product(
    name: "cursor", eventSchema: "cursor-stream-json", command: "cursor-agent",
    configVariable: "CURSOR_CONFIG_DIR", fixedEnvironment: ["AGENT_CLI_CREDENTIAL_STORE": "file"],
    statusArgs: ["status", "--format", "json"], authenticatedField: "isAuthenticated",
    loginArgs: ["login"]),
  Product(
    name: "codex", eventSchema: "codex-jsonl", command: "codex", configVariable: "CODEX_HOME",
    statusArgs: ["login", "status"], authenticatedField: nil, loginArgs: ["login"]),
  Product(
    name: "claude", eventSchema: "claude-stream-json", command: "claude",
    configVariable: "CLAUDE_CONFIG_DIR", statusArgs: ["auth", "status"],
    authenticatedField: "loggedIn", loginArgs: ["auth", "login"]),
  Product(
    name: "antigravity", eventSchema: "antigravity-stream-json", command: "agy",
    configVariable: nil, statusArgs: ["models"], authenticatedField: nil, loginArgs: []),
]

func defaultProfilesDirectory() throws -> String {
  let env = ProcessInfo.processInfo.environment
  let base: String
  if let xdg = env["XDG_DATA_HOME"], xdg.hasPrefix("/") {
    base = xdg
  } else {
    guard let home = env["HOME"], home.hasPrefix("/") else {
      throw BenchmarkError("HOME must be an absolute path; cannot locate the benchmark profiles")
    }
    base = path(home, ".local/share")
  }
  let profiles = path(base, "benchmark/profiles")
  let resolvedProfiles = try resolvePath(profiles)
  let resolvedRepository = try resolvePath(repositoryRoot)
  try require(
    !isWithin(resolvedProfiles, resolvedRepository),
    "benchmark profiles must live outside the repository")
  return profiles
}

func createWorkspaceRoot() throws -> String {
  guard let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty else {
    throw BenchmarkError("HOME is not set")
  }
  let excluded = try [resolvePath(home), resolvePath(repositoryRoot)]
  var failures: [String] = []
  for temporary in [NSTemporaryDirectory(), "/tmp", "/var/tmp"] {
    let candidate = path(try resolvePath(temporary), "benchmark-workspaces-\(geteuid())")
    if excluded.contains(where: { isWithin(candidate, $0) }) { continue }
    do {
      return try prepareWorkspaceRoot(candidate)
    } catch { failures.append("\(candidate): \(error)") }
  }
  throw BenchmarkError(
    "cannot create a workspace outside HOME and the repository"
      + (failures.isEmpty ? "" : " (\(failures.joined(separator: "; ")))"))
}

/// Profiles are shared by every checkout of this user, so the per-checkout results lock alone
/// cannot stop a login in another worktree from rewriting a profile that a run is reading.
func lockProfiles(for targets: [TargetConfig]? = nil) throws -> FileLock? {
  if let targets, !targets.contains(where: { $0.adapter == "cli-agent" }) { return nil }
  // Without a usable location the reference targets fail preflight, so there is nothing to guard.
  guard let profiles = try? defaultProfilesDirectory() else { return nil }
  let parent = URL(fileURLWithPath: profiles).deletingLastPathComponent().path
  try privateDirectory(parent)
  return try FileLock(path(parent, ".benchmark.lock"))
}

func createWorkspaceRoot(for targets: [TargetConfig]) throws -> String? {
  guard targets.contains(where: { $0.adapter == "cli-agent" }) else { return nil }
  return try createWorkspaceRoot()
}

func verifyInteractiveLogin(
  _ product: Product, profiles: String, exitStatus: Int32
) throws {
  guard exitStatus != 0 else { return }
  guard product.name == "antigravity" else {
    throw BenchmarkError("\(product.command) exited with status \(exitStatus)")
  }
  let check = try runProcess(
    product.command, args: product.statusArgs, directory: product.scratch(profiles),
    environment: product.environment(profiles), timeout: 60, cancellation: interruption)
  try require(
    authenticationState(product, status: check) == .authenticated,
    "\(product.command) exited with status \(exitStatus) and authentication could not be verified")
  standardError(
    "warning: \(product.command) exited with status \(exitStatus); authentication check succeeded")
}

private func nestedAuthenticationFlag(_ value: JSON, field: String, depth: Int) -> Bool? {
  if let flag = value[field].bool { return flag }
  guard depth > 0 else { return nil }
  let children =
    value.array ?? value.object.map { object in object.keys.sorted().map { object[$0]! } } ?? []
  return children.lazy.compactMap {
    nestedAuthenticationFlag($0, field: field, depth: depth - 1)
  }.first
}

private func skipDeepJSONContainer(_ bytes: [UInt8], from start: Int) -> Int? {
  var depth = 0
  var quoted = false
  var escaped = false
  var cursor = start
  repeat {
    let byte = bytes[cursor]
    cursor += 1
    if quoted {
      if escaped {
        escaped = false
      } else if byte == 92 {
        escaped = true
      } else if byte == 34 {
        quoted = false
      }
    } else if byte == 34 {
      quoted = true
    } else if byte == 123 || byte == 91 {
      depth += 1
    } else if byte == 125 || byte == 93 {
      depth -= 1
    }
  } while cursor < bytes.count && depth > 0
  return depth > 0 ? nil : cursor
}

enum AuthenticationState { case checkFailed, authenticated, notAuthenticated, unrecognized }

/// Interprets a status command the same way for `doctor`, `run`, and `login --status`.
func authenticationState(_ product: Product, status: ProcessResult) -> AuthenticationState {
  guard status.success else { return .checkFailed }
  guard let field = product.authenticatedField else { return .authenticated }
  switch authenticatedFlag(status.output, field: field) {
  case true: return .authenticated
  case false: return .notAuthenticated
  case nil: return .unrecognized
  }
}

/// Scan complete JSON containers once. Children of a container never become new roots.
func authenticatedFlag(_ output: String, field: String) -> Bool? {
  let bytes = Array(output.utf8)
  var cursor = 0
  while cursor < bytes.count {
    guard bytes[cursor] == 123 || bytes[cursor] == 91 else {
      cursor += 1
      continue
    }
    let start = cursor
    var parser = JSONParser(bytes: bytes, offset: start)
    do {
      let value = try parser.prefixValue()
      if let flag = nestedAuthenticationFlag(value, field: field, depth: 16) { return flag }
      cursor = max(start + 1, parser.position)
    } catch {
      if parser.position >= bytes.count { return nil }
      if String(describing: error).contains("nesting limit") {
        // Skip the whole deep container without promoting an inner authentication flag.
        guard let next = skipDeepJSONContainer(bytes, from: start) else { return nil }
        cursor = next
      } else {
        cursor = max(start + 1, parser.position)
      }
    }
  }
  return nil
}
