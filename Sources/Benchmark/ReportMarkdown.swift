import Foundation

extension ReportLanguage {
  func text(_ japanese: String, _ english: String) -> String { self == .ja ? japanese : english }
}

func markdownEscape(_ value: String) -> String {
  var value = value.replacingOccurrences(of: "&", with: "&amp;", options: .literal)
    .replacingOccurrences(of: "<", with: "&lt;", options: .literal).replacingOccurrences(
      of: ">", with: "&gt;", options: .literal)
  for char in ["\\", "|", "`", "[", "]", "*", "_", "!", "~"] {
    value = value.replacingOccurrences(of: char, with: "\\" + char, options: .literal)
  }
  return value.replacingOccurrences(of: "\r\n", with: "<br>", options: .literal)
    .replacingOccurrences(of: "\r", with: "<br>", options: .literal).replacingOccurrences(
      of: "\n", with: "<br>", options: .literal)
}

func markdownCode(_ value: String) -> String {
  if value.isEmpty { return "-" }
  let value = value.replacingOccurrences(of: "\r\n", with: " ", options: .literal)
    .replacingOccurrences(of: "\r", with: " ", options: .literal).replacingOccurrences(
      of: "\n", with: " ", options: .literal)
  let length = value.unicodeScalars.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
  let fence = String(repeating: "`", count: length + 1)
  let padding =
    value.unicodeScalars.first.map { $0 == "`" || $0 == " " } == true
      || value.unicodeScalars.last.map { $0 == "`" || $0 == " " } == true ? " " : ""
  return fence + padding + value + padding + fence
}

func displayOrDash(_ value: JSON) -> String {
  value == .null ? "-" : markdownEscape(value.text)
}

func formatted(_ value: JSON, _ digits: Int, suffix: String = "", scale: Double = 1) -> String {
  value.double.map { String(format: "%.*f", digits, $0 * scale) + suffix } ?? "-"
}

func percent(_ value: JSON) -> String { formatted(value, 1, suffix: "%", scale: 100) }
func gib(_ value: JSON) -> String {
  formatted(value, 2, suffix: " GiB", scale: 1 / Double(gibibyte))
}

func speed(_ row: JSON) -> String {
  row["adapter"].string == "cli-agent"
    ? "n/a" : formatted(row["median_output_tokens_per_second"], 1)
}

func scalarPrefix(_ value: String, _ length: Int) -> String {
  String(String.UnicodeScalarView(value.unicodeScalars.prefix(length)))
}

func tableCodePrefix(_ value: JSON, _ length: Int) -> String {
  markdownCode(scalarPrefix(value == .null ? "-" : value.text, length)).replacingOccurrences(
    of: "|", with: "\\|", options: .literal)
}

func targetLabel(_ row: JSON, table: Bool = true) -> String {
  let fingerprint = scalarPrefix(row["target_fingerprint"].string ?? "", 8)
  let label =
    markdownCode(row["target_id"].text) + (fingerprint.isEmpty ? "" : " (`\(fingerprint)`)")
  return table ? label.replacingOccurrences(of: "|", with: "\\|", options: .literal) : label
}

func modelLabel(_ row: JSON) -> String {
  let value = row["model_resolved"].truthy ? row["model_resolved"] : row["model_requested"]
  var model = value.truthy ? markdownEscape(scalarPrefix(value.text, 128)) : "-"
  if row["model_revision"].truthy {
    let revision = row["model_revision"].text
    let digest =
      revision.firstIndex(of: ":").map { String(revision[revision.index(after: $0)...]) }
      ?? revision
    model += "@" + markdownEscape(scalarPrefix(digest, 8))
  }
  return model
}

struct ReportMarkdownInput {
  let manifests: [JSON]
  let summary: [JSON]
  let categories: [JSON]
  let trials: [JSON]
  /// Trial records per run ID, including skips superseded by another run.
  let recordedTrials: [String: Int]
  let selection: SelectionSettings
  let language: ReportLanguage
}

private func markdownRow(_ cells: [String]) -> String {
  "| " + cells.joined(separator: " | ") + " |"
}

private func markdownTable(
  _ language: ReportLanguage, japanese: String, english: String, alignment: String,
  rows: [[String]]
) -> [String] {
  [language.text(japanese, english), alignment] + rows.map(markdownRow)
}

private func appendMarkdownSection(
  _ lines: inout [String], language: ReportLanguage, japanese: String, english: String,
  body: [String]
) {
  lines += ["", "## " + language.text(japanese, english), ""] + body
}

private func environmentTable(_ manifests: [JSON], language: ReportLanguage) -> [String] {
  markdownTable(
    language,
    japanese: "| ホスト | チップ | メモリ | macOS | リビジョン | 未コミット変更 | 実行 | スイート SHA-256 |",
    english: "| Host | Chip | Memory | macOS | Revision | Dirty | Run | Suite SHA-256 |",
    alignment: "| --- | --- | ---: | --- | --- | --- | --- | --- |",
    rows: manifests.map { manifest in
      let dirty =
        manifest["repository"]["dirty"].bool.map {
          $0 ? language.text("あり", "yes") : language.text("なし", "no")
        } ?? "-"
      return [
        displayOrDash(manifest["host_id"]), displayOrDash(manifest["host"]["chip"]),
        gib(manifest["host"]["memory_bytes"]), displayOrDash(manifest["host"]["os_version"]),
        tableCodePrefix(manifest["repository"]["revision"], 12), dirty,
        displayOrDash(manifest["run_id"]), tableCodePrefix(manifest["suite"]["sha256"], 12),
      ]
    })
}

private func warningLines(_ manifests: [JSON]) -> [String] {
  manifests.flatMap { manifest in
    (manifest["warnings"].array ?? []).compactMap(\.string).map {
      "- \(displayOrDash(manifest["run_id"])): \(markdownCode($0))"
    }
  }
}

private func progressTable(
  _ manifests: [JSON], recordedTrials: [String: Int], language: ReportLanguage
) -> [String] {
  markdownTable(
    language, japanese: "| 実行 | 状態 | 予定 | 記録済み | 未実施 |",
    english: "| Run | Status | Scheduled | Recorded | Not run |",
    alignment: "| --- | --- | ---: | ---: | ---: |",
    rows: manifests.map { manifest in
      let count = (try? scheduleShape(manifest).total) ?? 0
      let recorded = recordedTrials[manifest["run_id"].text] ?? 0
      return [
        displayOrDash(manifest["run_id"]), displayOrDash(manifest["status"]), String(count),
        String(recorded), String(max(0, count - recorded)),
      ]
    })
}

private func passSummary(_ row: JSON) -> String {
  "\(displayOrDash(row["passed_trials"]))/\(displayOrDash(row["attempted_trials"])) (\(percent(row["pass_rate"])))"
}

private func comparisonTable(_ summary: [JSON], language: ReportLanguage) -> [String] {
  markdownTable(
    language,
    japanese:
      "| ホスト | 対象 | モデル | キャッシュ | 合格 | スコア | 初回トークン時間 | 読込時間 | tok/s | ピークRSS p90 | モデルメモリ | ピークスワップ増分 最大 | 打ち切り |",
    english: """
      | Host | Target | Model | Cache | Pass | Score | TTFT | Load | tok/s | Peak RSS p90 | Model memory \
      | Peak swap delta max | Truncated |
      """,
    alignment:
      "| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    rows: summary.map { row in
      [
        displayOrDash(row["host_id"]), targetLabel(row), modelLabel(row),
        displayOrDash(row["cache_condition"]), passSummary(row), formatted(row["mean_score"], 3),
        formatted(row["median_ttft_ms"], 0, suffix: " ms"),
        formatted(row["median_load_ms"], 0, suffix: " ms"), speed(row),
        gib(row["p90_peak_backend_rss_bytes"]), gib(row["max_model_memory_bytes"]),
        gib(row["max_peak_swap_delta_bytes"]), displayOrDash(row["truncated_trials"]),
      ]
    })
}

private func categoryTable(_ categories: [JSON], language: ReportLanguage) -> [String] {
  markdownTable(
    language, japanese: "| ホスト | 対象 | キャッシュ | カテゴリ | 合格 | スコア | tok/s | 打ち切り |",
    english: "| Host | Target | Cache | Category | Pass | Score | tok/s | Truncated |",
    alignment: "| --- | --- | --- | --- | ---: | ---: | ---: | ---: |",
    rows: categories.map { row in
      [
        displayOrDash(row["host_id"]), targetLabel(row), displayOrDash(row["cache_condition"]),
        displayOrDash(row["task_category"]), passSummary(row), formatted(row["mean_score"], 3),
        speed(row), displayOrDash(row["truncated_trials"]),
      ]
    })
}

private func failureLines(_ trials: [JSON], language: ReportLanguage) -> [String] {
  let failures = Dictionary(
    grouping: trials.filter { $0["failure_reason"] != .null },
    by: { $0["failure_reason"].text })
  return failures.isEmpty
    ? [language.text("- 失敗は記録されていません。", "- No failures were recorded.")]
    : failures.keys.sorted().map { "- \(markdownCode($0)): \(failures[$0]!.count)" }
}

func reportMarkdown(_ input: ReportMarkdownInput) -> String {
  var lines = [input.language.text("# LLMベンチマークレポート", "# LLM Benchmark Report")]
  appendMarkdownSection(
    &lines, language: input.language, japanese: "実行環境", english: "Environment",
    body: environmentTable(input.manifests, language: input.language))
  let warnings = warningLines(input.manifests)
  if !warnings.isEmpty {
    appendMarkdownSection(
      &lines, language: input.language, japanese: "警告", english: "Warnings", body: warnings)
  }
  appendMarkdownSection(
    &lines, language: input.language, japanese: "実行状況", english: "Run progress",
    body: progressTable(
      input.manifests, recordedTrials: input.recordedTrials, language: input.language))
  appendMarkdownSection(
    &lines, language: input.language, japanese: "比較結果", english: "Comparison",
    body: comparisonTable(input.summary, language: input.language))
  appendMarkdownSection(
    &lines, language: input.language, japanese: "カテゴリ別結果", english: "Results by category",
    body: categoryTable(input.categories, language: input.language))
  let candidates = localCandidates(
    input.manifests, summary: input.summary, selection: input.selection,
    language: input.language)
  appendMarkdownSection(
    &lines, language: input.language, japanese: "ローカル候補", english: "Local candidates",
    body: candidates)
  appendMarkdownSection(
    &lines, language: input.language, japanese: "失敗内訳", english: "Failures",
    body: failureLines(input.trials, language: input.language))
  appendMarkdownSection(
    &lines, language: input.language, japanese: "解釈上の注意", english: "Interpretation notes",
    body: interpretationNotes(input.manifests, language: input.language))
  return lines.joined(separator: "\n") + "\n"
}

func compactNumber(_ value: Double) -> String {
  value.rounded() == value && abs(value) < 1e15 ? String(format: "%.0f", value) : String(value)
}

private func recommendation(
  _ host: String, manifests: [JSON], summary: [JSON], selection: SelectionSettings,
  language: ReportLanguage
) -> String {
  let measured = summary.filter {
    $0["host_id"].string == host && $0["inference_location"].string == "local"
      && $0["cache_condition"].string == "warm" && ($0["attempted_trials"].double ?? 0) > 0
  }
  let eligible = measured.filter {
    hasCompleteSchedule($0, manifests: manifests, summary: summary) && passesGates($0, selection)
  }.sorted { rankedBefore($0, $1) }
  let hostLabel = markdownCode(host)
  guard let best = eligible.first else {
    return "- \(hostLabel): "
      + (measured.isEmpty
        ? language.text(
          "warm条件のローカル測定値がありません。", "No local measurements are available for the warm condition.")
        : language.text(
          "選定基準をすべて満たすローカル候補はありません。", "No local candidate meets all selection criteria."))
  }
  let cloud = summary.filter {
    $0["host_id"].string == host && $0["inference_location"].string == "remote"
      && $0["pass_rate"].double != nil
      && hasCompleteSchedule($0, manifests: manifests, summary: summary)
  }.sorted { rankedBefore($0, $1, cloud: true) }
  var gap = ""
  if let cloudBest = cloud.first, let rate = cloudBest["pass_rate"].double {
    let difference = String(format: "%+.1f", ((best["pass_rate"].double ?? 0) - rate) * 100)
    gap = language.text(
      "、クラウド最高合格率との差 \(difference)ポイント",
      ", gap to the best cloud pass rate \(difference) percentage points")
    // The local pick passed the gates, which allow no timeouts; only the reference can have any.
    if let cloudTimeouts = cloudBest["timeout_trials"].uint, cloudTimeouts > 0 {
      gap += language.text(
        "（参照のタイムアウト \(cloudTimeouts)件。合格率の分母に含む）",
        " (reference timeouts: \(cloudTimeouts); included in pass-rate denominator)")
    }
  }
  let label = targetLabel(best, table: false)
  let rate = percent(best["pass_rate"])
  let speed = formatted(best["median_output_tokens_per_second"], 1)
  return language.text(
    "- \(hostLabel): \(label)。合格率 \(rate)、中央値 \(speed) tok/s\(gap)。",
    "- \(hostLabel): \(label). Pass rate \(rate), median \(speed) tok/s\(gap).")
}

private func localCandidates(
  _ manifests: [JSON], summary: [JSON], selection: SelectionSettings,
  language: ReportLanguage
) -> [String] {
  let hosts = Set(summary.map { $0["host_id"].text }).sorted()
  var candidates = hosts.map {
    recommendation(
      $0, manifests: manifests, summary: summary, selection: selection,
      language: language)
  }
  candidates += [
    "",
    language.text(
      "自動選定はwarm条件のローカル行を対象とし、予定された全タスク・反復・キャッシュ条件が記録され、関連する実行がcompletedで、warm条件にスキップされた試行がない候補に限ります。",
      """
      Automatic selection considers only local warm-condition rows and requires every scheduled task, repeat, and cache condition to be recorded, all \
      relevant runs to be completed, and no skipped trials in the warm condition.
      """
    ),
  ]
  let rate = percent(.number(selection.minimumPassRate))
  let minimumSpeed = formatted(.number(selection.minimumMedianTokensPerSecond), 1)
  let swap = compactNumber(selection.maximumPeakSwapDeltaGib)
  let fraction = compactNumber(selection.maximumBackendMemoryFraction)
  candidates.append(
    language.text(
      "選定基準: 合格率 \(rate)以上、タイムアウトなしで生成速度中央値 \(minimumSpeed) tok/s以上、試行ピークのスワップ増分の最大 \(swap) GiB以下。指標が取得できない候補は自動選定しません。",
      """
      Selection criteria: pass rate at least \(rate), no timed-out trial and median generation speed \
      at least \(minimumSpeed) tok/s, and maximum per-trial peak swap growth at most \(swap) GiB. \
      Candidates with missing metrics \
      are not selected automatically.
      """
    ))
  let rssPercent = formatted(.number(selection.maximumBackendMemoryFraction * 100), 2)
  candidates.append(
    language.text(
      "試行ピークのバックエンドRSS p90上限: ホストメモリの \(rssPercent)%以下（設定比率 \(fraction)）。",
      "Per-trial peak backend RSS p90 limit: at most \(rssPercent)% of host memory (configured fraction \(fraction))."
    ))
  return candidates
}

private func interpretationNotes(_ manifests: [JSON], language: ReportLanguage) -> [String] {
  var notes = reportNotes.map { language.text($0.0, $0.1) }
  for (key, japanese, english) in [
    (
      "repeat", "- 実行間でrepeatが異なります。対象ごとの試行数を確認して合格率を比較してください。",
      "- Runs use different repeat counts. Compare pass rates alongside each target's trial count."
    ),
    (
      "cache_conditions", "- 実行間でcache_conditionsが異なります。同じキャッシュ条件の行を比較してください。",
      "- Runs use different cache_conditions. Compare rows with the same cache condition."
    ),
  ] {
    let values = manifests.map { manifest -> String in
      let value = manifest["run_settings"][key]
      return key == "cache_conditions"
        ? (value.array ?? []).map { $0.serialized() }.sorted().joined(separator: ",")
        : value.serialized()
    }
    if Set(values).count > 1 { notes.append(language.text(japanese, english)) }
  }
  return notes
}
