<!-- Delegation prompt skeleton. Replace every {{...}}; delete any line that does not apply.
     Leave no decision open — settle remaining choices before dispatching. -->

# Task

{{one sentence: what to change and why}}

## Files

{{the exact paths to touch, one per line — the delegate must not have to search}}

## Done when

{{mechanically checkable conditions, e.g. "npm test passes", "src/x.ts exports add(a, b)"}}

## Do not

- Commit, push, or run any state-changing git command
- Touch files other than the ones listed above
- Add dependencies, tooling, or config the repository does not already use

## This repository

{{what it actually has and lacks: package manager, test runner, linter, framework —
   state it plainly so nothing is inferred from instruction files outside this repo}}

Where the repository rules below contradict the code already in these files:
{{usually "new code follows the rules; leave existing code as it is"}}

Reply in {{language}}.

<!-- collect-rules.sh appends the applicable repository rules below this line.
     Keep it last; nothing you write after it will read as part of the task. -->

