#!/usr/bin/env bash
# check-client-leaks.sh
#
# Scans the repo for any reference to a specific RevealUI Studio client,
# prospect, or warm-intro contact. Customer/prospect names belong in the
# private internal repo only. Never in this public surface.
#
# Exit 0 on clean. Exit 1 on any violation. Exit 2 on tool/setup error.
# In CI, a missing or empty CLIENT_LEAK_PATTERNS exits 1 (fail closed).
# Locally, with neither the env var nor .client-name-watchlist.local, exit 2.
#
# Usage:
#   bash scripts/check-client-leaks.sh                     # scan repo root
#   bash scripts/check-client-leaks.sh <path> [<path>...]  # scan specific paths
#   LEAK_JSON=1 bash scripts/check-client-leaks.sh         # machine-readable
#
# CI wiring: .github/workflows/check-client-leaks.yml
# The workflow runs on push and pull_request to master.
#
# Adding a new client / prospect / contact:
#   Add one line to the CLIENT_LEAK_PATTERNS org secret
#   (format: tag|literal-string|reason). Never add it to a committed file.
#   There is no .leakignore for this scanner. The property must be unconditional.
#
# Pattern source, in order:
#   1. CLIENT_LEAK_PATTERNS (multiline env; one pattern per line)
#   2. Local fallback only, when not in CI: gitignored .client-name-watchlist.local
#   CI (CI=true or GITHUB_ACTIONS=true) never reads the local file.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAN_PATHS=("$@")
[[ ${#SCAN_PATHS[@]} -eq 0 ]] && SCAN_PATHS=("$REPO_ROOT")

for _path in "${SCAN_PATHS[@]}"; do
  if [[ ! -e "$_path" ]]; then
    echo "[client-leak] error: scan path not found: $_path" >&2
    exit 2
  fi
done
unset _path

# REGEX-CONFIG-BOUNDARY: strings are consumed by grep -F (fixed strings),
# so each pattern is a literal substring. No metacharacter handling.
# No regex authored. The literal pattern list is not stored in this file.

is_ci=0
if [[ "${CI:-}" == "true" || "${GITHUB_ACTIONS:-}" == "true" ]]; then
  is_ci=1
fi

PATTERNS=()

append_pattern_line() {
  local trimmed="$1"
  local tag rest pattern
  if [[ "$trimmed" != *"|"*"|"* ]]; then
    echo "[client-leak] error: a pattern line is not in tag|literal|reason form." >&2
    exit 2
  fi
  tag="${trimmed%%|*}"
  rest="${trimmed#*|}"
  pattern="${rest%%|*}"
  if [[ -z "$tag" || -z "${pattern//[[:space:]]/}" ]]; then
    echo "[client-leak] error: a pattern line is missing a tag or literal." >&2
    exit 2
  fi
  PATTERNS+=("$trimmed")
}

load_pattern_lines() {
  local line trimmed
  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [[ -z "$trimmed" ]] && continue
    [[ "$trimmed" == \#* ]] && continue
    append_pattern_line "$trimmed"
  done
}

fail_closed_ci() {
  echo "[client-leak] error: CLIENT_LEAK_PATTERNS is empty or unset." >&2
  echo "[client-leak] Set the org Actions secret CLIENT_LEAK_PATTERNS (one tag|literal|reason line per pattern) and make it visible to this repo." >&2
  echo "[client-leak] Refusing to pass without a pattern list." >&2
  exit 1
}

raw_patterns="${CLIENT_LEAK_PATTERNS:-}"
if [[ -n "${raw_patterns//[[:space:]]/}" ]]; then
  load_pattern_lines <<< "${raw_patterns}"
  if [[ ${#PATTERNS[@]} -eq 0 ]]; then
    if (( is_ci )); then
      fail_closed_ci
    fi
    echo "[client-leak] warning: CLIENT_LEAK_PATTERNS did not contain any pattern lines." >&2
    echo "[client-leak] Refusing to report a pass." >&2
    exit 2
  fi
elif (( is_ci )); then
  fail_closed_ci
elif [[ -f "$REPO_ROOT/.client-name-watchlist.local" ]]; then
  load_pattern_lines < "$REPO_ROOT/.client-name-watchlist.local"
  if [[ ${#PATTERNS[@]} -eq 0 ]]; then
    echo "[client-leak] warning: .client-name-watchlist.local did not contain any pattern lines." >&2
    echo "[client-leak] Refusing to report a pass." >&2
    exit 2
  fi
else
  echo "[client-leak] warning: CLIENT_LEAK_PATTERNS is unset and .client-name-watchlist.local is absent." >&2
  echo "[client-leak] Add the line to the CLIENT_LEAK_PATTERNS org secret (never to a committed file), or use the gitignored local file." >&2
  echo "[client-leak] Refusing to report a pass." >&2
  exit 2
fi
unset raw_patterns

# Directories / file globs to skip.
# The scanner script is scanned: it no longer holds the literal pattern list.
EXCLUDE_DIRS=(node_modules .git dist build .next .turbo .pnpm coverage target .direnv .nyc_output playwright-report test-results)
EXCLUDE_FILES=(
  pnpm-lock.yaml package-lock.json yarn.lock Cargo.lock
  # Local-only pattern source. Gitignored. It holds the literals under scan,
  # so a hit inside that file is not a public leak.
  .client-name-watchlist.local
  CHANGELOG.md
  '*.png' '*.jpg' '*.jpeg' '*.gif' '*.webp' '*.pdf' '*.zip' '*.tar.gz' '*.tgz'
  '*.ico' '*.woff' '*.woff2' '*.ttf' '*.otf'
  '*.har' '*.snap'
)

if ! command -v grep >/dev/null 2>&1; then
  echo "[client-leak] error: grep not found on PATH" >&2
  exit 2
fi

grep_excludes=()
for d in "${EXCLUDE_DIRS[@]}"; do
  grep_excludes+=(--exclude-dir="$d")
done
for f in "${EXCLUDE_FILES[@]}"; do
  grep_excludes+=(--exclude="$f")
done

violations=0
json_entries=()

for entry in "${PATTERNS[@]}"; do
  tag="${entry%%|*}"
  rest="${entry#*|}"
  pattern="${rest%%|*}"
  reason="${rest#*|}"

  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    file="${hit%%:*}"
    rest_="${hit#*:}"
    line="${rest_%%:*}"
    content="${rest_#*:}"

    if [[ -n "${LEAK_JSON:-}" ]]; then
      if command -v jq >/dev/null 2>&1; then
        json_entries+=("$(jq -cn --arg tag "$tag" --arg file "$file" --arg line "$line" --arg reason "$reason" --arg content "$content" \
          '{tag:$tag, file:$file, line:($line|tonumber), reason:$reason, content:$content}')")
      else
        safe="${content//\\/\\\\}"
        safe="${safe//\"/\\\"}"
        safe="${safe//$'\n'/\\n}"
        safe="${safe//$'\t'/\\t}"
        sreason="${reason//\\/\\\\}"
        sreason="${sreason//\"/\\\"}"
        json_entries+=("{\"tag\":\"$tag\",\"file\":\"$file\",\"line\":$line,\"reason\":\"$sreason\",\"content\":\"$safe\"}")
      fi
    else
      printf '[CLIENT-LEAK:%s] %s:%s: %s\n  %s\n' "$tag" "$file" "$line" "$reason" "$content"
    fi
    violations=$((violations+1))
  done < <(grep -rFIn "${grep_excludes[@]}" -- "$pattern" "${SCAN_PATHS[@]}" 2>/dev/null || true)
done

if [[ -n "${LEAK_JSON:-}" ]]; then
  printf '{"violations":%d,"entries":[%s]}\n' "$violations" "$(IFS=,; echo "${json_entries[*]:-}")"
fi

if (( violations > 0 )); then
  if [[ -z "${LEAK_JSON:-}" ]]; then
    echo "" >&2
    echo "[client-leak] FAIL: $violations violation(s)." >&2
    echo "" >&2
    echo "Customer / prospect names must NEVER appear in this public-facing repo." >&2
    echo "Move the content to the private internal repo (or genericize with a" >&2
    echo "placeholder like 'Acme Corp' / 'acme' / 'first customer')." >&2
    echo "" >&2
    echo "If a new client onboards and their name needs scanner coverage, add" >&2
    echo "the line to the CLIENT_LEAK_PATTERNS org secret (never to a committed file)." >&2
  fi
  exit 1
fi

[[ -z "${LEAK_JSON:-}" ]] && echo "[client-leak] OK: no client/prospect names detected across: ${SCAN_PATHS[*]}"
exit 0
