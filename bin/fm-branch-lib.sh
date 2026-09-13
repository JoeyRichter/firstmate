# shellcheck shell=bash
# Single owner of a task's git branch name.
# Usage: . bin/fm-branch-lib.sh
#
# Firstmate names every task branch `fm/<task-id>` by default. A project may
# register a different prefix so its branches satisfy that repo's own branch
# rules (e.g. the CRM repo's Conventional-Commits-style require-jira-ticket check
# exempts `chore/`, so a firstmate-opened non-ticket PR there must ship on
# `chore/fm-<task-id>`). This library is the ONE place that maps a project to its
# branch name; every consumer (bin/fm-brief.sh, bin/fm-dod-lib.sh,
# bin/fm-merge-local.sh, bin/fm-review-diff.sh, bin/fm-promote.sh) resolves the
# name through it rather than re-deriving `fm/$ID`, which is how the pattern
# drifted before.
#
# Per-project configuration lives in the data/projects.md registry as an optional
# `branch=<prefix>` token inside the posture bracket; bin/fm-project-mode.sh's
# header owns that registry line format. An unconfigured project resolves to the
# unchanged `fm/` prefix, so no existing project's behavior changes.
#
# fm_registry_posture_tokens is the single tokenizer of that bracket; both this
# file's fm_branch_prefix (the branch= token) and bin/fm-project-mode.sh (the
# mode and +yolo tokens) call it instead of each parsing the bracket themselves.
#
# Supported prefix shapes are exactly the two the reverse mapping below can undo:
#   fm/            -> branch fm/<id>            (the default)
#   <seg>/fm-      -> branch <seg>/fm-<id>      (a repo-compliant prefix)
# The literal `fm-<id>` substring in the second shape keeps the branch
# human-recognizable and lets fm_branch_task_id map a PR head back to its task.
# A configured prefix of any other shape fails closed rather than producing a
# branch the reverse mapping cannot recover.

# Resolve the registry path from the same env the consumers already export.
_fm_branch_registry() {
  if [ -n "${FM_DATA_OVERRIDE:-}" ]; then
    printf '%s/projects.md\n' "$FM_DATA_OVERRIDE"
  elif [ -n "${FM_HOME:-}" ]; then
    printf '%s/data/projects.md\n' "$FM_HOME"
  elif [ -n "${FM_ROOT:-}" ]; then
    printf '%s/data/projects.md\n' "$FM_ROOT"
  else
    printf 'data/projects.md\n'
  fi
}

_fm_branch_invalid() {  # <prefix> <name>
  echo "error: project '${2:-?}' has an unsupported branch prefix '$1'; expected 'fm/' or '<segment>/fm-'" >&2
}

# fm_registry_posture_tokens <registry-file> <project-name> -> the project's
# posture-bracket tokens (space-separated, possibly empty), one line on stdout.
# Exits nonzero if the registry file is missing or has no line for the project;
# a matched project with no bracket at all exits 0 with an empty line. This is
# the ONE place that tokenizes a registry line's `[...]` bracket, so fm_branch_prefix
# below and bin/fm-project-mode.sh's mode/+yolo parsing read the same tokens
# rather than two independently maintained bracket parsers.
fm_registry_posture_tokens() {  # <registry-file> <project-name>
  local reg=${1:-} name=${2:-}
  [ -n "$reg" ] && [ -f "$reg" ] || return 1
  awk -v n="$name" '
    $1=="-" && $2==n {
      s="";
      if ($3 ~ /^\[/) {
        for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
        gsub(/^\[|\]$/, "", s);
      }
      print s;
      found=1;
      exit
    }
    END { if (!found) exit 3 }
  ' "$reg"
}

# fm_branch_prefix <project-name-or-path> -> the branch prefix (default fm/).
# Accepts either a bare registry name or an absolute project path (its basename
# is the registry name), so every consumer calls this with what it already holds.
# Absence of a registry, entry, or branch= token silently yields fm/; a
# malformed configured prefix fails closed with a nonzero status.
fm_branch_prefix() {
  local proj=${1:-} name reg prefix found seg tok tokens
  case "$proj" in
    */*) name=${proj%/}; name=${name##*/} ;;
    *)   name=$proj ;;
  esac
  prefix=fm/
  reg=$(_fm_branch_registry)
  if [ -n "$name" ]; then
    tokens=$(fm_registry_posture_tokens "$reg" "$name") || tokens=
    found=
    for tok in $tokens; do
      case "$tok" in
        branch=*) found=${tok#branch=}; break ;;
      esac
    done
    [ -z "$found" ] || prefix=$found
  fi
  case "$prefix" in
    fm/) ;;
    */fm-)
      seg=${prefix%/fm-}
      case "$seg" in
        ""|*/*|fm) _fm_branch_invalid "$prefix" "$name"; return 1 ;;
      esac
      ;;
    *) _fm_branch_invalid "$prefix" "$name"; return 1 ;;
  esac
  printf '%s\n' "$prefix"
}

# fm_branch_name <project-name-or-path> <task-id> -> the full branch name.
fm_branch_name() {
  local proj=${1:-} id=${2:-} prefix
  [ -n "$id" ] || { echo "error: fm_branch_name: missing task id" >&2; return 2; }
  prefix=$(fm_branch_prefix "$proj") || return 1
  printf '%s%s\n' "$prefix" "$id"
}

# fm_branch_task_id <branch-or-headRefName> -> the task id, or nonzero if the ref
# carries no firstmate prefix. Prefix-agnostic and takes no project, because the
# reverse consumer (bin/fm-bearings-snapshot.sh) has only a repo slug. It undoes
# exactly the two shapes fm_branch_prefix produces, leftmost so a task id that
# itself begins with `fm-` (e.g. fm/fm-foo -> fm-foo) is never over-stripped.
fm_branch_task_id() {
  local ref=${1:-} seg rest
  case "$ref" in
    fm/?*) printf '%s\n' "${ref#fm/}"; return 0 ;;
  esac
  case "$ref" in
    */fm-?*)
      seg=${ref%%/*}
      rest=${ref#*/}
      [ -n "$seg" ] || return 1
      case "$rest" in
        fm-?*) printf '%s\n' "${rest#fm-}"; return 0 ;;
      esac
      ;;
  esac
  return 1
}

# fm_branch_ref_is_default <branch-or-headRefName> -> success if ref is the
# unconfigured default shape (fm/<id>), as opposed to a configured <seg>/fm-
# shape. A caller with only a repo slug (bin/fm-bearings-snapshot.sh) uses this
# to apply extra claim evidence only to the ambiguous configured shape, without
# re-deriving prefix knowledge itself: `fm/` was never a human branch
# convention, so the default shape needs no such gate.
fm_branch_ref_is_default() {
  case "${1:-}" in
    fm/?*) return 0 ;;
    *) return 1 ;;
  esac
}
