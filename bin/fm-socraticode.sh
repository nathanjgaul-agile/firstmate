#!/usr/bin/env bash
# Report whether a registered project is marked as SocratiCode-enabled in this
# home, and print the one absolute path a SocratiCode tool call may target.
#
# SocratiCode is a local MCP codebase-intelligence server. The decision
# procedure for using it - which tool answers which question, how to handle a
# declared/live disagreement, and the main-checkout blind spot - is owned by the
# agent-only `socraticode` skill (AGENTS.md section 13). This script is only the
# registry and clone read that skill's enablement check calls for.
#
# Enablement is DECLARED here and PROVEN elsewhere. This script reads two cheap
# local facts:
#   registry  - the project's annotation in data/projects.md carries the
#               additive +socraticode token (bin/fm-project-mode.sh owns that
#               annotation format and is the single registry parser)
#   clone     - $FM_HOME/projects/<name> exists in this home
# The marker is a PER-HOME assertion, never an inherited one: it claims that
# THIS home's own clone, at the absolute path printed below, has itself been
# indexed. A secondmate home's clone is an independent checkout at a different
# absolute path, and SocratiCode derives identity from the path, so the main
# home's index says nothing about it. A marker that reached a home by having its
# registry line copied in rather than by that home's own clone being indexed is
# a registry error to report and correct, not coverage.
# It deliberately cannot read the third and decisive fact, whether the index is
# live, because that lives in the MCP server rather than on disk. The caller
# confirms it with one codebase_list_projects call and compares the absolute
# path printed here. A marker can drift from the live index, so a caller that
# skips that comparison is trusting a stale record.
#
# projectPath is the main checkout, never a task worktree. SocratiCode derives
# project identity from the path when no project id is configured, so a call
# made from a worktree - or with projectPath omitted, which resolves to the
# working directory - looks like a brand-new project and invites a full
# re-index of a checkout that is discarded at teardown. Passing the path
# printed here is what prevents that.
#
# Output is stable `key: value` lines, one per key, in this order:
#   project, registry, projectPath, clone, verify
#
# Exit codes:
#   0  this home is marked enabled and its own clone is present; projectPath is
#      the path this home's marker asserts is indexed, still to be confirmed live
#   1  usage error, or the project is not in the registry at all
#   3  registered but NOT marked +socraticode; use ordinary tools
#   4  marked +socraticode but this home has no such clone; report the
#      disagreement rather than degrading silently. A marker never crosses
#      homes - local and remote seeding both strip it from a copied registry
#      line - so this state is this home's own marker outliving its own clone,
#      never an inherited one.
#
# Usage: fm-socraticode.sh <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

NAME=${1:-}
[ -n "$NAME" ] || { echo "usage: fm-socraticode.sh <project-name>" >&2; exit 1; }
if [ "$#" -gt 1 ]; then
  echo "error: fm-socraticode.sh takes exactly one project name" >&2
  exit 1
fi

# One registry parser: fm-project-mode.sh owns the annotation format, and a
# project absent from the registry is its non-zero exit rather than a default.
annotation=$("$SCRIPT_DIR/fm-project-mode.sh" --annotation "$NAME") || exit 1

enabled=no
for token in $annotation; do
  [ "$token" = "+socraticode" ] && enabled=yes
done

path="$PROJECTS/$NAME"
clone=present
[ -d "$path" ] || clone=absent

printf 'project: %s\n' "$NAME"
if [ "$enabled" = no ]; then
  printf 'registry: not-marked\n'
  printf 'projectPath: -\n'
  printf 'clone: %s\n' "$clone"
  printf 'verify: not enabled here; use ordinary search and read tools\n'
  exit 3
fi

printf 'registry: enabled\n'
printf 'projectPath: %s\n' "$path"
printf 'clone: %s\n' "$clone"
if [ "$clone" = absent ]; then
  printf 'verify: marked enabled but no clone at the path above; report the disagreement and use ordinary tools\n'
  exit 4
fi
printf 'verify: codebase_list_projects must list the projectPath above before you rely on it\n'
