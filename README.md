# Agent Harness M2

Agent Harness M2 は、Claude Code / Codex 用の最小限の project-local pre-work harness です。
M3 core is a pre-work harness:

```text
/branch -> /map -> /translate -> scope-guard
```

AI がコードに触る前に、作業ブランチ・既存構造・依頼内容・編集可能範囲を明確にします。
Less approval, not more autonomy: M3 は、人間の確認回数を減らすために、AI の作業前ループを制御します。

---

## 何を防ぐのか

たとえば、ユーザーがこう頼んだとします。

```text
ChatGPT みたいな画面を作って
```

この依頼は、そのままでは曖昧です。

* UI だけなのか、API 連携まで必要なのか
* ストリーミング応答が必要なのか
* ログインが必要なのか
* チャット履歴を保存するのか
* 既存 UI コンポーネントを使うのか
* 既存ルーティングにどう入れるのか
* 触ってはいけない範囲はどこか

M2 は、いきなり実装に入らせません。
AI の自由度を広げるのではなく、依頼原文・既存構造・解釈・編集範囲を固定してズレにくくします。

まず `/branch` で作業場所を分けます。
次に `/map` で既存構造を確認します。
3 つ目に `/translate` で曖昧な依頼を具体的な作業に落とします。
最後に `scope-guard` が、`/translate` で宣言した `scope.files` の外側を編集させない境界になります。

---

## 対象ユーザー

### おすすめ

* Claude Code / Codex に、最低限の安全確認を入れたい
* デフォルトのまま AI に実装させるのが不安
* 個人開発や小さなリポジトリで、Agentic coding 環境を整えたい

### 合わないかもしれない

* eval / test / review / post-work workflow まで一体化したフルワークフローが欲しい
* チーム全体の開発ルール、レビュー制度、ブランチ戦略まで一括で管理したい
* `CLAUDE.md` / `AGENTS.md` / hooks を変更したくない
* すでに別の agent harness が settings / hooks / skills / Git hooks を管理している

---

## 4 ゲート

```text
M3 core is a pre-work harness:
  /branch -> /map -> /translate -> scope-guard
```

### 1. branch

`/branch` は、AI にいきなり原本を触らせないためのステップです。

`main` / `master` は、リポジトリの基準になるブランチです。
AI に直接編集させるのではなく、作業用ブランチで変更させます。

あわせて、ユーザーの依頼原文を `.agent-harness/user-prompt.txt` に保存します。

Git の `commit-msg` hook はこのファイルを読み、コミット本文に `User prompt:` として自動付与します。
すでに `User prompt:` がある場合は二重付与しません。

`.agent-harness/user-prompt.txt` は、Git 履歴に残すための一時バッファです。
正式な保存先はコミット本文です。
`.agent-harness/` は `.gitignore` 対象なので、中継ファイル自体は Git に入りません。
raw prompt を Git commit body に残すことは M2 の設計上必須であり、削除したり任意化したりしません。

> **警告:** raw prompt はそのまま Git のコミット本文（履歴）に残ります。API キー・認証情報・社内 URL・顧客データ・ログ断片など、履歴に残したくない情報をプロンプトに含めないでください。

新しいタスクを始めるときは、前回の完了状態を持ち越さないように、短い task-aware state を作ります。

```text
.agent-harness/current-task.json
.agent-harness/current-task.md
```

`current-task.json` は hook 用です。branch、prompt hash、`map` / `translate` の phase だけを持ちます。
`current-task.md` は AI が読む短い summary です。作業範囲と次にやることを 20 行以内で残します。
旧版の `map-done` / `translate-done` が残っていれば削除します。

### 2. map

`/map` は、いきなり作らせないためのステップです。
実装前に、作業対象を次の観点で確認します。

* 現在地
* 入口
* 依存
* 既存パターン
* 触らない場所
* 危険な文脈

`old`、`backup`、`archive`、`tmp`、`legacy` のような名前は stale context 候補として扱います。
古い残骸を、現在の正しい仕様として読まないためです。

また、現在の working tree が `continue` / `commit-candidate` / `push-candidate` / `merge-candidate` のどれに見えるかも軽く surface します。
これは自動 commit / push / merge ではなく、作業単位を大きくしすぎないための注意喚起です。

完了時に、`current-task.json` の `phase.map` を `done` にします。

```text
.agent-harness/current-task.json
```

`map-guard` は、空 sentinel ファイルではなく、この state が現在の branch / prompt と一致し、`map` が完了しているかを見ます。

### 3. translate

`/translate` は、曖昧な依頼をそのまま実装させないためのステップです。
たとえば、次のような言葉をそのまま進めないようにします。

* ChatGPT みたいな
* いい感じに
* 全部チェックして
* 使いやすくして
* それっぽく

`/translate` は `/map` の結果を使い、依頼を具体的な作業に落とします。

変更を伴う場合は、論点を整理し、ソフトウェアエンジニアリング上の作業に変換し、リポジトリ上の具体箇所へ紐付けます。
完了時に、`current-task.json` の `phase.translate` を `done` にし、`current-task.md` に scope / out of scope / next を短く残します。

```text
.agent-harness/current-task.json
.agent-harness/current-task.md
```

`translate-guard` は、空 sentinel ファイルではなく、この state が現在の branch / prompt と一致し、`translate` が完了しているかを見ます。

### 4. scope-guard

`scope-guard` は、`/translate` が記録した `scope.files` の外側への Edit / Write を block する 4 番目のゲートです。
新しいファイルは、`/translate` が `scope.new_files_allowed` を明示した場合だけ許可します。

`scope-guard` は agent が実行する skill ではなく、hook が静かに適用する実効境界です。
スコープ外を触る必要が出たら、黙って広げずに `/translate` を再実行して `scope.files` を更新します。

---

## GitHub workflow（検知・推奨のみ）

`/map` may surface `push-candidate` or `merge-candidate` states, but this is detection only.
M3 does not commit, push, open PRs, merge, or sync local main as part of core behavior.

GitHub workflow は M3 core の外側です。`/map` は候補状態を検知・推奨しますが、commit / push / PR / merge / local sync は実行しません。

---

## インストール

*もし開発に不慣れなら、この GitHub の URL をそのまま AI エージェントに提供してください。*

### Claude Code

```bash
bash scripts/install-claude.sh /path/to/your/repo
```

### Codex

```bash
bash scripts/install-codex.sh /path/to/your/repo
```

### 導入確認

```bash
bash scripts/doctor.sh /path/to/your/repo
```

`doctor.sh` は導入先リポジトリの install state を確認する、Agent Harness M2 独自の診断スクリプトです。
Claude Code 組み込みの `/doctor` とは別物です。

---

## どこに入るか

Agent Harness M2 は project-local install です。
指定したプロジェクトでのみ機能します。
installer は hook 設定に導入先の絶対 hook パスを書き込むため、`dev/` のような上位作業ディレクトリに入れた場合でも、その設定が読み込まれる子ディレクトリから同じ hook を呼べます。

`~/.claude` のようなグローバル設定には書き込みません。
他のプロジェクトにも影響しません。

Git 管理外ディレクトリでは `/branch` は実ブランチを作れず、ユーザープロンプトも Git commit body には保存されません。
その場合も `.agent-harness/current-task.json` は作り、後続の `/map` / `/translate` guard が成立するようにします。

## この repo の canonical source

この配布 repo で編集する canonical files は次の範囲です。

```text
skills/
hooks/
templates/
scripts/
docs/
README.md
```

`.claude/` / `.codex/` / `.agents/skills/` は installer が導入先 repo に生成する installed copy です。
この配布 repo では追跡しません。
installed copy を repo に持たないことで、canonical source との drift を避けます。

root の `CLAUDE.md` / `AGENTS.md` は、この repo 自体を dogfooding するための managed instruction です。
canonical template は `templates/claude/CLAUDE.md` と `templates/codex/AGENTS.md` です。

---

## 注意

M2 は OS レベルのサンドボックスではありません。

`Edit` / `Write` / `apply_patch` 系の操作は project-local hook で止めますが、`Read` / `Bash` / 外部操作を完全に禁止するものではありません。

また、M2 は eval runner ではありません。
作業結果の正しさは、導入先プロジェクトのテスト、CI、レビュー、人間判断に任せます。

Claude Code / Codex の hooks、skills、memory、instruction file、trust の正確な挙動は、各公式ドキュメントを正としてください。

* Claude Code: https://code.claude.com/docs
* Codex: https://developers.openai.com/codex

Claude Code / Codex の memory は、M2 とは別経路で文脈に入ることがあります。
厳密に検証したい場合は、公式ドキュメントに従って memory の使用状況を確認してください。

---

## 他のハーネスとの併用

M2 は既存 harness との併用を主目的にしていません。

すでに別の harness が次のファイルやディレクトリを管理している repo では、M2 の導入は基本的に非推奨です。

```text
.claude/settings.json
.codex/hooks.json
.claude/hooks/
.codex/hooks/
.claude/skills/
.agents/skills/
.git/hooks/commit-msg
```

installer は既存ファイルの backup を作りますが、既存 hook graph を安全に merge するものではありません。
複数の `PreToolUse` hook、hook の実行順、skill 名の衝突、Git `commit-msg` hook の上書きは、導入先ごとに判断が必要です。

既存 harness がある場合は、M2 を重ねて入れるのではなく、既存 harness 側に `/branch -> /map -> /translate -> scope-guard` の考え方だけを取り込むことを推奨します。

M2 が最も向いているのは、まだ agent harness が入っていない個人開発・小規模 repo です。

詳しくは `docs/technical-notes.md` を参照してください。

---

## なぜ eval を入れていないか

M2 は eval runner ではありません。
eval / test / review はプロジェクトごとに正解が違います。
Web UI、API、CLI、LLM agent、データ処理、社内ツールでは、必要な検証方法が変わります。

M2 が eval まで抱えると、既存 CI やテスト設計と衝突しやすくなります。
そのため、M2 は作業前の 4 ゲートに絞っています。

* 作業場所は安全か
* 既存構造を把握したか
* 依頼を具体作業へ翻訳したか
* 翻訳した scope の外側を編集していないか

作業結果の正しさは、既存のテスト、CI、レビュー、人間判断に任せます。

---

## 設計思想

M2 は、新しい AI モデルでも、eval runner でもありません。
Claude Code / Codex の hooks、skills、instruction file、Git hook を組み合わせて、AI がコードに触る前の入口手順を作るためのハーネスです。
やることは小さく、効果は大きいです。

```text
branch で作業場所を分ける
map で既存構造を見る
translate で曖昧な依頼を具体化する
scope-guard で scope.files の外側を止める
それ以上はやらない
```

---

## License

MIT
