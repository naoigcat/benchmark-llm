import Darwin
import Foundation
import Synchronization

final class Cancellation: Sendable {
  private let flag = Atomic<Bool>(false)
  var isCancelled: Bool { flag.load(ordering: .relaxed) }
  func cancel() { flag.store(true, ordering: .relaxed) }
  func reset() { flag.store(false, ordering: .relaxed) }
}

let interruption = Cancellation()
// write(contentsOf:) reports EPIPE as an error; write(_:) raises an exception that aborts cleanup.
func standardOutput(_ text: String) {
  try? FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8))
}
func installSignalHandlers() {
  // Initialize the cancellation storage before a signal handler can access it. Lazy global
  // initialization is not safe to begin from an async signal context.
  interruption.reset()
  signal(SIGPIPE, SIG_IGN)
  signal(SIGINT) { _ in interruption.cancel() }
  signal(SIGTERM) { _ in interruption.cancel() }
  signal(SIGHUP) { _ in interruption.cancel() }
}

func monotonicTime() -> Double { ProcessInfo.processInfo.systemUptime }
struct ProcessResult {
  var status: Int32
  var stdout: String
  var stderr: String
  var started: Double
  var ended: Double
  var cleanupMS: Double
  var stdoutTruncated: Bool = false
  var success: Bool { status == 0 }
  var output: String {
    let bytes = (stdout + (stdout.isEmpty || stderr.isEmpty ? "" : "\n") + stderr).utf8.prefix(
      processDiagnosticLimit)
    return diagnosticText(Data(bytes)).trimmed
  }
}

/// A capture limit may split the last scalar; retain the complete diagnostic prefix.
func diagnosticText(_ data: Data) -> String {
  for removed in 0...min(3, data.count) {
    if let text = String(data: data.dropLast(removed), encoding: .utf8) { return text }
  }
  // Malformed diagnostic bytes must not erase the valid text around them.
  return String(decoding: data, as: UTF8.self)
}

/// Returns an absolute path: posix_spawn changes directory before resolving a relative executable.
func executablePath(_ command: String, environment: [String: String]) throws -> String {
  let current = FileManager.default.currentDirectoryPath
  // Like execvp, skip directories: access(X_OK) also succeeds for a searchable directory.
  func isExecutableFile(_ candidate: String) -> Bool {
    var info = stat()
    return stat(candidate, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
      && access(candidate, X_OK) == 0
  }
  if command.contains("/") {
    try require(isExecutableFile(command), "cannot start \(command): executable not found")
    return command.hasPrefix("/") ? command : path(current, command)
  }
  for directory in (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").components(
    separatedBy: ":")
  {
    let candidate = path(directory.hasPrefix("/") ? directory : path(current, directory), command)
    if isExecutableFile(candidate) { return candidate }
  }
  throw ApiError("cannot start \(command): executable not found on PATH")
}

/// Nonblocking pipes are serviced together, including stdin, so a child cannot deadlock the caller.
/// waitid(WNOWAIT) reserves the leader PID until its process group has been terminated.
func runProcess(
  _ program: String, args: [String], directory: String? = nil,
  environment: [String: String] = ProcessInfo.processInfo.environment, input: String? = nil,
  timeout: Double, cancellation: Cancellation? = nil,
  captureLimit: Int = processDiagnosticLimit,
  onLine: ((String, Double) throws -> Void)? = nil
) throws -> ProcessResult {
  try require(timeout.isFinite && timeout > 0, "process timeout must be positive and finite")
  if cancellation?.isCancelled == true { throw ApiError("interrupted", interrupted: true) }
  let executable = try executablePath(program, environment: environment)
  let pipes = try ProcessPipes()
  let child = try spawnProcess(
    executable, arguments: [program] + args, directory: directory,
    environment: environment, pipes: pipes)
  let process = ProcessMonitor(pid: child.pid)
  pipes.prepareForIO()
  let output = ProcessOutput(pipes: pipes, input: input, captureLimit: captureLimit, onLine: onLine)
  while true {
    let now = monotonicTime()
    if cancellation?.isCancelled == true && output.failure == nil {
      output.failure = ApiError("CLI interrupted", interrupted: true)
    }
    if now - child.started >= timeout && process.exitedAt == nil && output.failure == nil {
      output.failure = ApiError("CLI command timed out after \(timeout) seconds", timeout: true)
    }
    try process.checkExit(at: now)
    if output.failure != nil || process.exitedAt != nil { process.terminate(at: now) }
    output.servicePipes()
    if let exitedAt = process.exitedAt,
      pipes.descriptors[1][0] < 0 && pipes.descriptors[2][0] < 0 || now - exitedAt > 1
    {
      break
    }
    if let deadline = process.terminationDeadline, now >= deadline {
      // Keep the timeout or interruption that caused the kill as the trial's reason.
      throw output.failure ?? ApiError("CLI did not terminate after SIGKILL")
    }
    let deadline = process.terminationDeadline ?? child.started + timeout
    waitForProcessIO(pipes, timeout: processWaitTimeout(until: deadline))
  }
  output.finishLines()
  let ended = monotonicTime()
  let status: Int32
  do {
    status = try process.reap(deadline: process.terminationDeadline ?? ended + 30)
  } catch { throw output.failure ?? error }
  if let failure = output.failure { throw failure }
  if status == 0 && !output.wroteCompletePrompt {
    throw ApiError("CLI exited before accepting the complete prompt")
  }
  return ProcessResult(
    status: status, stdout: diagnosticText(output.stdout),
    stderr: diagnosticText(output.stderr), started: child.started,
    ended: ended,
    cleanupMS: (monotonicTime() - ended) * 1000, stdoutTruncated: output.stdoutTruncated)
}

private let processPollInterval = 0.05

private func processWaitTimeout(until deadline: Double) -> Double {
  min(processPollInterval, max(0, deadline - monotonicTime()))
}

private func waitForProcessIO(_ pipes: ProcessPipes, timeout: Double) {
  for index in 0...2 {
    let descriptor = index == 0 ? pipes.descriptors[index][1] : pipes.descriptors[index][0]
    pipes.pollDescriptors[index].fd = descriptor
    pipes.pollDescriptors[index].events =
      index == 0 ? Int16(POLLOUT) : Int16(POLLIN | POLLHUP | POLLERR)
    pipes.pollDescriptors[index].revents = 0
  }
  let milliseconds = Int32((max(0, timeout) * 1000).rounded(.up))
  pipes.pollDescriptors.withUnsafeMutableBufferPointer { buffer in
    _ = Darwin.poll(buffer.baseAddress, nfds_t(buffer.count), milliseconds)
  }
}

func commandOutput(_ args: [String], timeout: Double = 5, directory: String? = nil) -> String? {
  guard let first = args.first,
    let result = try? runProcess(
      first, args: Array(args.dropFirst()), directory: directory, timeout: timeout,
      captureLimit: 16 * 1024 * 1024), result.success, !result.stdoutTruncated
  else { return nil }
  return result.stdout.trimmed
}
