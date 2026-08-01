#!/usr/bin/env bash
# Collect the .cursor/rules that apply to given paths, for inlining into a delegation prompt.
#
# Usage:
#     collect-rules.sh <repo> <path> [<path> ...] [--include-always]
#
# Prints the effective text of every rule whose `globs:` match one of the paths,
# with `@reference` lines replaced by the referenced file's contents. Rules marked
# `alwaysApply: true` are skipped by default: cursor-agent loads those on every run,
# so inlining them only duplicates context. Exits 0 with no output when nothing applies.
set -euo pipefail

usage() { sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'; }

include_always=0
args=()
for a in "$@"; do
  case "$a" in
    --include-always) include_always=1 ;;
    -h|--help) usage; exit 0 ;;
    *) args+=("$a") ;;
  esac
done
[ ${#args[@]} -ge 2 ] || { usage >&2; exit 2; }

repo=$(cd "${args[0]}" 2>/dev/null && pwd) || { echo "no such directory: ${args[0]}" >&2; exit 2; }
rules_dir="$repo/.cursor/rules"

# Repository-relative target paths (validated before the rules directory is consulted).
targets=()
for raw in "${args[@]:1}"; do
  case "$raw" in
    /*) abs="$raw" ;;
    *)  abs="$repo/$raw" ;;
  esac
  case "$abs" in
    "$repo"/*) targets+=("${abs#"$repo"/}") ;;
    *) echo "path outside the repository: $raw" >&2; exit 2 ;;
  esac
done

[ -d "$rules_dir" ] || exit 0

# Translate a Cursor glob into an anchored ERE.
glob_to_ere() {
  local pattern=$1 out='^' i=0 c
  while [ $i -lt ${#pattern} ]; do
    c=${pattern:$i:1}
    if [ "${pattern:$i:3}" = '**/' ]; then out+='(.*/)?'; i=$((i + 3))
    elif [ "${pattern:$i:2}" = '**' ]; then out+='.*'; i=$((i + 2))
    elif [ "$c" = '*' ]; then out+='[^/]*'; i=$((i + 1))
    elif [ "$c" = '?' ]; then out+='[^/]'; i=$((i + 1))
    else
      case "$c" in
        .|+|\(|\)|\[|\]|\{|\}|^|\$|\||\\) out+="\\$c" ;;
        *) out+="$c" ;;
      esac
      i=$((i + 1))
    fi
  done
  printf '%s$' "$out"
}

# Print the rule body with `@path` lines replaced by the referenced file's contents.
emit_body() {
  local file=$1 rule_dir target
  awk 'NR==1 && $0=="---" { infm=1; next }
       infm && $0=="---" { infm=0; started=1; next }
       infm { next }
       { if (!started && NR==1) started=1; print }' "$file" |
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*@([^[:space:]]+)[[:space:]]*$ ]]; then
      target=${BASH_REMATCH[1]}
      rule_dir=$(dirname "$file")
      if [ -f "$repo/$target" ]; then
        printf '<!-- %s -->\n' "$target"; cat "$repo/$target"
      elif [ -f "$rule_dir/$target" ]; then
        printf '<!-- %s -->\n' "$target"; cat "$rule_dir/$target"
      else
        printf '<!-- referenced file not found: %s -->\n' "$target"
      fi
    else
      printf '%s\n' "$line"
    fi
  done
}

collected=""
while IFS= read -r rule; do
  front=$(awk 'NR==1 && $0=="---" { infm=1; next } infm && $0=="---" { exit } infm { print }' "$rule")
  always=$(printf '%s\n' "$front" | sed -n 's/^[[:space:]]*alwaysApply[[:space:]]*:[[:space:]]*//p' | tr '[:upper:]' '[:lower:]')
  globs=$(printf '%s\n' "$front" | sed -n 's/^[[:space:]]*globs[[:space:]]*:[[:space:]]*//p')

  if [ "$always" = "true" ]; then
    [ "$include_always" -eq 1 ] || continue
  else
    [ -n "$globs" ] || continue
    globs=${globs#[}; globs=${globs%]}
    matched=0
    IFS=',' read -ra patterns <<< "$globs"
    for pattern in "${patterns[@]}"; do
      pattern=$(printf '%s' "$pattern" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^["'"'"']//' -e 's/["'"'"']$//')
      [ -n "$pattern" ] || continue
      ere=$(glob_to_ere "$pattern")
      for target in "${targets[@]}"; do
        if printf '%s\n' "$target" | grep -Eq "$ere"; then matched=1; break 2; fi
      done
    done
    [ "$matched" -eq 1 ] || continue
  fi

  body=$(emit_body "$rule" | sed -e '/./,$!d')   # drop leading blank lines; $() drops trailing ones
  [ -n "${body//[$' \t\n']/}" ] || continue
  collected+="### ${rule#"$repo"/}"$'\n\n'"$body"$'\n\n'
done < <(find "$rules_dir" -name '*.mdc' | sort)

if [ -n "$collected" ]; then
  # Leading blank line: the output is appended to an existing prompt, and a heading
  # glued to the previous paragraph is not parsed as a heading.
  printf '\n## Repository rules that apply to the files above\n\n%s\n' "${collected%$'\n\n'}"
fi
