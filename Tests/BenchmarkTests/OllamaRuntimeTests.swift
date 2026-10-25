import Foundation
import Testing

@testable import Benchmark

private func ollamaFixtureResponse(
  _ request: FixtureRequest, loaded: LockedValue<Bool>
) -> FixtureResponse {
  switch request.path {
  case "/api/version": return FixtureResponse(["version": "1.0"])
  case "/api/tags":
    return FixtureResponse([
      "models": [
        [
          "name": "test-model", "digest": "sha256:abc",
          "details": ["quantization_level": "Q4_K_M"],
        ]
      ]
    ])
  case "/api/ps":
    return FixtureResponse([
      "models": loaded.value
        ? [
          [
            "name": "test-model", "size": 1024, "size_vram": 512, "context_length": 8192,
            "details": ["quantization_level": "Q4_K_M"],
          ]
        ] : []
    ])
  default:
    if request.body["keep_alive"].int == 0 {
      loaded.update { $0 = false }
      return FixtureResponse([:])
    }
    loaded.update { $0 = true }
    guard request.body["stream"].bool == true else { return FixtureResponse([:]) }
    let analysis =
      #"{"response":"<|channel|>analysis<|message|>reason<|end|><|start|>assistant"#
      + #"<|channel|>final<|message|>"}"#
    let final =
      #"{"response":"ok<|return|>","done":true,"model":"test-model","eval_count":21,"eval_duration":"#
      + #"500000000,"prompt_eval_count":10,"done_reason":"stop"}"#
    return FixtureResponse(chunks: [(analysis + "\n", 0), (final + "\n", 0.02)])
  }
}

extension RuntimeTests {
  @Test func finalAnswerRangeHandlesHarmonyMessageVariants() {
    let cases: [(String, String)] = [
      (
        #"<|channel|>analysis<|message|>thought<|end|><|start|>assistant<|channel|>final<|message|>first<|return|><|start|>assistant<|channel|>final<|message|>second<|return|>"#,
        "first"
      ),
      (
        #"<|start|>assistant<|channel|>final<|message|><|return|><|start|>assistant<|channel|>final<|message|>answer<|return|>"#,
        "answer"
      ),
      (
        #"<|start|>assistant<|channel|>final<|message|> \#n<|return|><|start|>assistant<|channel|>final<|message|>answer<|return|>"#,
        "answer"
      ),
      (#"<|start|>assistant<|message|>plain<|end|>"#, "plain"),
      (#"<|channel|>analysis<|message|>thought<|end|>"#, ""),
      (
        #"<|start|>assistant<|channel|>final<|constrain|>json<|message|>{"answer":"ok"}<|return|>"#,
        #"{"answer":"ok"}"#
      ),
      (#"<|start|>assistant<|channel|>final<|message|>callable<|call|>"#, "callable"),
      (#"<|start|>assistant<|channel|>final<|message|>partial"#, "partial"),
    ]
    for (text, expected) in cases {
      #expect(String(text[finalAnswerRange(text)]) == expected)
    }
  }

  @Test func ollamaCleanupPollingUsesAnExponentialBackoff() {
    #expect(nextOllamaCleanupDelay(0.05) == 0.1)
    #expect(nextOllamaCleanupDelay(0.75) == 1)
    #expect(nextOllamaCleanupDelay(1) == 1)
  }

  @Test func ollamaColdWarmGenerationAndRelease() throws {
    let loaded = LockedValue(false)
    let requests = LockedValue<[FixtureRequest]>([])
    let server = try FixtureServer { request in
      requests.update { $0.append(request) }
      return ollamaFixtureResponse(request, loaded: loaded)
    }
    defer { server.stop() }
    let adapter = OllamaAdapter(target: localTarget(server.baseURL), settings: testSettings())
    let cache = DoctorCache()
    #expect(try adapter.doctor(cache: cache).ok)
    #expect(try adapter.doctor(cache: cache).ok)
    #expect(requests.value.filter { $0.path == "/api/tags" }.count == 1)
    for condition in ["cold", "warm"] {
      try adapter.prepare(condition)
      #expect(loaded.value == (condition == "warm"))
      let result = try adapter.generate(testTask(), repeatNumber: 3)
      #expect(result.text == "ok")
      #expect(result.outputTokensPerSecond == 40)
      #expect((result.timeToFirstTokenMs ?? 0) >= 10)
      #expect(result.providerMetrics["model_memory_bytes"]?.uint == 1024)
      try adapter.cleanup(condition)
      #expect(!loaded.value)
    }
    let generated = requests.value.filter { $0.body["stream"].bool == true }
    #expect(
      generated.allSatisfy {
        $0.body["options"]["seed"].uint == 3 && $0.body["options"]["num_predict"].uint == 32
      })
    #expect(generated.allSatisfy { $0.body["system"] == .null })

    var configuredSettings = testSettings()
    configuredSettings.systemPrompt = "fixture system"
    let configured = OllamaAdapter(
      target: localTarget(server.baseURL), settings: configuredSettings)
    _ = try configured.generate(testTask(), repeatNumber: 1)
    let configuredRequest = try #require(
      requests.value.last { $0.path == "/api/generate" && $0.body["stream"].bool == true })
    #expect(configuredRequest.body["system"] == "fixture system")
  }

  @Test(arguments: ["task", String(repeating: "a", count: 200), String(repeating: "a", count: 220)])
  func fullRunWritesPrivateRawRecordsAndReports(_ taskID: String) throws {
    let temporary = try TemporaryDirectory()
    try temporary.write(
      "Resources/suites/one.jsonl",
      #"{"id":"\#(taskID)","category":"reasoning","prompt":"ok","scorer":{"type":"exact","expected":"ok"}}"#
        + "\n")
    let server = try FixtureServer { request in
      switch request.path {
      case "/api/version": return FixtureResponse(["version": "1.0"])
      case "/api/tags": return FixtureResponse(["models": [["name": "test-model"]]])
      case "/api/ps": return FixtureResponse(["models": []])
      default:
        if request.body["stream"].bool == true {
          let response =
            #"{"response":"ok","done":true,"model":"test-model","eval_count":2,"eval_duration":"#
            + #"100000000}"#
          return FixtureResponse(chunks: [(response + "\n", 0)])
        }
        return FixtureResponse([:])
      }
    }
    defer { server.stop() }
    let config = BenchmarkConfig(
      sourcePath: temporary.file("Resources/benchmark.json"),
      digest: String(repeating: "a", count: 64),
      run: testSettings(temporary.directory),
      hosts: [HostConfig(id: "fixture", chip: "test", memoryGib: 16)],
      targets: [localTarget(server.baseURL)])
    let detectedHost: JSON = [
      "os": "Darwin", "os_version": "15.0", "architecture": "arm64",
      "hardware_model": "fixture", "chip": "test", "memory_bytes": .unsigned(16 * gibibyte),
      "physical_cpu_count": 1, "logical_cpu_count": 1,
    ]
    let directory = try #require(
      try runBenchmark(config, detectedHost: detectedHost))
    let manifest = try readJSON(path(directory, "manifest.json"))
    #expect(manifest["status"] == "completed")
    #expect(manifest["application"]["language"] == "swift")
    #expect(manifest["run_settings"]["ollama_server_environment"].object != nil)
    let manifestSchema = try readJSON(
      path(repositoryRoot, "Resources/schemas/manifest.schema.json"))
    let trialSchema = try readJSON(path(repositoryRoot, "Resources/schemas/trial.schema.json"))
    try validateJSONSchema(manifest, against: manifestSchema)
    let records = try String(contentsOfFile: path(directory, "trials.jsonl"), encoding: .utf8)
      .split(separator: "\n").map { try JSON.parse(String($0)) }
    #expect(records.count == 2)
    for record in records { try validateJSONSchema(record, against: trialSchema) }
    for record in records { try expectTrialTimestamps(record) }
    #expect(records.allSatisfy { $0["passed"].bool == true && $0["score_detail"] == .null })
    let raw = try FileManager.default.contentsOfDirectory(atPath: path(directory, "raw")).filter {
      $0.hasPrefix("000")
    }
    #expect(raw.count == 2)
    for record in records {
      #expect(record["task_id"] == .string(taskID))
      let saved = try readJSON(path(directory, "raw/" + record["trial_id"].text + ".json"))
      #expect(saved["response"] == "ok")
    }
    var info = stat()
    #expect(stat(path(directory, "raw/" + raw[0]), &info) == 0)
    #expect(info.st_mode & 0o777 == 0o600)
    #expect(FileManager.default.fileExists(atPath: path(directory, "report.md")))
    #expect(
      try httpRequest("GET", url: server.baseURL + "/api/version", timeout: 1)["version"] == "1.0")
  }

  @Test(arguments: [false, true])
  func oversizedRawFilenamesFailBeforePreflight(_ dryRun: Bool) throws {
    let temporary = try TemporaryDirectory()
    let taskID = String(repeating: "a", count: 221)
    try temporary.write(
      "Resources/suites/one.jsonl",
      #"{"id":"\#(taskID)","category":"reasoning","prompt":"ok","scorer":{"type":"exact","expected":"ok"}}"#
    )
    let requests = LockedValue(0)
    let server = try FixtureServer { _ in
      requests.update { $0 += 1 }
      return FixtureResponse(["version": "1.0", "models": []])
    }
    defer { server.stop() }
    let config = BenchmarkConfig(
      sourcePath: temporary.file("Resources/benchmark.json"),
      digest: String(repeating: "a", count: 64), run: testSettings(temporary.directory),
      hosts: [HostConfig(id: "fixture", chip: "test", memoryGib: 16)],
      targets: [localTarget(server.baseURL)])
    #expect {
      try runBenchmark(
        config, dryRun: dryRun,
        detectedHost: ["chip": "test", "memory_bytes": .unsigned(16 * gibibyte)])
    } throws: { String(describing: $0).contains("raw filename exceeds") }
    #expect(requests.value == 0)
    #expect(!FileManager.default.fileExists(atPath: config.run.resultsDir))
  }
}
