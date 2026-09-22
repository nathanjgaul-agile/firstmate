#!/usr/bin/env bash
# Behavior tests for bin/fm-socraticode.sh and the +socraticode registry marker.
#
# Two contracts are under test. First, the marker is additive: it must be
# readable as a capability flag without ever changing the project's registered
# delivery posture, because the delivery gate and the capability share one
# registry line and one parser (bin/fm-project-mode.sh). Second, enablement is
# reported in states rather than as a boolean, so a marker that has drifted from
# the live index surfaces as a distinct, actionable exit code instead of a
# silent downgrade.
#
# The live index itself is deliberately not asserted here: it lives in the MCP
# server rather than on disk, so the script's whole job is to name the path a
# caller must confirm, which is what these tests pin.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SOC="$ROOT/bin/fm-socraticode.sh"
MODE="$ROOT/bin/fm-project-mode.sh"
TMP_ROOT=$(fm_test_tmproot fm-socraticode)

make_home() {
  local home=$1
  mkdir -p "$TMP_ROOT/$home/data" "$TMP_ROOT/$home/projects"
  cat > "$TMP_ROOT/$home/data/projects.md" <<'REG'
# Projects registry

- marked [no-mistakes-prod-only +socraticode] - enabled and cloned (added 2026-09-15)
- plain [direct-PR] - registered without the marker (added 2026-09-01)
- legacy - legacy line with no annotation at all (added 2026-08-01)
- yolo-too [direct-PR +yolo +socraticode] - both additive flags (added 2026-09-02)
- ghost [no-mistakes +socraticode] - marked but never cloned here (added 2026-09-03)
- bare-flag [+socraticode] - the marker with no mode token beside it (added 2026-09-04)
- bare-both [+socraticode +yolo] - flags alone, yolo among them (added 2026-09-05)
- bare-yolo [+yolo] - the long-supported flags-only spelling (added 2026-09-06)
- mis-mode [+socraticode local-only] - the mode written after the marker (added 2026-09-07)
- mis-yolo [+socraticode +yolo direct-PR] - a misplaced mode beside +yolo (added 2026-09-08)
REG
  mkdir -p "$TMP_ROOT/$home/projects/marked" "$TMP_ROOT/$home/projects/plain" \
    "$TMP_ROOT/$home/projects/legacy" "$TMP_ROOT/$home/projects/yolo-too" \
    "$TMP_ROOT/$home/projects/bare-flag" "$TMP_ROOT/$home/projects/bare-both"
  printf '%s\n' "$TMP_ROOT/$home"
}

# Sets SOC_OUT and SOC_RC as globals rather than printing: a command
# substitution would run the helper in a subshell and lose the exit code, and
# the exit code is half of what this script's contract promises.
SOC_OUT=
SOC_RC=0
soc() {  # <home> <project>
  local home=$1 project=$2
  SOC_OUT=$(FM_HOME="$home" "$SOC" "$project" 2>&1) && SOC_RC=0 || SOC_RC=$?
}

# The capability marker rides in the same bracket annotation as the delivery
# mode. If reading it ever perturbed that mode, a project could silently ship
# through the wrong gate, so this pins posture against every marker shape.
test_marker_never_changes_delivery_posture() {
  local home
  home=$(make_home posture)
  assert_equals "no-mistakes off" "$(FM_HOME="$home" "$MODE" marked)" \
    "a +socraticode marker must not change the mapped delivery posture"
  assert_equals "no-mistakes-prod-only off" "$(FM_HOME="$home" "$MODE" --raw marked)" \
    "a +socraticode marker must not change the raw registered annotation"
  assert_equals "direct-PR on" "$(FM_HOME="$home" "$MODE" yolo-too)" \
    "+yolo must still be honoured alongside +socraticode"
  assert_equals "direct-PR off" "$(FM_HOME="$home" "$MODE" plain)" \
    "an unmarked project keeps its registered posture"
  pass "fm-socraticode: the +socraticode marker is additive and posture-neutral"
}

# An annotation may carry additive flags alone: `[+yolo]` has always been a
# legal spelling, so `[+socraticode]` is one too. A leading flag is not a mode,
# and reading it as one both warns spuriously and drops yolo through the
# unknown-mode fallback, silently downgrading the project's merge authority.
test_flag_only_annotation_keeps_the_default_mode_and_its_flags() {
  local home err
  home=$(make_home bareflag)
  assert_equals "no-mistakes off" "$(FM_HOME="$home" "$MODE" bare-flag 2>/dev/null)" \
    "a flag-only annotation must resolve to the default mode"
  err=$(FM_HOME="$home" "$MODE" bare-flag 2>&1 >/dev/null)
  assert_equals "" "$err" "a leading additive flag must not warn as an unknown mode"
  assert_equals "no-mistakes on" "$(FM_HOME="$home" "$MODE" bare-both 2>/dev/null)" \
    "+yolo must survive beside a leading additive flag"
  assert_equals "no-mistakes on" "$(FM_HOME="$home" "$MODE" bare-yolo 2>/dev/null)" \
    "the flags-only +yolo spelling must keep resolving yolo on"
  assert_equals "+socraticode +yolo" "$(FM_HOME="$home" "$MODE" --annotation bare-both 2>/dev/null)" \
    "--annotation must print the flag-only token list verbatim"
  soc "$home" bare-flag
  expect_code 0 "$SOC_RC" \
    "a flag-only annotation must still read as enabled (got: $SOC_OUT)"
  pass "fm-socraticode: a flag-only annotation keeps the default mode and its flags"
}

# The mode is only ever the first token. A line that writes it after the marker
# means a posture the parser cannot honour, so it must say so instead of
# resolving to the default in silence - and it must never leave yolo on, or a
# malformed line would grant merge authority the captain never registered.
test_misplaced_mode_token_warns_and_falls_back() {
  local home err
  home=$(make_home misplaced)
  assert_equals "no-mistakes off" "$(FM_HOME="$home" "$MODE" mis-mode 2>/dev/null)" \
    "a mode written after the marker must fall back to the default posture"
  err=$(FM_HOME="$home" "$MODE" mis-mode 2>&1 >/dev/null)
  assert_contains "$err" "local-only" \
    "the warning must name the misplaced token (got: $err)"
  assert_equals "no-mistakes off" "$(FM_HOME="$home" "$MODE" mis-yolo 2>/dev/null)" \
    "a malformed line must never resolve yolo on"
  assert_equals "no-mistakes off" "$(FM_HOME="$home" "$MODE" --raw mis-mode 2>/dev/null)" \
    "--raw must report the same fallback rather than the unreadable posture"
  assert_equals "+socraticode local-only" \
    "$(FM_HOME="$home" "$MODE" --annotation mis-mode 2>/dev/null)" \
    "--annotation stays a verbatim read of whatever the line carries"
  pass "fm-socraticode: a misplaced mode token warns and falls back"
}

# --annotation exists so capability readers reuse the single registry parser.
# It must return what is written, not the mapped posture, and must refuse an
# unregistered project rather than answering with a default.
test_annotation_query_is_a_raw_registry_read() {
  local home out rc
  home=$(make_home annotation)
  assert_equals "no-mistakes-prod-only +socraticode" \
    "$(FM_HOME="$home" "$MODE" --annotation marked)" \
    "--annotation must print the verbatim token list"
  assert_equals "" "$(FM_HOME="$home" "$MODE" --annotation legacy)" \
    "a legacy line with no annotation must print nothing"
  out=$(FM_HOME="$home" "$MODE" --annotation absent 2>&1); rc=$?
  expect_code 1 "$rc" "--annotation must fail for an unregistered project"
  assert_contains "$out" "not in registry" \
    "--annotation must say why it failed (got: $out)"
  pass "fm-socraticode: --annotation is a raw read that refuses to guess"
}

# The enabled path's whole purpose is to hand the caller one absolute path and
# tell it the path is not yet proven.
test_enabled_project_reports_the_path_to_verify() {
  local home out
  home=$(make_home enabled)
  soc "$home" marked; out=$SOC_OUT
  expect_code 0 "$SOC_RC" "a marked, cloned project must exit 0 (got: $out)"
  assert_contains "$out" "registry: enabled" "must report the marker (got: $out)"
  assert_contains "$out" "projectPath: $home/projects/marked" \
    "must print the absolute main-checkout path (got: $out)"
  assert_contains "$out" "clone: present" "must report the clone (got: $out)"
  assert_contains "$out" "codebase_list_projects" \
    "must tell the caller the live index is what settles enablement (got: $out)"
  pass "fm-socraticode: an enabled project reports its one legal projectPath"
}

# An unmarked project must not be handed a path at all: printing one would
# invite exactly the unindexed-path call the contract exists to prevent.
test_unmarked_project_is_distinguishable_and_pathless() {
  local home out
  home=$(make_home unmarked)
  for project in plain legacy; do
    soc "$home" "$project"; out=$SOC_OUT
    expect_code 3 "$SOC_RC" "an unmarked project must exit 3 (got: $out)"
    assert_contains "$out" "registry: not-marked" \
      "must say the project is not marked (got: $out)"
    assert_contains "$out" "projectPath: -" \
      "an unmarked project must not be handed a queryable path (got: $out)"
    assert_not_contains "$out" "$home/projects/$project" \
      "an unmarked project must not print a main-checkout path (got: $out)"
  done
  pass "fm-socraticode: an unmarked project is distinguishable and gets no path"
}

# Drift between the registry and reality is the case the brief called out: it
# must be visible and separately actionable, never collapsed into "not enabled".
test_marked_without_clone_is_its_own_state() {
  local home out
  home=$(make_home drift)
  soc "$home" ghost; out=$SOC_OUT
  expect_code 4 "$SOC_RC" "marked-but-uncloned must exit 4, not 0 or 3 (got: $out)"
  assert_contains "$out" "registry: enabled" \
    "the marker is still what the registry says (got: $out)"
  assert_contains "$out" "clone: absent" "must report the missing clone (got: $out)"
  assert_contains "$out" "report the disagreement" \
    "must tell the caller to report rather than degrade silently (got: $out)"
  pass "fm-socraticode: a marked project with no clone is its own reported state"
}

test_unregistered_project_and_usage_errors_fail_closed() {
  local home out rc
  home=$(make_home usage)
  soc "$home" nowhere; out=$SOC_OUT
  expect_code 1 "$SOC_RC" "an unregistered project must fail (got: $out)"
  out=$(FM_HOME="$home" "$SOC" 2>&1); rc=$?
  expect_code 1 "$rc" "a missing project name must fail (got: $out)"
  out=$(FM_HOME="$home" "$SOC" marked extra 2>&1); rc=$?
  expect_code 1 "$rc" "a second argument must fail rather than be ignored (got: $out)"
  out=$(FM_HOME="$home" "$SOC" --help 2>&1); rc=$?
  expect_code 0 "$rc" "--help must succeed (got: $out)"
  assert_contains "$out" "never a task worktree" \
    "--help must carry the worktree rule (got: $out)"
  pass "fm-socraticode: unregistered projects and usage errors fail closed"
}

test_marker_never_changes_delivery_posture
test_flag_only_annotation_keeps_the_default_mode_and_its_flags
test_misplaced_mode_token_warns_and_falls_back
test_annotation_query_is_a_raw_registry_read
test_enabled_project_reports_the_path_to_verify
test_unmarked_project_is_distinguishable_and_pathless
test_marked_without_clone_is_its_own_state
test_unregistered_project_and_usage_errors_fail_closed
