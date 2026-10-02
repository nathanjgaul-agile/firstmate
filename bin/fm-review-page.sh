#!/usr/bin/env bash
# fm-review-page.sh - build the interactive milestone review page for a local
# feature branch and serve it through Lavish.
#
# Usage:
#   fm-review-page.sh build <project-dir> <feature-branch> <base> <notes.json>
#   fm-review-page.sh render <project-dir> <feature-branch> <base> <notes.json>
#   fm-review-page.sh summary <notes.json>
#
# build    Refuse unless verdict_key and every decision key is a task held for
#          the captain, render, then serve the page through `fm-bearings-board.sh serve`,
#          which proves the Lavish session live and binds its answers to the
#          keyed-answer intake (bin/fm-captain-hold.sh) before arming it, exactly
#          as the bearings board does. Output starts with `page: <path>`.
# render   Validate the notes, compute the diff of <base>...<feature-branch>,
#          and write the page without serving it. Prints `page: <path>`.
# summary  Print the notes' summary as Markdown for the feature PR description.
#
# The page shows what changed (summary bullets, reused versus new), the diff
# size and local CI result, try-it steps with before/after screenshots, the
# key diffs beside their notes, risks, decision buttons, the full diff
# collapsed, and Approve / Request changes. Every diff line is its own element
# so a Lavish annotation is a line comment. Answers are queued in the
# fm-bearings-answer.v1 shape bin/fm-procevent-lavish.sh `answers` reads, so
# verdict_key and every decision key must name a task held for the captain
# (bin/fm-captain-hold.sh hold) or the intake skips the answer.
#
# The agent-written notes file is JSON (schema fm-review-notes.v1):
#   { "schema": "fm-review-notes.v1",
#     "title": "Milestone 1 - ...",
#     "verdict_key": "<held task id answered by Approve / Request changes>",
#     "summary": ["..."], "reuse": ["..."], "new": ["..."],
#     "ci": "local CI result, as one line",
#     "try_it": [{"step": "...", "before": "shot.png", "after": "shot.png"}],
#     "key_diffs": [{"file": "path/in/repo", "note": "why it changed"}],
#     "risks": ["..."],
#     "decisions": [{"key": "<held task id>", "title": "...", "detail": "...",
#       "options": [{"value": "a", "label": "...", "hint": "..."}],
#       "recommend_value": "a"}] }
# summary, ci, title, verdict_key, and 1-6 key_diffs are required. Screenshot
# paths are relative to the notes file and are embedded as data: URIs, so the
# page is self-contained. Validation refuses anything else before writing.
#
# The page path is stable per project and feature branch -
# $FM_HOME/.lavish/review-<project>-<feature>.html - so a rebuild keeps the same
# Lavish session URL. FM_REVIEW_PAGE_TEMPLATE overrides the template (tests only).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

TEMPLATE="${FM_REVIEW_PAGE_TEMPLATE:-$SCRIPT_DIR/../.agents/skills/ship-landing/assets/review-template.html}"
PLACEHOLDER='__FM_REVIEW_PAGE_DATA__'
SCHEMA=fm-review-notes.v1

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

fail() {
  printf 'fm-review-page: %s\n' "$*" >&2
  exit 1
}

validate_notes() {  # <notes.json>
  jq -e --arg schema "$SCHEMA" '
    def text: type == "string" and length > 0;
    def texts: type == "array" and all(.[]; text);
    def slug: type == "string" and test("^[A-Za-z0-9._-]{1,128}$");
    def opt($k; f): (has($k) | not) or (.[$k] | f);
    type == "object"
    and .schema == $schema
    and (.title | text) and (.ci | text) and (.verdict_key | slug)
    and (.summary | texts and length > 0)
    and opt("reuse"; texts) and opt("new"; texts) and opt("risks"; texts)
    and opt("try_it"; type == "array" and all(.[];
      type == "object" and (.step | text) and opt("before"; text) and opt("after"; text)))
    and (.key_diffs | type == "array" and length >= 1 and length <= 6
      and all(.[]; type == "object" and (.file | text) and (.note | text)))
    and opt("decisions"; type == "array" and all(.[];
      type == "object" and (.key | slug) and (.title | text) and opt("detail"; type == "string")
      and (.options | type == "array" and length > 0
        and all(.[]; type == "object" and (.value | slug) and .value != "reconcile"
          and (.label | text) and opt("hint"; type == "string")))
      and ((has("recommend_value") | not)
        or (.recommend_value as $r | [.options[].value] | index($r) != null))))
    and ([.verdict_key, (.decisions // [])[].key] | length == (unique | length))
  ' "$1" >/dev/null
}

page_path() {  # <project-dir> <feature-branch>
  local slug
  slug=$(printf '%s-%s' "$(basename "$1")" "$2" | tr -c 'A-Za-z0-9._-' '-')
  printf '%s/.lavish/review-%s.html\n' "$FM_HOME" "$slug"
}

image_mime() {  # <path>
  case "$(printf '%s' "${1##*.}" | tr '[:upper:]' '[:lower:]')" in
    png) echo image/png ;;
    jpg|jpeg) echo image/jpeg ;;
    gif) echo image/gif ;;
    webp) echo image/webp ;;
    *) return 1 ;;
  esac
}

command_render() {
  [ "$#" -eq 4 ] || { usage >&2; exit 2; }
  local proj=$1 feature=$2 base=$3 notes=$4 notes_dir range work file shot mime page tmp
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$notes" ] || fail "notes file does not exist: $notes"
  jq empty "$notes" 2>/dev/null || fail "notes file is not valid JSON: $notes"
  validate_notes "$notes" || fail "notes file does not satisfy $SCHEMA: $notes"
  [ -f "$TEMPLATE" ] && [ "$(grep -cxF "$PLACEHOLDER" "$TEMPLATE")" -eq 1 ] \
    || fail "review template is missing its data slot: $TEMPLATE"
  git -C "$proj" rev-parse --verify --quiet "$feature^{commit}" >/dev/null || fail "unknown feature branch: $feature"
  git -C "$proj" rev-parse --verify --quiet "$base^{commit}" >/dev/null || fail "unknown base: $base"
  notes_dir=$(cd "$(dirname "$notes")" && pwd)
  range="$base...$feature"

  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-review-page.XXXXXX") || fail "cannot stage the page"
  # shellcheck disable=SC2064  # Expand now: the path is fixed for this run.
  trap "rm -rf -- '$work'" EXIT
  : > "$work/diffs.jsonl"
  : > "$work/shots.jsonl"
  while IFS= read -r file; do
    git -C "$proj" diff "$range" -- "$file" > "$work/one.diff" || fail "cannot diff $file"
    [ -s "$work/one.diff" ] || fail "key diff $file has no changes in $range"
    jq -Rs --arg file "$file" '{file: $file, diff: .}' < "$work/one.diff" >> "$work/diffs.jsonl"
  done < <(jq -r '.key_diffs[].file' "$notes")
  while IFS= read -r shot; do
    case "$shot" in /*) file=$shot ;; *) file="$notes_dir/$shot" ;; esac
    [ -f "$file" ] || fail "screenshot does not exist: $file"
    mime=$(image_mime "$file") || fail "screenshot is not png, jpeg, gif, or webp: $file"
    base64 < "$file" | tr -d '\n' \
      | jq -Rs --arg path "$shot" --arg mime "$mime" '{path: $path, src: ("data:" + $mime + ";base64," + .)}' \
      >> "$work/shots.jsonl"
  done < <(jq -r '(.try_it // [])[] | (.before // empty), (.after // empty)' "$notes")
  git -C "$proj" diff "$range" | jq -Rs . > "$work/full.json" || fail "cannot compute the full diff"

  jq -c --arg project "$(basename "$proj")" --arg feature "$feature" --arg base "$base" \
    --arg head "$(git -C "$proj" rev-parse --short "$feature")" \
    --arg shortstat "$(git -C "$proj" diff --shortstat "$range" | sed 's/^ *//')" \
    --slurpfile diffs "$work/diffs.jsonl" --slurpfile shots "$work/shots.jsonl" \
    --slurpfile full "$work/full.json" '
    ($diffs | map({(.file): .diff}) | add // {}) as $d
    | ($shots | map({(.path): .src}) | add // {}) as $s
    | . + {project: $project, feature: $feature, base: $base, head: $head,
        shortstat: $shortstat, full_diff: $full[0]}
    | .key_diffs |= map(.diff = $d[.file])
    | .try_it = ((.try_it // []) | map(
        (if .before then .before_src = $s[.before] else . end)
        | (if .after then .after_src = $s[.after] else . end)))
  ' "$notes" > "$work/page.json" || fail "cannot assemble the page data"

  page=$(page_path "$proj" "$feature")
  (umask 077; mkdir -p "${page%/*}") || fail "cannot create ${page%/*}"
  tmp=$(umask 077; mktemp "${page%/*}/.review.XXXXXX") || fail "cannot stage the page"
  # `<` never appears in JSON syntax outside strings, so escaping it keeps the
  # payload valid JSON while making a diff's "</script>" inert.
  if ! DATA="$work/page.json" perl -pe '
      BEGIN { open my $f, "<", $ENV{DATA} or die; local $/; $j = <$f>; chomp $j; $j =~ s/</\\u003c/g }
      s/^\Q'"$PLACEHOLDER"'\E$/$j/' "$TEMPLATE" > "$tmp" \
    || grep -qxF "$PLACEHOLDER" "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot inject the page data"
  fi
  if ! { chmod 0600 "$tmp" && mv -f -- "$tmp" "$page"; }; then
    rm -f -- "$tmp"
    fail "cannot publish the page"
  fi
  printf 'page: %s\n' "$page"
}

# Every answer the page can queue must have a held task to resolve, or the
# keyed-answer intake would skip it, so build refuses before serving.
require_held() {  # <notes.json>
  local key
  validate_notes "$1" 2>/dev/null || fail "notes file does not satisfy $SCHEMA: $1"
  while IFS= read -r key; do
    "$SCRIPT_DIR/fm-captain-hold.sh" open "$key" --distinguish-absent >/dev/null 2>&1 \
      || fail "$key is not a task held for the captain; hold it (bin/fm-captain-hold.sh hold) before building"
  done < <(jq -r '.verdict_key, (.decisions // [])[].key' "$1")
}

command_summary() {
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_notes "$1" || fail "notes file does not satisfy $SCHEMA: $1"
  jq -r '
    def bullets: map("- " + .) | join("\n");
    "## Summary\n\n" + (.summary | bullets)
    + (if (.reuse // []) | length > 0 then "\n\n**Reused:**\n\n" + (.reuse | bullets) else "" end)
    + (if (.new // []) | length > 0 then "\n\n**New:**\n\n" + (.new | bullets) else "" end)
    + "\n\nLocal CI: " + .ci
    + (if (.try_it // []) | length > 0
       then "\n\n<details>\n<summary>How to try it</summary>\n\n"
         + ([.try_it | to_entries[] | "\(.key + 1). \(.value.step)"] | join("\n"))
         + "\n\n</details>"
       else "" end)
  ' "$1"
}

case "${1-}" in
  render) shift; command_render "$@" ;;
  build)
    shift
    [ "$#" -eq 4 ] || { usage >&2; exit 2; }
    require_held "$4"
    out=$(command_render "$@") || exit 1
    printf '%s\n' "$out"
    exec "$SCRIPT_DIR/fm-bearings-board.sh" serve "${out#page: }"
    ;;
  summary) shift; command_summary "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
