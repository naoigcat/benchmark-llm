import Foundation

func nextOllamaCleanupDelay(_ delay: Double) -> Double {
  min(delay * 2, 1)
}

final class OllamaAdapter: Adapter {
  let target: TargetConfig
  let settings: RunSettings
  let cancellation: Cancellation?
  let baseURL: String
  init(target: TargetConfig, settings: RunSettings, cancellation: Cancellation? = nil) {
    self.target = target
    self.settings = settings
    self.cancellation = cancellation
    baseURL = target.baseUrl.hasSuffix("/") ? String(target.baseUrl.dropLast()) : target.baseUrl
  }
  private func request(
    _ endpoint: String, payload: JSON? = nil, timeout: Double? = nil,
    ignoreCancellation: Bool = false
  ) throws -> JSON {
    try httpRequest(
      payload == nil ? "GET" : "POST", url: baseURL + endpoint, payload: payload,
      timeout: timeout ?? settings.requestTimeoutSeconds,
      cancellation: ignoreCancellation ? nil : cancellation)
  }
  private func checkInterrupted() throws {
    if cancellation?.isCancelled == true {
      throw ApiError("Ollama operation interrupted", interrupted: true)
    }
  }
  private var loadOptions: JSON { target.contextWindow.map { ["num_ctx": .unsigned($0)] } ?? [:] }
  func doctor(cache: DoctorCache) throws -> DoctorResult {
    if cache.ollama[baseURL] == nil {
      cache.ollama[baseURL] = Result { (try request("/api/version"), try request("/api/tags")) }
    }
    let versionResponse: JSON
    let tags: JSON
    do { (versionResponse, tags) = try cache.ollama[baseURL]!.get() } catch {
      return .unavailable(redactCLIText(String(describing: error)))
    }
    let version = versionResponse["version"].truthy ? versionResponse["version"].text : nil
    let models = tags["models"].array ?? []
    guard let model = models.first(where: { modelMatches($0, target.model) }) else {
      return DoctorResult(
        ok: false, version: version,
        metadata: [
          "available_models": .array(models.filter { $0.object != nil }.map { $0["name"] })
        ], message: "model \(target.model) is not installed")
    }
    let details = model["details"]
    let metadata: [String: JSON] = [
      "digest": model["digest"], "size_bytes": model["size"], "format": details["format"],
      "family": details["family"], "parameter_size": details["parameter_size"],
      "quantization_level": details["quantization_level"],
    ]
    let resolved = [model["model"], model["name"]].first(where: \.truthy)?.text ?? target.model
    return DoctorResult(
      ok: true, version: version, resolvedModel: resolved, metadata: metadata, message: "ready")
  }
  private func modelIsLoaded(timeout: Double) throws -> Bool {
    let response = try request("/api/ps", timeout: timeout)
    guard let models = response["models"].array else {
      throw ApiError("Ollama model check has no models array")
    }
    for model in models {
      try require(
        model.object != nil
          && [model["name"], model["model"]].contains { !($0.string ?? "").isEmpty },
        "Ollama model check contains an invalid model entry")
    }
    return models.contains { modelMatches($0, target.model) }
  }
  private func unloadAndWait() throws {
    let started = monotonicTime()
    let interrupted = cancellation?.isCancelled == true
    do {
      _ = try request(
        "/api/generate",
        payload: ["model": .string(target.model), "keep_alive": 0, "stream": false],
        timeout: min(settings.requestTimeoutSeconds, interrupted ? 1 : 5),
        ignoreCancellation: true)
    } catch {
      if cancellation?.isCancelled == true {
        throw ApiError(redactCLIText(String(describing: error)), interrupted: true)
      }
      throw error
    }
    if interrupted { return }
    if cancellation?.isCancelled == true {
      throw ApiError("Ollama cleanup interrupted", interrupted: true)
    }
    var delay = 0.05
    while true {
      try checkInterrupted()
      let remaining = settings.requestTimeoutSeconds - (monotonicTime() - started)
      if remaining <= 0 {
        throw ApiError("timed out waiting for Ollama model to unload", timeout: true)
      }
      if try !modelIsLoaded(timeout: min(5, remaining)) { return }
      Thread.sleep(forTimeInterval: min(delay, remaining))
      delay = nextOllamaCleanupDelay(delay)
    }
  }
  func prepare(_ condition: String) throws {
    try require(
      ["cold", "warm"].contains(condition), "invalid Ollama cache condition: \(condition)")
    try checkInterrupted()
    if try modelIsLoaded(timeout: min(5, settings.requestTimeoutSeconds)) { try unloadAndWait() }
    if condition == "warm" {
      _ = try request(
        "/api/generate",
        payload: [
          "model": .string(target.model), "keep_alive": -1, "stream": false, "options": loadOptions,
        ])
    }
  }
  func cleanup(_ condition: String) throws {
    if ["cold", "warm"].contains(condition) { try unloadAndWait() }
  }
  private func modelMemory() -> [String: JSON] {
    guard cancellation?.isCancelled != true,
      let response = try? request("/api/ps", timeout: min(5, settings.requestTimeoutSeconds)),
      let model = response["models"].array?.first(where: { modelMatches($0, target.model) })
    else { return [:] }
    return [
      "model_memory_bytes": .value(countValue(model["size"])),
      "model_accelerator_memory_bytes": .value(countValue(model["size_vram"])),
      "loaded_context_window": .value(countValue(model["context_length"])),
      "runtime_quantization": .value(model["details"]["quantization_level"].string),
    ]
  }
  func generate(_ task: BenchmarkTask, repeatNumber: Int) throws
    -> GenerationResult
  {
    try checkInterrupted()
    var options = loadOptions
    options["temperature"] = .number(settings.temperature)
    options["seed"] = .integer(Int64(repeatNumber))
    options["num_predict"] = .unsigned(settings.maxOutputTokens)
    var payload: JSON = [
      "model": .string(target.model), "prompt": .string(task.prompt),
      "stream": true, "keep_alive": -1, "options": options,
    ]
    if !settings.systemPrompt.isEmpty { payload["system"] = .string(settings.systemPrompt) }
    let started = monotonicTime()
    var text = ""
    var fragments: [(Int, Double)] = []
    var events: [JSON] = []
    var final: JSON = [:]
    _ = try httpRequest(
      "POST", url: baseURL + "/api/generate", payload: payload,
      timeout: settings.requestTimeoutSeconds, cancellation: cancellation
    ) { event, timestamp in
      try require(
        events.count < streamEventLimit, "Ollama event stream exceeds \(streamEventLimit) events")
      if event["error"].truthy { throw ApiError(event["error"].text) }
      if let fragment = event["response"].string, !fragment.isEmpty {
        text += fragment
        fragments.append((text.utf8.count, timestamp))
      }
      events.append(event)
      if event["done"].truthy { final = event }
    }
    let ended = monotonicTime()
    try require(final["done"].truthy, "Ollama stream ended before a final done event")
    let range = finalAnswerRange(text)
    let answer = String(text[range])
    let offset = text[..<range.lowerBound].utf8.count
    let first = answer.isEmpty ? nil : fragments.first(where: { $0.0 > offset })?.1
    var metrics: [String: JSON] = [
      "generation_seed": .integer(Int64(repeatNumber)),
      "total_duration_ns": final["total_duration"], "load_duration_ns": final["load_duration"],
    ]
    metrics.merge(modelMemory()) { _, new in new }
    return GenerationResult(
      text: answer, resolvedModel: final["model"] == .null ? target.model : final["model"].text,
      wallTimeMs: (ended - started) * 1000,
      timeToFirstTokenMs: first.map { ($0 - started) * 1000 },
      inputTokens: countValue(final["prompt_eval_count"]),
      outputTokens: countValue(final["eval_count"]),
      promptEvalMs: nonnegative(final["prompt_eval_duration"]).map { $0 / 1e6 },
      generationMs: nonnegative(final["eval_duration"]).map { $0 / 1e6 },
      loadMs: nonnegative(final["load_duration"]).map { $0 / 1e6 },
      finishReason: final["done_reason"] == .null ? nil : final["done_reason"].text,
      providerMetrics: metrics, rawEvents: events)
  }
}

func modelMatches(_ value: JSON, _ model: String) -> Bool {
  value["name"].string == model || value["model"].string == model
}

func finalAnswerRange(_ text: String) -> Range<String.Index> {
  var offset = text.drop(while: \.isWhitespace).startIndex
  if !["<|channel|>", "<|start|>", "<|message|>"].contains(where: { text[offset...].hasPrefix($0) })
  {
    return text.startIndex..<text.endIndex
  }
  while offset < text.endIndex {
    offset = text[offset...].drop(while: \.isWhitespace).startIndex
    if text[offset...].hasPrefix("<|start|>") {
      offset = text.index(offset, offsetBy: "<|start|>".count)
    }
    guard let headerEnd = text.range(of: "<|message|>", range: offset..<text.endIndex) else {
      break
    }
    let header = String(text[offset..<headerEnd.lowerBound])
    offset = headerEnd.upperBound
    let end = ["<|end|>", "<|return|>", "<|call|>"].compactMap {
      text.range(of: $0, range: offset..<text.endIndex)
    }.min { $0.lowerBound < $1.lowerBound }
    let bodyEnd = end?.lowerBound ?? text.endIndex
    let parts = header.components(separatedBy: "<|channel|>")
    let role = parts[0].components(separatedBy: "<|constrain|>")[0].trimmed
    let channel = (parts.count > 1 ? parts[1] : "final").components(separatedBy: "<|constrain|>")[0]
      .trimmed
    if ["", "assistant"].contains(role) && channel == "final"
      && !text[offset..<bodyEnd].allSatisfy(\.isWhitespace)
    {
      return offset..<bodyEnd
    }
    guard let end else { break }
    offset = end.upperBound
  }
  return text.endIndex..<text.endIndex
}
