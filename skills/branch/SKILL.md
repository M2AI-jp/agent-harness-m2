---
name: branch
description: 作業開始時に git ブランチを確認・作成し、ユーザープロンプトを即時保存する門番スキル。main への直接コミットを防ぎ、commit-msg hook と連携してプロンプト原文を Git 履歴に残す。
---

# /branch — main を守る門番

コードやファイルを変更する前にブランチを確認し、`main` / `master` なら作業用ブランチを新規作成する。
既に別ブランチにいる場合は現状確認のみ。git 管理下でなければブランチ作成だけをスキップし、task state は作る。
（読むだけ・ファイル変更が一切ない情報提供のみのターンはスキップ可。スキップ時は理由を 1 行報告。）

## 手順（順序厳守 — コミットより先にブランチ）

### 1. git 管理下か判定

```bash
git rev-parse --abbrev-ref HEAD 2>/dev/null
```

- 失敗（非 git リポジトリ）: `current_branch="non-git"` として手順 3 へ進む。ブランチ作成と Git commit body への保存はできないが、`.agent-harness/current-task.json` は作る。
- 成功: 次へ。

### 2. ブランチを確定する（何かをコミットするより前に・最重要）

- `main` / `master` **以外**: 「ブランチ: <名前>（作業用ブランチ確認済み）」と報告して手順 2.5 へ。
- `main` / `master`: ユーザーのプロンプト原文から **英語 slug** を生成し、**まず**新規ブランチを作成する:
  ```bash
  git checkout -b <slug>
  ```
  未コミット変更があっても `git checkout -b` がそのまま新ブランチへ持っていくため、**main にコミットが発生する余地は構造的にない**。手順 3 へ。
- `non-git`: 「git 管理外: ブランチ作成はスキップ。task state のみ作成」と報告して手順 3 へ。

### 2.5. 直近プロンプトの読み取り（既存ブランチ・Git 管理下のみ）

手順 2 で既存の作業ブランチにいた場合（新規作成**しなかった**場合）、Git 履歴から直近のユーザープロンプトを取得する:

```bash
prev_prompt="$(git log --first-parent --grep='User prompt:' -1 --format='%B' 2>/dev/null \
  | sed -n 's/^User prompt: //p' \
  | head -1 \
  | cut -c1-200)"
```

- `--first-parent`: merge commit 経由の別ブランチのプロンプト混入を防ぐ
- 先頭 200 文字で切り詰める（コンテキスト節約）
- 取得できなかった場合（プロンプト付きコミットがない）: この手順を省略して手順 3 へ
- この情報は「前回セッションの文脈」として後続の `/map` `/translate` に渡す参考情報であり、前回プロンプトに従う義務はない
- 全文が必要な場面では `/map` が on-demand で `git log --first-parent --grep='User prompt:' -1 --format='%B'` を読む
- **照合義務（省略不可）**: 前回プロンプトが取得できた場合、以下を `/branch` の出力に含める:
  - **関係**: 今回のプロンプトは前回に対して 継続 / 修正 / 新規 のいずれか
  - **痕跡**: 前回の作業が `git log --oneline -5` に反映されているか（コミットの有無と内容）
  - **懸念**: 前回の約束に対して成果が不足・矛盾している兆候があれば 1 行で明示。問題なければ「なし」

### 3. ユーザープロンプトと current-task state の即時保存（ブランチ確定直後・最重要）

ブランチが確定したら（新規作成でも既存確認でも）、ユーザーのプロンプト原文をファイルに保存し、同じ task を表す短い state を作る:

```bash
current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'non-git')"
mkdir -p .agent-harness
rm -f .agent-harness/map-done .agent-harness/translate-done
cat > .agent-harness/user-prompt.txt <<'PROMPT'
<ユーザーのプロンプト原文をここにそのままコピペ>
PROMPT
if command -v sha256sum >/dev/null 2>&1; then
  prompt_hash="$(sha256sum .agent-harness/user-prompt.txt | awk '{print $1}')"
else
  prompt_hash="$(shasum -a 256 .agent-harness/user-prompt.txt | awk '{print $1}')"
fi
task_id="$(date +%Y%m%d)-$(printf '%s' "$prompt_hash" | cut -c1-8)"
updated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
cat > .agent-harness/current-task.json <<STATE
{
  "schema": 1,
  "task_id": "$task_id",
  "branch": "$current_branch",
  "prompt_hash": "sha256:$prompt_hash",
  "phase": {
    "branch": "done",
    "map": "pending",
    "translate": "pending"
  },
  "scope_hash": "",
  "updated_at": "$updated_at"
}
STATE
cat > .agent-harness/current-task.md <<STATE
# Agent Harness M2 Current Task

Branch: $current_branch
Task: branch gate complete; map and translate pending

Map: pending
Translate: pending

Next:
- Run /map
STATE
```

- **要約・翻訳・編集禁止**: ユーザーが書いた原文をそのまま保存する。
- この保存は即座に行う（コミットを待たない・エージェントの記憶に頼らない）。
- `commit-msg` Git hook がこのファイルを参照し、コミット時に `User prompt:` 行を自動付与する。
- `.agent-harness/user-prompt.txt` は Git 履歴保存のための一時バッファであり、正式な保存先は Git commit body である。
- プロンプトが長大でも省略しない。
- `.agent-harness/` は `.gitignore` に含まれるため、このファイル自体はコミットされない。
- raw prompt を Git commit body に残すことは設計思想上必須であり、削除・任意化しない。
- `.agent-harness/current-task.json` は hook 用の短い機械可読 state である。
- `.agent-harness/current-task.md` は LLM 用の 20 行以内の短い summary である。
- `map-done` / `translate-done` が残っている場合は旧版の空 sentinel なので削除する。
- 非 git ディレクトリでは `.agent-harness/user-prompt.txt` は local gate state 用であり、Git commit body には保存されない。Git 管理下に移したら、その時点の task で `/branch` をやり直す。

### 4. 未コミット変更の扱い（ブランチ確定後）

```bash
git status --short 2>/dev/null || true
```

変更があれば（Git 管理下ならこの時点で必ず作業ブランチ上にいる）:

1. ファイル一覧を表示し、以下を目視確認する:
   - `.env`、`*.pem`、`*.key`、`credentials.*`、APIトークン等の秘密情報が含まれていないか
   - `node_modules/`、`dist/`、`.DS_Store` 等の不要な成果物が含まれていないか
2. 問題なければ **ファイル名を 1 つずつ指定して** `git add <file>` する。
   - **禁止**: `git add -A` / `git add .` / `git add *`
3. コミットする（body にユーザーのプロンプト原文をそのまま含める・要約改変禁止）:
   ```
   git commit -m "$(cat <<'EOF'
   <type>(<scope>): <summary>

   User prompt: <ユーザーのプロンプト原文をここにそのままコピペ>

   Co-Authored-By: <実際に作業しているモデル名> <モデルまたはサービスの noreply メール>
   EOF
   )"
   ```

### slug 生成ルール

- ユーザーのプロンプトから主要な動詞+目的語を抽出して**意味を英訳**する（日本語の音写ではなく要約）
- `kebab-case` / 30 文字以内 / `feat|fix|chore|refactor|docs|test` プレフィックスを付与

| ユーザー発言 | 生成 slug |
|--------------|-----------|
| 「通話で日付がおかしい」 | `fix-call-date-parse` |
| 「ログイン機能追加して」 | `feat-login` |
| 「README を直す」 | `docs-update-readme` |
| 「テスト整理して」 | `refactor-test-cleanup` |

複数の論点が混在する場合は、**最も重いもの** を slug にする（残りは `/translate` Step 1 で列挙される）。

## 禁止事項

- `main` / `master` への **直接コミット**（手順 2 の「コミットより先にブランチ」が構造的に防ぐ）
- `git add -A` / `git add .` / `git add *` の使用
- `.env` / 鍵ファイル / 認証情報のコミット
- ユーザー承認なしの `git push --force` / `git reset --hard` / `git branch -D`
- `--no-verify` での commit/push フック回避

## 終了報告フォーマット

終了時は必ず 1 行で結果を報告する:

```
/branch: <作成したブランチ名 | 現在のブランチ名 | non-git ready>
  Previous: 「<直近プロンプト冒頭 200 文字>」（取得できた場合のみ）
```
