#!/bin/bash
# Does the health check notice when the GAME dies and the wrapper does not?
#
# `pgrep -f` searches full command lines, and the shell running the
# check has the pattern in its own - so written without the bracket, this
# check passed for every pattern ever given to it, including one naming a
# process that does not exist. A server on the machine this template comes
# from crashed with a core dump and reported healthy for seventeen hours.
# Splitting the first letter into a character class makes the pattern no
# longer match the literal text of the command carrying it.
#
# Docker does not restart an unhealthy container by itself, so a check that
# stays green with the game dead is a check nobody else corrects.
#
# No game download involved: two processes with the right names are enough,
# and the check reads /proc, not the game.
set -uo pipefail

RUN="kf2-server-hc-$$"
PASSED=0; FAILED=0
cleanup() { docker rm -f "$RUN" >/dev/null 2>&1; }
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }

EXACT='pgrep -f '\''[K]FGameSteamServer.bin'\'' >/dev/null'
LOOSE='pgrep -f '\''KFGameSteamServer.bin'\'' >/dev/null'

echo "=== the health check, in both directions ==="
echo

docker rm -f "$RUN" >/dev/null 2>&1
# debian, not alpine: busybox dispatches on argv[0], so a copy of its sleep
# named KFGameSteamServer.bin is not an applet it knows and exits immediately. A real standalone
# binary takes the name it is invoked under, which is what /proc/N/comm reads.
docker run -d --name "$RUN" ubuntu:24.04 sh -c '
  g=KFGameStea; g="${g}mServer.bin"
  cp /bin/sleep "/tmp/$g"
  cp /bin/sleep /tmp/kf2server
  "/tmp/$g" 3600 &
  /tmp/kf2server 3600 &
  wait' >/dev/null 2>&1 || { echo "cannot start the fixture container"; exit 1; }

# Both processes have to exist before anything is asserted, or a pass below
# would only mean the container was slow.
ready=false
for _ in $(seq 1 40); do
  if docker exec "$RUN" sh -c "$EXACT" 2>/dev/null; then ready=true; break; fi
  sleep 0.5
done
if [ "$ready" = true ]; then
  pass "with the game running, the exact check is green"
else
  fail "the fixture never came up; nothing below would mean anything"
  docker logs "$RUN" 2>&1 | tail -5 | sed 's/^/        /'
  echo; echo "passed: $PASSED   failed: $FAILED"; exit 1
fi

# Both names are present, so the loose form is green too. It has to be, or the
# comparison below proves nothing.
if docker exec "$RUN" sh -c "$LOOSE" 2>/dev/null; then
  pass "and so is the substring check, as expected"
else
  fail "the substring check was already red, so the fixture is wrong"
fi

# THE CASE THIS EXISTS FOR: kill the game, leave the wrapper.
#
# /proc rather than pgrep: debian:stable-slim ships no procps, and a missing
# command exits non-zero, which a naive check reads as "the process is gone".
# The first version of this file did exactly that and reported a kill that
# never happened - the same shape of silent no-op the health check itself is
# written to avoid.
docker exec "$RUN" sh -c 'for p in /proc/[0-9]*; do
  [ "$(tr "\0" "\n" < "$p/cmdline" 2>/dev/null | head -1)" = "/tmp/KFGameSteamServer.bin" ] && kill -9 "${p##*/}" 2>/dev/null
done; true' >/dev/null 2>&1
# Waiting on something OTHER than the assertion. Waiting until $EXACT fails and
# then asserting that $EXACT fails proves nothing at all; this reads the comm
# files itself and counts.
gone=false
for _ in $(seq 1 20); do
  n="$(docker exec "$RUN" sh -c 'c=0; for p in /proc/[0-9]*; do
        [ "$(tr "\0" "\n" < "$p/cmdline" 2>/dev/null | head -1)" = "/tmp/KFGameSteamServer.bin" ] && c=$((c+1)); done; echo "$c"' 2>/dev/null)"
  if [ "${n:-1}" = "0" ]; then gone=true; break; fi
  sleep 0.5
done
if [ "$gone" != true ]; then
  fail "could not kill the game process, so the assertion below is meaningless"
else
  if docker exec "$RUN" sh -c "$EXACT" 2>/dev/null; then
    fail "the exact check stayed green with the game dead"
  else
    pass "with the game dead, the exact check goes red"
  fi

  if docker exec "$RUN" sh -c "$LOOSE" 2>/dev/null; then
    pass "and the substring check stays green — which is the trap this avoids"
  else
    fail "the substring check also went red, so there is nothing to avoid and the comment is wrong"
  fi
fi

# And the wrapper is genuinely still there, so "green" above was about it.
if docker exec "$RUN" sh -c 'for p in /proc/[0-9]*; do [ "$(tr "\0" "\n" < "$p/cmdline" 2>/dev/null | head -1)" = "/tmp/kf2server" ] && exit 0; done; exit 1' 2>/dev/null; then
  pass "the wrapper is still running, which is what made the substring check lie"
else
  fail "the wrapper died too, so the scenario was not the one described"
fi

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
