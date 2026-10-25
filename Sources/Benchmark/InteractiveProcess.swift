import Darwin
import Foundation

/// Interactive login inherits the foreground process group and terminal file descriptors.
func runInteractiveProcess(
  _ program: String, args: [String], directory: String, environment: [String: String],
  cancellation: Cancellation = interruption
) throws -> Int32 {
  let executable = try executablePath(program, environment: environment)
  var actions: posix_spawn_file_actions_t?
  guard posix_spawn_file_actions_init(&actions) == 0 else {
    throw BenchmarkError("cannot initialize interactive login")
  }
  defer { posix_spawn_file_actions_destroy(&actions) }
  let changeDirectory = posix_spawn_file_actions_addchdir_np(&actions, directory)
  guard changeDirectory == 0 else { throw BenchmarkError("cannot set login working directory") }
  // Like system(3): Ctrl-C that quits the CLI also reaches this process group, and the profile
  // marker must still be written after an exit such as Antigravity's 130.
  let previousInterrupt = signal(SIGINT, SIG_IGN)
  let previousQuit = signal(SIGQUIT, SIG_IGN)
  defer {
    signal(SIGINT, previousInterrupt)
    signal(SIGQUIT, previousQuit)
  }
  let (pid, result) = spawn(
    executable, arguments: [program] + args, environment: environment, actions: &actions,
    defaultSignals: [SIGPIPE, SIGINT, SIGQUIT], newProcessGroup: false)
  guard result == 0 else {
    throw BenchmarkError("cannot start \(program): \(String(cString: strerror(result)))")
  }
  var status: Int32 = 0
  var forwarded = false
  while true {
    let waited = waitpid(pid, &status, WNOHANG)
    if waited == pid { break }
    if waited < 0 {
      if errno == EINTR { continue }
      throw posixError("wait for login")
    }
    // SIGTERM or SIGHUP sent to this process alone only sets the flag; pass it on to the CLI.
    if cancellation.isCancelled && !forwarded {
      kill(pid, SIGTERM)
      forwarded = true
    }
    usleep(50_000)
  }
  return decodedProcessStatus(status)
}
