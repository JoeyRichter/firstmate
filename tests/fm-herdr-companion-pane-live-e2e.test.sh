#!/usr/bin/env bash
# Default-on live guard for the Herdr presentation companion-pane tolerance.
#
# Whether a freshly created presentation workspace converges is decided by what
# a real Herdr plus its real installed plugins actually put in that workspace,
# and no fixture can prove that mapping: a canned registry only re-states the
# assumption already written into it. This guard builds the real projected
# shape with real Herdr calls, lets the real installed pane-injecting plugin
# dock its own companion pane into the task tab, and then asks the production
# convergence verifier for its verdict. It fails naming the Herdr version and
# the plugin version rather than degrading quietly.
#
# Its subject is the convergence verdict only. The shape is assembled here
# rather than through the projected-create helper on purpose, so the verdict is
# measured against a settled workspace instead of racing the plugin's
# asynchronous dock: the companion pane does not exist yet when the task tab is
# created, so a guard that merely ran a create could converge on a lone pane
# and prove nothing.
#
# A run submits no prompt and spends no model tokens, so the shared live gate
# runs it by default wherever its tools exist. Run it after every Herdr or
# pane-injecting-plugin upgrade and before trusting a refreshed
# docs/verification/runtime-backends.md "Presentation companion panes" entry.
#
# Every Herdr invocation is routed through bin/fm-herdr-lab.sh against a named
# non-default lab session, so the captain's own session is never touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
cleanup_all() { :; }

fm_live_gate default-on FM_HERDR_COMPANION_PANE_LIVE_E2E herdr jq

[ -x "$LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $LAB_HELPER"; exit 0; }

HERDR_VERSION=$(herdr status --json 2>/dev/null | jq -r '.client.version // "unknown"')

# The subject of this guard is a real pane-injecting plugin. Without one
# installed and enabled there is nothing to attribute, so say so and refuse to
# report a pass that checked nothing.
REGISTRY=$(herdr plugin list --json 2>/dev/null) || REGISTRY=''
if [ -z "$REGISTRY" ]; then
  echo "skip: this Herdr client ($HERDR_VERSION) has no 'plugin list --json'"
  exit 0
fi
INJECTOR=$(printf '%s' "$REGISTRY" | jq -r '
  ["workspace.created", "tab.created", "pane.created",
   "workspace.focused", "tab.focused", "pane.focused"] as $injecting
  | [ .result.plugins[]?
      | select(.enabled == true)
      | select((.panes | type) == "array" and (.panes | length) > 0)
      | select([ .events[]?
                 | ((.on // "") | gsub("_"; "."))
                 | select(. as $on | ($injecting | index($on)) != null)
               ] | length > 0)
      | "\(.plugin_id) \(.version // "unknown")"
    ] | first // empty' 2>/dev/null) || INJECTOR=''
if [ -z "$INJECTOR" ]; then
  echo "skip: no enabled pane-injecting Herdr plugin installed (herdr-sidebar or equivalent); nothing to attribute"
  exit 0
fi
INJECTOR_ID=${INJECTOR%% *}
INJECTOR_VERSION=${INJECTOR#* }
VERSIONS="herdr $HERDR_VERSION, $INJECTOR_ID $INJECTOR_VERSION"

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-companion.XXXXXX")
ORIGINAL_PATH=$PATH

LAB_SESSION=$("$LAB_HELPER" name fm-companion) \
  || { echo "skip: could not derive a lab session name"; exit 0; }
LAB_PROVISIONED=0

cleanup_all() {
  [ "$LAB_PROVISIONED" -eq 1 ] || return 0
  LAB_PROVISIONED=0
  PATH=$ORIGINAL_PATH "$LAB_HELPER" teardown "$LAB_SESSION" >/dev/null 2>&1 || true
}
trap cleanup_all EXIT

lab() { PATH=$ORIGINAL_PATH "$LAB_HELPER" run "$LAB_SESSION" "$@"; }

# verify: run the production convergence verifier against the lab session.
# The adapter appends its own trailing --session, so it is invoked with the lab
# session name and reaches Herdr through the ordinary client on PATH.
verify() {  # <workspace> <seeded-tab> <task-tab> <task-pane>
  HERDR_SESSION="$LAB_SESSION" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_projection_convergence_verify "$1" "$2" "$3" "$4" "$5"
  ' "$ROOT" "$LAB_SESSION" "$1" "$2" "$3" "$4" 2>&1
}

budget() {
  HERDR_SESSION="$LAB_SESSION" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_projection_companion_pane_budget "$1"
  ' "$ROOT" "$LAB_SESSION" 2>/dev/null
}

PATH=$ORIGINAL_PATH "$LAB_HELPER" provision "$LAB_SESSION" \
  || { echo "skip: could not provision the isolated Herdr lab"; exit 0; }
LAB_PROVISIONED=1

# A projected workspace is never the session's first, so seed a baseline the
# way production always has one, and let the plugin finish with it.
lab workspace create --cwd "$TMP_ROOT" --label fm-companion-baseline >/dev/null 2>&1 \
  || fail "could not seed the lab's baseline workspace ($VERSIONS)"

# The real projected shape: a workspace Herdr seeded with its own default tab,
# plus the normal task tab Firstmate creates in it.
WS_OUT=$(lab workspace create --cwd "$TMP_ROOT" --label "└ companion-live · p:$$" --no-focus 2>/dev/null) \
  || fail "could not create the projected workspace ($VERSIONS)"
WS_ID=$(printf '%s' "$WS_OUT" | jq -r '.result.workspace.workspace_id // empty')
SEEDED_TAB=$(printf '%s' "$WS_OUT" | jq -r '.result.tab.tab_id // empty')
[ -n "$WS_ID" ] && [ -n "$SEEDED_TAB" ] \
  || fail "the projected workspace create returned incomplete ids ($VERSIONS)"

TAB_OUT=$(lab tab create --workspace "$WS_ID" --cwd "$TMP_ROOT" --label "fm-companion-live-$$" --no-focus 2>/dev/null) \
  || fail "could not create the projected task tab ($VERSIONS)"
TASK_TAB=$(printf '%s' "$TAB_OUT" | jq -r '.result.tab.tab_id // empty')
TASK_PANE=$(printf '%s' "$TAB_OUT" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$TASK_TAB" ] && [ -n "$TASK_PANE" ] \
  || fail "the projected task-tab create returned incomplete ids ($VERSIONS)"

# Wait for the plugin to dock its companion into the TASK tab. Without one
# docked this guard would be measuring an ordinary lone-pane workspace.
COMPANIONS=0
for _ in $(seq 1 60); do
  COMPANIONS=$(lab pane list --workspace "$WS_ID" 2>/dev/null \
    | jq -r --arg tab "$TASK_TAB" --arg pane "$TASK_PANE" \
        '[.result.panes[]? | select(.tab_id == $tab and .pane_id != $pane)] | length' 2>/dev/null)
  case "$COMPANIONS" in ''|*[!0-9]*) COMPANIONS=0 ;; esac
  [ "$COMPANIONS" -gt 0 ] && break
  sleep 0.25
done
[ "$COMPANIONS" -gt 0 ] \
  || fail "$INJECTOR_ID never docked a companion pane into the task tab, so this guard would verify nothing ($VERSIONS); confirm the plugin is enabled and its binary is built"
pass "real Herdr lab: $INJECTOR_ID docked $COMPANIONS companion pane(s) into the projected task tab ($VERSIONS)"

# Firstmate's own prune target is the seeded tab; remove it here so the verdict
# is measured on the settled single-task-tab shape the projection aims for.
lab tab close "$SEEDED_TAB" >/dev/null 2>&1 \
  || fail "could not remove the seeded default tab ($VERSIONS)"
for _ in $(seq 1 40); do
  lab tab list --workspace "$WS_ID" 2>/dev/null \
    | jq -e --arg seeded "$SEEDED_TAB" \
        '([.result.tabs[]? | select(.tab_id == $seeded)] | length) == 0' >/dev/null 2>&1 && break
  sleep 0.25
done

OUT=$(verify "$WS_ID" "$SEEDED_TAB" "$TASK_TAB" "$TASK_PANE")
STATUS=$?
[ "$STATUS" -eq 0 ] \
  || fail "convergence refused a real projected workspace holding $COMPANIONS real companion pane(s) from $INJECTOR_ID ($VERSIONS): $OUT"
pass "real Herdr lab: convergence accepts $COMPANIONS real companion pane(s) beside the exact task pane ($VERSIONS)"

# The tolerance must come from the live registry, not a blanket allowance.
BUDGET=$(budget)
case "$BUDGET" in ''|*[!0-9]*) BUDGET=0 ;; esac
[ "$BUDGET" -ge "$COMPANIONS" ] \
  || fail "the live plugin registry attributed only $BUDGET companion pane(s) but $INJECTOR_ID docked $COMPANIONS ($VERSIONS)"
pass "real Herdr lab: the live registry attributes $BUDGET companion pane(s), covering what $INJECTOR_ID actually docked ($VERSIONS)"

# Non-vacuity: the same real workspace must still refuse once its pane shape
# exceeds what the live registry can explain. Split the task pane to add an
# unattributed pane beyond the plugin's own budget.
EXTRA=$BUDGET
while [ "$COMPANIONS" -le "$BUDGET" ] && [ "$EXTRA" -ge 0 ]; do
  lab pane split "$TASK_PANE" --direction down --no-focus >/dev/null 2>&1 \
    || fail "could not add an unattributed pane to the task tab ($VERSIONS)"
  COMPANIONS=$(lab pane list --workspace "$WS_ID" 2>/dev/null \
    | jq -r --arg tab "$TASK_TAB" --arg pane "$TASK_PANE" \
        '[.result.panes[]? | select(.tab_id == $tab and .pane_id != $pane)] | length' 2>/dev/null)
  case "$COMPANIONS" in ''|*[!0-9]*) COMPANIONS=0 ;; esac
  EXTRA=$((EXTRA - 1))
done
[ "$COMPANIONS" -gt "$BUDGET" ] \
  || fail "could not drive the task tab past its $BUDGET-pane attribution budget ($VERSIONS)"
OUT=$(verify "$WS_ID" "$SEEDED_TAB" "$TASK_TAB" "$TASK_PANE")
STATUS=$?
[ "$STATUS" -ne 0 ] \
  || fail "convergence accepted $COMPANIONS pane(s) against a live budget of $BUDGET, so the bound is not enforced against real Herdr ($VERSIONS)"
case "$OUT" in
  *"can be attributed to a registered herdr plugin"*) ;;
  *) fail "convergence refused for the wrong reason at $COMPANIONS pane(s) ($VERSIONS): $OUT" ;;
esac
pass "real Herdr lab: convergence still refuses $COMPANIONS pane(s) against a live budget of $BUDGET ($VERSIONS)"

cleanup_all
printf 'ok - real Herdr lab companion-pane guard complete (%s)\n' "$VERSIONS"
