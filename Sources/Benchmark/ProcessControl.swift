import Darwin
import Foundation

func decodedProcessStatus(_ status: Int32) -> Int32 {
  status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
}

final class ProcessPipes {
  var descriptors = [[Int32]](repeating: [Int32](repeating: -1, count: 2), count: 3)
  var pollDescriptors = [pollfd](
    repeating: pollfd(fd: -1, events: 0, revents: 0), count: 3)

  init() throws {
    for index in descriptors.indices {
      guard pipe(&descriptors[index]) == 0 else { throw posixError("pipe") }
      for descriptor in descriptors[index] { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
    }
  }

  deinit {
    for pair in descriptors {
      for descriptor in pair where descriptor >= 0 { Darwin.close(descriptor) }
    }
  }

  func close(_ pipeIndex: Int, _ endIndex: Int) {
    if descriptors[pipeIndex][endIndex] >= 0 {
      Darwin.close(descriptors[pipeIndex][endIndex])
      descriptors[pipeIndex][endIndex] = -1
    }
  }

  func prepareForIO() {
    for (pipeIndex, endIndex) in [(0, 0), (1, 1), (2, 1)] { close(pipeIndex, endIndex) }
    for descriptor in [descriptors[0][1], descriptors[1][0], descriptors[2][0]] {
      _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
    }
    // Prevent SIGPIPE from aborting the benchmark when a CLI refuses its prompt.
    _ = fcntl(descriptors[0][1], F_SETNOSIGPIPE, 1)
  }
}

func spawnProcess(
  _ executable: String, arguments: [String], directory: String?,
  environment: [String: String], pipes: ProcessPipes
) throws -> (pid: pid_t, started: Double) {
  var actions: posix_spawn_file_actions_t?
  posix_spawn_file_actions_init(&actions)
  defer { posix_spawn_file_actions_destroy(&actions) }
  let descriptors = pipes.descriptors
  for (source, destination) in [
    (descriptors[0][0], STDIN_FILENO), (descriptors[1][1], STDOUT_FILENO),
    (descriptors[2][1], STDERR_FILENO),
  ] {
    posix_spawn_file_actions_adddup2(&actions, source, destination)
  }
  for pair in descriptors {
    for descriptor in pair
    where descriptor >= 0 && ![STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO].contains(descriptor) {
      posix_spawn_file_actions_addclose(&actions, descriptor)
    }
  }
  if let directory { posix_spawn_file_actions_addchdir_np(&actions, directory) }
  let started = monotonicTime()
  let (pid, code) = spawn(
    executable, arguments: arguments, environment: environment, actions: &actions,
    defaultSignals: [SIGPIPE, SIGINT, SIGTERM, SIGHUP], newProcessGroup: true)
  guard code == 0 else {
    throw ApiError("cannot start \(arguments[0]): \(String(cString: strerror(code)))")
  }
  return (pid, started)
}

/// Every child starts with an empty signal mask and the listed signals at their defaults; the
/// benchmark itself ignores SIGPIPE, and ignored dispositions survive exec.
func spawn(
  _ executable: String, arguments: [String], environment: [String: String],
  actions: inout posix_spawn_file_actions_t?, defaultSignals signals: [Int32],
  newProcessGroup: Bool
) -> (pid: pid_t, code: Int32) {
  var attributes: posix_spawnattr_t?
  let initialized = posix_spawnattr_init(&attributes)
  guard initialized == 0 else { return (0, initialized) }
  defer { posix_spawnattr_destroy(&attributes) }
  var defaultSignals = sigset_t()
  sigemptyset(&defaultSignals)
  for signal in signals { sigaddset(&defaultSignals, signal) }
  var mask = sigset_t()
  sigemptyset(&mask)
  posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
  posix_spawnattr_setsigmask(&attributes, &mask)
  var flags = POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
  if newProcessGroup {
    flags |= POSIX_SPAWN_SETPGROUP
    posix_spawnattr_setpgroup(&attributes, 0)
  }
  posix_spawnattr_setflags(&attributes, Int16(flags))
  let argv = arguments.map { strdup($0) } + [nil]
  let envp = environment.keys.sorted().map { strdup($0 + "=" + environment[$0]!) } + [nil]
  defer { for pointer in argv + envp { free(pointer) } }
  var pid: pid_t = 0
  let code = argv.withUnsafeBufferPointer { arguments in
    envp.withUnsafeBufferPointer { environment in
      posix_spawn(
        &pid, executable, &actions, &attributes, arguments.baseAddress!, environment.baseAddress!)
    }
  }
  return (pid, code)
}

final class ProcessMonitor {
  let pid: pid_t
  private var reaped = false
  private var groupStopped = false
  private(set) var terminationDeadline: Double?
  private(set) var exitedAt: Double?

  init(pid: pid_t) { self.pid = pid }

  deinit {
    if !groupStopped && !reaped { kill(-pid, SIGKILL) }
    let deadline = terminationDeadline ?? monotonicTime() + 30
    var status: Int32 = 0
    guard !reaped else { return }
    // Poll at least once: the deadline has already passed when SIGKILL timed out.
    repeat {
      let result = waitpid(pid, &status, WNOHANG)
      if result == pid || (result < 0 && errno == ECHILD) { break }
      usleep(1000)
    } while monotonicTime() < deadline
  }

  func checkExit(at time: Double) throws {
    guard exitedAt == nil else { return }
    var info = siginfo_t()
    let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
    if result == 0 && info.si_pid == pid {
      exitedAt = time
    } else if result < 0 && errno == ECHILD {
      reaped = true
      groupStopped = true
      throw ApiError("CLI process was reaped by another owner")
    } else if result < 0 && errno != EINTR {
      throw posixError("wait for CLI")
    }
  }

  func terminate(at time: Double) {
    guard !groupStopped else { return }
    kill(-pid, SIGKILL)
    groupStopped = true
    terminationDeadline = time + 30
  }

  func reap(deadline: Double) throws -> Int32 {
    var status: Int32 = 0
    while true {
      let result = waitpid(pid, &status, WNOHANG)
      if result == pid { break }
      if result < 0 && errno == ECHILD {
        reaped = true
        throw ApiError("CLI process was reaped by another owner")
      }
      if result < 0 && errno != EINTR { throw posixError("waitpid") }
      if monotonicTime() >= deadline { throw ApiError("CLI did not terminate after SIGKILL") }
      usleep(1000)
    }
    reaped = true
    return decodedProcessStatus(status)
  }
}
