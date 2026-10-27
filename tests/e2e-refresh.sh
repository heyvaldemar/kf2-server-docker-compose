#!/bin/bash
# Does tools/kf2-refresh.sh restart only an empty server that is behind, and
# is LinuxGSM's own hourly update really unable to run under this template?
#
# A restart ends the round for everyone on the server, so the decisions are
# the whole script: up to date, leave it; behind with players on, wait; behind
# and the server does not answer, wait AND exit 1, because "cannot count" read
# as zero is how a restart lands on a full server; behind and empty, restart.
#
# Against the moderation stand-in (tests/fixtures/): the pinned image with
# fake-kf2.py answering A2S where the game would be, players set per case. The
# two build numbers come through KF2_BUILDS instead of LinuxGSM asking Steam.
# Nothing here reaches the real restart: the cases that would go ahead run
# with --dry-run, and the start counter proves nothing restarted.
#
# And the reason this script exists, against the pinned image itself: as the
# game's user, LinuxGSM's update cron cannot be installed under
# no-new-privileges, and can without it. If that ever changes, this fails and
# the README has to change with it.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASSED=0; FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }

export KF2_COMPOSE_FILE=tests/fixtures/moderation-compose.yml
export COMPOSE_PROJECT_NAME="kf2-refreshtest-$$"
export KF2_QUERY_PORT=27015
export KF2_SERVER_UID=1000 KF2_SERVER_GID=1000 KF2_MODERATION_WEBHOOK=""
KF2_SERVER_IMAGE_TAG="$(grep -m1 -oE '\$\{KF2_SERVER_IMAGE_TAG:-.*' kf2-server-docker-compose.yml | sed -E -e ':a' -e 's/\$\{[A-Z0-9_]+:-([^{}]*)\}/\1/' -e 'ta')"
export KF2_SERVER_IMAGE_TAG
[ -n "$KF2_SERVER_IMAGE_TAG" ] || { echo "could not read the pinned image from the compose file"; exit 1; }

compose() { docker compose -f "$KF2_COMPOSE_FILE" -p "$COMPOSE_PROJECT_NAME" "$@"; }
cleanup() { compose down -v --remove-orphans >/dev/null 2>&1; }
trap cleanup EXIT
fake_set() { compose exec -T kf2-server sh -c "printf '%s' \"\$1\" > /data/$2" -- "$1" "$2" 2>/dev/null; }
fake_rm()  { compose exec -T kf2-server rm -f "/data/$1" 2>/dev/null; }
starts()   { compose exec -T kf2-server sh -c 'grep -c . /data/starts' 2>/dev/null; }
refresh() {
  if command -v timeout >/dev/null 2>&1; then timeout 120 tools/kf2-refresh.sh "$@"
  else perl -e 'alarm 120; exec @ARGV' tools/kf2-refresh.sh "$@"; fi
}

echo "=== why: LinuxGSM's own update cron, against the pinned image ==="
echo "    $KF2_SERVER_IMAGE_TAG"
echo
cron='echo "*/60 * * * * /app/kf2server update" | crontab - 2>&1; echo "exit $?"'
hardened="$(docker run --rm --security-opt no-new-privileges:true --user linuxgsm --entrypoint sh "$KF2_SERVER_IMAGE_TAG" -c "$cron" 2>&1)"
plain="$(docker run --rm --user linuxgsm --entrypoint sh "$KF2_SERVER_IMAGE_TAG" -c "$cron" 2>&1)"
if grep -q "Permission denied" <<<"$hardened" && grep -q "exit 1" <<<"$hardened"; then
  pass "under no-new-privileges the update cron cannot be installed: $(grep -m1 "Permission denied" <<<"$hardened")"
else
  fail "under no-new-privileges the update cron was installed: $hardened"
fi
if grep -q "exit 0" <<<"$plain"; then pass "without it, the same install works: the hardening is the cause"; else fail "the install fails even without the hardening: $plain"; fi
if grep -qE '^ +UPDATE_CHECK: "0"$' kf2-server-docker-compose.yml; then pass "the compose file turns it off on purpose (UPDATE_CHECK: \"0\")"; else fail "the compose file does not set UPDATE_CHECK to 0"; fi

echo
echo "=== the refresh, the build and the players on the server ==="
echo
compose up -d --quiet-pull >/dev/null 2>&1 || { echo "cannot start the stand-in server"; exit 1; }
for _ in $(seq 1 60); do [ -n "$(tools/kf2-a2s.sh players 2>/dev/null)" ] && break; sleep 1; done
before="$(starts)"

# 1. Up to date: nothing to do.
out="$(KF2_BUILDS="100 100" refresh 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q "up to date: build 100" <<<"$out"; then pass "up to date: says so"; else fail "up to date: exit $rc, said: $out"; fi

# 2. --check reports a server that is behind and changes nothing.
out="$(KF2_BUILDS="100 101" refresh --check 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q "behind: running build 100, Steam ships 101" <<<"$out"; then pass "--check: reports behind"; else fail "--check: exit $rc, said: $out"; fi

# 3. Behind, with players on: wait.
fake_set 2 players
out="$(KF2_BUILDS="100 101" refresh 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q "but 2 player(s) are on" <<<"$out" && [ "$(starts)" = "$before" ]; then pass "behind, two players on: waits, not restarted"; else fail "behind, two players on: exit $rc, said: $out"; fi

# 4. THE CASE THIS FILE EXISTS FOR: behind, and the server does not answer.
fake_set 1 silent
out="$(KF2_BUILDS="100 101" refresh 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q "did not answer the player query" <<<"$out" && [ "$(starts)" = "$before" ]; then pass "behind, no answer: waits, exit 1, not restarted"; else fail "behind, no answer: exit $rc, said: $out"; fi

# 5. --force overrides an unknown count, and says that it did.
out="$(KF2_BUILDS="100 101" refresh --dry-run --force 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q "players online: ?, forced" <<<"$out"; then pass "behind, no answer, --force: it would restart"; else fail "behind, no answer, --force: exit $rc, said: $out"; fi
fake_rm silent

# 6. Behind and empty: it would restart.
fake_set 0 players
for _ in $(seq 1 20); do [ "$(tools/kf2-a2s.sh players 2>/dev/null)" = 0 ] && break; sleep 1; done
out="$(KF2_BUILDS="100 101" refresh --dry-run 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q "would restart to update (100 -> 101): players online: 0" <<<"$out"; then pass "behind, nobody on: it would restart"; else fail "behind, nobody on: exit $rc, said: $out"; fi

# 7. A build LinuxGSM did not print: nothing is decided on a guess.
out="$(KF2_BUILDS="" refresh 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q "could not read both builds" <<<"$out"; then pass "a build that could not be read: exit 1, nothing changed"; else fail "unreadable build: exit $rc, said: $out"; fi

# 8. Steam silent, the installed build read: tolerated, and the start noted.
silent="$(mktemp)"; rm -f "$silent"
out="$(KF2_BUILDS="100 " KF2_REFRESH_STEAM_SILENT_FILE="$silent" refresh 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q "Steam did not say which build it ships (running build 100); quiet for 0 min, tolerated up to 180 min" <<<"$out" && [ -s "$silent" ]; then pass "Steam silent: tolerated, exit 0, the start noted"; else fail "Steam silent: exit $rc, said: $out"; fi

# 9. However often it runs, the span is what counts: quiet for four hours fails.
echo "$(( $(date +%s) - 14400 ))" > "$silent"
out="$(KF2_BUILDS="100 " KF2_REFRESH_STEAM_SILENT_FILE="$silent" refresh 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q "for 240 min, past the 180 min tolerance" <<<"$out"; then pass "Steam silent for four hours: exit 1"; else fail "Steam silent past the span: exit $rc, said: $out"; fi

# 10. Steam answers again: the span starts over.
out="$(KF2_BUILDS="100 100" KF2_REFRESH_STEAM_SILENT_FILE="$silent" refresh 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ ! -e "$silent" ]; then pass "Steam answers: the silence is forgotten"; else fail "Steam answers: exit $rc, file left: $([ -e "$silent" ] && echo yes), said: $out"; fi

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
