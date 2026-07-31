---
name: cursor-agent
description: Run cursor-agent (Cursor CLI) non-interactively to delegate investigation or implementation work. Use whenever the task is to drive Cursor from the command line — "have Cursor implement this", "run it through cursor-agent", "delegate to the Cursor CLI", "let Cursor plan it in plan mode". 日本語でも発動する: 「Cursorに実装させて」「cursor-agentで回して」「CursorをCLIで叩いて」「Cursorに委譲して」「plan modeで調べさせて」。Covers the preflight gate that must pass before any delegation, building the command, choosing a safety envelope (plan mode / sandbox), reading stream-json output, detecting failures, and resuming sessions. Not for driving the Cursor editor by hand, and not for orchestrating the host agent's own subagents.
allowed-tools: Bash(cursor-agent:*), Bash(jq:*), Bash(mktemp:*), Bash(command:*), Bash(grep:*), Bash(tee:*), Bash(git:*), Read, Write
model: sonnet
effort: low
---

# Driving cursor-agent non-interactively

`cursor-agent` is expensive per run, has real side effects, and signals failure in its output stream rather than in its exit code. The full flag list is in `cursor-agent --help`; this skill covers only the measured behavior that `--help` does not tell you, plus the procedure around it.

## Preflight gate

Run this once per session, before the first invocation. **It is a hard gate: if it fails, stop and report — do not attempt the delegated work by other means, and do not install or authenticate on the user's behalf.**

```bash
command -v cursor-agent >/dev/null || { echo "NOT_INSTALLED: not on PATH"; exit 1; }
STATUS=$(cursor-agent status 2>&1)
grep -q "Logged in" <<<"$STATUS" || { echo "NOT_LOGGED_IN: $STATUS"; exit 1; }
echo "GATE_OK: $(command -v cursor-agent) / $STATUS"
```

Match on the output, not the exit status: `cursor-agent status` exits 0 even when logged out. The gate carries its own evidence (path, raw status text) so a failure can be reported to the user without a second diagnostic round.

- `NOT_INSTALLED` — tell the user to install it: `curl https://cursor.com/install -fsS | bash` (lands in `~/.local/bin/cursor-agent`, which must be on `PATH`). Then stop.
- `NOT_LOGGED_IN` — tell the user to run `cursor-agent login`. It opens a browser, so it cannot be done for them, and it cannot be done from a non-interactive session. Then stop.

Both are the user's decision to make: installing software and authenticating an account are not steps to take unattended. Report which check failed and what the user should run, then end your turn — do not block waiting for input.

## Basic invocation

Two invariants, whatever mechanism you use to satisfy them:

- The prompt reaches cursor-agent **on stdin**. As an argument, quoting breaks and long specs do not fit
- The prompt file and the stream log both live **outside the target repository at run-unique paths**. Inside the repo they appear as untracked files and destroy the `git status` check you need afterwards; a fixed name collides with the previous run

Assume every shell command runs in a **fresh process** — cwd resets and variables are lost between calls. So carry literal paths forward by hand and never rely on `cd`, in three steps.

**1. Create the scratch dir and read the path off the output.**

```bash
mktemp -d /tmp/ca-run-XXXXXX
# -> /tmp/ca-run-Ab12Cd        substitute this literal path for <RUN> below
```

**2. Write the delegated task to `<RUN>/prompt.md`.** A heredoc works; so does whatever file-writing tool your harness gives you. Content is covered in "Writing the prompt".

**3. Invoke, naming the target repository with `--workspace`.**

```bash
cursor-agent -p --trust --workspace <target repo> <envelope flags> --output-format stream-json \
  < <RUN>/prompt.md | tee <RUN>/ca.ndjson \
  | jq -r --unbuffered 'select(.type=="tool_call" and .subtype=="started") | .tool_call | to_entries[0].key'
```

`tee` writes the **complete** stream to `<RUN>/ca.ndjson` while `jq` shows live tool activity; the file — not the filtered console view — is the authoritative record every query in "Reading the result" runs against.

- Target the repository with `--workspace`, never by prefixing `cd <repo> &&`. A compound command defeats the host's per-command permission matching, so every run re-prompts; `--workspace` keeps the invocation a single `cursor-agent` command. Every `git` command in this skill likewise uses `git -C <target repo>`
- `<envelope flags>` comes from "Choose a safety envelope" below. Decide it before running; it is empty only for real implementation
- **Do not read `$?` after this pipeline** — it belongs to `jq`, not to cursor-agent. Judge the outcome from `is_error` (pitfall 2)
- `--trust` is required the first time you run in a directory (see pitfall 1)
- Default to `--output-format stream-json`. With `text` or `json` you lose tool activity and the plan body
- Do **not** pass `--model`. Respect the user's default in `~/.cursor/cli-config.json`. Override only with a reason, after checking `cursor-agent models`
- `--force` / `--yolo` are unnecessary: `-p` already grants file writes and shell access

## Choose a safety envelope

Decide this explicitly before dispatching work.

| Goal | Extra flags | Effect (all restrictions apply to the delegate process, never to your own shell) |
| --- | --- | --- |
| Investigate / plan only | `--mode plan --sandbox enabled` | The delegate makes no edits; its shell gets no network and cannot write outside the workspace |
| Real implementation | (none) | The delegate edits the workspace directly. Requires a clean working tree |

`--mode plan` alone still permits writes to `/tmp`. Pair it with `--sandbox enabled` when read-only actually matters. Your own commands are unaffected — teeing the log to a scratch dir outside the repo works, and the run still reaches the model over the network.

Before an implementation run, check the tree: **dirty := `git -C <target repo> status --porcelain` produces any output, untracked files included.** If it is dirty on arrival, take the abort path. Do not stash or revert it — afterwards you would have no way to separate the delegate's changes from the pre-existing ones, and the `git diff` verification becomes meaningless.

## Aborting

Three conditions stop the procedure: `NOT_INSTALLED`, `NOT_LOGGED_IN`, and a dirty tree before an implementation run. Every one of them ends the same way — report all three of the following, then end your turn without blocking for input:

1. Which check failed, with the evidence you observed
2. The exact action that unblocks it — `curl https://cursor.com/install -fsS | bash`, `cursor-agent login`, or the user's decision on the pre-existing changes
3. That the delegated work was not done by any other means

Never substitute your own implementation for a delegation that did not happen.

## Pitfalls (measured; absent from `--help`)

1. **In an untrusted directory nothing runs at all.** It exits 1 and emits no `result` event. `--trust` is needed only on the first run in a given directory — the decision persists — but keep it in scripts regardless.
2. **Always check `is_error`.** The exit code only catches startup failures (untrusted directory, invalid model → 1). Whether the agent's actual work failed appears only in the `result` event's `is_error`.
3. **In plan mode the plan body never reaches `result`.** It exists only inside `createPlanToolCall.args.plan`, so `text` and `json` output drop it entirely.
4. **`globs:`-scoped `.cursor/rules` load, but not dependably.** Across five otherwise identical runs one silently failed to attach, and when two rules declared the same glob only one of them ever attached. A rule the delegate must obey belongs in `alwaysApply: true` or `AGENTS.md`, which load on every run — or state it directly in the prompt.
5. **`~/.claude/skills` is loaded.** Global skills and instruction files written for other agents leak into every cursor-agent run — a delegate will happily propose tooling, conventions, or an output language that the target repository shows no trace of. Mitigate at dispatch time: state the repository's actual state in the prompt ("no package.json, no test runner, no linter") and tell the delegate to propose nothing the repo does not already use. Suspect this first when the delegate behaves strangely.

Loaded automatically: `AGENTS.md`, `CLAUDE.md`, `.cursor/rules` with `alwaysApply`, and the skills directories. Slash commands in `.cursor/commands/*.md` work under `-p` (`-p "/command-name"`).

An `@other-file.md` reference inside a rule or `AGENTS.md` is **not** expanded up front — the delegate resolves it by reading that file with a tool. A rule that is only a pointer therefore costs an extra read and is skipped entirely when the delegate has no reason to follow it. Inline what must not be missed.

## Reading the result

```bash
# Did it run at all? (0 means it never started — untrusted directory, etc.)
grep -c '"type":"result"' <RUN>/ca.ndjson

# Outcome and final message
jq -r 'select(.type=="result") | "is_error=\(.is_error)\ntokens=\(.usage.inputTokens)/\(.usage.outputTokens)\n\n\(.result)"' <RUN>/ca.ndjson

# Session id (needed to resume)
jq -r 'select(.type=="result") | .session_id' <RUN>/ca.ndjson

# Plan body in plan mode (recovers pitfall 3; emitted twice, so keep only "completed")
jq -r 'select(.type=="tool_call" and .subtype=="completed" and (.tool_call.createPlanToolCall != null))
       | .tool_call.createPlanToolCall.args.plan' <RUN>/ca.ndjson
```

`is_error=false` means the agent terminated normally — **not** that the work is correct. After delegating an implementation, verify with `git -C <target repo> status`, `git -C <target repo> diff`, and the repository's own tests. If the repository has no test runner, exercise the changed code directly from the scratch dir (a throwaway script under `<RUN>/`, never a file inside the repo) — an unverified diff is not a finished delegation.

Judge the delegate by its **artifacts** — the diff, the plan body, the files — never by its closing prose. The narration is where leaked global conventions surface (pitfall 5), so it can contradict the prompt even when the artifact obeys it.

## Resuming

To continue rather than redo, resume instead of starting fresh: the cached context cuts input tokens dramatically.

```bash
cursor-agent --resume <session_id> -p --trust --workspace <target repo> --output-format stream-json < <RUN>/followup.md
```

`--continue` resumes the most recent session. The interactive pickers (`cursor-agent ls`, `cursor-agent resume`) **fail outside a TTY** with a raw-mode error, so keep track of the session id yourself.

## Writing the prompt

Write it to `<RUN>/prompt.md` first (the run-scoped scratch dir from "Basic invocation" — never inside the target repo). cursor-agent is strong on well-scoped execution and weaker on long exploration and open design decisions.

- Name the target paths so it does not have to search
- State completion conditions mechanically ("the tests pass", "this function exists in this file")
- State what not to do (do not commit, do not touch other files)
- Leave no decisions open — settle any remaining choice before dispatching
- Inventory the repository yourself, then state what it actually has and lacks ("no package.json, no test runner, no linter") and forbid proposing anything it does not already use — this is the dispatch-time mitigation for pitfall 5
- Pin the output language explicitly; global instruction files otherwise decide it for you
