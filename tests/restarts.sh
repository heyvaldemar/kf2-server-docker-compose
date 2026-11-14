#!/bin/bash
# tools/kf2-idle-reset.sh's restart watch against a container that really crashes.
#
# Not the game: a container named as this template's server, with Docker's
# restart policy, that prints a crash line and exits 3 every twelve seconds
# (longer than a run of the script, so a run never lands mid-restart). The
# takeover reading is supplied ("not in the log"), and there is no LinuxGSM
# in it, so the only thing the script can say is about restarts. The order,
# each step a run of the script:
#   first run                 writes the count down, says nothing
#   after the first crash     says it once, with the exit code and the crash
#                             line from the log, exit 0
#   the run after             says nothing
#   after `docker restart`    the count is back at 0: says nothing
#   three restarts later      3 or more in 24 hours: exit 1
# and a second container, 16 MB of memory, that eats more: the kill for
# memory is named from Docker's oom event, with exit 137 (SIGKILL), because a
# restarted container's own state no longer says so.
# shellcheck disable=SC2015   # pass and fail always exit 0, so "A && pass || fail" is if-then-else here
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASSED=0; FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }
SERVICE=kf2-server
T="$(mktemp -d)"; P="restarts-test-$$"
cleanup() { docker compose -p "$P" -f "$T/compose.yml" down -t 0 >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT
mkdir -p "$T/repo/tools"
cp tools/kf2-idle-reset.sh tools/kf2-a2s.sh "$T/repo/tools/"
cat >"$T/compose.yml" <<YAML
services:
  $SERVICE:
    image: alpine:3.22
    restart: on-failure:5
    command: ["sh", "-c", "sleep 12; echo 'Signal: SIGSEGV [segmentation fault]'; exit 3"]
YAML
cid() { docker compose -p "$P" -f "$T/compose.yml" ps -q "$SERVICE"; }
count() { docker inspect -f '{{.RestartCount}}' "$(cid)"; }
running() {  # wait until it runs again
  for _ in $(seq 1 60); do [ "$(docker inspect -f '{{.State.Running}}' "$(cid)")" = true ] && return 0; sleep 0.5; done; return 1
}
until_count() {  # n: wait until Docker has restarted it n times, and it runs
  for _ in $(seq 1 180); do [ "$(count)" -ge "$1" ] && running && return 0; sleep 1; done; return 1
}
run() {
  out=$(cd "$T/repo" && KF2_COMPOSE_FILE="$T/compose.yml" COMPOSE_PROJECT_NAME="$P" KF2_TAKEOVER="" \
    KF2_IDLE_RESET_STATE="$T/state" tools/kf2-idle-reset.sh 2>&1); rc=$?
}

echo "=== a container that crashes, under Docker's restart policy ==="
docker compose -p "$P" -f "$T/compose.yml" up -d >/dev/null 2>&1 || { echo "cannot start the test container"; exit 1; }
running; run
[ "$rc" = 0 ] && [[ $out != *restarted* ]] && pass "first run: the count written down, nothing said (exit 0)" || fail "first run: exit $rc, $out"
until_count 1; run
[ "$rc" = 0 ] && [[ $out == *"the server restarted 1 time since"*", last exit code 3, "*"its log before that: Signal: SIGSEGV [segmentation fault]"* ]] \
  && pass "after the first crash: said once, exit code 3 and the crash line, exit 0" || fail "after the crash: exit $rc, $out"
run
[ "$rc" = 0 ] && [[ $out != *restarted* ]] && pass "the run after: nothing said" || fail "the run after: exit $rc, $out"
docker restart -t 0 "$(cid)" >/dev/null; running
[ "$(count)" = 0 ] && pass "docker restart sets the count back to 0 (measured here)" || fail "after docker restart the count is $(count)"
run
[ "$rc" = 0 ] && [[ $out != *restarted* ]] && pass "after a restart by hand: the new starting point, nothing said" || fail "after the restart by hand: exit $rc, $out"
until_count 3; run
[ "$rc" = 1 ] && [[ $out == *"the server restarted 3 times since"*"in 24 h)"* ]] \
  && pass "three restarts by the policy since, four in 24 hours: exit 1" || fail "the limit: exit $rc, $out"

echo
echo "=== a container killed for memory, under the same policy ==="
docker compose -p "$P" -f "$T/compose.yml" down -t 0 >/dev/null 2>&1
rm -f "$T/state"*
cat >"$T/compose.yml" <<YAML
services:
  $SERVICE:
    image: alpine:3.22
    restart: on-failure:5
    mem_limit: 16m
    memswap_limit: 16m
    command: ["sh", "-c", "sleep 4; tail /dev/zero"]
YAML
docker compose -p "$P" -f "$T/compose.yml" up -d >/dev/null 2>&1 || { echo "cannot start the memory test container"; exit 1; }
running; run
[ "$rc" = 0 ] && [[ $out != *restarted* ]] && pass "first run: nothing said" || fail "memory, first run: exit $rc, $out"
until_count 1; run
[ "$rc" = 0 ] && [[ $out == *"the server restarted 1 time since"*"; killed for memory (oom event, exit 137 (SIGKILL))"* ]] \
  && pass "killed for memory: named from the oom event, exit 137 (SIGKILL)" || fail "memory: exit $rc, $out"

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
