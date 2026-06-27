# Agent Harness M2

<important>
## 入口の門（必須・4 ゲート）

ユーザーがタスクを出したら、ファイルの読み書き・コマンド実行・コミットの前に、
この順でスキルを実行する:

1. `/branch` — `main`/`master` を離れ、ユーザーの指示原文を最終的な Git コミット本文に保存する。
2. `/map` — いきなり実装せず、現在の構造・入口・依存・既存パターン・スコープ境界・危険な文脈を把握する。
3. `/translate` — コードに触る前に、ユーザーの言葉を明示的なエンジニアリング作業へ翻訳し、**`scope.files` を明示宣言する**。
4. `scope-guard` — （hook 自動）`scope.files` 外の Edit/Write を block。スコープ外を触りたくなったら `/translate` を再実行してスコープを更新する。**黙って広げない**。

リクエストが明白に見えてもこの門をスキップしない。
`UserPromptSubmit` hook が毎ターンこのルールを繰り返す。

### bypass を防ぐ構造

各スキルの完了は `.agent-harness/.gates/<name>.done` という **platform-signed sentinel** で記録される。
これは `PostToolUse(Skill)` hook がプラットフォーム側で発火して書くため、通常の Edit/Write や JSON の `phase` 書き換えでは偽造できない。
`current-task.json` の `phase` 欄を AI が直接書き換えても、sentinel が無ければ guards は通さない。
`.gates/` ディレクトリへの shell/Edit/Write は `bash-protect` / 各 guard が block する。
ただし M2 は OS sandbox ではない。shell/interpreter での直接書き込みや hook の無効化までは止められないため、これは「偽造を不可能にする」ものではなく **tamper-evident な protocol** として扱う（詳細は `docs/technical-notes.md`）。
</important>

## 整地の原則

> **リポジトリは現在の正しい状態だけを表す。歴史は git / PR / issue / ADR が持つ。**
> 「保全」を名目に古いコード・未使用ファイル・コメントアウト実装・古いメモを残さない。
> 今も判断に要る文脈は、残骸でなく **「現在形の理由」** として 1 行で残す。不要なら消す。

## 禁止事項

- `main` / `master` への直接コミット
- `git add -A` / `git add .` / `git add *` による一括追加（`.env` 等の混入防止）
- `--no-verify` での commit/push フック回避
- ユーザー承認なしの force push、reset --hard、branch -D
- `.env` / 鍵ファイル / 認証情報のコミット
- 「念のため」で古いコード・未使用ファイル・コメントアウト実装を残すこと（履歴は git にある）

## 出力

門の出力は短く:

```text
/branch: <branch> ready; prompt will be preserved in commit body
/map: map built; <地図サマリ> / clean
/translate: <scope summary>; scope.files recorded
scope-guard: <enforced silently by hook>
```

## 参考

- Claude Code: https://code.claude.com/docs
- Codex: https://developers.openai.com/codex
