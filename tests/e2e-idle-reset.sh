#!/bin/bash
# Does tools/kf2-idle-reset.sh restart only an empty server, and only in the
# one state it exists for: closed to takeover for fifteen minutes? And is the
# uptime rule v1.5 removed gone, settings and clock included?
#
# A restart ends the round for everyone on the server, so the decisions are
# the whole script. Each case that must not restart is checked against the
# stand-in's start counter, and the rule restarts the stand-in once for real,
# so the path that acts is run as well as the one that decides.
#
# Against the moderation stand-in (tests/fixtures/): the pinned image with
# fake-kf2.py answering A2S where the game would be, players set per case.
# The takeover advertisement comes through KF2_TAKEOVER instead of
# Launch.log; the clocks the rule keeps are files, written here to stand for
# a server seen empty some time ago.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASSED=0; FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }

export KF2_COMPOSE_FILE=tests/fixtures/moderation-compose.yml
export COMPOSE_PROJECT_NAME="kf2-idletest-$$"
export KF2_QUERY_PORT=27015
export KF2_SERVER_UID=1000 KF2_SERVER_GID=1000 KF2_MODERATION_WEBHOOK=""
KF2_SERVER_IMAGE_TAG="$(grep -m1 -oE '\$\{KF2_SERVER_IMAGE_TAG:-.*' kf2-server-docker-compose.yml | sed -E -e ':a' -e 's/\$\{[A-Z0-9_]+:-([^{}]*)\}/\1/' -e 'ta')"
export KF2_SERVER_IMAGE_TAG
[ -n "$KF2_SERVER_IMAGE_TAG" ] || { echo "could not read the pinned image from the compose file"; exit 1; }
STATES="$(mktemp -d)"
export KF2_IDLE_RESET_STATE="$STATES/reset"

compose() { docker compose -f "$KF2_COMPOSE_FILE" -p "$COMPOSE_PROJECT_NAME" "$@"; }
cleanup() { compose down -v --remove-orphans >/dev/null 2>&1; rm -rf "$STATES"; }
trap cleanup EXIT
fake_set() { compose exec -T kf2-server sh -c "printf '%s' \"\$1\" > /data/$2" -- "$1" "$2" 2>/dev/null; }
fake_rm()  { compose exec -T kf2-server rm -f "/data/$1" 2>/dev/null; }
starts()   { compose exec -T kf2-server sh -c 'grep -c . /data/starts' 2>/dev/null; }
answers()  { for _ in $(seq 1 60); do [ "$(tools/kf2-a2s.sh players 2>/dev/null)" = "$1" ] && return 0; sleep 1; done; return 1; }
reset() {
  if command -v timeout >/dev/null 2>&1; then timeout 120 tools/kf2-idle-reset.sh "$@"
  else perl -e 'alarm 120; exec @ARGV' tools/kf2-idle-reset.sh "$@"; fi
}
ago() { echo $(( $(date +%s) - $1 )); }
clean() { rm -f "$KF2_IDLE_RESET_STATE" "$KF2_IDLE_RESET_STATE.last" "$KF2_IDLE_RESET_STATE.uptime"; }
H=3600

compose up -d --quiet-pull >/dev/null 2>&1 || { echo "cannot start the stand-in server"; exit 1; }
fake_set 0 players
answers 0 || { echo "the stand-in never answered A2S"; exit 1; }
before="$(starts)"

echo "=== the rule: empty and closed to takeover ==="
echo

# 1. Open to takeover: a quiet server is left alone.
out="$(KF2_TAKEOVER=True reset 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q "open to takeover: nothing to do" <<<"$out"; then pass "open to takeover: nothing to do"; else fail "open: exit $rc, said: $out"; fi

# 2. Closed with people on: their game.
fake_set 2 players; answers 2
out="$(KF2_TAKEOVER=False reset 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q "closed to takeover with 2 player(s) on: their game" <<<"$out" && [ ! -e "$KF2_IDLE_RESET_STATE" ]; then pass "closed, two players on: left alone, no clock started"; else fail "closed, two on: exit $rc, said: $out"; fi

# 3. THE CASE THAT MUST NEVER GUESS: closed, and the server does not answer.
fake_set 1 silent
out="$(KF2_TAKEOVER=False reset 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q "did not answer the player query; not acting on a guess" <<<"$out" && [ "$(starts)" = "$before" ]; then pass "closed, no answer: exit 1, not restarted"; else fail "closed, no answer: exit $rc, said: $out"; fi
fake_rm silent
fake_set 0 players; answers 0

# 4. Closed and empty, first seen now: the clock starts.
out="$(KF2_TAKEOVER=False reset 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q "empty and closed to takeover for 0s; resetting after 900s" <<<"$out" && [ -s "$KF2_IDLE_RESET_STATE" ]; then pass "closed and empty, just now: waits 900s, clock started"; else fail "closed, empty, now: exit $rc, said: $out"; fi

# 5. Closed and empty for 16 minutes: it would restart.
ago 960 >"$KF2_IDLE_RESET_STATE"
out="$(KF2_TAKEOVER=False reset --dry-run 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q "would restart: empty and closed to takeover for 16 min" <<<"$out"; then pass "closed and empty for 16 min: it would restart"; else fail "closed, empty 16 min: exit $rc, said: $out"; fi

# 6. ...but not within an hour of its own last reset: no loop.
ago 600 >"$KF2_IDLE_RESET_STATE.last"
out="$(KF2_TAKEOVER=False reset 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q "again within an hour of a reset" <<<"$out" && [ "$(starts)" = "$before" ]; then pass "closed again 10 min after a reset: exit 1, not restarted"; else fail "loop guard: exit $rc, said: $out"; fi
rm -f "$KF2_IDLE_RESET_STATE.last"

# 7. For real: closed and empty for 16 minutes, restarted once, and the loop
#    guard's stamp written.
ago 960 >"$KF2_IDLE_RESET_STATE"
out="$(KF2_TAKEOVER=False reset 2>&1)"; rc=$?
answers 0
if [ "$rc" = 0 ] && grep -q "restarted: empty and closed to takeover" <<<"$out" && [ "$(starts)" = $((before + 1)) ] && [ -s "$KF2_IDLE_RESET_STATE.last" ] && [ ! -e "$KF2_IDLE_RESET_STATE" ]; then pass "restarted once, for real; the loop guard's stamp written"; else fail "the restart: exit $rc, starts $(starts) from $before, said: $out"; fi
before="$(starts)"; clean

echo
echo "=== the uptime rule, removed in v1.5 ==="
echo

# 8. Its settings still in someone's environment, and its clock left behind
#    by v1.4, on a server up 20 hours and empty: nothing happens, and the
#    stale clock is cleared.
ago 3600 >"$KF2_IDLE_RESET_STATE.uptime"
out="$(KF2_MAX_UPTIME=1 KF2_UPTIME_EMPTY_FOR=1 KF2_UPTIME=$((20 * H)) KF2_TAKEOVER=True reset 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q "open to takeover: nothing to do" <<<"$out" && [ "$(starts)" = "$before" ] && [ ! -e "$KF2_IDLE_RESET_STATE.uptime" ]; then pass "v1.4's uptime settings and clock: not restarted, the clock cleared"; else fail "removed rule: exit $rc, starts $(starts) from $before, said: $out"; fi

# 9. No takeover line in the log yet (a server that has just started): only
#    quiet, left alone.
out="$(KF2_TAKEOVER="" reset 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q "no takeover advertisement in the log yet: nothing to do" <<<"$out" && [ "$(starts)" = "$before" ]; then pass "no advertisement in the log yet: nothing to do"; else fail "not in the log: exit $rc, said: $out"; fi

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
