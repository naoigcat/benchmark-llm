import Darwin
import Foundation

func checkInterrupted(_ cancellation: Cancellation = interruption) throws {
  if cancellation.isCancelled { throw ApiError("interrupted", interrupted: true) }
}

func endpointKey(_ baseURL: String) -> String {
  guard var url = URLComponents(string: baseURL) else { return baseURL }
  url.scheme = url.scheme?.lowercased()
  if url.path.isEmpty { url.path = "/" }
  if (url.scheme == "http" && url.port == 80) || (url.scheme == "https" && url.port == 443) {
    url.port = nil
  }
  return url.string ?? baseURL
}

/// Returns true only for ECONNREFUSED. Occupied, stalled, or invalid services never allow startup.
func connectionIsRefused(_ url: URLComponents, timeout: Double) throws -> Bool {
  let host = (url.host ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
  let family = host.contains(":") ? AF_INET6 : AF_INET
  let descriptor = socket(family, SOCK_STREAM, 0)
  guard descriptor >= 0 else { throw posixError("probe socket") }
  defer { close(descriptor) }
  _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
  guard
    let portNumber = UInt16(exactly: url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80))
  else { throw BenchmarkError("invalid endpoint port") }
  let port = portNumber.bigEndian
  let result: Int32
  if family == AF_INET {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port
    inet_pton(AF_INET, host, &address.sin_addr)
    result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
  } else {
    var address = sockaddr_in6()
    address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    address.sin6_family = sa_family_t(AF_INET6)
    address.sin6_port = port
    inet_pton(AF_INET6, host, &address.sin6_addr)
    result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
      }
    }
  }
  if result == 0 { return false }
  if errno == ECONNREFUSED { return true }
  guard errno == EINPROGRESS else { throw posixError("cannot probe Ollama") }
  var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
  guard poll(&pollDescriptor, 1, Int32(min(timeout * 1000, Double(Int32.max)))) > 0 else {
    throw ApiError("Ollama connection probe timed out", timeout: true)
  }
  var error: Int32 = 0
  var size = socklen_t(MemoryLayout<Int32>.size)
  guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0 else {
    throw posixError("probe socket status")
  }
  if error == ECONNREFUSED { return true }
  try require(error == 0, "cannot probe Ollama: \(String(cString: strerror(error)))")
  return false
}

final class OwnedServer {
  let pid: pid_t
  let logPath: String
  private var reaped = false
  init(
    command: String = "ollama", arguments: [String] = ["serve"], address: String,
    logDirectory: String
  ) throws {
    var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("OLLAMA_") }
    env["OLLAMA_HOST"] = address
    // Resolve first so a missing executable leaves no empty log behind.
    let executable = try executablePath(command, environment: env)
    try privateDirectory(logDirectory)
    logPath = path(logDirectory, "ollama-" + UUID().uuidString + ".log")
    let log = open(logPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard log >= 0 else { throw posixError("create Ollama log") }
    defer { close(log) }
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
    // Keep server diagnostics out of the benchmark warnings without losing startup failures.
    let redirect = posix_spawn_file_actions_adddup2(&actions, log, STDERR_FILENO)
    try require(redirect == 0, "cannot redirect Ollama stderr")
    let (child, code) = spawn(
      executable, arguments: [command] + arguments, environment: env, actions: &actions,
      defaultSignals: [SIGPIPE, SIGINT, SIGTERM, SIGHUP], newProcessGroup: true)
    guard code == 0 else {
      throw BenchmarkError("cannot start ollama serve: \(String(cString: strerror(code)))")
    }
    pid = child
  }
  var hasExited: Bool {
    if reaped { return true }
    var info = siginfo_t()
    let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
    if result < 0 && errno == ECHILD {
      reaped = true
      return true
    }
    return result == 0 && info.si_pid == pid
  }
  func stop() {
    guard !reaped else { return }
    if !hasExited { kill(pid, SIGTERM) }
    if reaped { return }
    let deadline = monotonicTime() + 5
    while !hasExited && monotonicTime() < deadline { usleep(10000) }
    if reaped { return }
    // The unreaped leader still reserves its private process group.
    kill(-pid, SIGKILL)
    let finalDeadline = monotonicTime() + 5
    var status: Int32 = 0
    while monotonicTime() < finalDeadline {
      let result = waitpid(pid, &status, WNOHANG)
      if result == pid || (result < 0 && errno == ECHILD) {
        reaped = true
        return
      }
      usleep(10000)
    }
    standardError("warning: could not reap owned Ollama PID \(pid)")
  }
  deinit { stop() }
}

final class OllamaServers {
  var children: [OwnedServer] = []
  var failures: [String: String] = [:]
  var environments: [String: JSON] = [:]
  var warnings: [String] = []
  /// Released after `deinit` stops the children, so no other run reuses a server being stopped.
  var endpointLocks: [FileLock] = []
  private var temporaryLogDirectory: String?
  func startupError(_ target: TargetConfig) -> String? { failures[endpointKey(target.baseUrl)] }
  deinit {
    for child in children { child.stop() }
    if let temporaryLogDirectory {
      try? FileManager.default.removeItem(atPath: temporaryLogDirectory)
    }
  }
}

private struct OllamaStartupOptions {
  let cancellation: Cancellation
  let startupTimeout: Double
  let command: String
  let arguments: [String]
  let logDirectory: String
}

/// True when `pid` itself holds a TCP socket listening on `port`.
func processListens(_ pid: pid_t, port: Int) -> Bool {
  let stride = MemoryLayout<proc_fdinfo>.stride
  let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
  guard size > 0 else { return false }
  var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride)
  let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, size)
  guard filled > 0 else { return false }
  for descriptor in descriptors.prefix(Int(filled) / stride)
  where descriptor.proc_fdtype == PROX_FDTYPE_SOCKET {
    var info = socket_fdinfo()
    let expected = Int32(MemoryLayout<socket_fdinfo>.size)
    guard
      proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, expected) == expected,
      info.psi.soi_kind == SOCKINFO_TCP,
      info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN
    else { continue }
    let local = info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport
    if Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: local))) == port { return true }
  }
  return false
}

private func startOwnedServer(
  key: String, address: String, port: Int, servers: OllamaServers, options: OllamaStartupOptions
) throws {
  let child = try OwnedServer(
    command: options.command, arguments: options.arguments, address: address,
    logDirectory: options.logDirectory)
  standardError("ollama: server log: \(child.logPath)")
  do {
    let deadline = monotonicTime() + options.startupTimeout
    var ready = false
    var lastError = "connection refused"
    while case let remaining = deadline - monotonicTime(), remaining > 0 {
      try checkInterrupted(options.cancellation)
      do {
        try probeVersion(key, timeout: min(1, remaining), cancellation: options.cancellation)
        ready = true
      } catch { lastError = redactCLIText(String(describing: error)) }
      try require(
        child.hasExited == false, "ollama serve exited before becoming ready at \(key)")
      // Another server can claim the port between the refused probe and our child's bind.
      if ready {
        try require(
          processListens(child.pid, port: port),
          "another process answered at \(key) before ollama serve could listen")
        break
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
    try require(ready, "ollama serve did not become ready at \(key): \(lastError)")
    servers.children.append(child)
    servers.environments[key] = ["OLLAMA_HOST": .string(address)]
    standardError("ollama: started server at \(key) (PID \(child.pid))")
  } catch {
    child.stop()
    throw error
  }
}

/// The results lock is per checkout, so a run in another worktree would otherwise reuse, unload
/// models on, and finally stop the same server. The per-user temporary directory is shared by
/// every checkout. Endpoints are loopback only, so the port names the server whichever loopback
/// spelling a configuration uses.
func lockEndpoint(port: Int) throws -> FileLock {
  let root = path(NSTemporaryDirectory(), "benchmark-endpoint-locks-\(geteuid())")
  try privateDirectory(root)
  return try FileLock(path(root, "port-\(port).lock"))
}

private func ensureEndpoint(
  _ target: TargetConfig, servers: OllamaServers, seen: inout Set<String>,
  options: OllamaStartupOptions
) throws {
  try checkInterrupted(options.cancellation)
  let key = endpointKey(target.baseUrl)
  guard seen.insert(key).inserted else { return }
  servers.environments[key] = .null
  guard let url = URLComponents(string: key) else {
    throw BenchmarkError("invalid Ollama endpoint: \(key)")
  }
  servers.endpointLocks.append(
    try lockEndpoint(port: url.port ?? (url.scheme == "https" ? 443 : 80)))
  // HTTPS endpoints are never auto-started; the null environment marks this externally managed
  // endpoint for the resident-model inspection below.
  if url.scheme == "https" { return }
  do {
    if try !connectionIsRefused(url, timeout: 1) {
      try probeVersion(key, timeout: 1, cancellation: options.cancellation)
      standardError("ollama: using existing server at \(key)")
      return
    }
    try checkInterrupted(options.cancellation)
    let port = url.port ?? 80
    let address = (url.host ?? "127.0.0.1") + ":" + String(port)
    try startOwnedServer(
      key: key, address: address, port: port, servers: servers, options: options)
  } catch {
    try checkInterrupted(options.cancellation)
    let message = redactCLIText(String(describing: error))
    servers.failures[key] = message
    standardError("ollama: \(message)")
  }
}

private func inspectResidentModels(_ servers: OllamaServers, cancellation: Cancellation) throws {
  for key in servers.environments.keys.sorted()
  where servers.environments[key] == .null && servers.failures[key] == nil {
    try checkInterrupted(cancellation)
    let response = try? httpRequest(
      "GET", url: key + "api/ps", timeout: 1, cancellation: cancellation)
    if let models = response?["models"].array {
      let names = models.compactMap { model in
        [model["name"], model["model"]].compactMap(\.string).first { !$0.trimmed.isEmpty }
      }
      if names.count == models.count {
        if !names.isEmpty {
          servers.warnings.append(
            """
            Existing Ollama server at \(key) has resident models: \
            \(JSON.array(Set(names).sorted().map(JSON.string)).serialized()). Their memory may affect RSS and \
            swap measurements; unload unrelated models before measuring.
            """
          )
        }
        continue
      }
    }
    servers.warnings.append(
      "Could not inspect resident models at \(key); model memory attribution could not be checked."
    )
  }
}

extension OllamaServers {
  static func ensure(
    _ targets: [TargetConfig], host: String, cancellation: Cancellation = interruption,
    startupTimeout: Double = 30, command: String = "ollama", arguments: [String] = ["serve"],
    logDirectory: String? = nil
  ) throws -> OllamaServers {
    let servers = OllamaServers()
    for target in targets { try target.validate() }
    let effectiveLogDirectory: String
    if let logDirectory {
      effectiveLogDirectory = logDirectory
    } else {
      let root = path(NSTemporaryDirectory(), "benchmark-server-logs-\(geteuid())")
      try privateDirectory(root)
      cleanupStaleDirectories(root, prefix: "doctor-")
      let directory = path(root, "doctor-" + UUID().uuidString)
      try privateDirectory(directory)
      servers.temporaryLogDirectory = directory
      effectiveLogDirectory = directory
    }
    let options = OllamaStartupOptions(
      cancellation: cancellation, startupTimeout: startupTimeout, command: command,
      arguments: arguments,
      logDirectory: effectiveLogDirectory)
    var seen = Set<String>()
    for target in targets where target.adapter == "ollama" && target.eligible(on: host) {
      try ensureEndpoint(target, servers: servers, seen: &seen, options: options)
    }
    try inspectResidentModels(servers, cancellation: cancellation)
    try checkInterrupted(cancellation)
    return servers
  }
}

private func probeVersion(_ key: String, timeout: Double, cancellation: Cancellation) throws {
  let json = try httpRequest(
    "GET", url: key + "api/version", timeout: timeout, cancellation: cancellation,
    maximumBytes: 4096, allowRedirects: false)
  try require(
    !(json["version"].string ?? "").trimmed.isEmpty, "no Ollama version in response from \(key)")
}

func standardError(_ text: String) {
  try? FileHandle.standardError.write(contentsOf: Data((text + "\n").utf8))
}
