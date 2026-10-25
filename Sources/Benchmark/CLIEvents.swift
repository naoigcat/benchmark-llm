import Foundation

func countValue(_ value: JSON) -> UInt64? {
  value.uint ?? value.double.flatMap { UInt64(exactly: $0) }
}

func nonnegative(_ value: JSON) -> Double? {
  value.double.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
}

func contentText(_ value: JSON) -> String? {
  if let text = value.string { return text }
  if let values = value.array {
    let texts = values.compactMap(contentText)
    return values.isEmpty || !texts.isEmpty ? texts.joined() : nil
  }
  if let object = value.object {
    if ["tool_use", "tool_result"].contains(value["type"].string ?? "") { return nil }
    for key in ["text", "content", "delta"] {
      if let child = object[key], let text = contentText(child) { return text }
    }
  }
  return nil
}

// Visits each value once, so the cost stays linear in the event bytes already parsed under the
// referenceCLIEventByteLimit, and the 128-level parser nesting limit bounds the recursion depth.
func containsToolActivity(_ value: JSON) -> Bool {
  switch value {
  case .array(let values): values.contains(where: containsToolActivity)
  case .object(let object):
    marksToolActivity(value) || object.values.contains(where: containsToolActivity)
  case .scalarObject(let members):
    marksToolActivity(value) || members.contains { containsToolActivity($0.value) }
  default: false
  }
}

private func marksToolActivity(_ object: JSON) -> Bool {
  let type = object["type"].string ?? ""
  // The suffixes cover server_tool_use, mcp_tool_use, web_search_tool_result, and similar types.
  return [
    "tool_call", "tool_call_delta", "function_call", "function_response", "input_json_delta",
  ].contains(type) || type.hasSuffix("tool_use") || type.hasSuffix("tool_result")
    || object["role"].string == "tool" || !(object["tool_calls"].array ?? []).isEmpty
    || object["functionCall"] != .null || object["functionResponse"] != .null
}

func isErrorEvent(_ event: JSON) -> Bool {
  // Claude Code reports a retryable API failure (429, 529, network) and then retries itself.
  if event["type"].string == "system" && event["subtype"].string == "api_retry" { return false }
  return event["type"].string == "error" || event["error"].truthy
    || (event["type"].string == "result" && event["is_error"].bool == true)
    || (event["event"].object != nil && isErrorEvent(event["event"]))
}

func eventErrorMessage(_ event: JSON) -> String {
  for key in ["error", "message", "result"] {
    if let text = contentText(event[key]) ?? event[key]["message"].string { return text }
  }
  return event["event"].object != nil ? eventErrorMessage(event["event"]) : "CLI reported an error"
}

final class EventAccumulator {
  let schema: String
  var text = ""
  var hasResponse = false
  var firstTextAt: Double?
  var inputTokens: UInt64?
  var outputTokens: UInt64?
  var model: String
  var finishReason: String?
  private var hasIncrementalOutput = false
  /// The current Codex agent_message and the UTF-8 offset in `text` where its text begins.
  private var codexItem: (id: String, offset: Int)?
  var metrics: [String: JSON] = [:]
  var events: [JSON] = []
  var eventBytes = 0
  init(schema: String, model: String) {
    self.schema = schema
    self.model = model
  }
  func handle(_ line: String, at timestamp: Double) throws {
    let line = line.trimmed
    if line.isEmpty { return }
    try require(
      eventBytes + line.utf8.count <= referenceCLIEventByteLimit,
      "\(schema) event stream exceeds \(referenceCLIEventByteLimit) bytes")
    let event = try JSON.parse(line)
    try require(event.object != nil, "\(schema) event must be a JSON object")
    try require(
      events.count < streamEventLimit, "\(schema) event stream exceeds \(streamEventLimit) events")
    eventBytes += line.utf8.count
    events.append(event)
    collectMetadata(event)
    // Codex reports each stream reconnect as a top-level error and then retries; a failure that
    // persists still ends in turn.failed, a non-zero exit, or no answer.
    let codexNotice = schema == "codex-jsonl" && event["type"].string == "error"
    if isErrorEvent(event) && !codexNotice {
      throw ApiError(redactCLIText(eventErrorMessage(event)))
    }
    try require(
      !containsToolActivity(event),
      "CLI emitted tool activity; tools are disabled for benchmark trials")
    if schema == "codex-jsonl" {
      let type = event["type"].string ?? "<missing or non-string>"
      if ["item.started", "item.updated", "item.completed", "item.delta"].contains(type) {
        let item = event["item"]["type"].string ?? "<missing or non-string>"
        try require(
          ["agent_message", "reasoning"].contains(item),
          "Codex emitted an unsupported item type \(redactCLIText(item)); tools are disabled for benchmark trials"
        )
      } else {
        try require(
          ["thread.started", "turn.started", "turn.completed", "error"].contains(type),
          "Codex emitted an unsupported event type \(redactCLIText(type))")
      }
    }
    collectOutput(event, at: timestamp)
  }
  private func collectMetadata(_ event: JSON) {
    let objects = [
      event, event["event"], event["event"]["message"], event["message"], event["item"],
      event["delta"], event["event"]["delta"], event["item"]["delta"],
    ]
    for object in objects where object.object != nil {
      if let model = object["model"].string, !model.isEmpty { self.model = model }
      if let usage = object["usage"].object {
        var merged = metrics["usage"]?.object ?? [:]
        merged.merge(usage) { _, new in new }
        metrics["usage"] = .object(merged)
        if let uncached = ["input_tokens", "prompt_tokens", "inputTokens", "promptTokens"]
          .compactMap({ countValue(object["usage"][$0]) }).first
        {
          // Claude and Cursor report cached prompt tokens separately; Codex includes them.
          var total: UInt64? = uncached
          for key in [
            "cache_creation_input_tokens", "cache_read_input_tokens", "cacheReadTokens",
            "cacheWriteTokens",
          ] {
            let cached = countValue(object["usage"][key]) ?? 0
            total = total.map { $0.addingReportingOverflow(cached) }.flatMap {
              $0.overflow ? nil : $0.partialValue
            }
          }
          inputTokens = total
        }
        outputTokens =
          ["output_tokens", "completion_tokens", "outputTokens", "completionTokens"].compactMap {
            countValue(object["usage"][$0])
          }.first ?? outputTokens
      }
      for key in ["finish_reason", "stop_reason"] {
        if let reason = object[key].string { finishReason = reason }
      }
      for key in ["total_cost_usd", "duration_ms", "duration_api_ms", "num_turns"] {
        if let value = object.object?[key] { metrics[key] = value }
      }
    }
  }
  private func collectOutput(_ event: JSON, at timestamp: Double) {
    let type = event["type"].string ?? ""
    if schema == "codex-jsonl" {
      collectCodexOutput(event, type: type, at: timestamp)
      return
    }
    if type == "stream_event" {
      collectOutput(event["event"], at: timestamp)
      return
    }
    collectStandardOutput(event, type: type, at: timestamp)
  }
  /// Only the README's documented answer events count; others (including user echoes) are ignored.
  private func collectStandardOutput(_ event: JSON, type: String, at timestamp: Double) {
    switch type {
    case "content_block_delta":
      if let text = contentText(event["delta"]) ?? contentText(event["text"]) {
        append(text, timestamp)
      }
    case "assistant":
      collectAssistantOutput(event, at: timestamp)
    case "result":
      collectResultOutput(event, at: timestamp)
    case "system" where event["subtype"].string == "api_retry":
      // Deltas already streamed belong to the abandoned attempt; the retry streams the answer again.
      text = ""
      hasIncrementalOutput = false
      hasResponse = false
      firstTextAt = nil
    default:
      break
    }
  }
  private func collectResultOutput(_ event: JSON, at timestamp: Double) {
    guard let text = contentText(event["result"]) else { return }
    if schema == "cursor-stream-json" {
      replace(text, timestamp)
    } else {
      full(text, timestamp, final: true)
    }
  }
  private func collectCodexOutput(_ event: JSON, type: String, at timestamp: Double) {
    guard event["item"]["type"].string == "agent_message" else { return }
    let id = event["item"]["id"].string
    if let id, codexItem?.id != id { codexItem = (id, text.utf8.count) }
    if type == "item.delta", let text = contentText(event["delta"]) {
      append(text, timestamp)
    }
    if ["item.updated", "item.completed"].contains(type), let value = contentText(event["item"]) {
      if let id, let item = codexItem, item.id == id {
        // A snapshot of one message replaces only that message's text, after earlier messages.
        mark(value, timestamp)
        text = String(decoding: text.utf8.prefix(item.offset), as: UTF8.self) + value
      } else {
        full(value, timestamp)
      }
    }
  }
  private func collectAssistantOutput(_ event: JSON, at timestamp: Double) {
    if let text = contentText(event["message"]) ?? contentText(event["content"]) {
      if schema == "cursor-stream-json" {
        if event.object?["timestamp_ms"] != nil {
          append(text, timestamp)
        } else {
          replace(text, timestamp)
        }
      } else {
        full(text, timestamp)
      }
    }
  }
  private func mark(_ value: String, _ timestamp: Double) {
    hasResponse = true
    if !value.isEmpty && firstTextAt == nil { firstTextAt = timestamp }
  }
  private func append(_ value: String, _ timestamp: Double) {
    mark(value, timestamp)
    if !value.isEmpty { hasIncrementalOutput = true }
    text += value
  }
  private func replace(_ value: String, _ timestamp: Double) {
    mark(value, timestamp)
    text = value
  }
  private func full(_ value: String, _ timestamp: Double, final: Bool = false) {
    mark(value, timestamp)
    if value.isEmpty || text == value { return }
    // A final result or a content block after deltas may repeat part of the accumulated answer.
    if (final || hasIncrementalOutput) && (text.hasPrefix(value) || text.hasSuffix(value)) {
      return
    }
    // A snapshot that extends the accumulated text is the same message growing, not a new one.
    text = hasIncrementalOutput || value.hasPrefix(text) ? value : text + value
  }
}
