#!/usr/bin/env bash
# Behavior test for the bearings board's card-stack state preservation
# (.agents/skills/bearings/assets/board-template.html), exercised through a real
# `fm-bearings-board.sh build` and the DOM shim in
# tests/assets/board-cardstate-harness.mjs.
#
# The defect this guards: a Lavish hot reload of the board (its ~300ms file-watch
# reload on any rewrite) used to deal the captain back to card 1 of the Captain's
# Call stack, because nothing carried the active card across the reload. The fix
# stashes the active card's own key in a hidden input inside a [data-lavish-question]
# scope, which Lavish's review-state replay preserves, and restores it when the
# replay lands - keyed by identity so a rebuild that drops or reorders cards still
# returns the captain to the same decision, not whatever now sits at the old
# position. The vendor half of that round trip is proven live against real
# lavish-axi and a real browser in the delivery evidence; this file pins the
# template's own logic.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-bearings-board.sh"
HARNESS="$ROOT/tests/assets/board-cardstate-harness.mjs"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board-cardstate)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  mkdir -p "$home/state" "$home/data"
  fakebin=$(fm_fakebin "$home")
  # The build proves the session is live before it arms anything, so the stub
  # reports the opened shape the real lavish-axi emits; session liveness is not
  # this suite's concern.
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  --version) printf '0.1.67\n' ;;
  '')
    printf 'sessions[1]{file,status,url,pending_prompts}:\n'
    [ ! -s "$FM_HOME/lavish-open" ] \
      || printf '  %s,open,"http://127.0.0.1/session/cardstate",0\n' "$(cat "$FM_HOME/lavish-open")"
    ;;
  poll)
    while [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 1; done
    exit 75
    ;;
  *)
    real=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
    printf '%s\n' "$real" > "$FM_HOME/lavish-open"
    printf 'session:\n  status: opened\n'
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/lavish-axi"
  printf '%s\n' "$home"
}

# Build a board with <n-cards> Captain's Call cards, keyed call-0.. call-(n-1).
build_board() {  # <home> <n-cards>
  local home=$1 n=$2 data="$1/payload.json"
  jq -n --argjson n "$n" '{
    schema:"fm-bearings-board.v1", home:"cardstate-home", generated:"2026-09-12T00:00Z",
    prs_live:false,
    captains_call: [range(0;$n) | {
      key: ("call-" + (.|tostring)), type:"decision", repo:"sample",
      title: ("Call " + (.|tostring)),
      options: [{value:"yes", label:"Yes"}, {value:"no", label:"No"}]
    }],
    underway:[], landed:[], charted:[]}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
}

# Build a board with exactly the given Captain's Call keys, in that order - the
# shape of a rebuild that dropped some cards (their decisions landed) and
# resorted the rest by filed recency.
build_board_with_keys() {  # <home> <keys-json-array>
  local home=$1 keys=$2 data="$1/payload.json"
  jq -n --argjson keys "$keys" '{
    schema:"fm-bearings-board.v1", home:"cardstate-home", generated:"2026-09-12T00:00Z",
    prs_live:false,
    captains_call: [$keys[] | {
      key: ., type:"decision", repo:"sample",
      title: ("Call " + .),
      options: [{value:"yes", label:"Yes"}, {value:"no", label:"No"}]
    }],
    underway:[], landed:[], charted:[]}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
}

# Build a board with <n-cards> Captain's Call cards and drive its stack under the
# harness with <nav-clicks> Next presses.
run_cardstate() {  # <home> <n-cards> <nav-clicks>
  local home=$1 n=$2 clicks=$3
  build_board "$home" "$n"
  node "$HARNESS" "$home/.lavish/bearings-board.html" "$clicks" \
    || fail "the card-state harness did not run"
}

test_navigation_stashes_the_active_cards_key() {
  local home out
  home=$(make_home persist)
  # From card 1, two Next presses land on card 3 of 4 (the card keyed call-2).
  out=$(run_cardstate "$home" 4 2)
  printf '%s' "$out" | jq -e '
    .persist.hiddenValue == "call-2"
      and (.persist.card | test("card 3 of 4"))
  ' >/dev/null || fail "navigating the stack did not stash the active card's key: $out"
  pass "navigating the Captain's Call stack stashes the active card's key"
}

test_the_stashed_field_sits_in_a_lavish_question_scope() {
  local home out
  home=$(make_home question-scope)
  out=$(run_cardstate "$home" 4 2)
  printf '%s' "$out" | jq -e '
    .questionScope.dataLavishQuestion == "__bb-ui"
  ' >/dev/null || fail "the stashed card field is not inside a data-lavish-question scope: $out"
  pass "the stashed card field sits inside a data-lavish-question scope Lavish's SDK can collect"
}

test_the_restore_message_restores_the_active_card() {
  local home out
  home=$(make_home restore-message)
  out=$(run_cardstate "$home" 4 2)
  printf '%s' "$out" | jq -e '
    .restoreViaMessage.setTo == "call-2"
      and (.restoreViaMessage.card | test("card 3 of 4"))
  ' >/dev/null || fail "the restoreReviewState message did not restore the captain to their card: $out"
  pass "the async restoreReviewState message returns the captain to the card they were on"
}

test_the_fallback_timer_restores_the_active_card() {
  local home out
  home=$(make_home restore-fallback)
  out=$(run_cardstate "$home" 4 2)
  printf '%s' "$out" | jq -e '
    .restoreViaFallback.setTo == "call-2"
      and (.restoreViaFallback.card | test("card 3 of 4"))
  ' >/dev/null || fail "the fallback timer did not restore the captain to their card: $out"
  pass "the fallback timer alone returns the captain to the card they were on, not card 1"
}

test_the_restore_follows_the_cards_identity_across_a_rebuild() {
  local home_a home_b out
  home_a=$(make_home identity-a)
  home_b=$(make_home identity-b)
  build_board "$home_a" 4
  # A routine rebuild: call-0's decision landed and dropped, and the rest
  # resorted by filed recency, so call-2 - the card the captain was on - is
  # now second of the remaining three instead of third of four. A non-zero
  # landing position keeps this distinct from the page's own default
  # (showCard(0) at load), so a restore that silently does nothing cannot
  # pass this assertion by accident.
  build_board_with_keys "$home_b" '["call-3","call-2","call-1"]'
  out=$(node "$HARNESS" "$home_a/.lavish/bearings-board.html" 2 "$home_b/.lavish/bearings-board.html") \
    || fail "the card-state harness did not run"
  printf '%s' "$out" | jq -e '
    .persist.hiddenValue == "call-2"
      and (.restoreAcrossRebuild.card | test("card 2 of 3"))
  ' >/dev/null || fail "the rebuild reshuffle restored the wrong card by position instead of by identity: $out"
  pass "restore follows the card's identity across a rebuild that drops and reorders cards"
}

test_the_restore_degrades_to_card_one_when_the_stashed_card_is_gone() {
  local home_a home_b out
  home_a=$(make_home identity-drop-a)
  home_b=$(make_home identity-drop-b)
  build_board "$home_a" 4
  # call-2, the card the captain was on, landed and dropped in this rebuild.
  build_board_with_keys "$home_b" '["call-0","call-1","call-3"]'
  out=$(node "$HARNESS" "$home_a/.lavish/bearings-board.html" 2 "$home_b/.lavish/bearings-board.html") \
    || fail "the card-state harness did not run"
  printf '%s' "$out" | jq -e '
    .restoreAcrossRebuild.card | test("card 1 of 3")
  ' >/dev/null || fail "a stashed key with no matching card did not degrade to card 1: $out"
  pass "restore degrades to card 1 when the stashed card's key is no longer present after a rebuild"
}

test_navigation_stashes_the_active_cards_key
test_the_stashed_field_sits_in_a_lavish_question_scope
test_the_restore_message_restores_the_active_card
test_the_fallback_timer_restores_the_active_card
test_the_restore_follows_the_cards_identity_across_a_rebuild
test_the_restore_degrades_to_card_one_when_the_stashed_card_is_gone
