#!/usr/bin/env python3
"""Collect the .cursor/rules that apply to given paths, for inlining into a delegation prompt.

Usage:
    collect-rules.py <repo> <path> [<path> ...] [--include-always]

Prints the effective text of every rule whose `globs:` match one of the paths,
with `@reference` lines replaced by the referenced file's contents. Rules marked
`alwaysApply: true` are skipped by default: cursor-agent loads those on every run,
so inlining them only duplicates context. Exits 0 with no output when nothing applies.
"""

import re
import sys
from pathlib import Path


def parse_front_matter(text):
    """Return (fields, body). Missing or malformed front matter yields ({}, text)."""
    if not text.startswith("---"):
        return {}, text
    end = text.find("\n---", 3)
    if end == -1:
        return {}, text
    raw = text[3:end]
    body = text[end + 4 :].lstrip("\n")
    fields = {}
    for line in raw.splitlines():
        if ":" not in line or line.lstrip().startswith("#"):
            continue
        key, _, value = line.partition(":")
        fields[key.strip()] = value.strip()
    return fields, body


def parse_globs(value):
    """Accept `a/**`, `a/**, b/**`, and `["a/**", "b/**"]`."""
    value = value.strip()
    if not value:
        return []
    if value.startswith("["):
        value = value[1:-1] if value.endswith("]") else value[1:]
    return [p.strip().strip("\"'") for p in value.split(",") if p.strip().strip("\"'")]


def glob_to_regex(pattern):
    """Translate a Cursor glob to a regex anchored at the repository root."""
    out = []
    i = 0
    while i < len(pattern):
        c = pattern[i]
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif c == "*":
            out.append("[^/]*")
            i += 1
        elif c == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(c))
            i += 1
    return re.compile("^" + "".join(out) + "$")


def resolve_references(body, repo, rule_dir):
    """Replace `@path` lines with the referenced file's contents; cursor-agent does not expand them."""
    lines = []
    for line in body.splitlines():
        match = re.fullmatch(r"@(\S+)", line.strip())
        if not match:
            lines.append(line)
            continue
        target = match.group(1)
        for candidate in (repo / target, rule_dir / target):
            if candidate.is_file():
                lines.append(f"<!-- {target} -->")
                lines.append(candidate.read_text(encoding="utf-8").rstrip())
                break
        else:
            lines.append(f"<!-- referenced file not found: {target} -->")
    return "\n".join(lines).strip()


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    include_always = "--include-always" in argv
    if len(args) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    repo = Path(args[0]).resolve()
    targets = []
    for raw in args[1:]:
        path = Path(raw)
        path = path.resolve() if path.is_absolute() else (repo / path).resolve()
        try:
            targets.append(path.relative_to(repo).as_posix())
        except ValueError:
            print(f"path outside the repository: {raw}", file=sys.stderr)
            return 2

    rules_dir = repo / ".cursor" / "rules"
    if not rules_dir.is_dir():
        return 0

    chunks = []
    for rule in sorted(rules_dir.rglob("*.mdc")):
        fields, body = parse_front_matter(rule.read_text(encoding="utf-8"))
        always = fields.get("alwaysApply", "").lower() == "true"
        if always and not include_always:
            continue
        patterns = parse_globs(fields.get("globs", ""))
        if not always:
            if not patterns:
                continue
            regexes = [glob_to_regex(p) for p in patterns]
            if not any(r.match(t) for r in regexes for t in targets):
                continue
        text = resolve_references(body, repo, rule.parent)
        if text:
            label = rule.relative_to(repo).as_posix()
            chunks.append(f"### {label}\n\n{text}")

    if chunks:
        print("## Repository rules that apply to the files above\n")
        print("\n\n".join(chunks))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
