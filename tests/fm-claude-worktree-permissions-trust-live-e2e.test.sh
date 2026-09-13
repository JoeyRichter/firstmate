#!/usr/bin/env bash
# Default-on live regression for bin/fm-claude-trust.sh's canonical-root
# registration, proven against the real installed Claude Code rather than
# assumed from the vendor's rendered string alone.
#
# Claude runs two workspace-trust lookups. The plain one walks up from cwd and
# accepts the task worktree's own entry. The per-project one keys on the
# CANONICAL GIT ROOT - the main working tree a linked worktree's .git file
# points at - and it is what renders the gated-grants variant of the dialog
# ("This folder pre-approves N tool permissions...") when the workspace's
# .claude/settings.json carries permissions.allow rules. A crewmate pane would
# wedge on that variant, because firstmate's steering plane cannot move its
# selection off the default choice.
#
# The canonical root is NOT the <project> argument. They coincide only when
# <project> is the repository's main working tree, and fm-spawn.sh also supports
# a linked spawning home, where <project> is itself a linked worktree. This
# guard therefore builds all three directories and pins the DIFFERENCE: the
# argument-based registration this fix replaced is exercised as its own
# adversarial control and must still render the dialog, so a regression back to
# it cannot pass here.
#
# Reaching the dialog needs a genuinely interactive pty and real managed
# authentication (an unauthenticated or non-interactive `-p` launch never
# renders it at all), so this cannot be proven any other way.
#
# Spends no model tokens: each child claude process is killed at the composer,
# before any prompt is ever sent, so this runs default-on wherever its tools
# are installed rather than staying opt-in.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CLAUDE_TRUST_LIVE_E2E claude python3 git node

TRUST="$ROOT/bin/fm-claude-trust.sh"
CLAUDE_VERSION=$(claude --version)

LAB="$ROOT/.claude-trust-live-e2e.$$"
MAIN="$LAB/proj-main"
HOME_WT="$LAB/home-wt"
TASK_WT="$LAB/task-wt"
DRIVER="$LAB/drive.py"
KEYS="$LAB/keys.mjs"
STORE="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"

# This guard registers real trust in the operator's own store - the same store
# fm-spawn.sh writes for every real crewmate - because the vendor reads that
# store and nothing else. It must therefore remove exactly the three entries it
# could have added and leave every other project entry alone.
cleanup() {
  if [ -f "$STORE" ]; then
    node -e '
      const fs = require("node:fs");
      const [store, ...paths] = process.argv.slice(1);
      try {
        const j = JSON.parse(fs.readFileSync(store, "utf8"));
        if (j.projects) for (const p of paths) delete j.projects[p];
        fs.writeFileSync(store, JSON.stringify(j, null, 2) + "\n");
      } catch {}
    ' "$STORE" "$MAIN" "$HOME_WT" "$TASK_WT" 2>/dev/null || true
  fi
  if [ -d "$MAIN" ]; then
    git -C "$MAIN" worktree remove --force "$TASK_WT" >/dev/null 2>&1 || true
    git -C "$MAIN" worktree remove --force "$HOME_WT" >/dev/null 2>&1 || true
  fi
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
git init -q "$MAIN"
git -C "$MAIN" config user.email t@fm-claude-trust-live-e2e.test
git -C "$MAIN" config user.name fm-claude-trust-live-e2e
echo hi > "$MAIN/README.md"
git -C "$MAIN" add -A
git -C "$MAIN" commit -q -m init
# A linked spawning home, and the task worktree spawned from it: the shape where
# the <project> argument and the canonical root are different paths.
git -C "$MAIN" worktree add -q --detach "$HOME_WT" HEAD
git -C "$HOME_WT" worktree add -q --detach "$TASK_WT" HEAD
mkdir -p "$TASK_WT/.claude"
cat > "$TASK_WT/.claude/settings.json" <<'JSON'
{"permissions":{"allow":["Bash(npm:*)","Bash(git:*)"]}}
JSON

# Set the store's trusted paths to exactly the given set, so each case below is
# isolated from the last rather than inheriting its entries.
cat > "$KEYS" <<'JS'
import fs from "node:fs";
const [store, main, homeWt, taskWt, ...keys] = process.argv.slice(2);
let j = {};
try { j = JSON.parse(fs.readFileSync(store, "utf8")); } catch {}
j.projects ??= {};
for (const p of [main, homeWt, taskWt]) delete j.projects[p];
for (const k of keys) j.projects[k] = { ...(j.projects[k] || {}), hasTrustDialogAccepted: true };
fs.writeFileSync(store, JSON.stringify(j, null, 2) + "\n");
JS

set_trusted() { node "$KEYS" "$STORE" "$MAIN" "$HOME_WT" "$TASK_WT" "$@"; }

# A small pty driver: real terminal apps (Claude's Ink renderer included) only
# render their dialogs on a real pty, never on a plain pipe. CLAUDE*, CLAUDECODE
# and AI_AGENT are stripped from the child's environment so a live run of this
# guard from inside an active Claude Code session (this development loop
# included) cannot inherit a child-session marker that skips the vendor's own
# init flow and makes the check pass for the wrong reason.
cat > "$DRIVER" <<'PY'
import os, pty, sys, time, select

def main():
    cwd, snapshot_secs = sys.argv[1], float(sys.argv[2])
    env = dict(os.environ)
    for k in list(env.keys()):
        if k.startswith("CLAUDE") or k in ("CLAUDECODE", "AI_AGENT"):
            del env[k]
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(cwd)
        os.execvpe("claude", ["claude", "--dangerously-skip-permissions"], env)
        return
    out, end = b"", time.time() + snapshot_secs
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if fd in r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
    try:
        os.kill(pid, 9)
        os.waitpid(pid, 0)
    except OSError:
        pass
    sys.stdout.buffer.write(out)

main()
PY

gated_dialog_rendered() {  # <cwd>
  case "$(python3 "$DRIVER" "$1" 7 2>&1 | tr -d '\000')" in
    *"pre-approves"* | *"Quick safety check"*) return 0 ;;
  esac
  return 1
}

# Control 1, the pre-fix behavior: the worktree alone. Asserted first so a
# vendor that stopped rendering the dialog fails this guard loudly instead of
# letting every case below pass vacuously.
set_trusted "$TASK_WT"
gated_dialog_rendered "$TASK_WT" \
  || fail "claude ($CLAUDE_VERSION) did not render the gated-grants dialog under worktree-only trust; this guard cannot prove anything (control case is vacuous)"

# Control 2, the argument-based registration this fix replaced: the worktree
# plus the <project> argument, which in this shape is the linked spawning home.
# Claude never looks there, so the dialog must still render.
set_trusted "$TASK_WT" "$HOME_WT"
gated_dialog_rendered "$TASK_WT" \
  || fail "claude ($CLAUDE_VERSION) skipped the gated-grants dialog when only the worktree and the linked spawning home were trusted; the canonical root is no longer the key this guard pins"

# The production script, in the shape where the argument and the root differ.
set_trusted
TRUST_OUT=$("$TRUST" "$TASK_WT" "$HOME_WT" 2>&1)
expect_code 0 $? "bin/fm-claude-trust.sh must accept a worktree spawned from a linked spawning home: $TRUST_OUT"
assert_contains "$TRUST_OUT" "$MAIN" "the success line did not name the repository main checkout as the canonical root"
! gated_dialog_rendered "$TASK_WT" \
  || fail "claude ($CLAUDE_VERSION) still rendered the trust dialog after bin/fm-claude-trust.sh registered the worktree and its derived canonical root; a crewmate pane would wedge on this"

# The ordinary spawn shape, where <project> IS the main working tree.
set_trusted
TRUST_OUT=$("$TRUST" "$TASK_WT" "$MAIN" 2>&1)
expect_code 0 $? "bin/fm-claude-trust.sh must accept the ordinary spawn shape: $TRUST_OUT"
! gated_dialog_rendered "$TASK_WT" \
  || fail "claude ($CLAUDE_VERSION) still rendered the trust dialog for an ordinary spawn after both paths were registered"

pass "fm-claude-trust.sh: claude ($CLAUDE_VERSION) reaches the composer once the worktree and its DERIVED canonical root are registered, and still gates on the <project> argument alone"
