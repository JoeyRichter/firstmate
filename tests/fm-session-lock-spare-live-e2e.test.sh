#!/usr/bin/env bash
# tests/fm-session-lock-spare-live-e2e.test.sh - default-on, token-free live guard
# for the recycled-spare liveness distinction in bin/fm-session-lock-lib.sh
# (fm_harness_pid_alive / fm_harness_claude_args_are_idle_spare).
#
# Why this file exists: fm_harness_pid_alive's verdict comes from Claude Code's
# own argv, a surface the vendor controls and can change without notice. A live
# bg-pty-host that is actively hosting a session carries `--session-id` and must
# read as live; one the daemon has recycled into its idle spare pool instead
# carries `--bg-spare .../spare/<id>.claim.sock` with NO `--session-id` and must
# read as dead, or a stale session lock naming it would never be reclaimed. Only
# a real Claude Code release can drift those markers, so a real claude must be
# launched to prove the discriminator still separates the two shapes.
#
# Launch is bare with no prompt, so this consumes no model tokens and runs by
# default wherever claude is installed. The portable counterpart in
# tests/fm-session-lock-ancestry.test.sh pins both verdicts deterministically in
# CI. Run this guard after any Claude Code upgrade and before trusting refreshed
# session-lock evidence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_SESSION_LOCK_SPARE_LIVE claude tmux

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

REAL_TMUX=$(command -v tmux)
CLAUDE_BIN=$(command -v claude)
CLAUDE_VERSION=$("$CLAUDE_BIN" --version 2>/dev/null | head -1 | tr -d '\r'); [ -n "$CLAUDE_VERSION" ] || CLAUDE_VERSION=unknown
SOCKET="fm-spare-live-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-spare-live.XXXXXX")

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

# shellcheck source=/dev/null
. "$ROOT/bin/fm-session-lock-lib.sh"

mkdir -p "$LAB/wt"
"$REAL_TMUX" -L "$SOCKET" new-session -d -s spare -n control -c "$LAB/wt" \
  || fail "could not start the private tmux server"
# A bare claude brings up Claude Code's daemon and its bg-pty-host pool, which is
# the real behavior under test. Its own control process carries --session-id.
"$REAL_TMUX" -L "$SOCKET" new-window -d -t spare: -n claude -c "$LAB/wt" -- "$CLAUDE_BIN" \
  || fail "could not launch a claude window"

PANE_PID=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t spare:claude '#{pane_pid}' 2>/dev/null | tr -d ' ')
[ -n "$PANE_PID" ] || fail "could not read the pane pid for the launched claude window"

# All live pids descended from $1, root included, via ppid links. Scopes the
# active-session lookup to the claude window this fixture itself launched, so a
# claude session already running elsewhere on the host is never mistaken for it.
pid_subtree() {  # <root_pid>
  local root=$1 pairs pid ppid queue next
  pairs=$(ps -axo pid=,ppid= 2>/dev/null)
  printf '%s\n' "$root"
  queue=" $root "
  while [ -n "${queue// /}" ]; do
    next=''
    while read -r pid ppid; do
      [ -n "$pid" ] || continue
      case "$queue" in *" $ppid "*) printf '%s\n' "$pid"; next="$next $pid " ;; esac
    done <<EOF
$pairs
EOF
    queue=$next
  done
}

# Classify every live process's argv exactly as the harness identity does.
# Returns the first pid whose live argv matches predicate $1 ("session"|"spare").
# "session" is scoped to this fixture's own claude subtree (see pid_subtree
# above) so a session running elsewhere on the host is never mistaken for it.
# "spare" is scanned host-wide instead, because the daemon reparents a recycled
# bg-pty-host out of its hosting session's tree into its own idle pool: any
# genuine recycled-spare argv shape found anywhere on the host is equally valid
# evidence for this vendor-argv drift canary, with no discrimination of which
# session originally produced it.
find_pid() {  # <kind>
  local kind=$1 pid args source
  case "$kind" in
    session) source=$(pid_subtree "$PANE_PID") ;;
    spare) source=$(ps -axo pid= 2>/dev/null) ;;
  esac
  while read -r pid; do
    [ -n "$pid" ] || continue
    args=$(ps -o args= -p "$pid" 2>/dev/null) || continue
    case "$kind" in
      session)
        case " $args " in
          *' --session-id '*claude*|*claude*' --session-id '*) printf '%s\n' "$pid"; return 0 ;;
        esac ;;
      spare)
        case " $args " in *' --session-id '*) continue ;; esac
        case " $args " in
          *' --bg-spare '*claim.sock*) printf '%s\n' "$pid"; return 0 ;;
        esac ;;
    esac
  done <<EOF
$source
EOF
  return 1
}

# Observation prints nothing: whether this run counts as a skip is decided only
# after both pids are known, and a capability skip must be the run's first
# output line for bin/fm-test-run.sh's gate-skip detector to recognize it
# instead of an ordinary pass.
session_pid=''
spare_pid=''
for _ in $(seq 1 150); do
  [ -n "$session_pid" ] || session_pid=$(find_pid session || true)
  [ -n "$spare_pid" ] || spare_pid=$(find_pid spare || true)
  [ -n "$session_pid" ] && [ -n "$spare_pid" ] && break
  sleep 0.2
done

if [ -z "$session_pid" ] && [ -z "$spare_pid" ]; then
  fail "claude $CLAUDE_VERSION: observed neither an active session nor a recycled spare, so this run proved nothing about the live discriminator"
fi

# The recycled-spare verdict is the behavior this file exists to prove (see the
# header): an active-host-only observation exercises a shape the pre-change
# code already got right, so it is a capability skip, not a pass, when the
# daemon never pooled a spare within the poll window.
if [ -z "$spare_pid" ]; then
  printf 'skip: live: claude %s: an active --session-id host was observed but no recycled --bg-spare pool process appeared within the poll window; the recycled-spare discriminator this guard exists to prove is unverified here\n' "$CLAUDE_VERSION"
  note "active session pid $session_pid: $(ps -o args= -p "$session_pid" 2>/dev/null | cut -c1-100)"
  cleanup_all
  trap - EXIT
  exit 0
fi

CHECKED=0

# It must still name-match the harness (so it is genuinely being EXCLUDED, not
# merely unrecognized) yet must not read as a live harness.
comm=$(ps -o comm= -p "$spare_pid" 2>/dev/null); args=$(ps -o args= -p "$spare_pid" 2>/dev/null)
fm_harness_process_matches "$comm" "$args" \
  || fail "LIVENESS DRIFT: claude $CLAUDE_VERSION: a recycled spare (pid $spare_pid) no longer name-matches the harness; the exclusion is now vacuous. Re-check FM_HARNESS_RE and the spare shape."
if fm_harness_pid_alive "$spare_pid"; then
  fail "LIVENESS DRIFT: claude $CLAUDE_VERSION: a recycled unclaimed --bg-spare host (pid $spare_pid) classified LIVE. A stale lock naming it will never be reclaimed; re-check fm_harness_claude_args_are_idle_spare against this release's argv."
fi
note "recycled spare pid $spare_pid: $(ps -o args= -p "$spare_pid" 2>/dev/null | cut -c1-100)"
pass "session-lock live: a recycled unclaimed --bg-spare host classifies NOT live"
CHECKED=$((CHECKED + 1))

if [ -n "$session_pid" ]; then
  fm_harness_pid_alive "$session_pid" \
    || fail "LIVENESS DRIFT: claude $CLAUDE_VERSION: an active bg-pty-host carrying --session-id (pid $session_pid) classified NOT live. fm_harness_pid_alive is now rejecting a live session; re-check the --session-id marker in bin/fm-session-lock-lib.sh."
  note "active session pid $session_pid: $(ps -o args= -p "$session_pid" 2>/dev/null | cut -c1-100)"
  pass "session-lock live: an active claude session (--session-id) classifies alive"
  CHECKED=$((CHECKED + 1))
else
  note "no live claude --session-id process observed; the active-session verdict is unverified here"
fi

note "claude $CLAUDE_VERSION: verified $CHECKED of 2 live shapes"
cleanup_all
trap - EXIT
