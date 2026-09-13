#!/usr/bin/env bash
# Behavior tests for bin/fm-branch-lib.sh, the single owner of a task's git
# branch name. Covers the forward map (project -> prefix, default fm/), the
# reverse map (PR head -> task id) that bin/fm-bearings-snapshot.sh relies on,
# name-or-path input normalization, and fail-closed handling of a malformed
# configured prefix.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-branch-lib.sh
. "$ROOT/bin/fm-branch-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-branch-lib)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data"
REG="$HOME_DIR/data/projects.md"

cat > "$REG" <<'EOF'
- widget-app [no-mistakes-prod-only branch=chore/fm-] - Example Corp widget platform, github.com/example-corp/widget-app (added 2026-09-11)
- gadget-svc [no-mistakes-prod-only] - Example Corp gadget service (added 2026-09-12)
- yolo-proj [direct-PR +yolo branch=feat/fm-] - a project with yolo and a prefix (added 2026-09-12)
- bad-prefix [no-mistakes branch=chore/deep/fm-] - malformed two-segment prefix (added 2026-09-12)
- fm-collision [no-mistakes branch=fm/fm-] - configured prefix collides with the default (added 2026-09-13)
EOF

# (1) An unconfigured project resolves to fm/<id>, exactly as today.
test_unconfigured_defaults_to_fm() {
  local out
  out=$(FM_HOME="$HOME_DIR" fm_branch_name gadget-svc task-1)
  assert_equals "fm/task-1" "$out" "a registered project with no branch= token stays fm/"

  out=$(FM_HOME="$HOME_DIR" fm_branch_name not-in-registry task-1)
  assert_equals "fm/task-1" "$out" "a project absent from the registry stays fm/"

  # No registry file at all also yields fm/ silently.
  out=$(FM_HOME="$TMP_ROOT/empty" fm_branch_name anything task-1)
  assert_equals "fm/task-1" "$out" "absent registry stays fm/ with no error"
  pass "unconfigured projects resolve to fm/<id>"
}

# (2) widget-app resolves to chore/fm-<id>.
test_configured_project_resolves_to_custom_prefix() {
  local out
  out=$(FM_HOME="$HOME_DIR" fm_branch_prefix widget-app)
  assert_equals "chore/fm-" "$out" "widget-app prefix is chore/fm-"

  out=$(FM_HOME="$HOME_DIR" fm_branch_name widget-app fm-widget-cleanup)
  assert_equals "chore/fm-fm-widget-cleanup" "$out" "widget-app branch keeps the literal fm-<id> substring"

  # The branch= token is order-independent within the bracket (after +yolo here).
  out=$(FM_HOME="$HOME_DIR" fm_branch_name yolo-proj task-9)
  assert_equals "feat/fm-task-9" "$out" "branch= parses regardless of position in the bracket"
  pass "widget-app and peers resolve to their configured prefix"
}

# (3) The reverse PR-head-to-task-id mapping recovers the id for both shapes,
#     including a task id that itself begins with fm- (the greedy trap).
test_reverse_maps_head_to_task_id() {
  local out rc
  out=$(fm_branch_task_id "fm/task-1"); assert_equals "task-1" "$out" "fm/<id> -> id"
  out=$(fm_branch_task_id "chore/fm-task-1"); assert_equals "task-1" "$out" "chore/fm-<id> -> id"
  out=$(fm_branch_task_id "feat/fm-task-9"); assert_equals "task-9" "$out" "feat/fm-<id> -> id"

  # id that starts with fm- must not be over-stripped in either shape.
  out=$(fm_branch_task_id "chore/fm-fm-widget-cleanup")
  assert_equals "fm-widget-cleanup" "$out" "chore/fm-fm-<id> keeps the fm- in the id"
  out=$(fm_branch_task_id "fm/fm-widget-cleanup")
  assert_equals "fm-widget-cleanup" "$out" "fm/fm-<id> keeps the fm- in the id"

  # A ref with no firstmate prefix is not a task branch (nonzero, no output).
  out=$(fm_branch_task_id "feature/JIRA-123-thing"); rc=$?
  expect_code 1 "$rc" "a foreign branch is not a firstmate task branch"
  assert_equals "" "$out" "a foreign branch yields no id"
  out=$(fm_branch_task_id "main"); rc=$?
  expect_code 1 "$rc" "a bare branch name is not a firstmate task branch"
  pass "reverse mapping recovers the task id for every produced shape"
}

# name-or-path input: an absolute project path resolves via its basename, so the
# path-holding consumers (merge-local, review-diff, promote) call the same helper.
test_accepts_name_or_path() {
  local out
  out=$(FM_HOME="$HOME_DIR" fm_branch_name "/Users/x/projects/widget-app" t2)
  assert_equals "chore/fm-t2" "$out" "an absolute project path resolves by basename"
  out=$(FM_HOME="$HOME_DIR" fm_branch_name "/Users/x/projects/widget-app/" t2)
  assert_equals "chore/fm-t2" "$out" "a trailing slash on the path is tolerated"
  pass "forward map accepts a bare name or an absolute path"
}

# Forward and reverse round-trip for every configured shape.
test_round_trips() {
  local proj id branch back
  for proj in gadget-svc widget-app yolo-proj; do
    for id in plain fm-starts-with-fm; do
      branch=$(FM_HOME="$HOME_DIR" fm_branch_name "$proj" "$id")
      back=$(fm_branch_task_id "$branch")
      assert_equals "$id" "$back" "round-trip $proj/$id via $branch"
    done
  done
  pass "forward then reverse recovers the original task id"
}

# A configured prefix of an unsupported shape fails closed rather than producing
# a branch the reverse mapping cannot recover.
test_malformed_prefix_fails_closed() {
  local out rc
  out=$(FM_HOME="$HOME_DIR" fm_branch_name bad-prefix t3 2>/dev/null); rc=$?
  expect_code 1 "$rc" "a two-segment prefix is refused"
  assert_equals "" "$out" "a malformed prefix yields no branch on stdout"
  pass "a malformed configured prefix fails closed"
}

# A configured prefix whose leading segment is literally `fm` (e.g. fm/fm-)
# would collide with the default fm/<id> shape in the reverse mapping, so it is
# refused just like any other malformed shape.
test_fm_fm_collision_fails_closed() {
  local out rc
  out=$(FM_HOME="$HOME_DIR" fm_branch_name fm-collision t4 2>/dev/null); rc=$?
  expect_code 1 "$rc" "a branch=fm/fm- prefix is refused"
  assert_equals "" "$out" "an fm/fm- prefix yields no branch on stdout"
  pass "a branch prefix colliding with the default fm segment fails closed"
}

# fm_branch_ref_is_default distinguishes the unconfigured fm/<id> shape from a
# configured <seg>/fm- shape, so a caller (bin/fm-bearings-snapshot.sh) can gate
# claim evidence on only the ambiguous configured shape.
test_ref_is_default_classifier() {
  fm_branch_ref_is_default "fm/task-1"
  expect_code 0 "$?" "fm/<id> is the default shape"
  ! fm_branch_ref_is_default "chore/fm-task-1"
  expect_code 0 "$?" "<seg>/fm-<id> is not the default shape"
  ! fm_branch_ref_is_default "feature/JIRA-123-thing"
  expect_code 0 "$?" "a foreign branch is not the default shape either"
  pass "fm_branch_ref_is_default classifies the two produced shapes"
}

test_unconfigured_defaults_to_fm
test_configured_project_resolves_to_custom_prefix
test_reverse_maps_head_to_task_id
test_accepts_name_or_path
test_round_trips
test_malformed_prefix_fails_closed
test_fm_fm_collision_fails_closed
test_ref_is_default_classifier
