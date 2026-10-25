import Darwin
import Foundation
import Testing

@testable import Benchmark

@Suite(.serialized)
struct RuntimeTests {
  @Test func ownedOllamaServerStartsAndStopsItsProcessGroup() throws {
    let temp = try TemporaryDirectory()
    let reservation = try FixtureServer { _ in FixtureResponse([:]) }
    let target = localTarget(reservation.baseURL)
    // The port is reused at once; another process would have to draw the same random ephemeral
    // port in that gap.
    reservation.stop()
    let serverProgram = #"""
      import http.server, json, os, signal, subprocess, sys
      with open(sys.argv[1], 'w') as output:
          json.dump({k: v for k, v in os.environ.items() if k.startswith('OLLAMA_')}, output)
      print("server diagnostic", file=sys.stderr, flush=True)
      host, port = os.environ['OLLAMA_HOST'].rsplit(':', 1)
      # A runner in the server's process group, like llama-server under ollama serve.
      runner = subprocess.Popen(['/bin/sleep', '60'])
      with open(sys.argv[2], 'w') as output:
          output.write(str(runner.pid))
      class Handler(http.server.BaseHTTPRequestHandler):
          def do_GET(self):
              body = b'{"version":"fixture"}'
              self.send_response(200)
              self.send_header('Content-Type', 'application/json')
              self.send_header('Content-Length', str(len(body)))
              self.end_headers()
              self.wfile.write(body)
          def log_message(self, *args):
              pass
      server = http.server.ThreadingHTTPServer((host, int(port)), Handler)
      signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
      try:
          server.serve_forever()
      finally:
          server.server_close()
      """#
    let servers = try OllamaServers.ensure(
      [target, target], host: "test", startupTimeout: 30, command: "/usr/bin/python3",
      arguments: ["-c", serverProgram, temp.file("environment.json"), temp.file("runner.pid")],
      logDirectory: temp.file("logs"))
    let child = try #require(servers.children.first)
    defer { child.stop() }
    #expect(servers.children.count == 1)
    #expect(servers.failures.isEmpty)
    #expect(
      try String(contentsOfFile: child.logPath, encoding: .utf8).contains("server diagnostic"))
    var info = stat()
    #expect(stat(child.logPath, &info) == 0 && info.st_mode & 0o777 == 0o600)
    #expect(try readJSON(temp.file("environment.json")).object?.keys.sorted() == ["OLLAMA_HOST"])
    #expect(
      try httpRequest("GET", url: target.baseUrl + "/api/version", timeout: 2)["version"]
        == "fixture")
    let runner = try #require(
      Int32(try String(contentsOfFile: temp.file("runner.pid"), encoding: .utf8)))
    child.stop()
    #expect(child.hasExited)
    #expect(kill(child.pid, 0) == -1 && errno == ESRCH)
    // The runner is reparented to launchd once the leader exits, so only a group kill stops it.
    let deadline = monotonicTime() + 2
    while kill(runner, 0) == 0 && monotonicTime() < deadline { usleep(10000) }
    #expect(kill(runner, 0) == -1 && errno == ESRCH)
  }
  @Test func bufferedContentTypesCannotProduceMeasurements() throws {
    let server = try FixtureServer { _ in
      FixtureResponse(headers: ["Content-Type": "text/plain"], chunks: [("{}\n", 0.5)])
    }
    defer { server.stop() }
    do {
      _ = try httpRequest("GET", url: server.baseURL, timeout: 2) { _, _ in
        Issue.record("unexpected stream event")
      }
      Issue.record("expected MIME type error")
    } catch let error as ApiError {
      #expect(!error.isTimeout)
      #expect(error.description.contains("application/x-ndjson"))
    }
  }
  @Test func rejectedRedirectsAndLargeErrorsReturnPromptly() throws {
    let server = try FixtureServer { request in
      if request.path == "/redirect" {
        return FixtureResponse(
          status: 302, headers: ["Location": "http://example.com/"],
          chunks: [(String(repeating: "x", count: 1024), 0), ("wait", 1.5)])
      }
      return FixtureResponse(
        status: 429, chunks: [(String(repeating: "x", count: 65536), 0), ("wait", 1.5)])
    }
    defer { server.stop() }
    var started = monotonicTime()
    #expect(throws: (any Error).self) {
      try httpRequest("GET", url: server.baseURL + "/redirect", timeout: 2)
    }
    #expect(monotonicTime() - started < 1)
    started = monotonicTime()
    do {
      _ = try httpRequest("GET", url: server.baseURL, timeout: 2)
      Issue.record("expected HTTP error")
    } catch let error as ApiError { #expect(error.reason == "rate_limited") }
    #expect(monotonicTime() - started < 1)
  }
  @Test func interruptionDuringOllamaCleanupKeepsItsReason() throws {
    let cancellation = Cancellation()
    let server = try FixtureServer { _ in
      cancellation.cancel()
      return FixtureResponse(chunks: [("{}", 1.5)])
    }
    defer { server.stop() }
    var settings = testSettings()
    settings.requestTimeoutSeconds = 1
    let adapter = OllamaAdapter(
      target: localTarget(server.baseURL), settings: settings, cancellation: cancellation)
    do {
      try adapter.cleanup("cold")
      Issue.record("expected interruption")
    } catch let error as ApiError { #expect(error.isInterrupted) }
  }

  @Test func streamedHTTPDeliversEventsBeforeTheStreamEnds() throws {
    let server = try FixtureServer { _ in
      FixtureResponse(chunks: (1...10).map { ("{\"a\":\($0)}\n", 0.15) })
    }
    defer { server.stop() }
    var values: [JSON] = []
    var receivedAt: [Double] = []
    let started = monotonicTime()
    _ = try httpRequest("POST", url: server.baseURL, payload: [:], timeout: 5) {
      values.append($0)
      receivedAt.append($1)
    }
    #expect(values.count == 10)
    #expect(receivedAt[0] - started < 0.8)
    #expect(receivedAt.last! - receivedAt[0] > 1)
  }
  @Test func streamedHTTPHonorsTotalTimeout() throws {
    let server = try FixtureServer { _ in
      FixtureResponse(chunks: (1...20).map { ("{\"a\":\($0)}\n", 0.1) })
    }
    defer { server.stop() }
    do {
      _ = try httpRequest("POST", url: server.baseURL, payload: [:], timeout: 0.5) {
        _, _ in
      }
      Issue.record("expected total request timeout")
    } catch let error as ApiError {
      #expect(error.isTimeout)
    }
  }
  @Test func httpRejectsRemoteRedirectsInvalidJSONAndStalls() throws {
    let server = try FixtureServer { request in
      switch request.path {
      case "/remote":
        FixtureResponse(status: 302, headers: ["Location": "http://example.com/"], chunks: [])
      case "/stall": FixtureResponse(chunks: [("{}", 0.15)])
      case "/array": FixtureResponse([1, 2])
      case "/large": FixtureResponse(chunks: [(String(repeating: " ", count: 5000) + "{}", 0)])
      default: FixtureResponse(status: 429, chunks: [("{\"error\":{\"message\":\"busy\"}}", 0)])
      }
    }
    defer { server.stop() }
    for endpoint in ["/remote", "/array"] {
      #expect(throws: (any Error).self) {
        try httpRequest("GET", url: server.baseURL + endpoint, timeout: 1)
      }
    }
    #expect(throws: (any Error).self) {
      try httpRequest("GET", url: server.baseURL + "/large", timeout: 1, maximumBytes: 4096)
    }
    do {
      _ = try httpRequest("GET", url: server.baseURL + "/stall", timeout: 0.03)
      Issue.record("expected timeout")
    } catch let error as ApiError { #expect(error.isTimeout) }
    do {
      _ = try httpRequest("GET", url: server.baseURL, timeout: 1)
      Issue.record("expected rate limit")
    } catch let error as ApiError {
      #expect(error.reason == "rate_limited")
      #expect(error.description.contains("busy"))
    }
  }
  @Test(arguments: [
    "http://127.0.0.1:65536", "http://127.0.0.1:9999999999999", "http://127.0.0.1:-1",
  ])
  func invalidPortsFailWithoutTrapping(_ endpoint: String) {
    #expect(throws: (any Error).self) { try requireLoopbackEndpoint(endpoint) }
  }
  @Test func listenerCheckFindsOnlyTheOwningProcess() throws {
    let server = try FixtureServer { _ in FixtureResponse([:]) }
    defer { server.stop() }
    let port = try #require(URLComponents(string: server.baseURL)?.port)
    #expect(processListens(getpid(), port: port))
    #expect(!processListens(getpid(), port: port == 1 ? 2 : port - 1))
    #expect(!processListens(getppid(), port: port))
  }
  @Test func ownedServerRejectsAnAnswerFromAnotherProcess() throws {
    let temp = try TemporaryDirectory()
    let reservation = try FixtureServer { _ in FixtureResponse([:]) }
    let target = localTarget(reservation.baseURL)
    // The port is reused at once; another process would have to draw the same random ephemeral
    // port in that gap.
    reservation.stop()
    // The started process stays alive but a forked process answers, as when Ollama.app wins.
    let program = #"""
      import http.server, os, sys, time
      host, port = os.environ['OLLAMA_HOST'].rsplit(':', 1)
      if os.fork() == 0:
          with open(sys.argv[1], 'w') as output:
              output.write(str(os.getpid()))
          class Handler(http.server.BaseHTTPRequestHandler):
              def do_GET(self):
                  body = b'{"version":"foreign"}'
                  self.send_response(200)
                  self.send_header('Content-Type', 'application/json')
                  self.send_header('Content-Length', str(len(body)))
                  self.end_headers()
                  self.wfile.write(body)
              def log_message(self, *args):
                  pass
          http.server.HTTPServer((host, int(port)), Handler).serve_forever()
      time.sleep(30)
      """#
    defer {
      if let pid = try? String(contentsOfFile: temp.file("foreign.pid"), encoding: .utf8),
        let pid = pid_t(pid)
      {
        kill(pid, SIGKILL)
      }
    }
    let servers = try OllamaServers.ensure(
      [target], host: "test", startupTimeout: 30, command: "/usr/bin/python3",
      arguments: ["-c", program, temp.file("foreign.pid")], logDirectory: temp.file("logs"))
    #expect(servers.children.isEmpty)
    #expect(servers.startupError(target)?.contains("another process answered") == true)
  }
  @Test func httpsIsNeverStarted() throws {
    let server = try FixtureServer { _ in FixtureResponse([:]) }
    defer { server.stop() }
    let target = localTarget(server.baseURL.replacingOccurrences(of: "http", with: "HTTPS"))
    let servers = try OllamaServers.ensure([target], host: "host", command: "/does/not/exist")
    #expect(servers.children.isEmpty)
    #expect(servers.failures.isEmpty)
    #expect(endpointKey("HTTP://127.0.0.1:80") == "http://127.0.0.1/")
  }
}

extension RuntimeTests {
  @Test(arguments: [
    "cursor-stream-json", "claude-stream-json", "antigravity-stream-json", "codex-jsonl",
  ])
  func rejectsToolsForEveryProduct(_ schema: String) throws {
    let parser = EventAccumulator(schema: schema, model: "m")
    let response: JSON =
      schema == "codex-jsonl"
      ? ["type": "item.completed", "item": ["type": "agent_message", "text": "ok"]]
      : ["type": "assistant", "message": ["content": [["type": "text", "text": "ok"]]]]
    try parser.handle(response.serialized(), at: 1)
    #expect(parser.text == "ok")
    #expect(throws: (any Error).self) {
      try parser.handle(
        #"{"type":"content_block_start","content_block":{"type":"tool_use","name":"shell"}}"#, at: 2
      )
    }
  }
  @Test func cliParserPreservesDeltasUsageAndAuthoritativeResults() throws {
    let cursor = EventAccumulator(schema: "cursor-stream-json", model: "requested")
    for text in ["ha", "ha"] {
      try cursor.handle(
        JSON.object(["type": "assistant", "timestamp_ms": 1, "message": ["content": .string(text)]])
          .serialized(), at: 2)
    }
    #expect(cursor.text == "haha")
    try cursor.handle(
      #"{"type":"result","result":"revised","usage":{"input_tokens":9007199254740993},"model":"actual"}"#,
      at: 3)
    try cursor.handle(
      #"{"type":"message_delta","usage":{"output_tokens":3},"delta":{"stop_reason":"max_tokens"}}"#,
      at: 4)
    #expect(cursor.text == "revised")
    #expect(cursor.inputTokens == 9_007_199_254_740_993)
    #expect(cursor.outputTokens == 3)
    #expect(cursor.model == "actual")
    #expect(cursor.finishReason == "max_tokens")
    #expect(cursor.firstTextAt == 2)
    try cursor.handle(#"{"type":"result","result":""}"#, at: 5)
    #expect(cursor.text.isEmpty)
    #expect(cursor.hasResponse)
    let claude = EventAccumulator(schema: "claude-stream-json", model: "m")
    try claude.handle(
      #"{"type":"stream_event","event":{"type":"message_start","message":{"usage":{"input_tokens":3,"cache_creation_input_tokens":10,"cache_read_input_tokens":15000}}}}"#,
      at: 1)
    #expect(claude.inputTokens == 15_013)
    let cursorUsage = EventAccumulator(schema: "cursor-stream-json", model: "m")
    try cursorUsage.handle(
      #"{"type":"result","result":"ok","usage":{"inputTokens":4,"cacheReadTokens":900,"cacheWriteTokens":6}}"#,
      at: 1)
    #expect(cursorUsage.inputTokens == 910)
    try claude.handle(
      #"{"type":"system","subtype":"api_retry","attempt":1,"error_status":529,"error":"overloaded"}"#,
      at: 2)
    #expect(!claude.hasResponse)
    let retried = EventAccumulator(schema: "claude-stream-json", model: "m")
    for (offset, line) in [
      #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hel"}}}"#,
      #"{"type":"system","subtype":"api_retry","attempt":1,"error_status":529,"error":"overloaded"}"#,
      #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello world"}}}"#,
      #"{"type":"result","subtype":"success","is_error":false,"result":"Hello world"}"#,
    ].enumerated() { try retried.handle(line, at: Double(offset + 1)) }
    #expect(retried.text == "Hello world")
    #expect(retried.firstTextAt == 3)
    let codex = EventAccumulator(schema: "codex-jsonl", model: "m")
    try codex.handle(
      #"{"type":"error","message":"Reconnecting... waiting for network (Connection failed)"}"#,
      at: 1)
    #expect(!codex.hasResponse)
    try codex.handle(
      #"{"type":"item.completed","item":{"type":"reasoning","text":"private"}}"#, at: 1)
    #expect(codex.firstTextAt == nil)
    #expect(!codex.hasResponse)
    try codex.handle(
      #"{"type":"item.delta","item":{"type":"agent_message"},"delta":"hello"}"#, at: 2)
    try codex.handle(
      #"{"type":"item.completed","item":{"type":"agent_message","text":"hello world"}}"#, at: 3)
    #expect(codex.text == "hello world")
    #expect(codex.firstTextAt == 2)
    #expect(throws: (any Error).self) { try codex.handle(#"{"type":"new_event"}"#, at: 4) }
    #expect(throws: (any Error).self) {
      try codex.handle(#"{"type":"turn.failed","error":{"message":"stream disconnected"}}"#, at: 5)
    }
  }
  @Test func fullEventsPreserveCompatibleContentBlockDeltas() throws {
    let prefix = EventAccumulator(schema: "claude-stream-json", model: "m")
    try prefix.handle(#"{"type":"content_block_delta","delta":"AB"}"#, at: 1)
    try prefix.handle(
      JSON.object([
        "type": "assistant", "message": ["content": [["type": "text", "text": "A"]]],
      ]).serialized(), at: 2)
    #expect(prefix.text == "AB")

    let suffix = EventAccumulator(schema: "antigravity-stream-json", model: "m")
    try suffix.handle(#"{"type":"content_block_delta","delta":"AB"}"#, at: 1)
    try suffix.handle(#"{"type":"content_block_delta","delta":"CD"}"#, at: 2)
    try suffix.handle(
      JSON.object([
        "type": "assistant", "message": ["content": [["type": "text", "text": "CD"]]],
      ]).serialized(), at: 3)
    #expect(suffix.text == "ABCD")
  }
  @Test func fullEventsWithoutDeltasAreConcatenated() throws {
    let parser = EventAccumulator(schema: "claude-stream-json", model: "m")
    try parser.handle(
      #"{"type":"assistant","message":{"content":[{"type":"text","text":"first"}]}}"#,
      at: 1)
    try parser.handle(
      #"{"type":"assistant","message":{"content":[{"type":"text","text":"second"}]}}"#,
      at: 2)
    #expect(parser.text == "firstsecond")
    #expect(parser.firstTextAt == 1)

    let suffix = EventAccumulator(schema: "claude-stream-json", model: "m")
    try suffix.handle(
      #"{"type":"assistant","message":{"content":[{"type":"text","text":"ab"}]}}"#, at: 1)
    try suffix.handle(
      #"{"type":"assistant","message":{"content":[{"type":"text","text":"b"}]}}"#, at: 2)
    try suffix.handle(#"{"type":"result","result":"b"}"#, at: 3)
    #expect(suffix.text == "abb")
  }
  @Test func growingFullSnapshotsReplaceTheAccumulatedText() throws {
    let codex = EventAccumulator(schema: "codex-jsonl", model: "m")
    try codex.handle(
      #"{"type":"item.updated","item":{"type":"agent_message","text":"4"}}"#, at: 1)
    try codex.handle(
      #"{"type":"item.completed","item":{"type":"agent_message","text":"42"}}"#, at: 2)
    #expect(codex.text == "42")
    #expect(codex.firstTextAt == 1)

    let messages = EventAccumulator(schema: "codex-jsonl", model: "m")
    for (offset, (id, text, type)) in [
      ("i0", "A", "updated"), ("i0", "A", "completed"), ("i1", "B", "updated"),
      ("i1", "BC", "updated"), ("i1", "BC", "completed"),
    ].enumerated() {
      try messages.handle(
        JSON.object([
          "type": .string("item.\(type)"),
          "item": ["id": .string(id), "type": "agent_message", "text": .string(text)],
        ]).serialized(), at: Double(offset + 1))
    }
    #expect(messages.text == "ABC")
  }
  @Test(arguments: [
    "", "{\"type\":\"result\",\"is_error\":true,\"result\":\"bad\"}",
    "{\"type\":\"stream_event\",\"event\":{\"type\":\"error\",\"message\":\"bad\"}}", "[]",
    "not json",
  ])
  func cliInvalidOrEmptyEvents(_ line: String) throws {
    let parser = EventAccumulator(schema: "claude-stream-json", model: "m")
    if line.isEmpty {
      try parser.handle(line, at: 1)
      #expect(!parser.hasResponse)
    } else {
      #expect(throws: (any Error).self) { try parser.handle(line, at: 1) }
    }
  }
  @Test func processIOIsBoundedAndPreservesUnicode() throws {
    let result = try runProcess(
      "/bin/sh", args: ["-c", "printf '日本語'; printf '診断' >&2"], timeout: 1)
    #expect(result.output == "日本語\n診断")
    let full = try runProcess(
      "/usr/bin/awk",
      args: [
        "BEGIN { for(i=0;i<10000;i++) print \"123 /usr/bin/other\"; print \"456 /bin/ollama\" }"
      ], timeout: 2, captureLimit: 1024 * 1024)
    #expect(full.stdout.utf8.count > 65536)
    #expect(!full.stdoutTruncated)
    #expect(parseProcessRSS(full.stdout, matching: "ollama") == 456 * 1024)
    let limited = try runProcess(
      "/usr/bin/awk", args: ["BEGIN { for(i=0;i<10000;i++) print \"abcdefghij\" }"], timeout: 2)
    #expect(limited.stdoutTruncated)
    #expect(limited.stdout.utf8.count == 65536)
    #expect(limited.success)
    let start = monotonicTime()
    #expect(throws: (any Error).self) {
      try runProcess(
        "/bin/sh", args: ["-c", "sleep 10"], input: String(repeating: "x", count: 1024 * 1024),
        timeout: 0.05)
    }
    #expect(monotonicTime() - start < 5)
  }
  @Test func stdoutLineLimitIncludesTheLineEnding() throws {
    let callback: (String, Double) throws -> Void = { _, _ in }
    _ = try runProcess(
      "/bin/sh",
      args: ["-c", "head -c 8388607 /dev/zero; printf '\\n'"],
      timeout: 30, onLine: callback)
    #expect(throws: (any Error).self) {
      try runProcess(
        "/bin/sh",
        args: ["-c", "head -c 8388608 /dev/zero; printf '\\n'"],
        timeout: 30, onLine: callback)
    }
  }
  @Test func processStatusUsesExitCodeAndSignalConvention() throws {
    let exited = try runProcess("/bin/sh", args: ["-c", "exit 42"], timeout: 1)
    #expect(exited.status == 42)
    #expect(!exited.success)
    let signaled = try runProcess("/bin/sh", args: ["-c", "kill -TERM $$"], timeout: 1)
    #expect(signaled.status == 143)
    #expect(!signaled.success)
  }
  @Test func interactiveLoginKeepsTheParentAliveThroughInterrupts() throws {
    let previous = signal(SIGINT, SIG_DFL)
    defer { signal(SIGINT, previous) }
    let temp = try TemporaryDirectory()
    let started = temp.file("started")
    let release = temp.file("release")
    // A real Ctrl-C would reach the parallel tests in this process, so check the dispositions
    // this process holds while the child runs.
    let ignored = LockedValue<[Bool]>([])
    let observed = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      defer {
        FileManager.default.createFile(atPath: release, contents: nil)
        observed.signal()
      }
      let deadline = monotonicTime() + 5
      while !FileManager.default.fileExists(atPath: started) && monotonicTime() < deadline {
        usleep(1000)
      }
      for number in [SIGINT, SIGQUIT] {
        var action = sigaction()
        let result = sigaction(number, nil, &action)
        // SIG_IGN is handler 1.
        let handler = unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self)
        ignored.update { $0.append(result == 0 && handler == 1) }
      }
    }
    let script = """
      touch "$1"; i=0
      while [ ! -f "$2" ] && [ $i -lt 500 ]; do sleep 0.01; i=$((i + 1)); done
      kill -INT $$
      """
    let status = try runInteractiveProcess(
      "/bin/sh", args: ["-c", script, "sh", started, release], directory: "/",
      environment: ["PATH": "/bin:/usr/bin"])
    #expect(observed.wait(timeout: .now() + 5) == .success)
    #expect(status == 130)
    #expect(ignored.value == [true, true])
    var restored = sigaction()
    #expect(sigaction(SIGINT, nil, &restored) == 0)
    // SIG_DFL is the null handler.
    #expect(unsafeBitCast(restored.__sigaction_u.__sa_handler, to: Int.self) == 0)
  }
  @Test func interactiveLoginForwardsCancellationToTheCLI() throws {
    let cancellation = Cancellation()
    cancellation.cancel()
    let started = monotonicTime()
    let status = try runInteractiveProcess(
      "/bin/sh", args: ["-c", "exec sleep 10"], directory: "/",
      environment: ["PATH": "/bin:/usr/bin"], cancellation: cancellation)
    #expect(status == 128 + SIGTERM)
    #expect(monotonicTime() - started < 5)
  }
  @Test func antigravityLoginCanVerifyAuthenticationAfterNonzeroExit() throws {
    let temp = try TemporaryDirectory()
    let profiles = temp.file("profiles")
    let product = Product(
      name: "antigravity", eventSchema: "antigravity-stream-json", command: temp.file("agy"),
      configVariable: nil, statusArgs: ["models"], authenticatedField: nil, loginArgs: [])
    try product.createProfile(profiles)
    try temp.write(
      "agy",
      """
      #!/bin/sh
      test "$1" = models
      exit 0
      """)
    #expect(chmod(product.command, 0o700) == 0)
    try verifyInteractiveLogin(product, profiles: profiles, exitStatus: 130)
    try product.writeMarker(profiles)
    #expect(product.profileExists(profiles))
  }
  @Test func profileStateLeavesProductNameToTheCaller() throws {
    let temp = try TemporaryDirectory()
    let profiles = temp.file("profiles")
    let product = Product(
      name: "fixture", eventSchema: "fixture", command: temp.file("fixture"), configVariable: nil,
      statusArgs: ["status"], authenticatedField: nil, loginArgs: [])
    try product.createProfile(profiles)
    try product.writeMarker(profiles)
    try temp.write("fixture", "#!/bin/sh\ntest \"$1\" = status\n")
    #expect(chmod(product.command, 0o700) == 0)
    #expect(try profileState(product, profiles: profiles) == "authenticated")
  }
  @Test func workspaceRootPreparationCleansStaleDirectories() throws {
    let temp = try TemporaryDirectory()
    let root = temp.file("workspaces")
    let stale = path(root, "benchmark-trial-stale")
    try privateDirectory(root)
    try privateDirectory(stale)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -90_000)], ofItemAtPath: stale)
    #expect(try prepareWorkspaceRoot(root) == root)
    #expect(!FileManager.default.fileExists(atPath: stale))
  }
  @Test func processHelpersAndCancellationAreCleanedUp() throws {
    let temporary = try TemporaryDirectory()
    let pidPath = temporary.file("pid")
    let result = try runProcess(
      "/bin/sh", args: ["-c", "sleep 60 & echo $! > \"$1\"; echo done", "test", pidPath], timeout: 2
    )
    #expect(result.success)
    #expect(result.stdout.trimmed == "done")
    let pid = Int32(try String(contentsOfFile: pidPath, encoding: .utf8).trimmed)!
    let deadline = monotonicTime() + 2
    while kill(pid, 0) == 0 && monotonicTime() < deadline { usleep(10000) }
    #expect(kill(pid, 0) != 0)
    let cancellation = Cancellation()
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { cancellation.cancel() }
    do {
      _ = try runProcess(
        "/bin/sh", args: ["-c", "sleep 60"], timeout: 10, cancellation: cancellation)
      Issue.record("expected interruption")
    } catch let error as ApiError { #expect(error.isInterrupted) }
  }
  @Test func cliProfilesArePrivateAndEveryProcessUsesAFreshWorkspace() throws {
    let temp = try TemporaryDirectory()
    let profiles = temp.file("profiles")
    let workspaces = temp.file("workspaces")
    let product = products.first { $0.name == "codex" }!
    try product.createProfile(profiles)
    try product.writeMarker(profiles)
    for directory in [profiles, product.root(profiles), product.scratch(profiles)] {
      var info = stat()
      #expect(stat(directory, &info) == 0 && info.st_mode & 0o777 == 0o700, "\(directory)")
    }
    let program = temp.file("fake-cli")
    try temp.write(
      "fake-cli",
      """
      #!/bin/sh
      set -eu
      if [ "$1" = "--version" ]; then echo fake-1.0; exit; fi
      if [ "$1" = "login" ]; then exit; fi
      test -z "$(ls -A .)"
      test "$HOME" = "$2"
      test "${OPENAI_API_KEY-unset}" = unset
      test "$LANG" = fixture-locale
      test "$CODEX_HOME" = "$HOME/codex"
      cat > prompt
      printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"ok"}}'
      """)
    chmod(program, 0o700)
    let target = TargetConfig(
      id: "cloud", inferenceLocation: "remote", adapter: "cli-agent", model: "m", command: program,
      args: ["generate", product.root(profiles)], promptDelivery: "stdin",
      eventSchema: product.eventSchema)
    let adapter = CLIAgentAdapter(target: target, settings: testSettings(temp.directory))
    adapter.profilesOverride = profiles
    adapter.workspaceOverride = workspaces
    // The fake CLI fails if the operator's key reaches it, or if this environment is not used.
    var operatorEnvironment = ProcessInfo.processInfo.environment
    operatorEnvironment["OPENAI_API_KEY"] = "operator-secret"
    operatorEnvironment["LANG"] = "fixture-locale"
    adapter.inheritedEnvironmentOverride = operatorEnvironment
    #expect(try adapter.doctor(cache: DoctorCache()).ok)
    for _ in 0..<2 {
      #expect(
        try adapter.generate(testTask(), repeatNumber: 1).text
          == "ok")
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: workspaces).isEmpty)
    let environment = product.environment(
      profiles,
      inherited: [
        "PATH": "/bin", "OPENAI_API_KEY": "secret", "CODEX_HOME": "/outside", "HOME": "/operator",
        "LANG": "ja_JP.UTF-8",
      ])
    #expect(environment["OPENAI_API_KEY"] == nil)
    #expect(environment["HOME"] == product.root(profiles))
    #expect(environment["LANG"] == "ja_JP.UTF-8")
  }
}
