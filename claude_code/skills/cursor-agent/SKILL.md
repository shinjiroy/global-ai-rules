---
name: cursor-agent
description: Run cursor-agent (Cursor CLI) non-interactively to delegate investigation or implementation work. Use whenever the task is to drive Cursor from the command line — "have Cursor implement this", "run it through cursor-agent", "delegate to the Cursor CLI", "let Cursor plan it in plan mode". 日本語でも発動する: 「Cursorに実装させて」「cursor-agentで回して」「CursorをCLIで叩いて」「Cursorに委譲して」「plan modeで調べさせて」。Covers the preflight gate that must pass before any delegation, building the command, choosing a safety envelope (plan mode / sandbox), inlining the repository rules that govern the files being changed, reading stream-json output, detecting failures, and resuming sessions. Not for driving the Cursor editor by hand, and not for orchestrating the host agent's own subagents.
allowed-tools: Bash(cursor-agent:*), Bash(jq:*), Bash(git:*), Bash(tee:*), Bash(${CLAUDE_SKILL_DIR}/scripts/preflight.sh:*), Bash(${CLAUDE_SKILL_DIR}/scripts/new-run.sh:*), Bash(${CLAUDE_SKILL_DIR}/scripts/collect-rules.sh:*), Bash(${CLAUDE_SKILL_DIR}/scripts/await-run.sh:*), Bash(${CLAUDE_SKILL_DIR}/scripts/summarize-run.sh:*), Read, Write
model: sonnet
effort: low
---

# Driving cursor-agent non-interactively

`cursor-agent` is expensive per run, has real side effects, and signals failure in its output stream rather than in its exit code. The full flag list is in `cursor-agent --help`; this skill covers only the measured behavior that `--help` does not tell you, plus the procedure around it.

Whether you run this yourself or inside a subagent you spawned is the caller's decision — this skill works the same either way and does not ask for one shape. Everything below is written for whoever performs the delegation.

Needs `bash`, `jq`, `git`, and the usual POSIX tools. `${CLAUDE_SKILL_DIR}` in the commands below is Claude Code's substitution for this skill's own directory; on a host that does not provide it, use the directory holding this file.

## Preflight gate

Run this once per session, before the first invocation. **It is a hard gate: if it fails, stop and report — do not attempt the delegated work by other means, and do not install or authenticate on the user's behalf.**

```bash
${CLAUDE_SKILL_DIR}/scripts/preflight.sh <target repo> --implementation   # drop both arguments for a plan-only run, or when resuming an interrupted one
```

| Exit | Meaning |
| --- | --- |
| 0 | Ready to delegate |
| 1 | `cursor-agent` not on PATH |
| 2 | Not logged in |
| 3 | The working tree already carries changes |

It matches on output rather than exit status — `cursor-agent status` exits 0 even when logged out — and prints the evidence a failure report needs (binary path, raw status text, the dirty paths), so no second diagnostic round is necessary.

Optional, when the delegation runs in a spawned subagent: whoever is about to spawn it can run this script first. It needs no context beyond the path, so an abort costs two commands instead of a whole subagent turn. That is a caller-side optimization, not part of this procedure — the subagent still runs the gate itself, because the tree can change in between.

- `NOT_INSTALLED` — tell the user to install it: `curl https://cursor.com/install -fsS | bash` (lands in `~/.local/bin/cursor-agent`, which must be on `PATH`). Then stop.
- `NOT_LOGGED_IN` — tell the user to run `cursor-agent login`. It opens a browser, so it cannot be done for them, and it cannot be done from a non-interactive session. Then stop.

Both are the user's decision to make: installing software and authenticating an account are not steps to take unattended. Report which check failed and what the user should run, then end your turn — do not block waiting for input.

## Choose a safety envelope

Decide this explicitly before dispatching work.

| Goal | Extra flags | Blocked for the delegate | Still permitted for the delegate |
| --- | --- | --- | --- |
| Investigate / plan only | `--mode plan --sandbox enabled` | Editing files; network; writing outside the workspace | Reading everything; writing inside its own scratch space |
| Real implementation | `--force` when the delegate must run commands | Shell commands, unless `--force` is passed (pitfall 5) | Any file in the workspace, network. Requires a clean working tree |

Restrictions bind the delegate process only, never your own shell.

`--mode plan` alone still permits writes to `/tmp`. Pair it with `--sandbox enabled` when read-only actually matters. Your own commands are unaffected — teeing the log to a scratch dir outside the repo works, and the run still reaches the model over the network.

Neither flag stops a delegate from creating a **new** file inside the workspace in an implementation run. When the user asked for no new files at all, say so in the prompt; the envelope will not enforce it.

Before an implementation run, check the tree: **dirty := `git -C <target repo> status --porcelain` produces any output, untracked files included.** If it is dirty on arrival, take the abort path. Do not stash or revert it — afterwards you would have no way to separate the delegate's changes from the pre-existing ones, and the `git diff` verification becomes meaningless.

One case is not an arrival: a run that was **cut off mid-work** leaves the delegate's own unfinished changes behind. Resuming that session is the continuation of a delegation already in progress, not a new one — see "Resuming an interrupted run".

## Aborting

Three conditions stop the procedure: `NOT_INSTALLED`, `NOT_LOGGED_IN`, and — before an implementation run — any output at all from `git -C <target repo> status --porcelain`, untracked files included. The tree rule admits exactly one exception, the interrupted run above, and it has to be established from that run's log rather than assumed; there is none for a small task or a single stray file. Every one of them ends the same way — report all three of the following, then end your turn without blocking for input:

1. Which check failed, with the evidence you observed
2. The exact action that unblocks it — `curl https://cursor.com/install -fsS | bash`, `cursor-agent login`, or the user's decision on the pre-existing changes
3. That the delegated work was not done by any other means

Never substitute your own implementation for a delegation that did not happen.

## Basic invocation

Reach this section only after the preflight gate passed and, for an implementation run, the working tree came up clean. Everything below has side effects or costs money; the gates above do not.

Two invariants, whatever mechanism you use to satisfy them:

- The prompt reaches cursor-agent **on stdin**. As an argument, quoting breaks and long specs do not fit
- The prompt file and the stream log both live **outside the target repository at run-unique paths**. Inside the repo they appear as untracked files and destroy the `git status` check you need afterwards; a fixed name collides with the previous run

Assume every shell command runs in a **fresh process** — cwd resets and variables are lost between calls. So carry literal paths forward by hand and never rely on `cd`, in three steps.

**1. Create the scratch dir and read the path off the output.**

```bash
${CLAUDE_SKILL_DIR}/scripts/new-run.sh
# -> /tmp/ca-run-Ab12Cd        substitute this literal path for <RUN> below
```

It seeds `<RUN>/prompt.md` from `assets/prompt-template.md`. Everything one delegation produces stays in that directory:

| File | Contents |
| --- | --- |
| `prompt.md` | The delegated task, plus the repository rules appended to it |
| `ca.ndjson` | The complete stream log — the authority for every judgment about the run |
| `ca.pid`, `ca.err` | The detached run's pid and stderr, written by the invocation below |
| `followup-N.md` | The Nth `--resume` prompt |
| `ca-followup-N.ndjson` | Its log. Numbered, so a follow-up never overwrites the first log |
| `check.*` | A throwaway script used to exercise the change when the repo has no test runner |

Nothing deletes these; leave them for the OS to reap. The log is the only evidence of what happened, and it is worth more after the turn than the few tens of KB it costs.

**2. Fill in `<RUN>/prompt.md`.** Replace every `{{...}}` placeholder in the seeded template; see "Writing the prompt".

**3. Invoke, naming the target repository with `--workspace`.**

```bash
cursor-agent -p --trust --workspace <target repo> <envelope flags> --output-format stream-json \
  < <RUN>/prompt.md | tee <RUN>/ca.ndjson \
  | jq -r --unbuffered 'select(.type=="tool_call" and .subtype=="started") | .tool_call | to_entries[0].key'
```

`tee` writes the **complete** stream to `<RUN>/ca.ndjson` while `jq` shows live tool activity; the file — not the filtered console view — is the authoritative record every query in "Reading the result" runs against.

- Target the repository with `--workspace`, never by prefixing `cd <repo> &&`. A compound command defeats the host's per-command permission matching, so every run re-prompts; `--workspace` keeps the invocation a single `cursor-agent` command. Every `git` command in this skill likewise uses `git -C <target repo>`
- `<envelope flags>` comes from "Choose a safety envelope" below. Decide it before running; it is empty only for an implementation run whose delegate needs no shell
- **Do not read `$?` after this pipeline** — it belongs to `jq`, not to cursor-agent. Judge the outcome from `is_error` (pitfall 2)
- `--trust` is required the first time you run in a directory (see pitfall 1)
- Default to `--output-format stream-json`. With `text` or `json` you lose tool activity and the plan body
- Do **not** pass `--model`. Respect the user's default in `~/.cursor/cli-config.json`. Override only with a reason, after checking `cursor-agent models`
- `-p` grants file writes but **not** shell commands. Add `--force` to an implementation run whose delegate has to run anything — the tests, `git`, a build (see pitfall 5). Leave it off in plan mode, where the sandbox is the point

### Keep the run alive to its own end

A run takes minutes to tens of minutes and dies with whatever shell started it. If your turn — or the sub-agent you are running as — can end before the pipeline returns, the delegate is killed **mid-edit**: the session is resumable, but the workspace is left holding half-finished, uncommitted work. Two ways to avoid it:

1. **Return only after the process exits.** Run the pipeline in the foreground of a call that you wait on. This is the simpler shape, and it holds only while the run fits inside the host's per-command timeout — Claude Code's Bash tool allows at most ten minutes, which a large task will outlast. Raise the timeout to its maximum when you take this path, and take the second one when the task is bigger than that or the host backgrounds the call regardless.
2. **Detach it from your process group**, so ending your turn does not take the run with it:

   ```bash
   setsid bash -c 'echo $$ > <RUN>/ca.pid; exec cursor-agent -p --trust --workspace <target repo> \
     <envelope flags> --output-format stream-json \
     < <RUN>/prompt.md > <RUN>/ca.ndjson 2> <RUN>/ca.err' &
   ```

   The live `jq` view is lost — read `<RUN>/ca.ndjson` instead — but the run finishes on its own. Three details are load-bearing:

   - **The inner shell records its own `$$` and then `exec`s**, so the pid file holds the run itself. `echo $! > <RUN>/ca.pid` does not work here: `setsid` forks, so `$!` is a wrapper that exits immediately, and polling it reports the run as finished seconds after it started
   - **stderr goes to its own file.** Merged into the log it breaks the NDJSON, and every `jq` query over the run then fails
   - `setsid` is Linux; where it is absent, use whatever detaches a process on that host

### Wait on the log, never on the process

```bash
${CLAUDE_SKILL_DIR}/scripts/await-run.sh <RUN>/ca.ndjson
```

**A run is over when `<RUN>/ca.ndjson` carries a `result` event.** Process liveness is not the signal: cursor-agent stays alive as long as it holds a foreground child it started — a dev server, a file watcher — so a loop like `while kill -0 "$(cat <RUN>/ca.pid)"; do sleep 30; done` blocks long after the delegate finished, with the completed result already sitting in the log (measured: 16 minutes). `await-run.sh` returns on the event, then kills the run's whole process group, which is what clears the leaked child.

| Exit | Meaning |
| --- | --- |
| 0 | The `result` event arrived. Anything still running was killed; go read the result |
| 3 | The log stopped growing for `--stall-seconds` (default 600) — read it before killing or resuming; this is the shape a genuine hang takes |
| 4 | The process exited before its `result` event — cut off, not failed. Resume it |

It reads `<RUN>/ca.pid` from beside the log; a follow-up run logging to `ca-followup-N.ndjson` needs `--pid-file`. Waiting is all the script does, so a call that hits the host's per-command timeout can just be repeated — nothing is lost and the log is unchanged.

Never poll by process **name**. `pgrep -f cursor-agent` matches the shell running that very command and so waits on itself forever, and the character-class form (`pgrep -f "[c]ursor-agent"`) matches an unrelated concurrent delegation instead.

A log whose last event is anything but `result` is a run that was cut off rather than one that failed; `summarize-run.sh` reports that case as `INTERRUPTED` (exit 4) as well.

## Pitfalls (measured; absent from `--help`)

1. **In an untrusted directory nothing runs at all.** It exits 1 and emits no `result` event. `--trust` is needed only on the first run in a given directory — the decision persists — but keep it in scripts regardless.
2. **Always check `is_error`.** The exit code only catches startup failures (untrusted directory, invalid model → 1). Whether the agent's actual work failed appears only in the `result` event's `is_error`.
3. **In plan mode the plan body never reaches `result`.** It exists only inside `createPlanToolCall.args.plan`, so `text` and `json` output drop it entirely.
4. **`globs:`-scoped `.cursor/rules` load, but not dependably.** Across five otherwise identical runs one silently failed to attach, and when two rules declared the same glob only one of them ever attached. A rule the delegate must obey belongs in `alwaysApply: true` or `AGENTS.md`, which load on every run — or state it directly in the prompt.
5. **Without `--force`, every shell command is rejected — and the delegate reports the output it never got.** Under `-p --trust` alone, each `shellToolCall` comes back `{"rejected": ...}` while file edits go through untouched. A delegate told to run the tests then writes a plausible passing transcript into its closing message: in a measured run it reported `Ran 40 tests ... OK` for a suite that in fact ended `FAILED (failures=1)`. Add `--force` when the delegate must execute anything, and read the outcome out of each `shellToolCall.result` rather than out of the prose: `rejected` means it never ran, `failure` means the command exited non-zero.
6. **`~/.claude/skills` is loaded.** Global skills and instruction files written for other agents leak into every cursor-agent run — a delegate will happily propose tooling, conventions, or an output language that the target repository shows no trace of. Mitigate at dispatch time: state the repository's actual state in the prompt ("no package.json, no test runner, no linter") and tell the delegate to propose nothing the repo does not already use. Suspect this first when the delegate behaves strangely.

Loaded automatically: `AGENTS.md`, `CLAUDE.md`, `.cursor/rules` with `alwaysApply`, and the skills directories. Slash commands in `.cursor/commands/*.md` work under `-p` (`-p "/command-name"`).

An `@other-file.md` reference inside a rule or `AGENTS.md` is **not** expanded up front — the delegate resolves it by reading that file with a tool. A rule that is only a pointer therefore costs an extra read and is skipped entirely when the delegate has no reason to follow it. Inline what must not be missed.

## Reading the result

```bash
${CLAUDE_SKILL_DIR}/scripts/summarize-run.sh <RUN>/ca.ndjson
```

It prints `is_error`, token usage, the session id needed for `--resume`, the plan body when the run was in plan mode (pitfall 3), and the final message. Its exit status carries the verdict:

| Exit | Meaning |
| --- | --- |
| 0 | The run completed with `is_error=false` |
| 1 | No `result` event and no work in the log — the run never started (untrusted directory, bad flags) |
| 2 | The run reported `is_error=true` |
| 4 | The run worked, then was cut off before its `result` event — resume it, do not restart |

`is_error=false` means the agent terminated normally — **not** that the work is correct. After delegating an implementation, verify with `git -C <target repo> status`, `git -C <target repo> diff`, and the repository's own tests. If the repository has no test runner, exercise the changed code directly from the scratch dir (a throwaway script under `<RUN>/`, never a file inside the repo) — an unverified diff is not a finished delegation.

Check two separate things. **Is the diff right** — read it. **Did anything else move** — the paths in `git status` must be exactly the ones the prompt named, nothing more. A delegate with write access can leave a stray file behind while still producing a correct diff. Under `--force` the tests themselves add to that list — a Python run leaves `__pycache__/` untracked — so account for build artifacts before treating an extra path as the delegate going off-script.

Judge the delegate by its **artifacts** — the diff, the plan body, the files — never by its closing prose. The narration is where leaked global conventions surface (pitfall 6), so it can contradict the prompt even when the artifact obeys it.

When reporting back, **relay the delegate's closing message verbatim** rather than rewriting it. It is already on disk, `summarize-run.sh` prints it, and the account of the change belongs to whoever made it. Keep your own verdict separate and short: what `is_error` said, what `git diff` showed, whether the check passed. Paraphrasing the delegate costs tokens and quietly launders an unverified claim into your own voice.

## Resuming

To continue rather than redo, resume instead of starting fresh: the cached context cuts input tokens dramatically.

```bash
cursor-agent --resume <session_id> -p --trust --workspace <target repo> --output-format stream-json \
  < <RUN>/followup-1.md | tee <RUN>/ca-followup-1.ndjson
```

`--continue` resumes the most recent session. The interactive pickers (`cursor-agent ls`, `cursor-agent resume`) **fail outside a TTY** with a raw-mode error, so keep track of the session id yourself.

### Resuming an interrupted run

When a run was killed before its `result` event, the workspace holds the delegate's own half-finished work. Confirm that provenance from `<RUN>/ca.ndjson` — the edits it logged should account for the paths `git status` now shows — and then resume that session with the dirty tree left exactly as it is.

Two mechanics differ from a fresh delegation:

- **Run the preflight gate without `--implementation`.** Only the install and login checks apply. The tree check would abort on the very changes you are resuming, and this is the one case where dirt is expected rather than disqualifying
- **Take the session id off the log's first line**, since no `result` event exists for `summarize-run.sh` to read it from:

  ```bash
  head -1 <RUN>/ca.ndjson | jq -r .session_id
  ```

  Every event carries it, including the opening `system`/`init`. When the log is empty the run died before emitting anything: there is no id and no provenance to establish, so `--continue` — which resumes the most recent session — is the only route, and without a log to corroborate them the changes fall back under the ordinary dirty-tree abort.

Say so in the follow-up prompt: the uncommitted changes are its own work in progress, it should read the current diff first and continue from there, and it must not stash or revert them. Without that, a delegate that finds an unexpectedly dirty tree may try to clean it up. Verification afterwards is unchanged, since the base commit you recorded still predates everything the delegation produced.

## Writing the prompt

Write it to `<RUN>/prompt.md` first (the run-scoped scratch dir from "Basic invocation" — never inside the target repo). cursor-agent is strong on well-scoped execution and weaker on long exploration and open design decisions.

- Name the target paths so it does not have to search
- State completion conditions mechanically ("the tests pass", "this function exists in this file")
- State what not to do (do not commit, do not touch other files)
- Leave no decisions open — settle any remaining choice before dispatching
- Inventory the repository yourself, then state what it actually has and lacks ("no package.json, no test runner, no linter") and forbid proposing anything it does not already use — this is the dispatch-time mitigation for pitfall 6
- Pin the output language explicitly; global instruction files otherwise decide it for you
- Inline the repository rules that govern the paths you named — use `collect-rules.sh` for this (next subsection); do not paste them by hand
- Say which wins when the written rules contradict the code already there. Repositories drift, so a rule like "snake_case" can collide with existing camelCase neighbours. State the resolution — usually "new code follows the rules; existing code stays untouched" — rather than leaving the delegate to guess

### Inline the applicable repository rules

`globs:`-scoped rules reach the delegate unreliably and `@` references are not expanded (pitfall 4). Append the rule text to the prompt instead of trusting either mechanism:

```bash
${CLAUDE_SKILL_DIR}/scripts/collect-rules.sh <target repo> <path> [<path> ...] >> <RUN>/prompt.md
```

Pass the same paths the prompt names. The script prints every `.cursor/rules/*.mdc` whose globs match, with `@` references resolved inline, and prints nothing when the repository has no rules or none apply. Rules marked `alwaysApply: true` are skipped because cursor-agent already loads them on every run; pass `--include-always` only when you want to see everything for debugging.
