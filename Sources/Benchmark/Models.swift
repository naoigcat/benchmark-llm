import Foundation

let benchmarkVersion = "0.1.0"

func isValidID(_ value: String) -> Bool {
  guard let first = value.utf8.first, (97...122).contains(first) || (48...57).contains(first) else {
    return false
  }
  return value.utf8.allSatisfy {
    (97...122).contains($0) || (48...57).contains($0)
      || $0 == 45 || $0 == 46 || $0 == 95
  }
}

func isOutputTruncated(_ reason: String?) -> Bool {
  reason.map { ["length", "max_tokens", "max_output_tokens"].contains($0.lowercased()) } ?? false
}

struct RunSettings: Equatable, Sendable {
  var resultsDir: String
  var suitesDir: String
  var workdir: String
  var repeatCount = 5
  var requestTimeoutSeconds = 300.0
  var cooldownSeconds = 3.0
  var maxOutputTokens: UInt64 = 2048
  var temperature = 0.7
  var seed: UInt64
  var cacheConditions = ["cold", "warm"]
  var systemPrompt = ""
}

enum ReportLanguage: String, Codable, Sendable { case ja, en }
struct SelectionSettings: Codable, Equatable, Sendable {
  enum CodingKeys: String, CodingKey {
    case minimumPassRate = "minimum_pass_rate"
    case minimumMedianTokensPerSecond = "minimum_median_tokens_per_second"
    case maximumPeakSwapDeltaGib = "maximum_peak_swap_delta_gib"
    case maximumBackendMemoryFraction = "maximum_backend_memory_fraction"
  }

  var minimumPassRate = 0.8
  var minimumMedianTokensPerSecond = 10.0
  var maximumPeakSwapDeltaGib = 1.0
  var maximumBackendMemoryFraction = 0.7
}

struct HostConfig: Equatable, Sendable {
  var id: String
  var chip: String
  var memoryGib: UInt64
}

struct TargetConfig: Equatable, Sendable {
  var id = ""
  var inferenceLocation = ""
  var adapter = ""
  var model = ""
  var baseUrl = ""
  var backend: String?
  var quantization: String?
  var contextWindow: UInt64?
  var eligibleHosts: [String] = []
  var processMatch: String?
  var command: String?
  var args: [String] = []
  var promptDelivery: String?
  var eventSchema: String?
  func validate() throws {
    switch (adapter, inferenceLocation) {
    case ("ollama", "local"):
      try requireLoopbackEndpoint(baseUrl)
      guard let components = URLComponents(string: baseUrl) else {
        throw BenchmarkError("Ollama baseUrl must be a valid URL")
      }
      try require(components.port != nil, "Ollama baseUrl must include an explicit port")
      try require(
        (components.path.isEmpty || components.path == "/") && components.query == nil
          && components.fragment == nil && components.user == nil
          && components.password == nil,
        "Ollama baseUrl must use the root path without a query, fragment, or authentication information"
      )
    case ("cli-agent", "remote"):
      try require(baseUrl.isEmpty, "cli-agent targets must not have an HTTP endpoint")
    default:
      throw BenchmarkError(
        "unsupported inferenceLocation/adapter combination: \(inferenceLocation)/\(adapter)")
    }
  }
  func cacheConditions(_ configured: [String]) -> [String] {
    adapter == "ollama" ? configured : ["provider-managed"]
  }
  func eligible(on host: String) -> Bool { eligibleHosts.isEmpty || eligibleHosts.contains(host) }
  var json: JSON {
    [
      "id": .string(id), "inference_location": .string(inferenceLocation),
      "adapter": .string(adapter),
      "model": .string(model), "base_url": .string(baseUrl), "backend": .value(backend),
      "quantization": .value(quantization), "context_window": .value(contextWindow),
      "eligible_hosts": .array(eligibleHosts.map(JSON.string)),
      "process_match": .value(processMatch),
      "command": .value(command), "args": .array(args.map(JSON.string)),
      "prompt_delivery": .value(promptDelivery), "event_schema": .value(eventSchema),
    ]
  }
}

struct BenchmarkConfig: Sendable {
  var sourcePath: String
  var digest: String
  var run: RunSettings
  var language: ReportLanguage = .ja
  var selection = SelectionSettings()
  var hosts: [HostConfig]
  var targets: [TargetConfig]
}

struct BenchmarkTask: Sendable {
  var id: String
  var category: String
  var prompt: String
  var scorer: [String: JSON]
  var passThreshold = 1.0
}

struct ScoreResult: Codable, Equatable, Sendable {
  var score: Double
  var detail: String
}

struct GenerationResult: Sendable {
  var text = ""
  var resolvedModel: String?
  var wallTimeMs = 0.0
  var timeToFirstTokenMs: Double?
  var inputTokens: UInt64?
  var outputTokens: UInt64?
  var promptEvalMs: Double?
  var generationMs: Double?
  var loadMs: Double?
  var finishReason: String?
  var providerMetrics: [String: JSON] = [:]
  var rawEvents: [JSON] = []
  /// Ollama counts the first token in eval_count but times it with the prompt, so the decode
  /// interval covers one token fewer.
  var outputTokensPerSecond: Double? {
    guard let tokens = outputTokens, tokens > 1, let milliseconds = generationMs,
      milliseconds > 0
    else { return nil }
    return Double(tokens - 1) / (milliseconds / 1000)
  }
}

struct DoctorResult: Sendable {
  var ok: Bool
  var version: String?
  var resolvedModel: String?
  var metadata: [String: JSON] = [:]
  var message: String
  static func unavailable(_ message: String) -> Self { .init(ok: false, message: message) }
  func failed(_ message: String) -> Self {
    var result = self
    result.ok = false
    result.resolvedModel = nil
    result.message = message
    return result
  }
  var json: JSON {
    [
      "ok": .bool(ok), "version": .value(version), "resolved_model": .value(resolvedModel),
      "metadata": .object(metadata), "message": .string(message),
    ]
  }
}
