# cursor-agent skill

An [Agent Skill](https://agentskills.io) for driving [`cursor-agent`](https://cursor.com/docs/cli/overview) (the Cursor CLI) non-interactively, so a host agent can delegate coding or investigation to Cursor and judge the result without a human relaying prompts.

`SKILL.md` is written for the agent. This file is for the human installing it.

## What it covers

`cursor-agent --help` lists the flags. This skill covers what the help does not: the behavior measured by actually running it.

- A preflight gate that stops the procedure when the CLI is missing or logged out, rather than silently doing the work another way
- Choosing a safety envelope — read-only (`--mode plan --sandbox enabled`) or a real implementation run
- Reading `stream-json`, including the plan body that never reaches the `result` event
- Judging success by `is_error`, not by the exit code
- Resuming a session instead of paying for a fresh one
- Five measured pitfalls that produce silent failures

## Layout

```
cursor-agent/
├── SKILL.md                  the instructions the agent reads
├── assets/
│   └── prompt-template.md    skeleton for the delegated task
└── scripts/
    ├── preflight.sh          check everything that can abort, before anything expensive
    ├── new-run.sh            create a scratch dir for one delegation
    ├── collect-rules.sh      collect the .cursor/rules that apply to given paths
    └── summarize-run.sh      report a run's outcome; exit code carries the verdict
```

## Requirements

- `cursor-agent`, installed and logged in (`curl https://cursor.com/install -fsS | bash`, then `cursor-agent login`)
- `bash`, `jq`, `git`, and the usual POSIX tools

The commands in `SKILL.md` reference `${CLAUDE_SKILL_DIR}`, which Claude Code substitutes with this directory. On a host that does not provide that variable, substitute the path yourself.

## Verification status

Measured against **cursor-agent 2026.07.23 on Linux (WSL2), bash 5.2**. Every behavioral claim in `SKILL.md` was observed on that setup, and the skill itself was iterated with blank-slate executor runs across implementation, plan-only, and abort scenarios.

Not verified:

- **macOS** — the scripts avoid bash 4.0+ syntax and should run under the bundled bash 3.2, but this has not been executed
- **Windows outside WSL** — `mktemp -d` behavior and path handling under Git Bash are untested
- **Non-English locales** — the preflight gate matches the string `Logged in` in `cursor-agent status` output

The pitfalls describe a moving target. Cursor may change any of them; re-measure before trusting them on a newer CLI build.
