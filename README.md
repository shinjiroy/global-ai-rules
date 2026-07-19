# global-ai-rules

私専用のAIに関するルール
PCを買い替えたり、会社用のPCにも同じルールを追加する時に使うためにここにまとめている

- Cursor
- Claude Code
- Claude（Desktop） ※対話用

に対応

## Claude Code スキル

`claude_code/skills/` を原本として Claude Code 用のスキルを管理する。**編集は必ずこのリポジトリ側で行い**、`~/.claude/skills/` にはコピーして配置する(シンボリックリンクは張らない)。原本を直したら再度コピーして反映する。

```bash
# リポジトリルートで実行。既存の他スキルは残したまま goal-authoring 等を配置/更新する
cp -r claude_code/skills/. ~/.claude/skills/
```

- `goal-authoring` — 計画セッションで実行可能なGOAL.mdと検証コードを作り、別セッションで `/goal` に食わせて回す2フェーズ運用の、計画フェーズを支援する
