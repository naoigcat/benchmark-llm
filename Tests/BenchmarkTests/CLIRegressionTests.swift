import Darwin
import Foundation
import Testing

@testable import Benchmark

private let benchmarkExecutable = path(repositoryRoot, ".build/debug/benchmark")

private func runBenchmarkCLI(
  _ arguments: [String], directory: String, environment: [String: String]? = nil
) throws -> ProcessResult {
  try runProcess(
    benchmarkExecutable, args: arguments, directory: directory,
    environment: environment ?? ProcessInfo.processInfo.environment, timeout: 10)
}

@Test func invalidRunArgumentsUseUsageExitStatus() {
  #expect(cliMain(["run", "--repeat", "0"]) == 2)
  #expect(
    cliMain(["run", "--target", "one", "--target", "one"]) == 2)
  #expect(cliMain(["run", "--", "--help"]) == 2)
}

@Test func extraVersionArgumentsAreReportedAsUsageErrors() {
  #expect(cliMain(["--version", "extra"]) == 2)
  #expect(cliMain(["-V", "extra"]) == 2)
  #expect(cliMain(["--help", "extra"]) == 2)
  #expect(cliMain(["-h", "extra"]) == 2)
}

@Test func reportRejectsManifestDirectories() throws {
  let temp = try TemporaryDirectory()
  try privateDirectory(temp.file("run"))
  try privateDirectory(temp.file("run/manifest.json"))
  #expect(throws: (any Error).self) {
    try reportInRepository([temp.file("run")], repository: temp.directory)
  }
  #expect(throws: (any Error).self) {
    try reportInRepository([temp.file("missing/run")], repository: temp.directory)
  }
  #expect(!FileManager.default.fileExists(atPath: temp.file("missing")))
}

@Suite(.serialized)
struct CLICommandRegressionTests {
  @Test func commandSurfaceUsesDecodedExitStatuses() throws {
    let temp = try TemporaryDirectory()
    let cases: [([String], Int32)] = [
      (["--help"], Int32(0)),
      (["help", "run"], Int32(0)),
      (["--version"], Int32(0)),
      (["help", "help"], Int32(0)),
      ([], Int32(2)),
      (["unknown"], Int32(2)),
      (["report"], Int32(2)),
      (["run", "--repeat", "invalid"], Int32(2)),
      (["run", "--", "--help"], Int32(2)),
    ]
    for (arguments, expectedStatus) in cases {
      let result = try runBenchmarkCLI(arguments, directory: temp.directory)
      #expect(result.status == expectedStatus)
    }
  }

  @Test func missingCommandWritesHelpToStandardError() throws {
    let temp = try TemporaryDirectory()
    let result = try runBenchmarkCLI([], directory: temp.directory)
    #expect(result.status == 2)
    #expect(result.stdout.isEmpty)
    #expect(result.stderr.contains("Usage: benchmark"))
  }

  @Test func modelfileCommandPrintsTheSelectedTargetRecipe() throws {
    let temp = try TemporaryDirectory()
    let target = "ollama-gpt-oss-swallow-20b"
    let expected = try #require(modelfile(for: target))
    let result = try runBenchmarkCLI(["modelfile", target], directory: temp.directory)
    #expect(result.success)
    #expect(result.stdout == expected)
    #expect(result.stderr.isEmpty)
  }

  @Test func loginCommandCompletesThroughTheForegroundTerminal() throws {
    let temp = try TemporaryDirectory()
    try temp.write(
      "bin/codex",
      """
      #!/bin/sh
      case "$*" in
        login)
          printf 'PTY_READY\\n'
          IFS= read -r token
          [ "$token" = 'fixture-answer' ] || exit 9
          ;;
        'login status')
          [ -f "$HOME/benchmark-profile.json" ] || exit 10
          cat >/dev/null 2>&1 || exit 12
          printf 'Logged in\\n'
          ;;
        *) exit 11 ;;
      esac
      """)
    #expect(chmod(temp.file("bin/codex"), 0o700) == 0)
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = temp.file("bin") + ":/usr/bin:/bin"
    environment["HOME"] = temp.file("operator")
    environment["XDG_DATA_HOME"] = temp.file("data")

    // A PTY is required to exercise the foreground-terminal behavior of login.
    let harness = #"""
      import os, pty, select, signal, sys, time
      pid, fd = pty.fork()
      if pid == 0:
          os.execv(sys.argv[1], [sys.argv[1], 'login', 'codex'])
      output = b''
      sent = False
      finished = False
      deadline = time.monotonic() + 5
      try:
          while time.monotonic() < deadline:
              if select.select([fd], [], [], 0.05)[0]:
                  try:
                      output += os.read(fd, 65536)
                  except OSError:
                      pass
              if b'PTY_READY' in output and not sent:
                  os.write(fd, b'fixture-answer\n')
                  sent = True
              child, status = os.waitpid(pid, os.WNOHANG)
              if child == pid:
                  finished = True
                  assert os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0, output
                  assert sent, output
                  print('interactive login completed')
                  break
          assert finished, output
      finally:
          if not finished:
              os.killpg(pid, signal.SIGKILL)
              os.waitpid(pid, 0)
          os.close(fd)
      """#
    let result = try runProcess(
      "/usr/bin/python3", args: ["-c", harness, benchmarkExecutable],
      environment: environment, timeout: 10)
    #expect(result.success)
    #expect(result.stdout.contains("interactive login completed"))
    #expect(FileManager.default.fileExists(atPath: temp.file("data/benchmark/.benchmark.lock")))
    let product = try #require(products.first { $0.name == "codex" })
    #expect(product.profileExists(temp.file("data/benchmark/profiles")))

    // With the benchmark's own stdin closed, the status check must still get an open stdin pipe.
    let closedStandardInput = try runProcess(
      "/usr/bin/python3",
      args: [
        "-c", "import os, sys; os.close(0); os.execv(sys.argv[1], sys.argv[1:])",
        benchmarkExecutable, "login", "--status", "codex",
      ],
      environment: environment, timeout: 10)
    #expect(closedStandardInput.stdout.contains("codex: authenticated"))
  }

  @Test func terminatedLoginExitsAsInterruptedWithoutAMarker() throws {
    let temp = try TemporaryDirectory()
    // The CLI handles the forwarded SIGTERM and exits 0, which must not count as a sign-in.
    try temp.write(
      "bin/codex",
      """
      #!/bin/sh
      [ "$*" = login ] || exit 11
      trap 'exit 0' TERM
      : > '\(temp.file("started"))'
      while :; do sleep 0.05; done
      """)
    #expect(chmod(temp.file("bin/codex"), 0o700) == 0)
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = temp.file("bin") + ":/usr/bin:/bin"
    environment["HOME"] = temp.file("operator")
    environment["XDG_DATA_HOME"] = temp.file("data")
    let harness = #"""
      import os, signal, subprocess, sys, time
      child = subprocess.Popen(
          [sys.argv[1], 'login', 'codex'], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
      deadline = time.monotonic() + 5
      while not os.path.exists(sys.argv[2]) and time.monotonic() < deadline:
          time.sleep(0.01)
      child.send_signal(signal.SIGTERM)
      print(child.wait(timeout=5))
      """#
    let result = try runProcess(
      "/usr/bin/python3", args: ["-c", harness, benchmarkExecutable, temp.file("started")],
      environment: environment, timeout: 10)
    #expect(result.stdout == "130\n")
    let product = try #require(products.first { $0.name == "codex" })
    #expect(!product.profileExists(temp.file("data/benchmark/profiles")))
  }
}
