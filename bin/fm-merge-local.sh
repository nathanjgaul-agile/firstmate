#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's immutable ship branch recorded in
# state/<task-id>.meta ("fm/<id>" for records created before that field existed).
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and onto the default branch only as a clean fast-forward - it
# refuses a diverged branch and tells you to have the crewmate rebase. See AGENTS.md prime directives,
# project management, and task lifecycle.
# The task's existing per-task control lock serializes the captain-hold check
# through that fast-forward. A still-held or unreadable row refuses before the
# merge, so a captain approval must be recorded as an `answer --release` before
# this entrypoint is invoked. The lock ends when the fast-forward returns;
# docs/captain-hold-lifecycle.md owns the accepted merge-to-cleanup residual.
#
# --onto <feature-branch> lands the ship branch on a named local feature branch
# instead of the default branch, so several tasks combine there before one
# feature PR. A missing feature branch starts at the default branch tip. It
# fast-forwards when it can, otherwise writes a merge commit, and refuses
# (touching nothing) when the task's copy has uncommitted work, when the feature
# branch is checked out somewhere other than a clean project checkout, or when
# the branches conflict, naming the conflicting files. The landing is recorded
# as landed_onto=<feature-branch> in the task meta, which fm-teardown.sh accepts
# as landed. --push then pushes the feature branch to origin as a backup (never
# forced, never a PR); a failed push leaves the landing in place and exits 3.
# Usage: fm-merge-local.sh <task-id> [--onto <feature-branch> [--push]]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
ID=${1-}
ONTO=
PUSH=0
[ "$#" -eq 0 ] || shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --onto) [ "$#" -ge 2 ] || { echo "error: --onto needs a branch" >&2; exit 2; }; ONTO=$2; shift 2 ;;
    --push) PUSH=1; shift ;;
    *) echo "error: invalid local merge request" >&2; exit 2 ;;
  esac
done
if ! fm_pr_task_id_valid "$ID" || { [ "$PUSH" = 1 ] && [ -z "$ONTO" ]; }; then
  echo "error: invalid local merge request" >&2
  exit 2
fi
fm_backlog_directory_present "$STATE" "state directory" || {
  echo "error: local merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
META="$STATE/$ID.meta"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
# Role partition: landing local-only work is MAIN-owned; the Pi supervision
# branch reports readiness and never lands (contract: bin/fm-lease-lib.sh;
# no-op in homes without a branch actor). This action is deliberately NOT
# relocated under the away-posture record: unlike the PR merge it has no
# record-side grant gate of its own, so a parked main keeps it held for the
# captain's return. This precedes reading the task record, because the wrong
# actor is refused for its role whatever it says.
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "local-only landing (fm-merge-local)"

[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: local merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
MERGE_EXPECTED_SPAWN_GEN=$FM_BACKLOG_META_SPAWN_GEN

MERGE_CONTROL_LOCK=
merge_control_cleanup() {
  [ -z "$MERGE_CONTROL_LOCK" ] || fm_lock_release "$MERGE_CONTROL_LOCK" || true
}
trap merge_control_cleanup EXIT
MERGE_CONTROL_LOCK="$STATE/.control-$ID.lock"
fm_lock_acquire_wait "$MERGE_CONTROL_LOCK"
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: task $ID changed while waiting to merge; refusing: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
if [ "$FM_BACKLOG_META_SPAWN_GEN" != "$MERGE_EXPECTED_SPAWN_GEN" ]; then
  echo "error: task $ID changed incarnation while waiting to merge; refusing" >&2
  exit 1
fi

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

BRANCH=$(grep '^branch=' "$META" | cut -d= -f2- || true)
[ -n "$BRANCH" ] || BRANCH="fm/$ID"
if ! git check-ref-format --branch "$BRANCH" >/dev/null 2>&1; then
  echo "error: task $ID has an invalid recorded ship branch '$BRANCH'" >&2
  exit 1
fi
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

if [ -z "$ONTO" ]; then
  TARGET=$DEFAULT
  # The project's main checkout must be on its default branch and clean, so the
  # fast-forward lands predictably (firstmate never writes here otherwise).
  cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
  [ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
  if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
    echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
    exit 1
  fi

  # Clean fast-forward only: DEFAULT must be an ancestor of BRANCH.
  if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BRANCH"; then
    echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
    echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
    exit 1
  fi
else
  TARGET=$ONTO
  git check-ref-format --branch "$ONTO" >/dev/null 2>&1 || { echo "error: invalid feature branch '$ONTO'" >&2; exit 2; }
  [ "$ONTO" != "$DEFAULT" ] && [ "$ONTO" != "$BRANCH" ] \
    || { echo "error: --onto must name a feature branch, not $ONTO" >&2; exit 2; }
  WT=$(grep '^worktree=' "$META" | cut -d= -f2- || true)
  if [ -n "$WT" ] && [ -d "$WT" ] \
    && [ -n "$(git -C "$WT" status --porcelain | grep -vE '^\?\? (\.claude/|\.fm-(grok|kimi)-turnend$)' | head -1)" ]; then
    echo "REFUSED: $WT has uncommitted work that would not land; have the crewmate commit it, then retry." >&2
    exit 1
  fi
  old=$(git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$ONTO" || true)
  tip=${old:-$(git -C "$PROJ" rev-parse --verify "refs/heads/$DEFAULT")}
  # A feature branch checked out in the project checkout is advanced there (so
  # its working tree follows); checked out anywhere else, it is not ours to move.
  holder=$(git -C "$PROJ" worktree list --porcelain | awk -v ref="branch refs/heads/$ONTO" '
    /^worktree / { wt = substr($0, 10) } $0 == ref { print wt; exit }')
  if [ -n "$holder" ]; then
    [ "$(cd "$holder" && pwd -P)" = "$(cd "$PROJ" && pwd -P)" ] \
      || { echo "REFUSED: $ONTO is checked out in $holder; cannot land onto it safely" >&2; exit 1; }
    [ -z "$(git -C "$PROJ" status --porcelain | head -1)" ] \
      || { echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2; exit 1; }
  fi
  if git -C "$PROJ" merge-base --is-ancestor "$BRANCH" "$tip"; then
    new=$tip
  elif git -C "$PROJ" merge-base --is-ancestor "$tip" "$BRANCH"; then
    new=$(git -C "$PROJ" rev-parse "refs/heads/$BRANCH")
  else
    mt_status=0
    mt=$(git -C "$PROJ" merge-tree --write-tree --name-only --no-messages "$tip" "refs/heads/$BRANCH") || mt_status=$?
    if [ "$mt_status" -eq 1 ]; then
      echo "REFUSED: $BRANCH conflicts with $ONTO; nothing was changed. Conflicting files:" >&2
      printf '%s\n' "$mt" | sed -n '2,$p' | sed '/^$/d' >&2
      echo "Have the crewmate merge or rebase onto $ONTO, then retry." >&2
      exit 1
    fi
    [ "$mt_status" -eq 0 ] || { echo "error: cannot compute the merge of $BRANCH into $ONTO" >&2; exit 1; }
    new=$(git -C "$PROJ" commit-tree "$(printf '%s\n' "$mt" | head -1)" -p "$tip" -p "refs/heads/$BRANCH" \
      -m "Merge branch '$BRANCH' into $ONTO") || { echo "error: cannot write the merge commit" >&2; exit 1; }
  fi
fi

before=$(git -C "$PROJ" rev-parse --short "${old:-$DEFAULT}")
hold_status=0
FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$ID" --distinguish-absent || hold_status=$?
case "$hold_status" in
  0)
    echo "error: task $ID is still held for the captain; release it before merging" >&2
    exit 1
    ;;
  1|3) ;;
  *)
    echo "error: could not determine whether task $ID is still held for the captain; refusing to merge" >&2
    exit 1
    ;;
esac
merge_status=0
if [ -z "$ONTO" ]; then
  git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null || merge_status=$?
elif [ -n "$holder" ]; then
  git -C "$PROJ" merge --ff-only "$new" >/dev/null || merge_status=$?
else
  git -C "$PROJ" update-ref -m "fm-merge-local: land $BRANCH" "refs/heads/$ONTO" "$new" "$old" || merge_status=$?
fi
fm_lock_release "$MERGE_CONTROL_LOCK" || true
MERGE_CONTROL_LOCK=
[ "$merge_status" -eq 0 ] || exit "$merge_status"
after=$(git -C "$PROJ" rev-parse --short "refs/heads/$TARGET")
if [ -n "$ONTO" ]; then
  if ! meta_lock=$(fm_meta_lock_path "$META") || ! fm_lock_acquire_wait "$meta_lock"; then
    echo "error: landed, but cannot lock $META to record it" >&2
    exit 1
  fi
  meta_tmp=$(mktemp "$STATE/.fm-merge-local-meta.XXXXXX") \
    && grep -v '^landed_onto=' "$META" > "$meta_tmp" \
    && printf 'landed_onto=%s\n' "$ONTO" >> "$meta_tmp" \
    && chmod 0600 "$meta_tmp" && mv -f -- "$meta_tmp" "$META" || meta_status=1
  fm_lock_release "$meta_lock" || true
  [ -z "${meta_status:-}" ] || { rm -f -- "$meta_tmp"; echo "error: landed, but cannot record landed_onto in $META" >&2; exit 1; }
fi
# Opt-in fleet activity ledger (docs/fleet-ledger.md); off costs one file test.
[ ! -e "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/fleet-ledger" ] || FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/fm-fleet-ledger.sh" merged "$ID" local || true
echo "merged $BRANCH into local $TARGET ($before -> $after) in $PROJ"
if [ "$PUSH" = 1 ] && ! git -C "$PROJ" push origin "refs/heads/$ONTO:refs/heads/$ONTO" >&2; then
  echo "warning: $ONTO landed locally, but the backup push to origin failed" >&2
  exit 3
fi
