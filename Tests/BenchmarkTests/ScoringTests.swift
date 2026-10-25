import Darwin
import Foundation
import Testing

@testable import Benchmark

@Test func numericLexemesAndUnicodeRemainExact() throws {
  #expect(try JSON.parse("1.0") == .number(1))
  #expect(try JSON.parse("1e2") == .number(100))
  #expect(try JSON.parse("1.0").uint == nil)
  #expect(throws: (any Error).self) { try JSON.parse("{\"x\":1,\"x\":2}") }
  #expect(try !JSON.parse("9007199254740993.0").equivalent(to: JSON.parse("9007199254740992")))
  #expect(!JSON.string("é").equivalent(to: .string("e\u{301}")))
  let two = try JSON.parse(#"{"é":1,"e\u0301":2}"#)
  #expect(two.members?.count == 2)
  #expect(two["é"] == 1)
  #expect(two["e\u{301}"] == 2)
  #expect(try JSON.parse(two.serialized()) == two)
  #expect(
    try scoreResponse(testTask(["type": "exact", "expected": .number(1)]), response: "1.0").score
      == 1)
  #expect(
    try scoreResponse(testTask(["type": "exact", "expected": "é"]), response: "e\u{301}").score == 0
  )
  #expect(
    try scoreResponse(testTask(["type": "contains_all", "expected": ["é"]]), response: "e\u{301}")
      .score == 0)
}

@Test func jsonScoringKeepsNumericPrecision() throws {
  for (expected, response, matches) in [
    ("3", "3.0000000000000001", false),
    ("3", "3.0", true),
    ("3", "30e-1", true),
    ("9007199254740993", "9007199254740993.0", true),
    ("18446744073709551616", "18446744073709551617", false),
    (
      "-12.345678901234567890123456789012345678901",
      "-12345678901234567890123456789012345678901e-39", true
    ),
    ("0", "1e-999", false),
    ("-0", "0.000e-999", true),
    ("1e-999999999999999999999", "10e-1000000000000000000000", true),
    ("1e-999999999999999999999", "1e-1000000000000000000000", false),
    ("1.00E+0002", "100", true),
    ("10e99", "1e100", true),
    ("0.1e100", "1e99", true),
    ("0.1e-99", "1e-100", true),
    ("0.0100", "1e-2", true),
    ("0.0100", "-1e-2", false),
  ] {
    let expectedJSON = try JSON.parse("{\"values\":[\(expected)]}")
    let task = testTask(["type": "json_exact", "expected": expectedJSON])
    let result = try scoreResponse(task, response: "{\"values\":[\(response)]}")
    #expect(result.score == (matches ? 1 : 0), "\(expected) versus \(response)")
    #expect(try JSON.parse(response).equivalent(to: JSON.parse(expected)) == matches)
    #expect(try JSON.parse(JSON.parse(response).serialized()).equivalent(to: JSON.parse(response)))
  }
  for token in ["3.0000000000000001", "9007199254740993.0", "1.00E+0002", "-0"] {
    #expect(try JSON.parse(token).serialized() == token)
  }
  let (tasks, _) = try loadTasks(at: path(repositoryRoot, "Resources/suites"))
  let bundled = try #require(tasks.first { $0.id == "structured-001" })
  #expect(
    try scoreResponse(
      bundled, response: #"{"name":"sora","count":3.0000000000000001,"active":true}"#
    ).score == 0)
  #expect(
    try scoreResponse(bundled, response: #"{"name":"sora","count":3e0,"active":true}"#).score
      == 1)
}
struct ScoringCase: Sendable {
  let scorer: JSON
  let response: String
  let expected: Double
}
private let scoringCases = [
  ScoringCase(scorer: ["type": "exact", "expected": "ok"], response: " ok\n", expected: 1),
  ScoringCase(scorer: ["type": "exact", "expected": "ok"], response: "OK", expected: 0),
  ScoringCase(scorer: ["type": "exact", "expected": ["a", 42]], response: "42", expected: 1),
  ScoringCase(
    scorer: ["type": "exact", "expected": "a b", "normalize_whitespace": true],
    response: " a\n\t b ", expected: 1),
  ScoringCase(
    scorer: ["type": "exact", "expected": "STRASSE", "case_sensitive": false],
    response: "Straße", expected: 1),
  ScoringCase(
    scorer: ["type": "exact", "expected": "σ", "case_sensitive": false], response: "ς", expected: 1),
  ScoringCase(
    scorer: ["type": "contains_all", "expected": ["a", "b"]], response: "a", expected: 0.5),
  ScoringCase(
    scorer: ["type": "contains_all", "expected": ["a", "b"]], response: "ab", expected: 1),
  ScoringCase(
    scorer: ["type": "contains_all", "expected": ["a"], "max_chars": 2], response: "abc",
    expected: 0),
  ScoringCase(
    scorer: ["type": "contains_all", "expected": ["é"], "max_chars": 1], response: "é", expected: 1),
  ScoringCase(
    scorer: ["type": "contains_all", "expected": ["か"]], response: "か\u{3099}", expected: 0),
  ScoringCase(
    scorer: ["type": "contains_all", "expected": ["か"]], response: "か\u{3099}か", expected: 1),
  ScoringCase(
    scorer: ["type": "contains_all", "expected": ["3時", "4月1日"]], response: "13時、4月11日",
    expected: 0),
  ScoringCase(
    scorer: ["type": "contains_all", "expected": ["3時", "4月1日"]], response: "13時と3時、4月1日",
    expected: 1),
  ScoringCase(
    scorer: ["type": "contains_all", "expected": ["3時", "L8", "二重計上"]],
    response: "0.3時、L8.5、東京3時、L8。〇二重計上", expected: 1),
  ScoringCase(
    scorer: ["type": "contains_all", "expected": ["3時", "L8"]], response: "0.3時、L8.5",
    expected: 0),
  ScoringCase(scorer: ["type": "regex", "pattern": "^[0-9]+$"], response: "123", expected: 1),
  ScoringCase(
    scorer: ["type": "regex", "pattern": "^ok$", "case_sensitive": false],
    response: " OK ", expected: 1),
  ScoringCase(scorer: ["type": "regex", "pattern": "^$"], response: " ", expected: 0),
  ScoringCase(
    scorer: ["type": "json_exact", "expected": ["a": 1]], response: "{\"a\":1.0}", expected: 1),
  ScoringCase(
    scorer: ["type": "json_exact", "expected": ["a": 1]], response: "{\"a\":true}", expected: 0),
  ScoringCase(
    scorer: ["type": "json_exact", "expected": [1, 2]], response: "[2,1]", expected: 0),
  ScoringCase(
    scorer: ["type": "json_exact", "expected": ["a": 1], "allow_code_fence": true],
    response: "```json\n{\"a\":1}\n```", expected: 1),
  ScoringCase(
    scorer: ["type": "json_exact", "expected": ["a": 1]],
    response: "```json\n{\"a\":1}\n```", expected: 0),
  ScoringCase(scorer: ["type": "json_exact", "expected": nil], response: "null", expected: 1),
  ScoringCase(
    scorer: ["type": "json_exact", "expected": "日本語"], response: "\"日本語\"", expected: 1),
]
@Test(arguments: scoringCases)
func scoringContracts(_ input: ScoringCase) throws {
  #expect(
    try scoreResponse(testTask(input.scorer), response: input.response).score == input.expected)
}
@Test func emptyAnswersSkipScorerSpecificEvaluation() throws {
  let result = try scoreResponse(
    testTask(["type": "contains_all", "expected": []]), response: " \n")
  #expect(result.score == 0)
  #expect(result.detail == "empty answer")
}
@Test(arguments: [
  "", "[", "{\"a\":1,}", "[1,]", "01", "+1", "1.", "1e", "NaN", "1e999", "true false",
  "\"\\uD800\"", "\"a\nb\"",
])
func invalidJSONIsRejected(_ text: String) {
  #expect(throws: (any Error).self) { try JSON.parse(text) }
}
@Test func regexHasABoundedEvaluation() {
  let start = monotonicTime()
  #expect {
    try regexMatches(
      "^(a+)+$", String(repeating: "a", count: 64) + "!", caseSensitive: true,
      cancellation: Cancellation())
  } throws: { "\($0)".contains("time limit") }
  #expect(monotonicTime() - start < 3)
}
@Test func matchingRegexWinsWhenCancellationArrivesWithMatch() throws {
  let cancellation = Cancellation()
  cancellation.cancel()
  #expect(try regexMatches("^ok$", "ok", caseSensitive: true, cancellation: cancellation))
}
@Test func cancelledRegexWithoutMatchIsAnInterruption() {
  let cancellation = Cancellation()
  cancellation.cancel()
  #expect {
    try regexMatches(
      "x", String(repeating: "a", count: 4096), caseSensitive: true, cancellation: cancellation)
  } throws: { ($0 as? ApiError)?.isInterrupted == true }
}
@Test func authenticationBannersAndDepth() {
  #expect(authenticatedFlag("banner\n{\"nested\":{\"loggedIn\":true}}", field: "loggedIn") == true)
  #expect(authenticatedFlag("{broken\n{\"loggedIn\":true}", field: "loggedIn") == true)
  #expect(
    authenticatedFlag(
      String(repeating: "{", count: 20000) + "{\"loggedIn\":true}", field: "loggedIn") == true)
  #expect(
    authenticatedFlag("{\"loggedIn\":false,\"child\":{\"loggedIn\":true}}", field: "loggedIn")
      == false)
  for depth in [17, 128, 200] {
    let deep =
      String(repeating: "[", count: depth) + "{\"loggedIn\":true}"
      + String(repeating: "]", count: depth)
    #expect(authenticatedFlag(deep, field: "loggedIn") == nil)
    #expect(authenticatedFlag(deep + "{\"loggedIn\":false}", field: "loggedIn") == false)
  }
}
@Test func privateFilesAndLocksRejectLinks() throws {
  let temp = try TemporaryDirectory()
  try temp.write("outside/value", "keep")
  chmod(temp.file("outside"), 0o755)
  #expect(symlink(temp.file("outside"), temp.file("alias")) == 0)
  #expect(throws: (any Error).self) { try privateDirectory(temp.file("alias")) }
  var info = stat()
  #expect(stat(temp.file("outside"), &info) == 0)
  #expect(info.st_mode & 0o777 == 0o755)
  #expect(try String(contentsOfFile: temp.file("outside/value"), encoding: .utf8) == "keep")
  let lock = try RunLock(temp.file("Deliverables/Runs"))
  #expect(throws: (any Error).self) { try RunLock(temp.file("Deliverables/Runs")) }
  withExtendedLifetime(lock) {}
  let port = Int.random(in: 100_000...999_999)  // Not a real port, so no fixture server shares it.
  let endpointLock = try lockEndpoint(port: port)
  #expect(throws: (any Error).self) { try lockEndpoint(port: port) }
  withExtendedLifetime(endpointLock) {}
  #expect(isWithin("/tmp/x", "/"))
  #expect(!isWithin("/homework", "/home"))
}
@Test func redactionCoversArgumentsAndDiagnostics() {
  let secret = "sk-abcdefghijklmnopqrstuvwxyz012345"
  let args = [
    "auth", "login", "--key", "secret", "--token=secret", "Bearer", "other",
    "https://user:secret@host", secret,
  ]
  #expect(
    redactCLIArguments(args) == [
      "auth", "login", "--key", "<redacted>", "--token=<redacted>", "<redacted>", "<redacted>",
      "<redacted>", "<redacted>",
    ])
  let text = redactCLIText("auth login\n  Authorization: Bearer \(secret)\n--password secret\n")
  #expect(!text.contains(secret))
  #expect(!text.contains("secret"))
  #expect(text.hasPrefix("auth login\n  "))
  let prefixed = redactCLIText("GITHUB_TOKEN=abc123def DB_PASSWORD=hunter2 x-api-key: abc123def")
  #expect(!prefixed.contains("abc123def") && !prefixed.contains("hunter2"))
  let camel = redactCLIText(
    "accessToken: ya29abc\n{\"refreshToken\":\"1//abc\"}\nclientSecret=xyz789\nmaxOutputTokens: 5")
  for leaked in ["ya29abc", "1//abc", "xyz789"] { #expect(!camel.contains(leaked)) }
  let acronyms = redactCLIText("GITHUBToken=gh1 APIToken=ap2 AWSSecret=aw3 OAuth2Token=oa4")
  for leaked in ["gh1", "ap2", "aw3", "oa4"] { #expect(!acronyms.contains(leaked)) }
  #expect(camel.contains("maxOutputTokens: 5"))
  let schemes = redactCLIText(
    "Authorization: Basic dXNlcjpw\nAuthorization: Token tok123\npassword = hunter2\n"
      + "GET https://h/v1?model=x&token=qry123 failed")
  for leaked in ["dXNlcjpw", "tok123", "hunter2", "qry123"] { #expect(!schemes.contains(leaked)) }
  #expect(schemes.contains("failed") && schemes.contains("password = "))
  let attached = redactCLIText(
    // One case per line: a sensitive label hides the rest of its line.
    [
      "password =at1 rest", #"{"api_key" :"at2"}"#, #"{"token" : "at5"}"#, "GITLAB_PAT=at3",
      "X-Auth: at4",
      "see glpat-abcdefghijklmnopqrstu",
    ].joined(separator: "\n"))
  for leaked in ["at1", "at2", "at3", "at4", "at5", "glpat-"] {
    #expect(!attached.contains(leaked), "\(leaked) leaked")
  }
  #expect(attached.hasPrefix("password =<redacted>"))
  #expect(redactCLIArguments(["GITLAB_PAT=at5"]) == ["GITLAB_PAT=<redacted>"])
  #expect(
    redactCLIArguments(["--url", "https://h/v1?key=qry123", "--base=https://h/?api_key=qry123"])
      == ["--url", "<redacted>", "--base=<redacted>"])
  #expect(redactCLIText("see https://h/v1?model=x") == "see https://h/v1?model=x")
  let headers = redactCLIText(
    #"{"headers":{"Authorization":"Bearer op1"}} {"headers": {"authorization": "Bearer op2"}} "#
      + "headers={'authorization': 'Bearer op3'}")
  for leaked in ["op1", "op2", "op3"] { #expect(!headers.contains(leaked)) }
  let schemes2 = redactCLIText(
    #"{"Authorization":"Basic ba1=="} {"Authorization":"Token to2"} Authorization=Basic ba3 "#
      + "Proxy-Authorization: Basic pr4\nCookie: session=co5; csrf=co6\n"
      + #"secret: "qu7 qu8" {"password":"qu9 qu10"} https://glpat-ur11@git.example.com/r.git"#)
  for leaked in ["ba1", "to2", "ba3", "pr4", "co5", "co6", "qu7", "qu8", "qu9", "qu10", "ur11"] {
    #expect(!schemes2.contains(leaked), "\(leaked) leaked")
  }
  // JSON nested in a string, as in CLI API error bodies.
  let escaped = redactCLIText(
    #"API Error: 401 {\"api_key\":\"es1\"}"# + "\n" + #"{\"password\" : \"es2\"}"# + "\n"
      + #"{\"header\":\"x\", \"auth\": \"Bearer es3\"}"# + "\n" + #"{\"value\": \"Bearer es4\"}"#)
  for leaked in ["es1", "es2", "es3", "es4"] {
    #expect(!escaped.contains(leaked), "\(leaked) leaked")
  }
  #expect(escaped.hasPrefix("API Error: 401 "))
  #expect(redactCLIText("secret: \"open\nnext line") == "<redacted> <redacted>\nnext line")
  let lines = redactCLIText(
    #"{"token":"a b","password":"c d"} x"# + "\n" + #"token: ["e f"]"# + "\n"
      + #"{"password":"g \"h i\" j"}"# + "\nkept line")
  for leaked in ["a b", "c d", "d\"", "f\"", "i\\", "j\""] {
    #expect(!lines.contains(leaked), "\(leaked) leaked")
  }
  #expect(lines.hasSuffix("\nkept line"))
  let long = String(repeating: #"{"a":1},"#, count: 40_000)
  let started = Date()
  #expect(redactCLIText(long) == long)
  #expect(Date().timeIntervalSince(started) < 5)
  #expect(
    redactCLIArguments(["--max-output-tokens", "5", "GITHUB_TOKEN=abc"]) == [
      "--max-output-tokens", "5", "GITHUB_TOKEN=<redacted>",
    ])
}
@Test func nestedErrorMessagesAndPrefixedToolTypesAreRecognized() throws {
  #expect(
    eventErrorMessage(try JSON.parse(#"{"type":"turn.failed","error":{"message":"usage limit"}}"#))
      == "usage limit")
  let block = try JSON.parse(#"{"content_block":{"type":"server_tool_use"}}"#)
  #expect(containsToolActivity(block))
  #expect(!containsToolActivity(try JSON.parse(#"{"type":"text","text":"tool_use"}"#)))
}
@Test func pathResolutionFollowsLinksAboveMissingDirectories() throws {
  let temp = try TemporaryDirectory()
  let repository = temp.file("repository")
  try privateDirectory(repository)
  #expect(symlink(repository, temp.file("link")) == 0)
  let resolved = try resolvePath(temp.file("link/benchmark/profiles"))
  #expect(isWithin(resolved, try resolvePath(repository)))
}
@Test func relativePathEntriesResolveBeforeChangingDirectory() throws {
  let temp = try TemporaryDirectory()
  // A PATH entry relative to the current directory, without changing the shared process cwd.
  let depth =
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath).pathComponents.count - 1
  let relative = String(repeating: "../", count: depth) + "bin"
  let resolved = try executablePath("echo", environment: ["PATH": relative])
  #expect(resolved.hasPrefix("/") && access(resolved, X_OK) == 0)
  let result = try runProcess(
    "echo", args: ["ok"], directory: temp.directory, environment: ["PATH": relative], timeout: 2)
  #expect(result.stdout.trimmed == "ok")
}
@Test func pathSearchSkipsDirectoriesNamedLikeTheCommand() throws {
  let temp = try TemporaryDirectory()
  try FileManager.default.createDirectory(
    atPath: temp.file("first/echo"), withIntermediateDirectories: true)
  let resolved = try executablePath("echo", environment: ["PATH": temp.file("first") + ":/bin"])
  #expect(resolved == "/bin/echo")
}
@Test func unreadableRSSSampleNullsThePeak() {
  var metrics = MemoryMetrics(peakRSS: 10)
  #expect(metrics.json["peak_backend_rss_bytes"] == 10)
  metrics.rssUnavailable = true
  #expect(metrics.json["peak_backend_rss_bytes"] == .null)
}
