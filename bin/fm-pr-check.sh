#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and the forge's
# exact pr_head=<sha> when available, then atomically arm a static merge poll.
# Refuses when bin/fm-dod-lib.sh will not accept the named head as reachable
# outside the worker's disposable copy; in no-mistakes mode a forge-reported
# head is that named head and is already stored on the forge.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# A GitHub pull request URL, a GitLab merge request URL, and a Gerrit change URL
# are all accepted, including a merge request or change on a self-hosted
# instance.
# A GitHub pull request the forge reports as a draft is refused, naming the draft
# state and recording and arming nothing: a draft cannot be merged, so a poll armed on it
# would wait for an event that cannot occur while nobody is asked to act.
# Mark the pull request ready for review, then arm again; a lane that keeps a
# draft on purpose declares a wait instead of reporting done. An unreadable
# draft state does not refuse, matching how the head read below is optional.
# bin/fm-pr-merge.sh records through this script with FM_PR_CHECK_MERGE=1 and
# skips this refusal, because its own merge-time draft refusal is authoritative.
# The recorded pr= also frees the task's place in a declared project capacity
# (bin/fm-project-capacity-lib.sh).
#
# --team-review records whether the task's already-recorded PR is out with the
# project's human reviewers, as team_review=<in-review|done> bound to that URL by
# team_review_pr=<url> (bin/fm-pr-lib.sh's fm_pr_team_review_state owns the read),
# written ahead of pr= because the metadata identity parse refuses unrecognized
# keys after it. It never touches the merge poll, so a merge during team review
# is still seen. The two states overwrite each other, which is also how a
# mistaken record is corrected.
#   in-review  record the PR as in team review and declare the task's wait with
#              `paused [key=team-review]: PR <url> in team review`, so an idle
#              worker takes the declared-wait cadence rather than stall alerts.
#   done       record team review as finished for the PR's current head, read
#              live from the forge and otherwise taken from the recorded
#              pr_head, as team_review_head=<sha>; with no readable head it
#              refuses. A recorded pr_head is updated to that head too, so a
#              push not yet re-recorded does not leave the done record reading
#              in team review. That record is the evidence bin/fm-pr-merge.sh
#              requires for a feature on a project registered +team-review.
# done ends the declared wait, when it is still the task's current one, with
# `done [key=team-review]: PR <url> team review done`, so the task reads as ready.
# A later ordinary recording of the same PR at a different head (a new round
# pushed after review) turns the done record back into in-review and declares
# the wait again, so team review is recorded again for what the team has not
# seen. Status lines go through the self-announced append (bin/fm-wake-lib.sh),
# so they do not wake the session that wrote them.
#
# --feature records an existing ship task's classification as a feature or not,
# as feature=<yes|no>, for a task already past intake (bin/fm-spawn.sh and
# bin/fm-promote.sh --feature classify at intake). It is written ahead of pr=
# for the same reason, replaces any earlier classification, and never touches
# the merge poll.
# Usage: fm-pr-check.sh <task-id> <pr-url>
#        fm-pr-check.sh --team-review <in-review|done> <task-id>
#        fm-pr-check.sh --feature <yes|no> <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"

# The PR's current head for a done record: live from the forge first, then the
# recorded pr_head. Prints nothing when neither is readable.
team_review_current_head() {  # <meta> <url>
  local meta=$1 url=$2 head=''
  if fm_pr_url_parse "$url"; then
    case "$FM_PR_PROVIDER" in
      github)
        command -v gh >/dev/null 2>&1 \
          && head=$(gh pr view "$url" --json headRefOid -q .headRefOid 2>/dev/null) || head=''
        ;;
      gitlab)
        command -v glab >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
          && head=$(GITLAB_HOST="$FM_PR_HOST" glab mr view "$FM_PR_NUMBER" -R "https://$FM_PR_HOST/$FM_PR_PATH" -F json 2>/dev/null \
            | jq -r '.sha // empty' 2>/dev/null) || head=''
        ;;
    esac
  fi
  fm_pr_head_valid "$head" || head=$(grep '^pr_head=' "$meta" | tail -1 | cut -d= -f2- || true)
  fm_pr_head_valid "$head" || return 0
  printf '%s\n' "$head"
}

# Replace <meta> under the task's metadata lock with what <filter> <args...>
# prints when given the current record on stdin.
meta_rewrite() {  # <meta> <filter> [<args>...]
  local meta=$1 lock tmp rc=0
  shift
  lock=$(fm_meta_lock_path "$meta") || return 1
  fm_lock_acquire_wait "$lock" || return 1
  tmp=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || { fm_lock_release "$lock" || true; return 1; }
  "$@" < "$meta" > "$tmp" && chmod 0600 "$tmp" && mv -f -- "$tmp" "$meta" || rc=1
  [ "$rc" -eq 0 ] || rm -f -- "$tmp"
  fm_lock_release "$lock" || true
  return "$rc"
}

# The team-review record, ahead of the pr= line. <head> is given only for a
# done record, which also becomes the recorded pr_head where one is recorded.
team_review_lines() {  # <state> <url> [<head>]
  local state=$1 url=$2 head=${3:-} line written=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      team_review=*|team_review_pr=*|team_review_head=*) continue ;;
      pr=*)
        if [ "$written" -eq 0 ]; then
          printf 'team_review=%s\nteam_review_pr=%s\n' "$state" "$url" || return 1
          [ -z "$head" ] || printf 'team_review_head=%s\n' "$head" || return 1
          written=1
        fi
        ;;
      pr_head=*) [ -z "$head" ] || line="pr_head=$head" ;;
    esac
    printf '%s\n' "$line" || return 1
  done
}

team_review_write() {  # <meta> <state> <url> [<head>]
  meta_rewrite "$1" team_review_lines "$2" "$3" "${4:-}"
}

# The one feature classification, ahead of the pr= line, or last when no PR is
# recorded yet.
feature_lines() {  # <yes|no>
  local value=$1 line written=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      feature=*) continue ;;
      pr=*)
        if [ "$written" -eq 0 ]; then
          printf 'feature=%s\n' "$value" || return 1
          written=1
        fi
        ;;
    esac
    printf '%s\n' "$line" || return 1
  done
  [ "$written" -eq 1 ] || printf 'feature=%s\n' "$value"
}

feature_command() {  # <yes|no> <task-id>
  local value=$1 id=$2 meta kind
  case "$value" in
    yes|no) ;;
    *) echo "error: --feature takes yes or no" >&2; return 2 ;;
  esac
  fm_pr_task_id_valid "$id" || { echo "error: invalid PR check request" >&2; return 2; }
  meta="$STATE/$id.meta"
  if [ ! -f "$meta" ] || [ -L "$meta" ] || [ "$(fm_pr_file_link_count "$meta")" != 1 ]; then
    echo "error: task metadata is unavailable" >&2
    return 1
  fi
  kind=$(grep '^kind=' "$meta" | tail -1 | cut -d= -f2- || true)
  if [ -n "$kind" ] && [ "$kind" != ship ]; then
    echo "error: $id is a $kind, not a ship task; only a ship task carries a feature classification" >&2
    return 1
  fi
  meta_rewrite "$meta" feature_lines "$value" \
    || { echo "error: could not record the feature classification for $id" >&2; return 1; }
  printf 'feature: %s recorded feature=%s\n' "$id" "$value"
}

# 0 when the task's declared wait is this command's own team-review pause.
team_review_pause_declared() {  # <task-id>
  local wait
  wait=$(status_declared_wait_line "$STATE/$1.status")
  status_is_paused "$wait" && [ "$(_fm_decision_key "$wait" 2>/dev/null || true)" = team-review ]
}

# Append one team-review status line through the self-announced append.
team_review_status() {  # <task-id> <line>
  local rc=0
  fm_wake_status_append_self_announced "$STATE" "$STATE/$1.status" "$2" || rc=$?
  [ "$rc" -ne 2 ]
}

team_review_command() {  # <in-review|done> <task-id>
  local action=$1 id=$2 meta url kind head=''
  case "$action" in
    in-review|done) ;;
    *) echo "error: --team-review takes in-review or done" >&2; return 2 ;;
  esac
  fm_pr_task_id_valid "$id" || { echo "error: invalid PR check request" >&2; return 2; }
  meta="$STATE/$id.meta"
  if [ ! -f "$meta" ] || [ -L "$meta" ] || [ "$(fm_pr_file_link_count "$meta")" != 1 ]; then
    echo "error: task metadata is unavailable" >&2
    return 1
  fi
  kind=$(grep '^kind=' "$meta" | tail -1 | cut -d= -f2- || true)
  if [ "$kind" = secondmate ]; then
    echo "error: $id is a secondmate, not a delivery lane; record team review on the task in the mate's own home" >&2
    return 1
  fi
  url=$(grep '^pr=' "$meta" | tail -1 | cut -d= -f2- || true)
  if [ -z "$url" ]; then
    echo "error: $id has no recorded PR; record it with fm-pr-check.sh $id <pr-url> first" >&2
    return 1
  fi
  if [ "$action" = "done" ]; then
    head=$(team_review_current_head "$meta" "$url")
    if [ -z "$head" ]; then
      echo "error: the current head of $url could not be read, so team review cannot be recorded against the commits the team reviewed; retry when the forge is reachable" >&2
      return 1
    fi
  fi
  team_review_write "$meta" "$action" "$url" "$head" \
    || { echo "error: could not record team review for $id" >&2; return 1; }

  # Only this command's own pause is ever declared or ended here: a worker that
  # has moved on since keeps whatever its own latest event says.
  if [ "$action" = in-review ]; then
    team_review_pause_declared "$id" \
      || team_review_status "$id" "paused [key=team-review]: PR $url in team review" \
      || { echo "error: recorded team review for $id but could not append its status line" >&2; return 1; }
    printf 'team review: %s in team review\n' "$url"
  else
    ! team_review_pause_declared "$id" \
      || team_review_status "$id" "done [key=team-review]: PR $url team review done" \
      || { echo "error: recorded team review for $id but could not append its status line" >&2; return 1; }
    printf 'team review: %s team review done at %s\n' "$url" "$head"
  fi
}

if [ "${1:-}" = --team-review ]; then
  [ "$#" -eq 3 ] || { echo "usage: fm-pr-check.sh --team-review <in-review|done> <task-id>" >&2; exit 2; }
  team_review_command "$2" "$3"
  exit $?
fi
if [ "${1:-}" = --feature ]; then
  [ "$#" -eq 3 ] || { echo "usage: fm-pr-check.sh --feature <yes|no> <task-id>" >&2; exit 2; }
  feature_command "$2" "$3"
  exit $?
fi

if [ "$#" -ne 2 ]; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
HOST=$FM_PR_HOST
PROJECT_PATH=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# A secondmate is a persistent worker, not a delivery lane: it never owns a
# pull request of its own. A URL reported on its routed status channel belongs
# to a task inside the mate's own home, which records and watches it there;
# arming a merge watch here would queue the mate itself for teardown as landed
# work once that pull request merges.
KIND=$(grep '^kind=' "$META" | tail -1 | cut -d= -f2- || true)
if [ "$KIND" = secondmate ]; then
  echo "error: $ID is a secondmate, not a delivery lane - $URL was reported on its status channel but belongs to a task in the mate's own home, which arms its own merge watch" >&2
  exit 1
fi

# A prior exact merged result may have queued its durable wake immediately
# before interruption.
# Finish only its identity-bound receipt before publishing a replacement poll.
fm_pr_poll_retirement_recover_one "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || {
  echo "error: pending PR poll retirement could not be validated" >&2
  exit 1
}

# Refuse to arm a watch with no CLI on PATH to read it. The poll is silent on
# every error by design, so a missing CLI would be indistinguishable from a
# change that is never merged. Arming is the one point where that can be
# reported, so the absent tool stops the watch here instead of watching nothing.
# The Gerrit poll also needs jq, because Gerrit's status has to be read out of a
# structured record rather than off a rendered line: the tool's own table prints
# a change's subject before its status, and a subject is free text.
if [ "$PROVIDER" = gitlab ] && ! command -v glab >/dev/null 2>&1; then
  echo "error: watching a GitLab merge request requires glab on PATH" >&2
  exit 1
fi
if [ "$PROVIDER" = gerrit ]; then
  if ! command -v gerrit-axi >/dev/null 2>&1; then
    echo "error: watching a Gerrit change requires gerrit-axi on PATH" >&2
    exit 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "error: watching a Gerrit change requires jq on PATH" >&2
    exit 1
  fi
fi

# The draft state is read before anything is recorded or armed. Only a positive
# draft reading refuses, because an unreadable one must not block arming.
if [ "$PROVIDER" = github ] && [ "${FM_PR_CHECK_MERGE:-}" != 1 ] && command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  DRAFT_JSON=$(gh pr view "$URL" --json isDraft 2>/dev/null || true)
  if [ "$(fm_pr_json_draft_state "$DRAFT_JSON")" = true ]; then
    echo "error: $URL is a draft pull request; a draft cannot be merged, so merge monitoring would wait for an event that cannot occur - mark it ready for review and arm again, or declare a wait instead of done if the draft is deliberate" >&2
    exit 1
  fi
fi

"$FM_ROOT/bin/fm-guard.sh" || true

# pr_head is recorded only when the forge's CLI can supply it. gh exposes the
# head commit as a selectable field; plain glab exposes it only inside its JSON
# output, which would need a JSON processor firstmate does not require, so a
# GitLab task records no pr_head, and neither does a Gerrit task: a Gerrit
# revision names one patch set, every amend or rebase is a new patch set, and
# bin/fm-review-diff.sh has no Gerrit path to resolve a current head with, so a
# recorded revision would silently become the reviewed content. Both consumers
# already treat it as optional:
# bin/fm-teardown.sh reads the head from the forge at teardown rather than from
# metadata and falls back to its provider-agnostic content check, and
# bin/fm-review-diff.sh fetches a pull request head from the remote when none is
# recorded and otherwise diffs the local branch, which is the current content.
# bin/fm-pr-merge.sh reads a GitLab head live at merge time for the same reason,
# and treats a recorded value that disagrees as stale rather than authoritative.
WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD=
if [ "$PROVIDER" = github ] && [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
  if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
    && fm_pr_head_valid "$REMOTE_HEAD"; then
    PR_HEAD=$REMOTE_HEAD
  fi
fi

MODE=$(grep '^mode=' "$META" | tail -1 | cut -d= -f2- || true)
PROJECT=$(grep '^project=' "$META" | tail -1 | cut -d= -f2- || true)
# The gate is asked about the ready report this task's worker was told to give;
# on a Gerrit change both publishing modes report the same published line.
case "$PROVIDER:$MODE" in
  gerrit:*) DONE_LINE="done: PR $URL published for review" ;;
  *:no-mistakes|*:) DONE_LINE="done: PR $URL checks green" ;;
  *) DONE_LINE="done: PR $URL" ;;
esac
if { [ -z "$PR_HEAD" ] || ! fm_dod_forge_head_is_named_head "$MODE"; } \
  && ! GATE_REASON=$(fm_dod_accept_ship_done "${KIND:-ship}" "$MODE" "$WT" "$PROJECT" "$DONE_LINE" "$STATE" "$ID" "$META"); then
  echo "error: $GATE_REASON" >&2
  exit 1
fi

META_TMP=
META_LOCK=
META_LOCK_HELD=0
PR_POLL_PUBLISH_LOCK=
PR_POLL_PUBLISH_LOCK_HELD=0
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  if [ "$PR_POLL_PUBLISH_LOCK_HELD" = 1 ]; then
    fm_lock_release "$PR_POLL_PUBLISH_LOCK" || true
    PR_POLL_PUBLISH_LOCK_HELD=0
  fi
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
chmod 0600 "$META_TMP" || exit 1
fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META_TMP" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=
fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0

PR_POLL_PUBLISH_LOCK="$STATE/.pr-poll-publish-$ID.lock"
fm_lock_acquire_wait "$PR_POLL_PUBLISH_LOCK"
PR_POLL_PUBLISH_LOCK_HELD=1
if fm_pr_poll_publish_prepared; then
  fm_lock_release "$PR_POLL_PUBLISH_LOCK" || exit 1
  PR_POLL_PUBLISH_LOCK_HELD=0
else
  fm_lock_release "$PR_POLL_PUBLISH_LOCK" || exit 1
  PR_POLL_PUBLISH_LOCK_HELD=0
  echo "error: could not publish PR poll" >&2
  exit 1
fi
# A done team review recorded for an earlier head of this PR no longer covers
# it: record it in team review again and declare the wait, so the new commits
# are reviewed before a gated merge. The merge-time re-record leaves the record
# alone, because bin/fm-pr-merge.sh compares the head it verifies itself.
if [ "${FM_PR_CHECK_MERGE:-}" != 1 ] && [ -n "$(fm_pr_team_review_head "$META")" ] \
  && [ "$(fm_pr_team_review_state "$META")" = in-review ]; then
  if team_review_write "$META" in-review "$URL"; then
    team_review_pause_declared "$ID" \
      || team_review_status "$ID" "paused [key=team-review]: PR $URL in team review again for its new head" \
      || printf 'actionable: %s is back in team review but its status line could not be appended\n' "$URL" >&2
    printf 'team review: %s has new commits since its team review; recorded in team review again\n' "$URL" >&2
  else
    printf 'actionable: %s has new commits since its team review, but the record could not be returned to in team review\n' "$URL" >&2
  fi
fi
# Opt-in fleet activity ledger (docs/fleet-ledger.md); off costs one file test.
# The merge-time re-record is not a new review-ready PR, so it writes nothing.
[ ! -e "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/fleet-ledger" ] || [ "${FM_PR_CHECK_MERGE:-}" = 1 ] \
  || FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/fm-fleet-ledger.sh" pr_ready "$ID" "$URL" || true
# The contribution observer uses the same authenticated check mechanism and
# owns verdict freshness, required actors and external feedback separately from
# the exact merged-state poll. Registration is local and performs no forge read.
if command -v jq >/dev/null 2>&1; then
  "$SCRIPT_DIR/fm-contributions.sh" arm >/dev/null \
    || printf 'contributions: observation not armed; coverage is unconfirmed\n' >&2
else
  printf 'contributions: jq unavailable; coverage is unconfirmed\n' >&2
fi
# In a secondmate home the registration itself is a captain-facing fact:
# publish the child's PR-ready line with the canonical URL just recorded, so it
# reaches the parent whether or not the mate model appends anything
# (bin/fm-parent-channel-lib.sh). A main home has no channel and this is a
# silent no-op there. The poll is armed either way; a channel that cannot be
# written is reported as actionable, and bin/fm-inactive-reconcile.sh still
# delivers the child's own ready line on the next supervision poll.
READY_LINE="done [key=child-pr-$ID]: child $ID PR ready: $URL"
PR_MODE=$(grep '^mode=' "$META" | tail -1 | cut -d= -f2- || true)
PR_YOLO=$(grep '^yolo=' "$META" | tail -1 | cut -d= -f2- || true)
[ -z "$PR_MODE" ] || READY_LINE="$READY_LINE mode=$(fm_parent_channel_clean_note "$PR_MODE")"
[ -z "$PR_YOLO" ] || READY_LINE="$READY_LINE yolo=$(fm_parent_channel_clean_note "$PR_YOLO")"
READY_RC=0
fm_parent_channel_report "$FM_HOME" "$STATE" "$READY_LINE" || READY_RC=$?
case "$READY_RC" in
  0|1) ;;
  *) printf 'actionable: PR %s is registered but its ready line did not reach the parent channel (rc=%s)\n' "$URL" "$READY_RC" >&2 ;;
esac
printf 'armed: state/%s.check.sh\n' "$ID"
