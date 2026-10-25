// Interpretation notes retained in both report languages.
let reportNotes: [(String, String)] = [
  (
    "- RSSの選定には試行ピークのp90を、スワップ増分の選定には最大値を使い、どちらの最大値とp90もCSVに残します。スワップ増分はシステム全体の値で、他プロセスの影響も含むため、除外された候補は再計測で確認してください。RSSのp90は孤立した外れ値を許容するため、最大値と実利用時の挙動も確認してください。",
    """
    - The RSS gate uses the p90 of per-trial peaks and the swap gate uses the maximum; CSV retains both \
    maxima and p90. Swap growth is system-wide and includes other processes, so re-measure a candidate \
    it excluded. RSS p90 tolerates isolated outliers; inspect maxima and behavior under real workloads too.
    """
  ),
  (
    "- 打ち切りはfinish_reasonがlength、max_tokens、max_output_tokens（大文字小文字は区別しない）の試行数です。出力上限で推論や回答が途中で切れることがあるため、低いスコアと併せて確認してください。",
    """
    - Truncated counts trials with finish_reason=length, max_tokens, or max_output_tokens \
    (case-insensitive). The output limit can cut off reasoning or the answer; inspect this alongside \
    low scores.
    """
  ),
  (
    "- 参照エージェントには製品固有のシステムプロンプトと文脈処理が含まれるため、「クラウド最高合格率との差」は製品差を含む参考値です。",
    """
    - Reference agents include product-specific system prompts and context handling, so the gap to the \
    best cloud pass rate is a reference value that also reflects product differences.
    """
  ),
  (
    "- `provider-managed`はクラウド側キャッシュを制御できないため、ローカルのcold/warmと直接比較しません。",
    """
    - The cloud cache cannot be controlled for `provider-managed` runs; do not compare them directly \
    with local cold/warm conditions.
    """
  ),
  (
    "- tok/sは参照エージェントでは測定対象外のため常にn/aです。Ollamaの出力トークンが2未満、または出力トークン数・生成時間が返されない場合は-です。CSVではどちらも空欄で、adapter列で区別します。推定値では補完していません。",
    """
    - Reference-agent tok/s is always n/a (not applicable). For Ollama, - means fewer than two output \
    tokens, or no token count or generation time, was reported. Both are blank in CSV; use the adapter column to distinguish \
    them. Missing values are not estimated.
    """
  ),
  (
    "- Ollamaと定額の参照エージェントに試行ごとの料金は設定していません。",
    "- No per-trial price is assigned to Ollama or subscription reference agents."
  ),
  (
    "- バックエンドRSSとモデルメモリは定義が異なります。Apple Siliconでは両方とも同じユニファイドメモリを消費し得ます。",
    """
    - Backend RSS and model memory have different definitions. Both can consume the same unified memory \
    on Apple Silicon.
    """
  ),
  (
    "- 異なるスイート SHA-256、解決済みモデル名、量子化、コンテキスト長の結果は同一条件として扱わないでください。",
    """
    - Results with different suite SHA-256 hashes, resolved model names, quantization, or context \
    lengths must not be treated as identical conditions.
    """
  ),
  (
    "- 「未コミット変更」が「あり」の実行は同じGitリビジョンでも実装差を否定できません。最終資料はコミット済みの状態で取り直してください。",
    """
    - Runs with `Dirty` set to yes may use different implementations even at the same Git revision. \
    Repeat final measurements from a committed working tree.
    """
  ),
]
