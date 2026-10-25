# Benchmark

A reproducible benchmark that measures local LLMs and subscription coding agents with the same tasks and the same scoring rules,
on a Mac Studio M2 Max with 96 GB of unified memory and a MacBook Pro M1 Pro with 16 GB.
The question it answers is which local model is actually worth running on a given Mac.

Run this code on each Mac being measured, with Ollama running on that same Mac.
Local models are the candidates, measured through Ollama so that model load time stays separate from the speed sustained afterwards.
The Cursor, Codex, Claude, and Antigravity CLIs, driven non-interactively, supply the quality ceiling; metered cloud APIs are deliberately not used,
so nothing here is billed per token. A candidate is recommended only after clearing both a quality bar and a speed bar —
no single blended score decides the ranking. [Methodology](#methodology) defines each metric, the cold and warm cache conditions,
and the selection rules that recommendation follows.

Completed CLI trials record wall time, time to the first text event, and token counts when reported; local trials also record generation speed and memory.
Anything a backend does not report is stored as `null` rather than estimated. A manifest pins the machine, the commit, the run settings,
and each target's backend and model settings, including CLI arguments, so runs stay comparable across machines and across weeks.

## Contents

-   [Quick start](#quick-start)
-   [Scope](#scope)
-   [Safety](#safety)
-   [Setting up a machine](#setting-up-a-machine)
-   [Configuration](#configuration)
-   [Running the benchmark](#running-the-benchmark)
-   [Methodology](#methodology)
-   [Experiment plan](#experiment-plan)
-   [License](#license)

## Quick start

Requires an Apple Silicon Mac running macOS 15 or later, with Xcode 16 through the Xcode that matches the Swift pin (currently Xcode 27)
supplying the Apple SDK; mise installs the pinned Swift toolchain.
[Setting up a machine](#setting-up-a-machine) covers OS prerequisites, tool installation, and agent sign-in.

```sh
brew install mise ollama
brew install --cask claude-code
ollama serve                     # in a second terminal; stop it with Ctrl-C after the pull
ollama pull gemma4:e2b-it-q4_K_M
mise trust
mise run build
mise run execute login claude   # once per reference agent you want measured
mise run execute doctor
mise run execute run --target ollama-gemma4-e2b --repeat 1
mise run execute report Deliverables/Runs/<run-id>
```

`doctor` and `run` select the matching `hosts` entry from the Mac's chip and installed memory, so the same commands work on either machine;
[Running the benchmark](#running-the-benchmark) covers the remaining options, the order to measure two machines in, and what a run leaves behind.
This quick-start run measures one local target once. For the smoke procedure and the full matrix, follow [Order of measurement](#order-of-measurement).

Model settings and CLI invocations are fixed in [`Sources/Benchmark/Targets.swift`](Sources/Benchmark/Targets.swift); JSON selects target IDs and eligible hosts.
Local candidates are Gemma 4, GPT-OSS Swallow, and Ornith 1.5,
with separate target IDs for each size. Install the exact tags in the [local model catalog](#ollama),
then select one or more with `mise run execute run --target ollama-gemma4-e2b` (repeat `--target` to compare candidates).
Reference agents become measurable once `mise run execute login <product>` has signed their benchmark profile in; `doctor` returns status 1
while eligible targets are unready and names the command to run.
[Configuration](#configuration) documents each key and the format of a task suite.
Reports, summary CSVs, and the manifest and trial records needed to regenerate them are tracked in Git, so committing a run's directory and pulling it
on the other Mac is enough to compare the two.

## Scope

Local targets are measured as bare models through Ollama, and they are the only candidates the selection rules apply to.
[Experiment plan](#experiment-plan) sets out which of them to measure first on each machine, and how to decide between them.

Reference values come from coding agents rather than raw model endpoints, because those agents are what is actually paid for here.
A reference row therefore includes the product's own system prompt and context handling, not just the model behind it.
The `cli-agent` adapter supports Cursor, Codex, Claude, and Antigravity JSON event streams, process timeouts, and version and authentication checks.
[Isolation](#isolation) is the benchmark's own: it keeps one profile per product, points each CLI's configuration, state, and `HOME`
into it, and runs preflight checks and trials in fresh empty directories outside the operator's home.
Those processes neither read nor modify your ordinary `~/.claude`, `~/.codex`, `~/.cursor`, and `~/.gemini`.
There is nothing to configure — sign in once per product with `mise run execute login`.
Reference rows are read as an upper bound on answer quality, never as a measurement of the underlying model.

## Safety

Ollama connections are restricted to loopback so that inference runs on the Mac whose hardware and memory are measured.
The runner checks endpoints before starting a measurement, restricts redirects to loopback, and bypasses HTTP proxy settings.
Reference agents authenticate through their own CLI into a benchmark-owned profile with owner-only permissions;
the manifest records which variables the isolation sets, never their values, and recognized sensitive CLI arguments are redacted.
Keep credentials out of configuration files, arguments, and CLI diagnostic output.
Raw prompts, responses, provider events, and detailed diagnostics stay out of version control.

`manifest.json` is shared through Git. Configuration and task suite paths inside the repository are recorded relative to its root;
paths outside it are `null`, and the working directory is recorded as `.`. Hostnames are omitted; hardware details and file hashes remain available
for comparison.

Host detection, memory telemetry, and repository metadata use `ps`, `sysctl`, `uname`, `sw_vers`, and `git`
resolved from the operator's inherited `PATH`. Use a trusted `PATH`, since these helpers affect the recorded
hardware details, memory measurements, and repository identity.

## Setting up a machine

What to install before the first run, and how to prove it works.
Both machines are set up the same way and kept on the same versions; the run procedure is in [Running the benchmark](#running-the-benchmark).

### Prerequisites

Use an Apple Silicon Mac running **macOS 15 or later**. The CLI is implemented in Swift and uses macOS process control, file locking, and memory telemetry.
`Package.swift` sets the minimum deployment target to macOS 15; other operating systems are not supported.
Building, testing, and linting require Xcode 16 through the Xcode that matches the Swift pin (currently Xcode 27) for the Apple SDK
and the Swift toolchain pinned in [`.mise.toml`](.mise.toml), including `swift format`.
Standalone Command Line Tools are not supported.

### What gets installed

| Tool              | Command          | Installed with                          | Needed for                                           |
| ----------------- | ---------------- | --------------------------------------- | ---------------------------------------------------- |
| Homebrew          | `brew`           | Install script                          | mise, Ollama, and agent CLIs                         |
| mise              | `mise`           | `brew install mise`                     | Running the tasks in [`.mise.toml`](.mise.toml)      |
| Swift             | `swift`          | `mise install` (see Swift, below)       | Building, testing, and linting the CLI               |
| Ollama            | `ollama`         | `brew install ollama`                   | Every local target                                   |
| Cursor CLI        | `cursor-agent`   | `brew install --cask cursor-cli`        | The Cursor reference target                          |
| Codex CLI         | `codex`          | `brew install --cask codex`             | The Codex reference target                           |
| Claude Code       | `claude`         | `brew install --cask claude-code`       | The Claude reference target                          |
| Antigravity CLI   | `agy`            | `brew install --cask antigravity-cli`   | The Antigravity reference target                     |

The first three are required on every machine, Ollama to measure any local model, and each agent CLI only for the reference target it belongs to —
one can be installed without the others.

Because the agents share one results table with the local models, install them from the same source on both machines,
so that a difference between two rows is a difference between products rather than between installation methods.

### Swift

Install Xcode 16 through the Xcode that matches the Swift pin (currently Xcode 27), open it, and complete its license agreement and initial component installation.
Select that installation before running the repository's tasks (adjust the path if Xcode is installed elsewhere):

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
brew install mise
mise trust             # once inside the checkout
mise install
mise run toolchain
```

Swift, including `swift format`, is pinned in [`.mise.toml`](.mise.toml) and installed by `mise install`; the Apple SDK still comes from the
selected Xcode. The pin matches the Swift release of the Xcode used for benchmarks, because a compiler older than the SDK cannot parse it, so
bump both together. `mise run toolchain` prints the selected Xcode and Swift versions, and `mise run verify` runs it first, so every local and CI log
records which pair produced the result. Use the same Xcode version on both benchmark machines;
if `DEVELOPER_DIR` is set, it must select the intended Xcode installation.
Swift Package Manager builds this package from `Package.swift`; the package has no external Swift dependencies.
Automatic dependency updates are disabled during checks and builds.
Swift Testing uses the frameworks and compiler plugins provided by Xcode.
The CI job named `Latest supported macOS (macos-latest)` runs on the platform used for measurements;
the separate `Minimum supported macOS (macos-15)` job checks the deployment floor. `macos-latest` is an alias and may resolve to
`macos-15`, so the labels preserve which runner contract each job is exercising even when the images coincide. Both jobs record the selected Xcode
and Swift versions before building.

### Installing Ollama

```sh
brew install ollama
```

The runner starts and stops its own server and loads and unloads models itself, so nothing needs to be resident before a run;
[Local inference servers](#local-inference-servers) describes that behaviour.
Run the benchmark and Ollama on the same Mac, with the server listening on loopback.

Installing a model is a separate one-time step that does need a server. If none is running, start one in another terminal,
pull from the original terminal, then stop the temporary server with Ctrl-C:

```sh
ollama serve          # in a second terminal, if nothing is serving yet
ollama pull gemma4:e2b-it-q4_K_M
ollama pull ornith-1.5:9b
ollama list
```

Pull only the candidates you want to measure. The [local model catalog](#ollama) lists all nine tags and their eligible machines,
including larger candidates for the 96 GB Mac. Use the exact tag in that table so preflight can find the installed model.

Both Swallow sizes require a custom Modelfile generated from their [Swift target definitions](Sources/Benchmark/Targets.swift).
Run the commands for the size you want to measure from the checkout while the Ollama server is running.
For 20B on either Mac:

```sh
ollama pull hf.co/mradermacher/GPT-OSS-Swallow-20B-RL-v0.1-GGUF:MXFP4_MOE
mise run execute modelfile ollama-gpt-oss-swallow-20b | \
    ollama create gpt-oss-swallow:20b-rl-v0.1-mxfp4 -f /dev/stdin
```

For 120B on the 96 GB Mac:

```sh
ollama pull hf.co/mradermacher/GPT-OSS-Swallow-120B-RL-v0.1-GGUF:MXFP4_MOE
mise run execute modelfile ollama-gpt-oss-swallow-120b | \
    ollama create gpt-oss-swallow:120b-rl-v0.1-mxfp4 -f /dev/stdin
```

Both recipes use mradermacher's RL v0.1 GGUF weights with MXFP4_MOE quantization and create the catalog's local tags.
They share the same single-turn Harmony template, medium reasoning, and a stop list that allows reasoning to finish.
The `modelfile` command writes only the generated recipe to standard output; `/dev/stdin` passes it directly to Ollama without creating a file.
It can also be run on its own to inspect the recipe before installation.
The HF packages' automatically generated templates have a malformed user boundary and incompatible stop tokens; the Modelfiles replace both.
The benchmark template omits the current date so inputs stay identical across measurement days.
Re-run the corresponding `modelfile | ollama create` command above to update an already installed Swallow tag.

### Reference agent CLIs

```sh
brew install --cask cursor-cli codex claude-code antigravity-cli
```

Homebrew installs the Cursor CLI as `cursor-agent`; the vendor's install script additionally creates an `agent` alias for the same binary.
This repository uses `cursor-agent`, which both installation methods provide.

Each product then signs in once per machine, through the benchmark:

```sh
mise run execute login cursor
mise run execute login codex
mise run execute login claude
mise run execute login antigravity
```

`login` runs the product's own sign-in inside a benchmark-owned profile, using the same environment variables as a trial.
[Isolation](#isolation) covers profile locations, the working directories `login` uses, and the limits of the controls.

Sign in only to the products you intend to measure; one can be prepared without the others. Nothing in `Resources/benchmark.json` changes.

Do not run `mise run execute login <product>` while a benchmark is running. Login updates the same profile that active trials read,
so wait for the run to finish or stop it before signing in again to avoid invalidating its credentials.
Interactive login holds the per-user profile lock at `$XDG_DATA_HOME/benchmark/.benchmark.lock` (or its `$HOME/.local/share` default)
and fails if a run or `doctor` that includes a reference target already owns it, even from another checkout or worktree.

The sign-in opens the product's usual browser flow. Antigravity has no dedicated login subcommand, so `login antigravity`
starts `agy` interactively — complete the prompt and quit the CLI.
While a product CLI runs, `Ctrl-C` and `Ctrl-\` reach only that CLI; the benchmark waits for it to exit and then checks the result.
A nonzero exit fails the login, except for Antigravity, whose authentication is then verified with `agy models`.
SIGTERM or SIGHUP sent to the benchmark itself is forwarded to the CLI as SIGTERM, and the login then exits with status 130.
If a CLI does not exit on Ctrl-C, stop its process from another terminal.

Your ordinary `~/.cursor`, `~/.codex`, and `~/.claude` profiles keep separate login state,
so signing the benchmark in or out does not sign your ordinary profile in or out.
Antigravity is the exception: `agy` keeps its sign-in in the login keychain (service `gemini`, account `antigravity`), which `HOME` does not move,
so the benchmark and your ordinary `agy` share one sign-in.
Each profile draws on the same subscription, so a benchmark run consumes the same allowance your ordinary account has.

Check what is prepared at any time:

```sh
mise run execute login --status
```

Each `login --status` check waits up to 60 seconds for the status process; preflight checks use the configured `request_timeout_seconds` instead.
Cleanup can add up to 30 seconds while waiting for the terminated process.

```text
profiles: /Users/you/.local/share/benchmark/profiles
  cursor       cursor-agent   authenticated
  codex        codex          not authenticated
  claude       claude         authenticated
  antigravity  agy            no benchmark profile prepared under the current isolation policy; run `mise run execute login antigravity`

Sign in with: mise run execute login <product>
```

`doctor` reports the same state per target and skips any target whose profile is missing or logged out, naming the `login`
command to run. Once a profile is authenticated, take a [targeted smoke run](#reference-agent-preflight) to check
the model ID and the event stream. The models to prepare are listed in [Reference targets](#reference-targets).

Sign in again when a subscription's session expires;
the benchmark profile expires on the product's own schedule, independently of your ordinary login (except Antigravity's shared keychain sign-in).

### Verifying

```sh
brew --version
mise --version
swift --version
ollama --version
cursor-agent --version
codex --version
claude --version
agy --version
```

`ollama --version` can warn when no server is running, which is expected; `doctor` starts one when a local target needs it.

Then build the CLI and let it check the configuration and the endpoints.

```sh
mise run build
mise run execute doctor
```

`doctor` matches the Mac's chip and installed memory to a host definition and checks every configured target.
Unavailable or incomplete targets appear as `SKIP`, with the reason. It returns status 1 if an eligible target is not ready;
`run` still measures the ready targets and records the others as skipped. No manual activation is needed.
[Configuration](#configuration) describes every key.

`mise run markdownlint` lints the Markdown files tracked by Git with markdownlint-cli2 in Docker.
CI runs the Swift checks in the `check` and `minimum-os` jobs on macOS and Markdown linting in a separate `markdown` job on Ubuntu,
where `docker/setup-docker-action` provides Docker.
To update the image by hand, change its tag and digest in `.mise.toml`.
Use the image index digest so both ARM64 and AMD64 select their matching image.
Dependabot updates GitHub Actions only, because the package has no Swift dependencies.
`.github/workflows/sync.yml` opens a weekly pull request that updates the image tag and digest in `.mise.toml` and the mise version in
`.github/mise-version`, because Dependabot does not read them; the Swift toolchain pinned in `.mise.toml` is reviewed manually.
The sync workflow dispatches the `check` workflow on its branch, because pull requests opened with `GITHUB_TOKEN` start no workflows.
When its open pull request already carries the same values, the sync workflow skips the push
and dispatches the checks again only if no uncancelled run exists for that commit.
Every CI job reads its mise version from `.github/mise-version`, since `GITHUB_TOKEN` cannot push changes under `.github/workflows/`.
Opening the pull request requires the repository setting "Allow GitHub Actions to create and approve pull requests".

### Keeping the machines aligned

Results are only comparable when both machines run the same versions, so upgrade them together rather than one at a time.

```sh
brew update
brew upgrade
```

Note the Ollama version and the four CLI versions on the day of a run. The manifest records the backend version for every target,
and the CLIs update without notice, which is exactly why the versions are worth writing down.

After upgrading Ollama or a reference CLI, run `mise run verify`, then `mise run execute doctor --smoke` on each benchmark machine.
The smoke check generates an answer for each prepared reference product and consumes subscription allowance.
Also run the [targeted smoke procedure](#reference-agent-preflight) for the models and effort settings being measured;
fixture tests alone cannot verify an installed CLI's current arguments and event format.

## Configuration

[`Resources/benchmark.json`](Resources/benchmark.json) selects the machines, targets, and run conditions;
[`Sources/Benchmark/Targets.swift`](Sources/Benchmark/Targets.swift) owns the model definitions, and [`Resources/suites/`](Resources/suites/) holds the questions.
Each manifest records the configuration and suite SHA-256, the implementation revision, and the effective target definitions.

### Benchmark configuration

The CLI always reads `Resources/benchmark.json` in the source checkout used to build it, regardless of the current working directory.
The path cannot be overridden, and a symlink resolving outside that root is rejected. Rebuild the CLI after moving the source checkout.
The file uses strict JSON; explanatory comments belong in this README.

| Object key  | Purpose                                                                                                    |
| ----------- | ---------------------------------------------------------------------------------------------------------- |
| `run`       | Repeats, timeout, cooldown, output ceiling, temperature, seed, cache conditions, system prompt             |
| `report`    | Language of the Markdown report                                                                            |
| `selection` | Thresholds a local model must clear to be recommended                                                      |
| `hosts`     | The machines, each with the chip and installed memory that `doctor` verifies against                       |
| `targets`   | Target IDs to measure and the hosts allowed to run them                                                    |

`run.seed` is required. Other `run` values have defaults; `--repeat` overrides the repetition count for a single run.
At least one `hosts` entry and one `targets` entry are required; `doctor` and `run` reject an empty target list before starting work.
Unknown keys are rejected everywhere, so a typo fails the run rather than being silently ignored.

| Key                       | Default when omitted  |
| ------------------------- | --------------------- |
| `repeat`                  | `5`                   |
| `request_timeout_seconds` | `300`                 |
| `cooldown_seconds`        | `3`                   |
| `max_output_tokens`       | `2048`                |
| `temperature`             | `0.7`                 |
| `seed`                    | Required; no default  |
| `cache_conditions`        | `["cold", "warm"]`    |
| `system_prompt`           | `""` (empty string)   |

`run.cache_conditions` accepts `cold` and/or `warm`. Removing `warm` is valid, but it disables automatic local-target selection because
the recommendation criteria are defined for warm-condition measurements.

Tasks are always loaded from every `*.jsonl` file directly in `Resources/suites/` in the source checkout.
Results are always saved under `Deliverables/Runs/` in that root, regardless of the current working directory.
These directories cannot be configured; specifying `run.suite`, `run.suites_dir`, or `run.results_dir` is an error.
Connectivity checks and production measurements use the same tasks: use `--repeat 1` for a quick check and `--repeat 5` or more for measurements.
A run supports at most 1,000,000 scheduled trials, counting every selected target's tasks, repeats, and cache conditions, including skipped targets.
Larger schedules and trial-count overflow are rejected before allocation or server startup, including with `--dry-run`.

To catch configuration mistakes before measurement, this benchmark accepts finite `run.temperature` values from `0` through `2` (inclusive).

Set `run.seed` to an integer from `0` through `9223372036854775807`; the bundled configuration uses `42`.
Omitting the value or the entire `run` object stops configuration loading with `run.seed is required`.
The configured value is saved as `run_settings.seed` in `manifest.json`. Use the same seed on both machines;
`report` rejects combining runs with different seeds.
To reproduce a run's trial order, keep the seed, implementation, target order, suite, repeats, and cache conditions the same.
Ollama uses the one-based repetition number as its generation seed (`repeat-v1`), independently of the trial-order seed.
The manifest records `generation_seed_algorithm`; each local trial and raw provider-metrics record stores `generation_seed`.
Matching repetitions use the same generation seed across tasks, targets, cache conditions, and machines. Reference-agent trials record `null`.
The default temperature is 0.7 so repetitions can sample different answers. Setting it to zero makes generation effectively deterministic even with
different seeds.
Neither mode guarantees identical responses across GPU executions.

For CLI targets, `request_timeout_seconds` bounds each version check, status check, and trial process separately. The bundled 300-second default
leaves additional headroom for the maximum-effort reference targets; review timeout failures before comparing their pass rates.
For Ollama HTTP requests, the same value bounds both total request time and time without receiving data, so a continuously streaming response
cannot extend a request beyond the configured deadline.
`max_output_tokens`, `temperature`, and `seed` are not forwarded to the CLI; the seed still controls the trial order.
A non-empty `system_prompt` is prepended to the CLI task prompt, separated by a blank line.
CLI targets always use `provider-managed` cache conditions, regardless of `run.cache_conditions`.
`run_settings.workdir`, the implementation repository root, is recorded as `.` in the manifest and is not a configurable JSON key.
CLI preflight checks and trials run in fresh empty directories outside the operator's home
([isolation](#isolation)).

#### Report language

```json
{
  "report": {
    "language": "ja"
  }
}
```

`language` accepts `ja` (Japanese) or `en` (English). The bundled configuration explicitly selects Japanese;
omitting `report` or `language` also defaults to Japanese. Unsupported values and misspelled keys are rejected.
The setting controls the title, headings, table labels, recommendations, and explanatory text in `report.md`.
CSV column names, JSON fields, model and target IDs, and recorded values keep their existing format.

Each run saves the setting as `report_settings.language` in `manifest.json`. The `report` command uses the first input run's
saved language. Manifests must declare a supported language; runs with different report languages can be combined.
Changing `report.language` affects subsequent runs; regenerating an existing run preserves its saved language.
Selection thresholds and measurement settings also come from the saved runs.

#### Hosts

`doctor` and `run` select one `hosts` entry by matching the detected chip and installed physical memory.
The chip name must match exactly, memory may differ by at most 1 GiB, both values must be detected, and exactly one entry must match.

```json
{
  "hosts": [
    {
      "id": "mac-studio-m2-max-96gb",
      "chip": "Apple M2 Max",
      "memory_gib": 96
    }
  ]
}
```

Run the benchmark code on each machine being measured. Its Ollama server and the reference CLI processes run on that same machine.
The selected `id` is recorded in results and checked against each target's `eligible_hosts`.
When nothing matches, update `chip` and `memory_gib` or add an entry; when several match, make the definitions unambiguous before running.

#### Targets

Model settings belong to [`Sources/Benchmark/Targets.swift`](Sources/Benchmark/Targets.swift). Each definition fixes the model ID, inference location, adapter,
loopback endpoint, backend, quantization, context length, memory process matcher, and CLI invocation including reasoning effort.
Changing a model or adding a candidate is a source change. JSON does not supply or validate these values.
Use a separate target for each model, quantization, context length, or effort combination.

A `targets` entry accepts only these two keys:

| Key              | Meaning                                                           |
| ---------------- | ----------------------------------------------------------------- |
| `id`             | Target ID defined in `Sources/Benchmark/Targets.swift`            |
| `eligible_hosts` | Host IDs allowed to measure it; omitted or empty means every host |

```json
{
  "targets": [
    {
      "id": "claude-sonnet-5-max",
      "eligible_hosts": ["mac-studio-m2-max-96gb", "macbook-pro-m1-pro-16gb"]
    }
  ]
}
```

Other target keys are rejected by the same unknown-key check used for the rest of the configuration.
Unknown target IDs, duplicate IDs, and unknown eligible hosts are also rejected. Keep target IDs fixed for the whole comparison.
Ollama definitions must use a loopback endpoint and `inferenceLocation: "local"` (recorded as `inference_location`).
CLI definitions use `inferenceLocation: "remote"` to describe provider-side inference, while the CLI itself runs on the measured Mac.
CLI definitions have no HTTP endpoint. These rules are checked when the configuration is loaded.

Every listed target is considered automatically. Use `run --target <id>` to select a subset for one run.
Missing models or CLI executables, unreachable endpoints, and unsigned or logged-out benchmark profiles produce `skipped` trials
with `failure_reason = "preflight_failed"`; ready targets continue. A run with no ready targets still writes a report and exits successfully.
Details are saved in `raw/preflight.json`.

##### Ollama

Local definitions fix Ollama's endpoint at `http://127.0.0.1:11434`, context length at 8192, backend at `ollama`, and the process matcher at `llama`.
`localModelDefinitions` in `Sources/Benchmark/Targets.swift` pins each candidate's target ID, model tag, and quantization together.
The candidate families are Gemma 4, GPT-OSS Swallow, and Ornith 1.5. The bundled configuration selects these sizes:

| Target ID                     | Exact Ollama model tag                      | Quantization | Eligible machines |
| ----------------------------- | ------------------------------------------- | ------------ | ----------------- |
| `ollama-gemma4-e2b`           | `gemma4:e2b-it-q4_K_M`                      | Q4_K_M       | 16 GB and 96 GB   |
| `ollama-gemma4-e4b`           | `gemma4:e4b-it-q4_K_M`                      | Q4_K_M       | 16 GB and 96 GB   |
| `ollama-gemma4-12b`           | `gemma4:12b-it-q4_K_M`                      | Q4_K_M       | 16 GB and 96 GB   |
| `ollama-gemma4-26b`           | `gemma4:26b-a4b-it-q4_K_M`                  | Q4_K_M       | 96 GB             |
| `ollama-gemma4-31b`           | `gemma4:31b-it-q4_K_M`                      | Q4_K_M       | 96 GB             |
| `ollama-gpt-oss-swallow-20b`  | `gpt-oss-swallow:20b-rl-v0.1-mxfp4`         | MXFP4_MOE    | 16 GB and 96 GB   |
| `ollama-gpt-oss-swallow-120b` | `gpt-oss-swallow:120b-rl-v0.1-mxfp4`        | MXFP4_MOE    | 96 GB             |
| `ollama-ornith-1.5-9b`        | `ornith-1.5:9b`                             | Q4_K_M       | 16 GB and 96 GB   |
| `ollama-ornith-1.5-35b`       | `ornith-1.5:35b`                            | Q4_K_M       | 96 GB             |

Gemma 4 and Ornith 1.5 tags were checked against the [Gemma 4 catalog](https://ollama.com/library/gemma4/tags)
and [Ornith 1.5 catalog](https://ollama.com/library/ornith-1.5/tags) on 2026-09-10.
The [Swallow 20B GGUF package](https://huggingface.co/mradermacher/GPT-OSS-Swallow-20B-RL-v0.1-GGUF)
and [Swallow 120B GGUF package](https://huggingface.co/mradermacher/GPT-OSS-Swallow-120B-RL-v0.1-GGUF) were checked on 2026-09-12.
Both use mradermacher's GGUF conversions of the corresponding `tokyotech-llm/GPT-OSS-Swallow-{20B,120B}-RL-v0.1` models with MXFP4_MOE quantization.
Their Modelfiles are generated by the same [Swift function](Sources/Benchmark/Targets.swift), with identical single-turn Harmony templates,
medium reasoning, and an answer-ending stop token (`<|return|>`). Both use `ollama create` to install a local tag; inference runs locally in Ollama.

Install the exact tag with `ollama pull <model-tag>` before measuring it, except the Swallow targets, which require `ollama create`;
see [Ollama setup](#installing-ollama) for both procedures.
An absent tag is skipped during preflight without downloading a replacement. Select target IDs in `Resources/benchmark.json` for the regular matrix,
or repeat `run --target <id>` to select a subset for one run.
Eligibility is a measurement plan, not a claim that a model meets the memory thresholds: Swallow 20B is a borderline candidate on 16 GB.
Ollama's detected quantization from `/api/ps` takes precedence over the source-defined value in reports.

The adapter controls loading for both cold and warm conditions. The benchmark starts and stops a server at its fixed loopback endpoint
when needed; an existing server is reused and left running. See [local inference servers](#local-inference-servers).

##### Reference agent

The benchmark defines the executable, arguments, prompt delivery, event schema, model, and effort for every reference target.
The same product definition supplies the executable used for login and measurement.
Operators only sign a product's benchmark profile in with `mise run execute login <product>`; for example,
`mise run execute login claude` prepares every configured Claude target.

Each trial process starts directly without a shell in a fresh empty directory. The bundled definitions deliver the run's system prompt, when non-empty,
followed by a blank line and the task prompt on stdin, then close stdin. The adapter expands `{model}` in the source-owned argument template
using the fixed model ID; it preserves both prompt texts verbatim.
Each non-empty stdout line must be a JSON object in the product's event format; text, usage, and reported model metadata are accumulated.
The [measurement definitions](#metric-availability) explain how missing deltas and usage affect the results.

Preflight uses the same profile, environment, and fresh-directory policy as generation, in this order:

1.  Run the product's executable with `--version` and require a successful exit. Record the first non-empty output line as the backend version.
2.  Require the product's benchmark profile to have been signed in with `mise run execute login`.
3.  Run the product's authentication check and require a successful exit and, where reported, an authenticated flag in its JSON output.

A failed check skips the target. Preflight does not independently confirm the requested model's availability;
a smoke run exercises generation. Successful preflight records the requested model ID, and generation records the reported ID as `model_resolved`.
The controls each product is isolated by are listed under [isolation](#isolation),
and the fixed command lines under [invocation](#invocation).

Each model/effort pair is a separate target. Effort is fixed in the model ID, CLI arguments, or both.
The [reference matrix](#reference-targets) lists the configured combinations.
The manifest saves the complete source-defined target, including `command`, `args`, `prompt_delivery`, and `event_schema`,
along with the isolation policy version, product, a `profile_root` field that is always `null`, variable names, and authentication-check arguments.
[`Resources/schemas/manifest.schema.json`](Resources/schemas/manifest.schema.json) defines its shape.
`{model}` remains in the saved argument template, with the selected model stored separately; recognized secret-bearing arguments are redacted.
Target fingerprints include the effective model and invocation, detected backend version, and isolation policy version,
so different measurement conditions do not merge silently. Environment values and profile contents are not recorded or fingerprinted.
Fingerprints use the actual arguments before redaction. If any argument was redacted, the fingerprint cannot be recomputed from the manifest alone.

#### Selection thresholds

```json
{
  "selection": {
    "minimum_pass_rate": 0.80,
    "minimum_median_tokens_per_second": 10.0,
    "maximum_peak_swap_delta_gib": 1.0,
    "maximum_backend_memory_fraction": 0.70
  }
}
```

All four apply to warm local targets only; reference agents are never candidates, since three of the four figures do not exist for them.
Automatic recommendations require `warm` in `run.cache_conditions`. A cold-only run is valid for diagnostics but produces no recommendation.
The rules themselves are in [Selection rules](#selection-rules).

#### Credentials

The Ollama endpoint is fixed at `http://127.0.0.1:11434` in [`Sources/Benchmark/Targets.swift`](Sources/Benchmark/Targets.swift); JSON cannot override it.
A source change to it is validated at load: it must be an HTTP or HTTPS URL with a loopback IP literal (`127.0.0.0/8` or `[::1]`;
hostnames, including `localhost`, are rejected), an explicit port, and the root path with no query, fragment, or authentication information.
Automatic server startup requires plain HTTP; a local HTTPS server must already be running.
The HTTP client also checks each request and redirect destination and bypasses proxy settings.
Streaming responses must declare `application/x-ndjson` or `application/json`, as Ollama does; other content types are rejected to avoid buffered
TTFT measurements.

Reference agents authenticate through their own CLI into the benchmark profile that `mise run execute login <product>` prepares.
Credentials stay inside that profile, which is created with owner-only permissions, and never reach `Resources/benchmark.json`.
Profile locations follow `XDG_DATA_HOME`, with a default outside the repository; see [isolation](#isolation).
Keep secrets out of `args` and CLI version/status output; argument redaction does not sanitize arbitrary events.
Each trial draws on that subscription's usage allowance, and hitting a limit is recorded as a failed trial rather than hidden.

### Task suites

A task carries its own prompt, its own scorer, and its own pass threshold, so adding a question never touches Swift code.
The model receives the task text and the run's instructions; scorer definitions are never sent to the model.

| File                                                                                           | Category                | Tasks |
| ---------------------------------------------------------------------------------------------- | ----------------------- | ----- |
| [`Resources/suites/code.jsonl`](Resources/suites/code.jsonl)                                   | `code`                  | 9     |
| [`Resources/suites/instruction-following.jsonl`](Resources/suites/instruction-following.jsonl) | `instruction-following` | 9     |
| [`Resources/suites/japanese.jsonl`](Resources/suites/japanese.jsonl)                           | `japanese`              | 9     |
| [`Resources/suites/reasoning.jsonl`](Resources/suites/reasoning.jsonl)                         | `reasoning`             | 9     |
| [`Resources/suites/retrieval.jsonl`](Resources/suites/retrieval.jsonl)                         | `retrieval`             | 9     |
| [`Resources/suites/structured-output.jsonl`](Resources/suites/structured-output.jsonl)         | `structured-output`     | 9     |

Each of the six categories has nine tasks, giving them equal weight in a complete run.
Every run loads all 54 tasks. Files are read in filename order, with tasks kept in line order before the seeded trial shuffle.
Only regular `*.jsonl` files directly in `Resources/suites/` are loaded; other files, symlinks, and subdirectories are ignored.
New category files are included automatically. Blank lines and lines beginning with `#` are ignored when parsing tasks.
Task IDs must be unique across all files; invalid files, duplicate IDs, or a directory with no tasks stop the command.
The manifest records `suite.path` as `Resources/suites` and a combined SHA-256 of every loaded filename and its complete contents,
including comments and blank lines. The digest uses filename order and 64-bit big-endian byte-length prefixes before each filename and payload.
It is independent of the checkout's absolute path and changes when a file is added, removed, renamed, or edited.

Each file holds one JSON object per line. The bundled suite is written mostly in Japanese and asks the model to reason, to follow an output format exactly,
to read code, to emit valid JSON, and to find facts in a supplied passage.

```json
{
  "id": "example-001",
  "category": "reasoning",
  "prompt": "回答だけを書いてください。2 + 3 = ?",
  "scorer": {
    "type": "exact",
    "expected": "5"
  },
  "pass_threshold": 1.0
}
```

| Field            | Requirement | Default | Meaning                                                    |
| ---------------- | ----------- | ------- | ---------------------------------------------------------- |
| `id`             | Required    | —       | Unique across all files, matching `^[a-z0-9][a-z0-9._-]*$` |
| `category`       | Required    | —       | Groups rows in `category-summary.csv`                      |
| `prompt`         | Required    | —       | Task text; combined with the run's system prompt           |
| `scorer`         | Required    | —       | Rule and its options, never sent to the model              |
| `pass_threshold` | Optional    | `1.0`   | Score at or above which the trial counts as passed         |

`category` must contain at least one non-whitespace character; its spelling is preserved.

`pass_threshold` must be between `0.0` and `1.0`, inclusive. Omitting it requires a full score to pass,
including matching every expected string for `contains_all`; set a lower threshold to allow partial credit to pass.
For `contains_all`, expected strings must be unique under the selected case-sensitivity rule; the loader rejects duplicates,
including Unicode case-folding equivalents when `case_sensitive` is false.
The loader also rejects tasks that could never pass: an empty `contains_all` string, or an `exact` string that is blank after trimming.
The bundled `japanese-002` through `japanese-009` and `retrieval-003` tasks award a quarter point per required fact and pass at 0.75.
This lets mean score distinguish answers covering three facts from answers covering all four, even when both pass.
These coverage checks reward the specified facts; they do not evaluate prose quality or penalize extra claims unless the character limit is exceeded.
An expected string that starts or ends with a decimal digit does not match inside a longer number, so `3時` is found in neither `13時` nor `0.3時`;
other numeric characters such as kanji numerals do not count as digits. Only an ASCII `.` joins two numbers this way,
so `300円` is still found in `1,300円` and `3時` in `1．3時`. Matching is otherwise plain substring search, so `3時` is also found in `3時間`.

#### Scorers

| Type           | Behaviour                                                                                                                        |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `exact`        | Compares the trimmed response with `expected`, or with any entry when `expected` is a list of acceptable answers                 |
| `contains_all` | Scores the fraction of the strings in `expected` that appear in the response, so it is the one scorer that awards partial credit |
| `regex`        | Matches `pattern` against the trimmed response                                                                                   |
| `json_exact`   | Parses the response as JSON and compares it structurally with `expected`                                                         |

| Option                 | Applies to                       | Effect                                                             |
| ---------------------- | -------------------------------- | ------------------------------------------------------------------ |
| `case_sensitive`       | `exact`, `contains_all`, `regex` | Defaults to true; when false, comparison uses Unicode case folding |
| `normalize_whitespace` | `exact`                          | Collapses runs of whitespace before comparing                      |
| `allow_code_fence`     | `json_exact`                     | Strips a surrounding code fence before parsing                     |
| `max_chars`            | `contains_all`                   | Scores zero when the trimmed response exceeds this limit           |

The `exact` scorer renders non-string expected values as JSON text, so numeric formatting is significant:
`1` matches `1`, while `1.0` matches `1.0`. Numbers with a fraction or exponent are rendered in their shortest
round-trip form rather than as written: `1.50` expects `1.5`, `1e3` expects `1000.0`, and `-0` expects `-0.0`.
Write the expected value as a string to keep its exact spelling, or use `json_exact` when numeric equivalence
should ignore formatting.
`structured-009` accepts a surrounding code fence while checking the JSON's contents; the other bundled JSON tasks require bare JSON.
`instruction-004` compares the number sequence after whitespace normalization.
`instruction-008` explicitly requests one item per line and retains exact line-break checks.

`max_chars` counts Unicode code points after trimming surrounding whitespace, without Unicode normalization.
Combining marks and variation selectors count separately: `が` counts as one, while `か` followed by a combining dakuten counts as two.
An emoji sequence such as `👩‍💻` counts as three, so the limit can differ from the number of visible characters.
Account for this when writing prompts and choosing limits for new tasks.

Patterns use Foundation `NSRegularExpression` (ICU syntax). Evaluation is limited to one second per answer; exceeding the limit records a scoring error.
Case-insensitive regular expressions use ICU case folding, including multi-character equivalents such as `straße` and `STRASSE`.
Anchor a pattern when the answer has to stand alone: an unanchored pattern also matches a model that buried the answer in a paragraph of commentary.

#### Writing a task

Keep the expected answer short and mechanically checkable, and say so in the prompt — output length cannot be enforced on the reference agents,
so any length limit has to come from the prompt itself.

Categories should stay stable once results exist, because renaming one splits its history across two rows in the category summary.

Validate all category files before measuring:

```sh
mise run execute doctor
```

## Running the benchmark

Commands, the order to measure two machines in, and what a run leaves behind.
Installation is in [Setting up a machine](#setting-up-a-machine), the definitions behind these numbers in [Methodology](#methodology),
and the settings in [Configuration](#configuration).

### Commands

Every command runs through mise, which builds the CLI in release mode and passes arguments through.

| Command     | Purpose                                                  | Options                                                     |
| ----------- | -------------------------------------------------------- | ----------------------------------------------------------- |
| `doctor`    | Checks configuration, host identity, endpoints, and CLIs | `--smoke`                                                   |
| `run`       | Executes trials and writes a run directory               | `--target` (repeatable), `--repeat`, `--dry-run`            |
| `login`     | Signs a reference agent CLI in to its benchmark profile  | `--status`                                                  |
| `report`    | Combines one or more recorded runs                       | Run directories (positional, one or more)                   |
| `modelfile` | Prints a custom Ollama Modelfile to standard output      | Target ID (positional)                                      |

```sh
mise run execute doctor
mise run execute run
mise run execute report Deliverables/Runs/<run-id>
```

The benchmark CLI uses these exit statuses:

| Status | Meaning                                                                                |
| ------ | -------------------------------------------------------------------------------------- |
| `0`    | Successful command, including explicit `--help`                                        |
| `1`    | Command error, including `doctor` finding an unready eligible target                   |
| `2`    | Invalid CLI arguments, or no subcommand supplied (prints help)                         |
| `130`  | Interruption handled by `doctor`, `run`, or `login` through Ctrl-C, SIGTERM, or SIGHUP |

`doctor` and `run` detect the Mac's chip and installed memory and select a matching `hosts` entry; if detection fails or the match is missing or ambiguous,
the command stops with an error. See [host configuration](#hosts).

`--dry-run` prints the schedule without sending a request, which is the cheapest way to confirm that a configuration change did what you expected.
Its `scheduled trials: N (M eligible)` line shows the total including skipped targets and the trials allowed by this host's eligibility rules.
Both counts include the selected targets' tasks, repeats, and cache conditions; backend readiness is checked during preflight when executing the run.

`report` resolves all run paths before reading them. It writes into the run's own directory when given one run,
and into `Deliverables/Comparisons/` in the source checkout used to build the CLI when given several.
It holds each distinct parent results-directory lock while reading inputs and writing reports, and fails if any is held by another command.
Combined reports also lock their output directory so concurrent reports cannot overwrite one another.
Report language comes from `report.language` in `Resources/benchmark.json` and is saved with each run. Regeneration uses the first input run's saved language.
See [report language](#report-language).

During development:

```sh
mise run format        # format Swift sources and tests with swift format format
mise run lint          # check Swift formatting with swift format lint
mise run check         # compile sources with warnings as errors
mise run test          # compile and run Swift tests with warnings as errors
mise run verify        # show the toolchain, then compile, lint, and test Swift code
mise run build         # release build
mise run clean         # remove Swift build products
mise run execute -- --help # show Benchmark CLI help
```

All task setup and commands are defined in [`.mise.toml`](.mise.toml).
`mise run format` applies `swift format format --in-place` to `Package.swift`, `Sources/`, and `Tests/`.
`mise run lint` checks the same files with `swift format lint --strict` without changing them.
Both commands use [`.swift-format`](.swift-format), with a 100-column line length and two-space indentation.
`mise run verify` shows the toolchain, then runs compilation, Swift format linting, and tests without changing source files.
The Swift package and library are named `Benchmark`, and its executable is `benchmark`.
Project inputs live in `Resources/`: `benchmark.json`, `schemas/`, and `suites/`.
Generated runs and comparisons remain in the checkout's `Deliverables/Runs/` and `Deliverables/Comparisons/` directories.

This package has no external Swift dependencies; keep `Package.swift` and the source checkout revision fixed for the runs that follow.
The Swift test suite covers the CLI, isolated agent processes, streamed loopback HTTP, Ollama lifecycle, scoring, and report recovery.

### Preparing a machine

Confirm that both machines use the same implementation revision, suite hash, and required `run.seed`,
and update macOS or an inference backend on both at once.
Note the starting swap figure on the 16 GB machine.

Install the local models in Ollama beforehand; startup does not download them. See [Installing Ollama](#installing-ollama).

For reference agents, note the installed CLI versions, which the manifest records,
and check the remaining subscription allowance and when it resets on the day of measurement.
Sign each product's benchmark profile in once with `mise run execute login <product>`; [Reference agent CLIs](#reference-agent-clis) covers it.
`mise run execute login --status` reports which profiles are ready. Products you have not signed in are skipped automatically,
so there is nothing to disable; `run --target` still limits a run to the targets you want.

Use the model definitions fixed in `Sources/Benchmark/Targets.swift` for every measurement in the comparison. If a fixed model is unavailable,
record a preflight failure or failed trial for that target; do not substitute another model.
Unready targets are skipped as described under [targets](#targets).

#### Selecting local candidates

Choose one or more sizes from Gemma 4, GPT-OSS Swallow, and Ornith 1.5 using the IDs in the [local model catalog](#ollama).
For example, compare a candidate from each family:

```sh
mise run execute run --target ollama-gemma4-e2b --target ollama-gpt-oss-swallow-20b --target ollama-ornith-1.5-9b --dry-run
mise run execute run --target ollama-gemma4-e2b --target ollama-gpt-oss-swallow-20b --target ollama-ornith-1.5-9b
```

The same `--target` option selects a larger candidate, such as `ollama-gemma4-26b`, on the 96 GB Mac.
Host eligibility still applies when selecting a target explicitly; a model reserved for the 96 GB Mac is skipped on the 16 GB Mac.

#### Reference agent preflight

For each CLI target, preflight runs the [version and authentication checks](#reference-agent) under a trial's [isolation](#isolation).
Ordinary preflight does not prove that the selected model or event format works.

Before a long measurement, run `mise run execute doctor --smoke`. After successful preflight it generates the first task from the category files in filename order
with the first ready target for each reference product and executable, using the actual generation arguments and event parser.
This consumes subscription allowance, prints the tested target and task, and returns status 1 if generation fails.
It does not write benchmark trials or score the answer. Other models and effort settings still need their own targeted smoke runs.

After signing a product in, select one of its targets for a smoke run:

```sh
mise run execute run --target claude-sonnet-5-max --repeat 1 --dry-run
mise run execute run --target claude-sonnet-5-max --repeat 1
```

The dry run validates the configuration and prints the schedule without spawning an agent CLI. The real run uses `provider-managed` cache conditions
and exercises the configured model, JSON event parsing, and scoring. Repeat `--target` to measure several prepared targets.
`doctor` has no `--target` option and checks every target listed in the repository's `Resources/benchmark.json`.

Read `raw/preflight.json` for skipped-target details and `raw/<trial-id>.json` for generation failures.
A missing CLI, an unsigned benchmark profile, a logged-out profile, or an unsuccessful version check produces `preflight_failed`;
for an unsigned or logged-out profile the message names the `login` command to run.
A trial timeout produces `timeout`; CLI errors, invalid JSON output, and a stream with no recognized answer event normally produce `request_error`.
The runner does not retry failed CLI trials. [Methodology](#failure-classification) defines the recorded failure reasons.

Timeout and interruption through Ctrl-C, SIGTERM, or SIGHUP terminate the process and its process group on Unix.
Trial records already written are preserved, and the trial's working directory is removed. Authentication in the benchmark profile persists
between runs by design; `raw/preflight.json` records the isolation applied, never its values.

#### Local inference servers

`doctor` and `run` check the source-defined local Ollama endpoint and start `ollama serve` when nothing is listening, waiting up to 30 seconds
for the version API to become ready before checking the installed models. Targets sharing one endpoint share one server,
and only targets eligible for this host can start a server. `run --dry-run` starts nothing and does not probe availability.

Automatic startup sets `OLLAMA_HOST` to that endpoint and removes every other inherited `OLLAMA_*` variable,
so server settings use the recorded Ollama version's defaults. This includes `OLLAMA_MODELS`: install models in Ollama's default location.
The manifest's `run_settings.ollama_server_environment` records the overrides per endpoint.
`null` means no startup environment was recorded: an existing server was reused, automatic startup was skipped for HTTPS, or automatic startup failed.
Check each target's `doctor` result for availability and startup failures; failed targets are recorded as `preflight_failed`.
For comparable runs, let the benchmark start the server or verify the existing server's settings on each machine.

Owned-server stderr is saved to private `raw/ollama-*.log` files in the run directory.
For `doctor`, startup logs are created in a private system-temporary subdirectory and removed when the command finishes.
The command prints the log path when starting a server; run logs remain available after startup failures.

An existing server is reused and left running. A server the command started is stopped when it finishes, including on errors or interruption
with Ctrl-C, SIGTERM, or SIGHUP. `doctor` and `report` also hold the relevant results-directory locks so they cannot overlap a run there.
If a server fails to start or respond, its targets are recorded as `preflight_failed` and skipped; the other targets continue.

### Order of measurement

Run the same sequence on each machine.

1.  Confirm that the chip and memory `doctor` detects match the host definition, and that `login --status` shows every product you plan to measure.
2.  Run `doctor --smoke` to check generation for each prepared reference product, then take one smoke run with a small local model.
3.  Measure every task at least five times per candidate.
4.  On the 16 GB machine, drop candidates that miss the swap-growth or response-speed bar.
5.  On the 96 GB machine, add the larger candidates eligible only there: Gemma 4 26B and 31B, Swallow 120B, and Ornith 1.5 35B.
6.  Measure the same reference agent from both machines, so that network and time-of-day differences become visible.
7.  Merge the runs and review the recommendation for each machine.

```sh
mise run execute doctor --smoke
mise run execute run --target ollama-gemma4-e2b --repeat 1
mise run execute run --repeat 5
```

The smoke run exists to prove that authentication, the model ID, scoring, and memory collection all work before a long run starts.
For each Swallow target, inspect the first run's `raw/<trial-id>.json`: `response` should contain only the final answer,
while `events` retain any reasoning and channel markers. Check `finish_reason` in `trials.jsonl` for `length` before increasing repetitions.
Use `--target ollama-gpt-oss-swallow-20b --repeat 1` (or the 120B target).
Do not delete a run that hit a rate limit or a backend crash; the failure reason is part of the result.
If the run failed or was interrupted, generate a report from its recorded trials with `mise run execute report Deliverables/Runs/<run-id>` after it stops.
This also works after a forced termination or power loss leaves the manifest's status as `running`.
The report shows the saved status and missing trials, preserves the inputs, and excludes that run's targets from automatic selection.
A run taken with a misconfiguration is re-taken as a new run instead of being edited.

Alternate the time of day for agent runs, since subscription allowances recover on their own schedule.

Plan for 54 tasks × 5 repeats × 2 cache conditions = 540 trials per eligible local target,
or 4,860 local trials when all nine candidates are available. Reference-agent trials add to this total.
Each successful local trial loads the model again, including warm trials, so the 120B candidate alone requires 540 full loads.
For illustration, an average 30-second load, 15 seconds for the rest of the request, and the configured 3-second cooldown
would take about 7.2 hours per candidate, before unloading, preflight, and other overhead. These timings are planning assumptions, not measurements.
Estimate each candidate on each machine from the whole elapsed time of its `--repeat 1` run with both cache conditions, multiplied by about five.
Include preparation and cleanup in that estimate: reported warm wall time excludes the preload and does not describe total run duration.

### Output

Each trial records UTC `started_at` (before preparation) and `completed_at` (after cleanup),
including failed and skipped trials.

Every run produces one directory under `Deliverables/Runs/` in the implementation repository root.
The `Deliverables/Runs/.benchmark.lock` lock is shared by runs in that repository.
Runs and `doctor` that include a reference target also hold the per-user profile lock,
which `login` takes too, so a sign-in from any checkout cannot rewrite a profile that is in use.
Runs and `doctor` also hold a per-user lock for each Ollama endpoint port in `$TMPDIR/benchmark-endpoint-locks-<uid>/`,
so a run from another checkout cannot reuse, unload models on, or stop the server being measured.

```text
Deliverables/Runs/
├── .benchmark.lock       # persistent file; held during run, doctor, or report
└── <run-id>/
    ├── manifest.json
    ├── trials.jsonl
    ├── raw/
    │   ├── preflight.json
    │   ├── cleanup.json   # when final cleanup fails
    │   ├── ollama-*.log   # when the run starts its own Ollama server
    │   └── <trial-id>.json
    ├── summary.csv
    ├── category-summary.csv
    └── report.md
```

Report generation uses `.report-staging-XXXXXX/` inside the report output directory.
These directories are normally removed when the work finishes; a later report generation reclaims abandoned, unlocked staging directories
owned by the current user once their modification time is at least 24 hours old.
Before replacing reports, staging is renamed to `.report-recovery-XXXXXX/` to retain backups of the previous reports.
Recovery directories are normally removed after publication or a successful rollback;
those left by a crash or a failed rollback are never automatically reclaimed.
After the run or report command has stopped, inspect these backups and restore any needed reports before deleting the recovery directory manually.

JSON updates create sibling `.tmp-XXXXXX` files, including under `raw/` for diagnostics.
They can remain after a failed write or a crash; a failed rename reports the recovery file's path in the error message.
Inspect and recover any needed data before deleting these files manually.
The repository's `.gitignore` excludes these intermediate files and directories under `Deliverables/Runs/` and `Deliverables/Comparisons/`.

Runs with status `failed` or `interrupted`, or stopped runs still marked `running`, do not automatically produce
`report.md`, `summary.csv`, or `category-summary.csv`.
These three of the five Git-tracked run files remain absent until you generate them from the retained `manifest.json` and `trials.jsonl`:

```sh
mise run execute report Deliverables/Runs/<run-id>
```

`manifest.json` pins the run, including its `system_prompt`; `trials.jsonl` holds each trial's metrics, score, and failure reason;
and `raw/` keeps the exact task prompt, response, provider events, and detailed diagnostics.
Trial IDs use `<position>__<task>__<target>__<cache-condition>__r<repeat>`, making `cold`, `warm`, and `provider-managed` visible in raw filenames.
The position uses at least five digits, widening to fit the whole schedule so filenames stay in execution order even above 99,999 trials.
Before preflight or inference, `run` rejects schedules whose raw filename (trial ID plus `.json`) exceeds 255 bytes; shorten the task or target ID.
Free-text error messages and scoring details stay out of the shared records.
For CLI targets, the manifest also records the command, argument templates, environment variable names, status-check arguments, prompt delivery,
event schema, and preflight version. Recognized sensitive arguments are redacted. Successful trials keep parsed events and provider metrics in their raw record;
a trial whose scoring fails also keeps its response so it can be re-scored.
Other failed trials keep the error detail but do not preserve the partial event stream or full stderr.

The JSON structure of the shared records and task inputs is defined by the schemas in [`Resources/schemas/`](Resources/schemas/):

-   [`manifest.schema.json`](Resources/schemas/manifest.schema.json) defines the run manifest.
-   [`trial.schema.json`](Resources/schemas/trial.schema.json) defines each trial record.
-   [`task.schema.json`](Resources/schemas/task.schema.json) defines the JSONL task entries and their scorer shapes.

Use these schemas when inspecting or validating records. The tests validate bundled task entries and generated manifests and trial records
against the schemas, as well as report consistency including successful, failed, and skipped trials.

Git tracks `manifest.json`, `trials.jsonl`, `report.md`, and both CSVs in each run directory, and excludes `raw/`
and other run-local files. It also excludes the shared lock at `Deliverables/Runs/.benchmark.lock`.
`report` reads the manifest and trials — the CSVs alone do not carry enough information to recompute medians and percentiles —
so keeping those two inputs in Git lets any checkout regenerate reports without copying raw responses between machines.

### Sharing results with Git

After a run finishes, publish its directory from the machine that measured it, from the repository root:

```sh
git add Deliverables/Runs/<run-id>
git commit -m "Record benchmark results for <run-id>"
git pull --rebase
git push
```

On the other Mac, pull the published results and generate a comparison from runs using the same implementation, suite, and measurement settings:

```sh
git pull --rebase
mise run execute report \
  Deliverables/Runs/<m1-pro-run> \
  Deliverables/Runs/<m2-max-run>
git add Deliverables/Comparisons/report.md Deliverables/Comparisons/summary.csv Deliverables/Comparisons/category-summary.csv
git commit -m "Update benchmark comparison"
git pull --rebase
git push
```

`Deliverables/Comparisons/` is tracked too, so pulling the repository also retrieves the combined report and CSVs.
Separate run IDs keep measurements in separate directories; select compatible runs explicitly when generating a comparison,
and use the `Deliverables/Runs/` and `Deliverables/Comparisons/` paths for this workflow.

Publishing results does not make otherwise compatible runs look different, because the manifest's implementation revision ignores those two directories
([reproducibility](#statistics-and-reproducibility)). Commit source, configuration, and suite changes before measuring.

### Reading the report

Quality is the pass rate over attempted trials, together with the mean score of completed responses.
Perceived responsiveness is the median time to first token, and raw generation speed is the median output tokens per second.
Stability is the share of trials that completed (`completion_rate` in `summary.csv`) and the failure-reason counts.
CLI subscription-limit failures share `request_error` with other CLI errors;
their details are available in the raw diagnostics.
Fit for the machine is the peak backend RSS, the model memory reported by Ollama, and the swap growth during the run.

Local models and reference agents share the table, so read the `adapter` column of `summary.csv` before sorting by any speed column
(in `report.md`, agent rows show tok/s as `n/a`): an agent's wall time includes process startup and the product's own processing. Cost stays `null` throughout,
for the reasons given in [Cost](#cost).

A local model is recommended only when it clears every threshold in the `selection` object.
The report also states how far the recommended model sits below the best agent pass rate,
which is the distance to the quality ceiling rather than a bar to clear.

## Methodology

How a measurement is defined, what each number means, and where the numbers stop being trustworthy.
The operational side is in [Running the benchmark](#running-the-benchmark) and the settings that produce these conditions in [Configuration](#configuration).

### Unit of comparison

A result belongs to one `host × target × cache_condition × task`. A target is not just a model name: it fixes the inference backend, the quantization,
and the context length as well, and a reference target additionally fixes the product, the model ID, the reasoning effort, the tool policy, and the CLI version.
Change any of those and the target changes with it — two runs of the same model at different reasoning efforts are two targets.

The upper bound on quality comes from coding agents already paid for by subscription, not from metered APIs.
Those agents carry their own system prompt and their own context handling, so a reference row measures a product rather than a bare model.
That gap cannot be closed; the isolation rules below shrink it as far as the CLIs allow, and the resulting rows sit in the same table as an upper bound,
never as a pass or fail criterion for a local candidate.

### Run conditions

Every run uses the same suite hash and configuration commit. Ollama uses the same output-token ceiling, temperature, and seed on each measured Mac.
The CLI adapter does not forward these generation settings. For a non-empty system prompt, Ollama sends it in its `system` field,
while the CLI adapter prepends the same instructions to the task text. An empty prompt omits Ollama's `system` field so a Modelfile `SYSTEM`
remains active. Trial order uses a Fisher–Yates shuffle with a seeded SplitMix64 generator
for all adapters. The manifest records this algorithm as `splitmix64-fisher-yates-v1`.

Measure each combination at least five times, and at least ten times for a finalist.

Agent runs are alternated across times of day and across orderings, and every rate limit or service failure is recorded rather than retried away by the runner.

A lock file in the results directory, together with the per-endpoint Ollama lock, prevents a second run from competing for CPU and memory.

### Cache conditions

**cold** — the runner checks `/api/ps` and, if the model is resident, unloads it with `keep_alive = 0` before the trial. The trial request loads the model
and reports `load_duration`; once the response and the model memory figures are collected, the model is unloaded once more.
This does not clear the OS filesystem cache or Metal's internal caches, so `cold` means the model is not resident in the inference server,
not that the machine was freshly rebooted.

**warm** — the runner unloads the model if resident, then loads it with an empty prompt and `keep_alive = -1` before the trial.

**provider-managed** — prompt caching, routing, and model residency on the provider's side cannot be controlled from here.
Those trials are labelled neither cold nor warm and aggregate into their own rows.

Ollama targets are unloaded after each cold or warm measurement; cleanup waits until `/api/ps` no longer lists the model,
polling immediately, then waiting 50 ms and backing off exponentially up to one second between polls.
A cleanup failure stops subsequent measurements after saving the failed trial. The runner prints `run: <directory>` as soon as it creates the run,
so the saved manifest, trials, and raw diagnostics can still be found after an error or interruption.
Final cleanup runs on normal exit and stops when interrupted.
Each unload or unload-status HTTP request is capped at five seconds, or `request_timeout_seconds` if shorter;
the full polling loop is bounded by `request_timeout_seconds`. Interruption cancels the in-flight confirmation poll and stops polling.
If a trial is already interrupted before cleanup, it still attempts one unload with a one-second cap, then skips confirmation polls.
Server startup happens before preflight and is outside trial timing;
the server stays alive across trials, so cold and warm describe model residency within it.

Ollama's [`thinking` field](https://docs.ollama.com/capabilities/thinking) stays in raw events and is excluded from scoring and TTFT.
For custom templates that return raw [Harmony channels](https://github.com/ollama/ollama/blob/main/harmony/harmonyparser.go),
the adapter extracts the first non-empty assistant `final` message and measures TTFT from its first response fragment.
Assistant messages without a channel are also final answers. If more final messages follow, the first non-empty answer remains the scored response;
later candidates stay in raw events and do not reset TTFT. Reasoning without a final answer scores as an empty answer.

### Measuring the reference agents

#### Invocation

Each trial spawns one process in the product's non-interactive mode, under the runner's [isolation](#isolation).
The bundled invocations below use neither `--continue` nor `--resume`, and each process starts in a fresh empty directory, so there is no prior
session to resume.

| Product     | Invocation                                                                                                                                |
| ----------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| Cursor      | `cursor-agent -p --output-format stream-json --stream-partial-output --mode ask --trust --model <id>`                                     |
| Codex       | `codex exec --json --sandbox read-only --skip-git-repo-check --ignore-user-config -m <id>` plus effort and tool-policy settings           |
| Claude      | `claude -p --verbose --output-format stream-json --include-partial-messages --tools "" --strict-mcp-config --model <id> --effort <level>` |
| Antigravity | `agy -p --output-format stream-json --disable-slash-commands --sandbox --model <id> --effort <level>`                                     |

Headless `cursor-agent` refuses to run in a directory it has not trusted, and every trial directory is new, so `--trust` is passed;
it leaves one trust marker per trial directory in the Cursor benchmark profile.

For a non-empty `run.system_prompt`, the CLI prompt is `system_prompt + "\n\n" + task.prompt`; otherwise it is exactly `task.prompt`.
Both texts are preserved without trimming or `{model}` expansion. The bundled targets deliver this combined prompt on stdin, then close stdin.
The adapter launches the executable directly without a shell.
The benchmark instructions match those sent to Ollama's `system` field when the prompt is non-empty. CLI agents receive these instructions as user-prompt text;
each product retains its own system prompt and context handling.

Every reference target pins the requested effort when the product exposes one. Depending on the CLI,
the level is part of the model ID, is passed as an argument, or both. For Antigravity, `--effort` must match the model ID suffix;
the [reference target policy](#reference-targets) prevents a session default from selecting a conflicting effort.
The selected model/effort pairs are those in the [reference matrix](#reference-targets).
For example, `codex-gpt-5.6-luna-max` in [Sources/Benchmark/Targets.swift](Sources/Benchmark/Targets.swift) includes `-m gpt-5.6-luna -c
'model_reasoning_effort="max"'`.
Every Codex invocation also applies `codexToolConfig` from that file. This disables shell execution, web search, agents, apps, plugins,
browser and image tools, and Code Mode execution.
The no-tools instruction is part of the shared `run.system_prompt` sent to every target; Codex receives no additional developer instruction.
`--ignore-user-config` keeps profile settings from adding capabilities while preserving the profile's authentication.
The settings follow the [Codex configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference).
Some CLI versions still advertise helper tools after these settings. Any tool, error item, or unknown event invalidates the trial,
even if an answer has already arrived; only answer and reasoning items and known lifecycle events are accepted.
A top-level `error` event is the exception: Codex prints one for each stream reconnect (`Reconnecting...`) and then retries,
so it stays in raw events and the trial continues. A failure that persists still ends in `turn.failed`, a non-zero exit, or no answer.
Claude Code's `system` `api_retry` event (429, 529, or a network failure) is handled the same way: Claude Code retries the request itself,
and any answer text already streamed by the abandoned attempt is discarded, so TTFT comes from the retried attempt.
Reasoning remains in raw events and does not contribute to the scored answer or TTFT.

Every reference product rejects trials containing tool-use or tool-result events, including nested content blocks and calls after an answer.
Literal JSON in answer text is still treated as text. Tool activity cannot contribute to a successful score or TTFT.
When the installed CLI version changes, compare its event stream with the parser and regression tests in
[`Sources/Benchmark/CLIEvents.swift`](Sources/Benchmark/CLIEvents.swift). In particular, Cursor `assistant` events with `timestamp_ms` append partial text,
while those without it replace the current answer. Its final `result` is authoritative, including revisions and an empty answer.
Claude and Antigravity `assistant`/`result` events and Codex `item.updated`/`item.completed` events carry full text. When a final `result`,
or any full value after incremental output, is already the accumulated text, its prefix, or its suffix, the parser keeps the accumulated value
to preserve content from streams that expose one content block at a time. A full value that starts with the accumulated text is a growing snapshot
of the same message and replaces it. Otherwise, if no incremental output has arrived, independent full messages are concatenated;
once incremental output exists, an unrelated full value replaces it.
Codex messages that carry an `item.id` are tracked separately: a snapshot replaces only its own message's text, after the earlier messages.

The adapter takes every reference model ID and invocation from Sources/Benchmark/Targets.swift.
JSON selects target IDs and eligible hosts; it cannot override model settings or effort.

The runner creates a fresh empty working directory outside the operator's home for each preflight check and trial, and removes it afterwards,
so no product-specific working-directory flag such as Codex's `-C` is part of the bundled invocation.
Preflight checks are excluded from trial timing.
[Reference agent](#reference-agent) describes the source-defined targets and their preflight checks.

#### Isolation

Isolation is part of the benchmark, not a setup step left to whoever runs it. The runner owns one profile per product,
uses it for every CLI process's environment, and refuses to measure a target whose profile is missing or logged out.
The controls below are fixed in [`Sources/Benchmark/Isolation.swift`](Sources/Benchmark/Isolation.swift) and recorded as `isolation.policy_version` in
each CLI target of the manifest.

| Product     | Command        | Configuration redirected by | Also pinned                          | Authentication check    |
| ----------- | -------------- | --------------------------- | ------------------------------------ | ----------------------- |
| Cursor      | `cursor-agent` | `CURSOR_CONFIG_DIR`         | `AGENT_CLI_CREDENTIAL_STORE=file`    | `status --format json`  |
| Codex       | `codex`        | `CODEX_HOME`                | —                                    | `login status`          |
| Claude      | `claude`       | `CLAUDE_CONFIG_DIR`         | —                                    | `auth status`           |
| Antigravity | `agy`          | `HOME` alone                | —                                    | `models`                |

Antigravity exposes no configuration-directory override and reads its configuration from `HOME`, so `HOME` carries its configuration isolation
on its own; its keychain sign-in is shared with your ordinary `agy` (see [Reference agent CLIs](#reference-agent-clis)).
Cursor keeps credentials in the login keychain by default, which a configuration redirect alone would not escape, so the file-backed
credential store is pinned as well. Every product also has `HOME` and `TMPDIR` pointed inside its profile.

What the runner does for preflight version and authentication checks, and for trial processes:

-   Clears the inherited environment, keeping only variables that describe the machine rather than the operator:
    `PATH`, `LANG`, `LC_ALL`, `LC_CTYPE`, `LC_MESSAGES`, `TERM`, the certificate variables
    `SSL_CERT_FILE`, `SSL_CERT_DIR`, `NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`, and the proxy variables
    `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `NO_PROXY` with their lowercase forms. It then sets `HOME`, `TMPDIR`,
    `NO_COLOR=1`, and the product's own variables from the table. None of the retained variables can select a user profile, provider,
    model, effort, or tool policy; the proxy and certificate ones are kept because a machine behind a corporate proxy
    could otherwise reach no product at all.
-   Runs the process in a fresh empty directory, removed afterwards on success, error, timeout, and interruption alike.
    That directory is created under the per-user temporary directory, **not** under the operator's home: these CLIs discover
    instructions and rules by walking the ancestors of their working directory, so a directory anywhere below `$HOME` would put
    `~/.cursor`, `~/.claude`, and any home-level `CLAUDE.md` back on the search path. As a result no repository, editor profile,
    or parent directory can supply `AGENTS.md`, `CLAUDE.md`, rules, skills, hooks, MCP servers, plugins, memories,
    or session history, and no trial can see the previous trial's directory.
-   Applies each product's tool policy: `--tools ""` with `--strict-mcp-config` for Claude, `codexToolConfig` and event validation for Codex,
    `--mode ask` for Cursor, and `--sandbox` for Antigravity. Codex's `--sandbox read-only` alone does not disable tools.
-   Requires the profile to carry a valid marker written by `mise run execute login` under the current isolation policy,
    and requires the product's own authentication check to pass. An outdated or malformed marker requires running `mise run execute login <product>` again.
    `cursor-agent status` exits successfully while logged out, so its JSON `isAuthenticated` field is read rather than its exit code;
    Claude's `loggedIn` is read the same way. A missing profile, a failed check, or a logged-out profile records `preflight_failed`
    and skips the target. There is no fallback to the ordinary profile.

Authentication is performed once per machine, into the profile and nowhere else:

```sh
mise run execute login claude
```

That runs the product's own login with the same environment variables as a trial, so a successful sign-in prepares the benchmark profile.
`login` and the authentication checks launched by `login --status` use the product profile's `tmp/` as their working directory.
This directory persists between calls and, with the default profile location, sits under the operator's home,
where ancestor discovery can find home-level instruction files. The fresh-directory policy outside the home applies to preflight checks and trials.
`mise run execute login --status` reports each product's state. See [reference agent CLIs](#reference-agent-clis).

Credentials live inside the product profile, created with mode `0700` at `$XDG_DATA_HOME/benchmark/profiles/<product>` when `XDG_DATA_HOME` is an absolute path.
When it is unset, empty, or relative, the location defaults to `$HOME/.local/share/benchmark/profiles/<product>` with an absolute `HOME`.
Profile locations resolving inside the implementation repository are rejected, including symlink aliases.
The throwaway working directories for preflight checks and trials live separately, under the per-user temporary directory, and hold no credentials.
The manifest records the policy version, the product, a `profile_root` field that is always `null` (profiles must stay outside the repository),
the names of the variables the policy sets, and the authentication-check arguments; it never records their values or the profile's contents.
The target fingerprint includes the policy version and the product for reference targets, so results taken under different isolation never merge silently.
Local targets are not isolated this way and are not fingerprinted against the policy, so a policy change does not invalidate their history.

Three limits remain, and none is checked automatically:

-   The benchmark verifies that its profile is authenticated, not that the CLI has no other configuration source. A future CLI version could
    read a scope none of these variables cover. Re-check the controls above when the installed CLI version changes.
-   Managed or enterprise configuration installed outside `HOME` is outside the benchmark's reach.
-   Antigravity's sign-in lives in the login keychain, so its authentication check passes whenever your ordinary `agy` is signed in.

#### Metric availability

| Metric                   | ollama                                  | cli-agent                                                 |
| ------------------------ | --------------------------------------- | --------------------------------------------------------- |
| Wall time                | Request start to end of stream          | Process startup through completion and stdout consumption |
| TTFT                     | Request start to first content fragment | To the first non-empty text event, including startup      |
| Generation time          | Decode time from the backend            | `null`                                                    |
| Output tokens/sec        | Computed                                | `null`                                                    |
| Input / output tokens    | From usage when reported                | Only when the CLI reports usage                           |
| Cost                     | `null`; no per-trial charge             | `null`; a flat fee has no per-trial price                 |
| Backend RSS / swap delta | Local targets only                      | `null`; inference happens elsewhere                       |
| Load time                | Ollama only                             | `null`                                                    |

For an agent, wall time answers "how long until an answer came back", not "how fast it generates", and TTFT carries process startup with it.
Wall time (in `summary.csv`) and TTFT share columns with local rows, so read the `adapter` column before comparing them.
In Markdown comparison and category tables, reference-agent tok/s is always `n/a` (not applicable);
Ollama uses `-` when timing or token counts are missing or fewer than two output tokens were generated.
Both CSVs keep missing speeds blank and include `adapter` to distinguish these cases.
If the CLI emits only a completed message, TTFT is the arrival time of that message; it is not a measurement of the provider's first generated token.
Input tokens include cached prompt tokens: Claude reports them separately as `cache_creation_input_tokens` and `cache_read_input_tokens`,
and Cursor as `cacheReadTokens` and `cacheWriteTokens`; these are added to `input_tokens` to match Codex, whose count already includes them.
Separate preflight version and status checks are excluded from wall time, while authentication performed inside the generation process is included.
CLI wall time and TTFT start after profile and workspace preparation; stale-workspace cleanup runs once per command.
Wall time ends when process completion has been observed and stdout has been consumed, including answer parsing.
The process-reaping interval is recorded separately as raw `provider_metrics.cli_cleanup_ms`; it excludes trial-workspace cleanup,
which happens after the process has been reaped and is outside both wall time and `cli_cleanup_ms`.
Total invocation time can extend beyond `request_timeout_seconds`: waiting for a terminated process is capped at 30 additional seconds.

The adapter does not forward `max_output_tokens`, `temperature`, or `seed` to the CLIs.
These run settings remain in the manifest, but there is no per-trial field indicating which were applied. Use the task prompt to request output length;
the runner does not enforce a CLI output-token ceiling. Provider timing, cost, and turn-count fields, when reported, remain in raw provider metrics
and do not populate generation speed or per-trial subscription cost.

### Metrics

#### Quality

Scorers are never shown to the model. The headline figure is `passed / attempted`; for tasks that award partial credit,
the mean score of completed responses is reported alongside.

| `status`      | Meaning                                                   | Aggregation                                    |
| ------------- | --------------------------------------------------------- | ---------------------------------------------- |
| `completed`   | A response arrived and was scored                         | Attempted, and included in quality figures     |
| `error`       | Timeout, authentication, rate limit, or another failure   | Attempted, and a failure in the success rate   |
| `skipped`     | Not eligible for this host, or preflight did not pass     | Scheduled only                                 |

`passed` says whether a completed response met the task threshold. Keeping that apart from `status` stops an outage from reading as a quality failure
while reliability still shows up in the success rate.

The bundled tasks screen candidates and check connectivity with different repetition counts.

#### Failure classification

The following bounds limit response processing and retained diagnostics. MiB and KiB use powers of 1024.

| Output                                                        | Limit       | Behavior when exceeded                                                         |
| ------------------------------------------------------------- | ----------: | ------------------------------------------------------------------------------ |
| One reference CLI stdout line, including its newline          | 8 MiB       | Exceeding it during a trial produces `request_error`                           |
| Reference CLI JSON events per trial                           | 100,000     | An additional event produces `request_error`                                   |
| Reference CLI event bytes per trial, after trimming each line | 16 MiB      | Exceeding it produces `request_error`                                          |
| Ollama JSON events per trial                                  | 100,000     | An additional event produces `request_error`                                   |
| HTTP response body                                            | 64 MiB      | Exceeding it during a trial produces `request_error`                           |
| Retained CLI stderr or combined check output                  | 64 KiB each | Excess output is drained and discarded; truncation alone does not fail a trial |

For a trial that exceeds a processing limit, inspect `raw/<trial-id>.json` for the specific error.
Limit errors during preflight instead make the target unavailable with `preflight_failed`.

These trial classifications apply to all adapters, including local Ollama targets. The [trial schema](Resources/schemas/trial.schema.json)
defines all eleven `failure_reason` values; successful trials use `null`.

| Event                                                                                 | `status`    | `failure_reason`       |
| ------------------------------------------------------------------------------------- | ----------- | ---------------------- |
| Unavailable target, missing CLI/model/profile, or failed version/authentication check | `skipped`   | `preflight_failed`     |
| Preparation or generation reports a timeout                                           | `error`     | `timeout`              |
| Operator interruption (including during cleanup)                                      | `error`     | `interrupted`          |
| HTTP 401 or 403                                                                       | `error`     | `authentication_error` |
| HTTP 429                                                                              | `error`     | `rate_limited`         |
| Other unsuccessful HTTP response                                                      | `error`     | `api_error`            |
| Transport/protocol error, CLI error/non-zero exit, invalid JSON, or no response       | `error`     | `request_error`        |
| An error while scoring the response                                                   | `error`     | `runner_error`         |
| Per-trial cleanup fails, such as unloading a cold Ollama model                        | `error`     | `cleanup_error`        |
| Scored answer below the task's pass threshold                                         | `completed` | `evaluation_failed`    |
| Output limit reached before any final answer                                          | `completed` | `output_truncated`     |

An explicit empty answer is a completed trial with score zero for every adapter, even with a zero pass threshold.
Its failure reason is `output_truncated` when the output limit was reached
(`finish_reason` is `length`, `max_tokens`, or `max_output_tokens`, case-insensitive), and `evaluation_failed` otherwise.
A CLI stream without any recognized answer event remains a protocol error. Operator interruptions have their own failure reason, `interrupted`.

The HTTP classifications apply during trial preparation or generation through `ollama`.
Failures discovered during preflight are recorded as `preflight_failed` instead.
CLI authentication and subscription-limit errors during generation share `request_error`; they are not classified as separate auth/rate-limit codes.
Detailed errors are saved in `raw/<trial-id>.json` and preflight diagnostics in `raw/preflight.json`.

A per-trial cleanup failure replaces any earlier `failure_reason` with `cleanup_error` unless the trial is already `interrupted`,
sets `status = "error"` and `passed = false`, and stores its details under `cleanup_error` in `raw/<trial-id>.json` in either case.
Final cleanup of the whole run is separate: its failures are saved in `raw/cleanup.json` and the manifest's `warnings`, without changing trial classifications.

For CLI targets, timeout and interruption terminate the child process and, on Unix, its process group; trial records already written remain available.
Usage limits depend on the time of day, so timestamps help relate failures to the measurement window.

#### Speed

Wall time runs from the start of the HTTP request to the end of the stream, and TTFT from the start of the request to the first non-empty content fragment.
Generation time is the decode time Ollama reports; it stays `null` when Ollama reports none.
Output tokens per second is the output token count minus one divided by generation time, because Ollama counts the first token
but times it with the prompt; a single-token answer has no speed. Load time is the model load duration Ollama reports.
Agent definitions follow the availability table above.

When Ollama reports fewer than two output tokens or no generation time, tokens per second stays `null`; token counts are not estimated from character counts.
Fractional token counts from either adapter are ignored instead of rounded; integral numeric values such as `42.0` remain valid.

#### Memory

For Ollama, sampling starts before preparation (including warm preload and cold unload waits) and ends after generation, before cleanup.
Peak RSS and swap growth therefore cover preparation as well as generation, even though warm wall time excludes the preload.

A sampler enumerates processes through macOS `libproc` every 200 ms and sums the RSS from `proc_pid_rusage` for every process whose executable basename
contains the target's `process_match`, ignoring case: `llama` for every local target, covering `ollama` and the `llama-server` runner it spawns
per model. It reads the executable path without arguments, so target IDs in benchmark or shell arguments do not count toward backend RSS.
Swap usage is read directly with `sysctlbyname("vm.swapusage")` at the same moments and the largest increase since sampling began
is derived from those readings.
If `proc_pid_rusage` rejects a matching process because it belongs to another user, that sample falls back to one `ps` snapshot so the RSS remains
system-wide. If the fallback cannot be read, that trial's RSS is recorded as `null`; the preflight warning reports unmeasured attribution
only when the same failure occurs in the measurement taken before server startup.
This is a system-wide value: swap used by unrelated processes also contributes to the recorded increase.
Before starting a managed server, `doctor` and `run` warn about existing processes matching eligible local targets.
A run saves these warnings in its manifest and report. RSS includes matching processes across all users; close unrelated instances before measurement.
For each reused Ollama endpoint, preflight also checks `/api/ps` and warns with the resident model names, or warns if the check fails.
These warnings are saved in the run's manifest and report. Unload unrelated models before measuring; their memory can affect RSS and swap attribution.
For Ollama it also records the model size, the accelerator memory, the context length actually allocated, and `runtime_quantization`, all from `/api/ps`.
Because CPU and GPU share unified memory on Apple Silicon, these figures are not added together; they are separate observations of the same system.

On the 16 GB machine, swap growth and interface responsiveness carry the most weight.

Reference agents run their inference elsewhere, so all of these are `null`.
Sampling the local CLI process would describe the terminal client rather than the model, so it is not recorded.

#### Cost

Because the reference values come from subscriptions, no per-trial cost is computed: dividing a flat monthly fee by a trial count would describe
how much the subscription happened to be used that month, so the trial field `cost_usd` stays `null`.
Summary CSVs and Markdown tables omit cost columns. Any provider-reported cost stays in raw provider metrics and is not a subscription price.

Cost is instead compared by hand in the write-up — the monthly total and how often the allowance ran out, set against local models that cost nothing
beyond electricity and hardware.

### Selection rules

Among local targets in the warm condition, the report treats a model as a candidate only when all four hold.

1.  The pass rate over attempted trials is at or above the configured minimum.
2.  No trial timed out, and the median output tokens per second is at or above the configured minimum.
    The median covers completed trials only, so a timed-out trial — usually the slowest — would otherwise make the model look faster.
3.  The largest per-trial peak swap growth is at or below the configured maximum. Pages pushed to swap stay there,
    so later trials of the same model start from the higher baseline and show little growth; a p90 would hide the one trial that pushed them out.
4.  The p90 of per-trial peak backend RSS is at or below the configured fraction of installed memory.

A candidate is excluded from automatic selection if any required metric is missing (`null`): `pass_rate`, `median_output_tokens_per_second`,
`max_peak_swap_delta_bytes`, `p90_peak_backend_rss_bytes`, or `host_memory_bytes`.
It is also excluded unless every run that lists it on that host completed and none of its trials in that condition were skipped,
including leftover skips recorded under a different fingerprint.

Survivors are ordered by pass rate, then mean score, then generation speed. There is no single weighted total, because the conclusion would follow
from the weights. Cold load time, model size, licensing, tool calling, and long-context behaviour are weighed by hand when candidates are close;
the report does not use them.

Reference agents are exempt from all four rules: three of the four figures do not exist for them, and they are not candidates for running on the machine
in the first place.
When agents were measured on the same host with a complete schedule, the report states the gap between the recommended local target and the best agent pass rate.
That gap is the distance to the quality ceiling, not a bar the local candidate has to clear.

### Statistics and reproducibility

In `summary.csv`, per-trial peak RSS and swap growth retain both maxima (`max_peak_*_bytes`) and p90 (`p90_peak_*_bytes`).
Memory statistics include failed attempts, and one attempt with an unknown peak makes that row's p90 and maximum `null`.
The RSS gate and the Markdown RSS column use p90; the swap gate and the Markdown swap column use the maximum.
Wall time is summarized by its median and p90; TTFT, load time, and output tokens per second have medians only.
Trial counts are reported per row as `scheduled_trials`, `attempted_trials`, `completed_trials`, and `passed_trials`, not per speed metric.
In both CSVs, `scheduled_trials` means the number of trial records recorded for that row, including `skipped` records; it is not the manifest's planned count.
The Markdown Run progress table shows the planned count and recorded count separately.
Both CSV summaries also include `truncated_trials`, the number of attempted trials
with `finish_reason` equal to `length`, `max_tokens`, or `max_output_tokens` (case-insensitive), and `timeout_trials`, the number recorded as `timeout`.
The Markdown comparison and category tables show this as Truncated / 打ち切り, so output limits can be distinguished from answer quality.
Ollama's output-token limit also includes reasoning tokens; inspect truncation during the smoke run and raise `run.max_output_tokens` if needed.

Runs are combined only when the suite hash, implementation revision, request and generation settings, selection settings, and application match,
and runs sharing a host ID report the same chip, memory, hardware model, architecture, and macOS version;
re-measure the whole host after a macOS update rather than combining across it. Targets whose fingerprints differ stay in separate rows.
Combined runs must not record the same host, target ID, target fingerprint, cache condition, task, and repeat twice; `report` rejects such a combination,
so report a re-measurement of an unchanged target on its own. `report` also rejects duplicate run IDs and mixed non-null `model_revision`,
`runtime_quantization`, or `loaded_context_window` within one host, target, fingerprint, and cache condition.
A `skipped` record is dropped when another combined run measured the same host, target ID, cache condition, task, and repeat,
whatever its fingerprint, so a target skipped before sign-in does not add empty rows or failure counts; the Run progress table still counts it as recorded.
Different repeat counts or cache-condition sets are allowed, but `report.md` warns about them so trial counts and matched cache rows can be compared.
Because a model alias can resolve to a new revision, both the requested name and the name the backend returned are stored.

Candidates separated by a small difference in success rate need more repetitions. Even 270 trials, from 54 tasks measured five times per cache condition,
cannot settle a narrow gap.

The manifest fixes the machine, the implementation revision and whether its working tree was dirty, the run settings, and every target down to backend,
quantization, and context length. Raw payloads keep the exact task prompt; the manifest supplies the run's system prompt.
Each trial keeps the resolved model and the backend version.

The implementation revision is the latest commit affecting files outside the root `Deliverables/Runs/` and `Deliverables/Comparisons/` directories,
and changes in those directories do not set the dirty flag either. Committing reports therefore preserves comparability between machines.
Git's discovered top-level directory must match the implementation checkout after resolving symlinks; Git worktrees are supported.
If Git is unavailable or the checkout is inside another repository without its own Git root, both revision and dirty state are `null`.

Anything that could not be measured is stored as `null`. Missing values are never filled in with an estimate from somewhere else.

### Limitations

-   Inference time and memory on a subscription agent's provider infrastructure cannot be measured.
-   A short memory peak between two memory samples can be missed.
-   Swap growth is system-wide and can include unrelated applications; matching RSS also spans all users and backend instances when it can be measured.
    The RSS p90 gate tolerates isolated outliers but cannot remove sustained background load, and the swap gate uses the maximum,
    so one burst of unrelated swapping excludes a candidate. Inspect the retained maxima and repeat a contaminated run.
-   Each local memory sample enumerates processes and reads system swap counters at a 200 ms interval.
    The sampler's CPU and memory load can affect inference timing and swap growth, particularly under memory pressure; that overhead is not subtracted.
-   Cold trials unload the model from Ollama but do not clear OS page caches; load-time medians mix disk reads and cached reads.
-   The bundled tasks do not adequately measure knowledge freshness, tool calling, or long-form code editing.
-   Local results measure models as served by Ollama and do not compare inference engines.
-   A reference agent includes the product's system prompt and context handling, so it does not equal the underlying model's performance.
-   An agent may retry internally or take several turns, and wall time cannot be broken down into those parts.
-   The CLIs and their backends update without notice, so the same model ID is not guaranteed to be comparable across a long measurement period.
-   Reporting rejects different non-null `model_resolved` values within the same host, target ID, target fingerprint, and cache condition,
    including reference agents, to avoid averaging different models as one measurement condition.
    A provider changing the resolved name for even one trial can fail the entire report with `mixed model_resolved`; the recorded inputs remain intact.
    If the mismatch is only between runs, report each run separately with `mise run execute report Deliverables/Runs/<run-id>` and do not combine those runs.
    If it occurs within a run, preserve that run and measure the affected target again with `mise run execute run --target <target-id>`
    once the provider's model is stable. There is no report option to split or filter out the conflicting trials; do not edit `trials.jsonl` to hide them.
-   Subscription limits depend on the time of day and on recent usage, which affects whether a measurement can be taken at all.

## Experiment plan

The plan for the first full round of measurement across the two machines.
Execute the benchmark code separately on each Mac, using Ollama on that same Mac.
Procedure lives in [Running the benchmark](#running-the-benchmark) and definitions in [Methodology](#methodology).

### Questions to answer

1.  Which local model can run on the MacBook Pro M1 Pro 16 GB alongside the usual development tools?
2.  Which local model on the Mac Studio M2 Max 96 GB comes closest to the quality ceiling?
3.  Which tasks should finish locally, and which should go to a subscription agent?

The recommendation is per machine. Forcing the best 96 GB model onto the 16 GB machine, or averaging the two machines into one ranking,
would answer a question nobody asked.

### Choosing local candidates

Choose local candidates from **Gemma 4, GPT-OSS Swallow, and Ornith 1.5**.
Model definitions are fixed in [`Sources/Benchmark/Targets.swift`](Sources/Benchmark/Targets.swift), including each size's model tag, quantization,
context length, and backend settings.
Select target IDs and eligible hosts in `Resources/benchmark.json`. Use `run --target <id>` to select a subset of those listed IDs for one measurement.
The [local model catalog](#ollama) lists the exact tags to install; missing installations are skipped automatically.
Within one model family, start at roughly 4-bit quantization and add a higher-precision build only for the candidates worth examining more closely.

| Family                  | 16 GB machine    | 96 GB machine               | Initial quantization |
| ----------------------- | ---------------- | --------------------------- | -------------------- |
| Gemma 4                 | E2B, E4B, 12B    | E2B, E4B, 12B, 26B A4B, 31B | Q4_K_M               |
| GPT-OSS Swallow RL v0.1 | 20B (borderline) | 20B, 120B                   | MXFP4_MOE            |
| Ornith 1.5              | 9B               | 9B, 35B                     | Q4_K_M               |

The 16 GB Swallow candidate is included to measure its limits; its memory and swap results must pass the same thresholds as every other candidate.

### Reference targets

`targetDefinitions()` in [`Sources/Benchmark/Targets.swift`](Sources/Benchmark/Targets.swift)
defines every available reference target ID and reasoning-effort variant.
Add the desired IDs to the `targets` array in `Resources/benchmark.json` before selecting them with `run --target <id>`.

The quality ceiling comes from the subscription CLIs through the implemented `cli-agent` adapter.
The bundled configuration selects five reference targets, with each model and effort fixed as listed below.
The 54 tasks with five repeats schedule 1350 remote trials per host.

| Product     | Command        | Model            | Effort | Target ID / model value                                             |
| ----------- | -------------- | ---------------- | ------ | ------------------------------------------------------------------- |
| Cursor      | `cursor-agent` | Composer 2.5     | —      | `cursor-composer-2.5` / `composer-2.5`                              |
| Codex       | `codex`        | GPT-5.6 Luna     | max    | `codex-gpt-5.6-luna-max` / `gpt-5.6-luna`                           |
| Claude      | `claude`       | Claude Sonnet 5  | max    | `claude-sonnet-5-max` / `claude-sonnet-5`                           |
| Antigravity | `agy`          | Gemini 3.8 Flash | high   | `antigravity-gemini-3.8-flash-high` / `gemini-3.8-flash-high`       |
| Antigravity | `agy`          | GPT-OSS 120B     | medium | `antigravity-gpt-oss-120b-medium` / `gpt-oss-120b-medium`           |

Antigravity encodes the listed effort levels in its model IDs and also accepts a session-level `--effort low|medium|high` flag.
Every Antigravity target explicitly passes the level matching its model ID suffix
(for example, `--model gemini-3.8-flash-high --effort high`) so a session default cannot select a conflicting effort.
Confirm the effective model and effort in the smoke run's recorded events before measuring the full matrix.

The target IDs, model IDs, and invocations are defined together in
[`Sources/Benchmark/Targets.swift`](Sources/Benchmark/Targets.swift). If a specified model or effort is unavailable,
record the failure without substituting another target.
[`Resources/benchmark.json`](Resources/benchmark.json) selects the five references above from the source catalog.
Its selected CLI entries are complete; a product's targets become measurable once
`mise run execute login <product>` has signed its benchmark profile in ([reference setup](#reference-agent-clis)).
Preflight checks the CLI version and the product's authentication, both under the benchmark's own [isolation](#isolation).

### First matrix

| Host           | Targets                                | Cache              | Context           | Repeat   |
| -------------- | -------------------------------------- | ------------------ | ----------------- | -------- |
| M1 Pro 16 GB   | Local targets eligible on 16 GB        | cold and warm      | 8K                | 5        |
| M2 Max 96 GB   | All nine local targets                 | cold and warm      | 8K                | 5        |
| Both           | Five selected reference targets        | provider-managed   | product default   | 5        |

Then measure only the top two candidates ten or more times and extend the suite toward real use.
That extension should cover Japanese summarization, classification, and structured output; reading and patching code from an actual repository;
retrieval across 8K, 16K, and 32K of context; the tool schemas you actually intend to use if tool calling matters;
and the memory growth and thermal throttling seen over thirty minutes of continuous use.

### Deciding

#### MacBook Pro M1 Pro 16 GB

Beyond the configured thresholds, use each finalist for at least fifteen continuous minutes with the usual IDE, browser, and terminal open.
Watch swap growth, interface stalls, and time to first token, and drop any candidate that costs the machine's overall responsiveness
for a small gain in answer quality.

#### Mac Studio M2 Max 96 GB

For the strongest candidates, add measurements at contexts longer than 8K and at higher-precision quantization.
Every target fixes an 8K context and one quantization, so each such combination first needs its own target in
[`Sources/Benchmark/Targets.swift`](Sources/Benchmark/Targets.swift).
The question is not only whether the model fits, but whether 16 to 24 GB remains free for ordinary development work.

#### Local or agent

State the following in the write-up: how close the recommended local model came to the best agent pass rate; whether the local warm TTFT and generation speed
are enough for daily use; the monthly subscription total and how often the allowance ran out during the measurement period;
the tasks that must stay local for offline or confidentiality reasons; and the task categories where the local model missed the bar
and the work should go to an agent instead.

Agent speed figures include process startup and the product's own processing, so they are not compared directly against local generation speed.
The axes that do compare are quality and whether the work can be done without hitting a limit.

The conclusion may well be a routing policy per machine and per task category rather than a single model for everything.

## License

Released under the MIT License. See [`LICENSE.md`](LICENSE.md).
