import Foundation

private struct LocalModelDefinition {
  let id: String
  let model: String
  let quantization: String
}

private struct CLIModelDefinition {
  let product: String
  let model: String
  let efforts: [String]
}

private let localModelDefinitions = [
  LocalModelDefinition(
    id: "ollama-gemma4-e2b", model: "gemma4:e2b-it-q4_K_M", quantization: "Q4_K_M"),
  LocalModelDefinition(
    id: "ollama-gemma4-e4b", model: "gemma4:e4b-it-q4_K_M", quantization: "Q4_K_M"),
  LocalModelDefinition(
    id: "ollama-gemma4-12b", model: "gemma4:12b-it-q4_K_M", quantization: "Q4_K_M"),
  LocalModelDefinition(
    id: "ollama-gemma4-26b", model: "gemma4:26b-a4b-it-q4_K_M", quantization: "Q4_K_M"),
  LocalModelDefinition(
    id: "ollama-gemma4-31b", model: "gemma4:31b-it-q4_K_M", quantization: "Q4_K_M"),
  LocalModelDefinition(
    id: "ollama-gpt-oss-swallow-20b", model: "gpt-oss-swallow:20b-rl-v0.1-mxfp4",
    quantization: "MXFP4_MOE"),
  LocalModelDefinition(
    id: "ollama-gpt-oss-swallow-120b", model: "gpt-oss-swallow:120b-rl-v0.1-mxfp4",
    quantization: "MXFP4_MOE"),
  LocalModelDefinition(
    id: "ollama-ornith-1.5-9b", model: "ornith-1.5:9b", quantization: "Q4_K_M"),
  LocalModelDefinition(
    id: "ollama-ornith-1.5-35b", model: "ornith-1.5:35b", quantization: "Q4_K_M"),
]

private let cliModelDefinitions = [
  CLIModelDefinition(
    product: "cursor", model: "cursor-grok-4.6", efforts: ["low", "medium", "high"]),
  CLIModelDefinition(
    product: "codex", model: "gpt-5.3-codex-spark", efforts: ["low", "medium", "high"]),
  CLIModelDefinition(
    product: "codex", model: "gpt-5.6-sol", efforts: ["low", "medium", "high", "max"]),
  CLIModelDefinition(
    product: "codex", model: "gpt-5.6-luna", efforts: ["low", "medium", "high", "max"]),
  CLIModelDefinition(
    product: "codex", model: "gpt-5.6-terra", efforts: ["low", "medium", "high", "max"]),
  CLIModelDefinition(
    product: "codex", model: "gpt-6-astra", efforts: ["low", "medium", "high", "max"]),
  CLIModelDefinition(
    product: "claude", model: "claude-opus-5", efforts: ["low", "medium", "high", "max"]),
  CLIModelDefinition(
    product: "claude", model: "claude-sonnet-5", efforts: ["low", "medium", "high", "max"]),
  CLIModelDefinition(
    product: "antigravity", model: "gemini-3.8-flash", efforts: ["low", "medium", "high"]),
  CLIModelDefinition(
    product: "antigravity", model: "gemini-3.1-pro", efforts: ["low", "high"]),
  CLIModelDefinition(product: "antigravity", model: "gpt-oss-120b", efforts: ["medium"]),
]

// Source-owned model definitions; Resources/benchmark.json only selects IDs and eligible hosts.
func targetDefinitions() -> [TargetConfig] {
  var targets = localModelDefinitions.map { definition in
    TargetConfig(
      id: definition.id, inferenceLocation: "local", adapter: "ollama", model: definition.model,
      baseUrl: "http://127.0.0.1:11434", backend: "ollama",
      quantization: definition.quantization,
      // Ollama runs llama.cpp models in a llama-server child; "llama" matches it and ollama itself.
      contextWindow: 8192, processMatch: "llama")
  }
  targets.append(cliTarget("cursor", model: "composer-2.5", effort: nil))
  for definition in cliModelDefinitions {
    targets += definition.efforts.map {
      cliTarget(definition.product, model: definition.model, effort: $0)
    }
  }
  precondition(Set(targets.map(\.id)).count == targets.count, "duplicate target catalog ID")
  precondition(targets.allSatisfy { isValidID($0.id) }, "invalid target catalog ID")
  return targets
}

private let codexToolConfig = [
  "features.shell_tool=false",
  "web_search=\"disabled\"",
  "agents.enabled=false",
  "features.multi_agent=false",
  "features.multi_agent_v2=false",
  "features.apps=false",
  "features.plugins=false",
  "features.remote_plugin=false",
  "features.browser_use=false",
  "features.computer_use=false",
  "features.image_generation=false",
  "features.view_image=false",
  "features.code_mode=false",
  "features.code_mode_host=false",
  "features.goals=false",
  "features.sleep_tool=false",
  "features.tool_suggest=false",
  "features.default_mode_request_user_input=false",
  "tools.update_plan.enabled=false",
  "tools.experimental_request_user_input.enabled=false",
  "orchestrator.mcp.enabled=false",
  "orchestrator.skills.enabled=false",
]

private func cliTarget(_ name: String, model: String, effort: String?) -> TargetConfig {
  guard let product = products.first(where: { $0.name == name }) else {
    preconditionFailure("unknown CLI product: \(name)")
  }
  let idModel = model.hasPrefix(name + "-") ? String(model.dropFirst(name.count + 1)) : model
  let id = name + "-" + idModel + (effort.map { "-" + $0 } ?? "")
  let resolvedModel =
    ["cursor", "antigravity"].contains(name) ? model + (effort.map { "-" + $0 } ?? "") : model
  var args: [String]
  let backend: String
  switch name {
  case "cursor":
    backend = "cursor-agent"
    args = [
      // Headless cursor-agent exits in an untrusted directory, and every trial directory is new.
      "-p", "--output-format", "stream-json", "--stream-partial-output", "--mode", "ask", "--trust",
      "--model", "{model}",
    ]
  case "codex":
    backend = "codex-cli"
    args = [
      "exec", "--json", "--sandbox", "read-only", "--skip-git-repo-check", "--ignore-user-config",
      "-m", "{model}",
    ]
    for setting in codexToolConfig { args += ["-c", setting] }
  case "claude":
    backend = "claude-code"
    args = [
      "-p", "--verbose", "--output-format", "stream-json", "--include-partial-messages", "--tools",
      "", "--strict-mcp-config", "--model", "{model}",
    ]
  case "antigravity":
    backend = "antigravity-cli"
    args = [
      "-p", "--output-format", "stream-json", "--disable-slash-commands", "--sandbox", "--model",
      "{model}",
    ]
  default:
    preconditionFailure("unsupported CLI product: \(name)")
  }
  if let effort {
    if name == "codex" { args += ["-c", "model_reasoning_effort=\"\(effort)\""] }
    if ["claude", "antigravity"].contains(name) { args += ["--effort", effort] }
  }
  return TargetConfig(
    id: id, inferenceLocation: "remote", adapter: "cli-agent", model: resolvedModel,
    backend: backend, command: product.command, args: args,
    promptDelivery: "stdin", eventSchema: product.eventSchema)
}

func modelfile(for target: String) -> String? {
  let size: String
  switch target {
  case "ollama-gpt-oss-swallow-20b": size = "20B"
  case "ollama-gpt-oss-swallow-120b": size = "120B"
  default: return nil
  }
  let channelLine =
    "# Valid channels: analysis, commentary, final. Channel must be included for every message."
  let template = #"""
    <|start|>system<|message|>You are ChatGPT, a large language model trained by OpenAI.
    Knowledge cutoff: 2024-06

    Reasoning: medium

    \#(channelLine)<|end|>{{ if .System }}<|start|>developer<|message|># Instructions

    {{ .System }}<|end|>{{ end }}<|start|>user<|message|>{{ .Prompt }}<|end|><|start|>assistant{{ .Response }}
    """#
  return ####"""
    # Weights: https://huggingface.co/mradermacher/GPT-OSS-Swallow-\####(size)-RL-v0.1-GGUF
    # Use the benchmark's single-turn Harmony template instead of the HF-generated one.
    # Both Swallow sizes share the publisher, quantization, template, and parameters.
    FROM hf.co/mradermacher/GPT-OSS-Swallow-\####(size)-RL-v0.1-GGUF:MXFP4_MOE

    TEMPLATE """\####(template)"""

    # Replace the inherited stop list: channel and message boundaries must not end reasoning.
    PARAMETER stop "<|return|>"
    # The benchmark overrides this default with run.temperature on each request.
    PARAMETER temperature 1

    """####
}
