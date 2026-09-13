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
# above); "spare" cannot be, because the daemon reparents a recycled bg-pty-host
# out of its hosting session's tree into its own idle pool, so it is scanned
# host-wide and the pass gate below - not this lookup - is what keeps an
# unrelated host's spare from being counted as proof of this fixture's own.
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

session_pid=''
spare_pid=''
for _ in $(seq 1 150); do
  [ -n "$session_pid" ] || session_pid=$(find_pid session || true)
  [ -n "$spare_pid" ] || spare_pid=$(find_pid spare || true)
  [ -n "$session_pid" ] && [ -n "$spare_pid" ] && break
  sleep 0.2
done

CHECKED=0
SPARE_VERIFIED=0

if [ -n "$session_pid" ]; then
  note "active session pid $session_pid: $(ps -o args= -p "$session_pid" 2>/dev/null | cut -c1-100)"
  fm_harness_pid_alive "$session_pid" \
    || fail "LIVENESS DRIFT: claude $CLAUDE_VERSION: an active bg-pty-host carrying --session-id (pid $session_pid) classified NOT live. fm_harness_pid_alive is now rejecting a live session; re-check the --session-id marker in bin/fm-session-lock-lib.sh."
  pass "session-lock live: an active claude session (--session-id) classifies alive"
  CHECKED=$((CHECKED + 1))
else
  note "no live claude --session-id process observed; the active-session verdict is unverified here"
fi

if [ -n "$spare_pid" ]; then
  note "recycled spare pid $spare_pid: $(ps -o args= -p "$spare_pid" 2>/dev/null | cut -c1-100)"
  # It must still name-match the harness (so it is genuinely being EXCLUDED, not
  # merely unrecognized) yet must not read as a live harness.
  comm=$(ps -o comm= -p "$spare_pid" 2>/dev/null); args=$(ps -o args= -p "$spare_pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args" \
    || fail "LIVENESS DRIFT: claude $CLAUDE_VERSION: a recycled spare (pid $spare_pid) no longer name-matches the harness; the exclusion is now vacuous. Re-check FM_HARNESS_RE and the spare shape."
  if fm_harness_pid_alive "$spare_pid"; then
    fail "LIVENESS DRIFT: claude $CLAUDE_VERSION: a recycled unclaimed --bg-spare host (pid $spare_pid) classified LIVE. A stale lock naming it will never be reclaimed; re-check fm_harness_claude_args_are_idle_spare against this release's argv."
  fi
  pass "session-lock live: a recycled unclaimed --bg-spare host classifies NOT live"
  CHECKED=$((CHECKED + 1))
  SPARE_VERIFIED=1
else
  note "no recycled --bg-spare pool process observed; the daemon may not have pooled one on this host/release"
fi

# The recycled-spare verdict is the behavior this file exists to prove (see the
# header). An active-host-only observation exercises a shape the pre-change code
# already got right, so it must not be reportable as a green pass on its own.
if [ "$SPARE_VERIFIED" -ne 1 ]; then
  printf 'skip: live: claude %s: no recycled --bg-spare pool process observed within the poll window, so the recycled-spare discriminator this guard exists to prove is unverified here\n' "$CLAUDE_VERSION"
  cleanup_all
  trap - EXIT
  exit 0
fi

note "claude $CLAUDE_VERSION: verified $CHECKED of 2 live shapes"
cleanup_all
trap - EXIT
