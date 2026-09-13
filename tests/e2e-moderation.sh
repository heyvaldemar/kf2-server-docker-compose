#!/bin/bash
# Does moderation without rcon do what it says, against the pinned image?
#
# The tools stop the server, edit a file inside its volume as its own user,
# start it again and read the file back; they queue a ban while anyone is on
# and apply it when the server is empty; they treat an unanswered query as
# "not proven empty"; and they say so, loudly, when the server drops an id
# or a webhook does not answer. None of that needs the game. What it needs is
# the image the tools run their python in, a volume laid out the way LinuxGSM
# lays it out, and something on the query port that answers A2S the way the
# engine does. tests/fixtures/ is that something.
#
# Negative cases throughout: a check that has only ever passed has not proved
# it can fail. The wrong id is refused, the busy server is not restarted, the
# silent one is not restarted, the dropped ban is reported as dropped, the
# missing section is reported and the server is started again afterwards.
# shellcheck disable=SC2015   # pass and fail always exit 0, so "A && pass || fail" is if-then-else here
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASSED=0; FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }

SCRATCH=$(mktemp -d)
INI=/data/serverfiles/KFGame/Config/kf2server/LinuxServer-KFGame.ini
export KF2_COMPOSE_FILE=tests/fixtures/moderation-compose.yml
export COMPOSE_PROJECT_NAME="kf2-modtest-$$"
export KF2_BAN_QUEUE="$SCRATCH/queue"
export KF2_QUERY_PORT=27015
export KF2_BAN_WAIT=90
# The stand-in runs as 1000:1000 whatever a maintainer's .env says, and no
# run of this may ever reach a real moderation channel.
export KF2_SERVER_UID=1000 KF2_SERVER_GID=1000 KF2_MODERATION_WEBHOOK=""
KF2_SERVER_IMAGE_TAG="$(grep -m1 -oE '\$\{KF2_SERVER_IMAGE_TAG:-.*' kf2-server-docker-compose.yml | sed -E -e ':a' -e 's/\$\{[A-Z0-9_]+:-([^{}]*)\}/\1/' -e 'ta')"
export KF2_SERVER_IMAGE_TAG
[ -n "$KF2_SERVER_IMAGE_TAG" ] || { echo "could not read the pinned image from the compose file"; exit 1; }

compose() { docker compose -f "$KF2_COMPOSE_FILE" -p "$COMPOSE_PROJECT_NAME" "$@"; }
cleanup() { compose down -v --remove-orphans >/dev/null 2>&1; rm -rf "$SCRATCH"; }
trap cleanup EXIT

fake_set() { compose exec -T kf2-server sh -c "printf '%s' \"\$1\" > /data/$2" -- "$1" "$2" 2>/dev/null; }
fake_rm()  { compose exec -T kf2-server rm -f "/data/$1" 2>/dev/null; }
ini_cat()  { compose run --rm --no-deps -T --entrypoint cat kf2-server "$INI" 2>/dev/null; }
starts()   { compose exec -T kf2-server sh -c 'grep -c . /data/starts' 2>/dev/null; }
# Ready means the stand-in answers A2S AND the container is healthy: the ban
# script treats "starting" as not proven empty, which is right for a real
# server mid-install and would only confuse the assertions here.
wait_ready() {
  local id
  for _ in $(seq 1 60); do
    id=$(compose ps -q kf2-server 2>/dev/null | head -1)
    if [ -n "$id" ] && [ "$(docker inspect --format '{{.State.Health.Status}}' "$id" 2>/dev/null)" = "healthy" ] \
       && [ -n "$(tools/kf2-a2s.sh players)" ]; then return 0; fi
    sleep 1
  done
  return 1
}

echo "=== moderation without rcon, against the pinned image ==="
echo "    $KF2_SERVER_IMAGE_TAG"
echo
compose up -d --quiet-pull >/dev/null 2>&1 || { echo "cannot start the stand-in server"; compose logs 2>&1 | tail -20; exit 1; }
if wait_ready; then
  pass "the stand-in server is up and answers A2S through the container"
else
  fail "the stand-in server never became ready; nothing below would mean anything"
  compose logs 2>&1 | tail -20 | sed 's/^/        /'
  echo; echo "passed: $PASSED   failed: $FAILED"; exit 1
fi

echo; echo "--- the one probe"
n=$(tools/kf2-a2s.sh players)
[ "$n" = "0" ] && pass "players: 0 on an empty server" || fail "players printed '$n', expected 0"
info=$(tools/kf2-a2s.sh info)
if printf '%s' "$info" | awk -F'\t' '$2 == "KF-BioticsLab" && $3 == 0 && $4 == 6 && $5 == "open" { ok = 1 } END { exit !ok }'; then
  pass "info: map, players, max and visibility parsed from the reply"
else
  fail "info printed '$info'"
fi
fake_set $'Alice\nBob' names
who=$(tools/kf2-a2s.sh who)
if [ "$(printf '%s\n' "$who" | grep -c .)" = "2" ] && printf '%s' "$who" | grep -q '^Alice' && printf '%s' "$who" | grep -q '^Bob'; then
  pass "who: two names, and nothing that looks like an id, because A2S carries none"
else
  fail "who printed: $who"
fi
fake_set '' names
[ "$(tools/kf2-a2s.sh who)" = "nobody is on" ] && pass "who: 'nobody is on' when the roster is empty" || fail "who on an empty roster: $(tools/kf2-a2s.sh who)"
fake_set 1 silent
[ -z "$(tools/kf2-a2s.sh players)" ] && pass "players prints NOTHING when the server does not answer, not zero" || fail "players printed '$(tools/kf2-a2s.sh players)' from a silent server"
fake_rm silent

echo; echo "--- ban on an empty server: stop, edit, start, read back"
[ "$(tools/kf2-ban.sh list)" = "nobody is banned" ] && pass "list: nobody is banned to begin with" || fail "list: $(tools/kf2-ban.sh list)"
before=$(starts)
out=$(tools/kf2-ban.sh add 76561198042335367 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$out" = "banned 76561198042335367" ] && pass "add: 'banned 76561198042335367', read back from the file the server rewrote" || fail "add exited $rc: $out"
wait_ready
if ini_cat | awk '/^\[/ { sec = $0 } sec == "[Engine.AccessControl]" && $0 == "BannedIDs=(Uid=(A=82069639,B=17825793))" { ok = 1 } END { exit !ok }'; then
  pass "the line is inside [Engine.AccessControl], with the id split into A=82069639,B=17825793"
else
  fail "the ban line is missing or in the wrong section:"; ini_cat | sed 's/^/        /'
fi
if ini_cat | awk 'BEGIN { RS = "" } /\[Engine.AccessControl\]/ && /BannedIDs/ { ok = 1 } END { exit !ok }' && ini_cat | awk '/^\[Engine.AccessControl\]/ { s = 1; next } s && /^\[/ { exit } s && /^$/ { blank = 1 } s && /^BannedIDs/ && blank { bad = 1 } END { exit bad }'; then
  pass "and it sits before the blank line that ends the section, not after it"
else
  fail "the ban line landed after the section's blank line"
fi
[ "$(starts)" = "$((before + 1))" ] && pass "the server was restarted exactly once for it" || fail "starts went from $before to $(starts)"
[ "$(tools/kf2-ban.sh list)" = "76561198042335367" ] && pass "list: the id, in decimal, whatever form the file uses" || fail "list: $(tools/kf2-ban.sh list)"

echo; echo "--- what is refused"
out=$(tools/kf2-ban.sh add 0x0110000104E44887 2>&1); rc=$?
[ "$rc" = 3 ] && [ "$out" = "already banned" ] && pass "the hex form the chat log writes is recognised as the same id: 'already banned', exit 3" || fail "hex add exited $rc: $out"
before=$(starts)
out=$(tools/kf2-ban.sh add 12345 2>&1); rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "not the id of a player account" && [ ! -s "$KF2_BAN_QUEUE" ] && [ "$(starts)" = "$before" ]; then
  pass "a number that is not a player id is refused: not written, not queued, no restart"
else
  fail "add 12345 exited $rc: $out"
fi
out=$(tools/kf2-ban.sh add abc 2>&1); rc=$?
[ "$rc" = 1 ] && pass "and so is a word" || fail "add abc exited $rc: $out"

echo; echo "--- with players on, a ban waits"
fake_set 2 players
before=$(starts)
out=$(tools/kf2-ban.sh add 76561198045356622 2>&1); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "^queued: 76561198045356622, 2 player(s) are on" && grep -q "^76561198045356622 " "$KF2_BAN_QUEUE" && [ "$(starts)" = "$before" ]; then
  pass "add with 2 on: queued, written down, nobody restarted"
else
  fail "add with players on exited $rc: $out"
fi
[ "$(tools/kf2-ban.sh list)" = "76561198042335367" ] && pass "the file is untouched while it waits" || fail "list changed: $(tools/kf2-ban.sh list)"
out=$(tools/kf2-ban.sh add 76561198045356622 2>&1)
printf '%s' "$out" | grep -q "^already queued" && pass "asking twice: 'already queued'" || fail "second add: $out"
tools/kf2-ban.sh queue | grep -q "^76561198045356622 " && pass "queue: lists what is waiting" || fail "queue: $(tools/kf2-ban.sh queue)"
out=$(tools/kf2-ban-queue.sh --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$out" = "2 player(s) on: 1 ban(s) stay queued" ] && [ "$(starts)" = "$before" ] && pass "the applier with 2 on: '$out'" || fail "applier with players on exited $rc: $out"

echo; echo "--- an unanswered query is not an empty server"
fake_set 1 silent
out=$(tools/kf2-ban-queue.sh 2>&1); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "did not answer" && grep -q "^76561198045356622 " "$KF2_BAN_QUEUE" && [ "$(starts)" = "$before" ]; then
  pass "the applier: '$out'"
else
  fail "applier on a silent server exited $rc: $out"
fi
out=$(tools/kf2-ban.sh add 76561198000000002 2>&1); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "not answering" && grep -q "^76561198000000002 " "$KF2_BAN_QUEUE" && [ "$(starts)" = "$before" ]; then
  pass "a fresh ban on a silent server is queued too, not applied on a guess"
else
  fail "add on a silent server exited $rc: $out"
fi
out=$(tools/kf2-ban.sh remove 76561198042335367 2>&1); rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q -- "--force" && pass "and lifting one is refused, with --force named as the way past" || fail "remove on a silent server exited $rc: $out"
fake_rm silent

echo; echo "--- the server empties: the queue applies, and says where it was asked"
fake_set 0 players
before=$(starts)
out=$(KF2_MODERATION_WEBHOOK=http://127.0.0.1:9/nothing-listens-here tools/kf2-ban-queue.sh 2>"$SCRATCH/err"); rc=$?
if printf '%s' "$out" | grep -q "^applied:" && printf '%s' "$out" | grep -q "^76561198045356622 (waited" && printf '%s' "$out" | grep -q "^76561198000000002 (waited"; then
  pass "both queued bans applied, each read back after its own restart"
else
  fail "applier exited $rc: $out"; cat "$SCRATCH/err"
fi
wait_ready
[ "$(starts)" = "$((before + 2))" ] && pass "one restart per ban, on purpose: $before -> $(starts)" || fail "starts went from $before to $(starts)"
[ ! -s "$KF2_BAN_QUEUE" ] && pass "the queue is empty afterwards" || fail "queue still holds: $(cat "$KF2_BAN_QUEUE")"
[ "$(tools/kf2-ban.sh list | sort | tr '\n' ' ')" = "76561198000000002 76561198042335367 76561198045356622 " ] && pass "list: all three" || fail "list: $(tools/kf2-ban.sh list | tr '\n' ' ')"
if [ "$rc" = 1 ] && grep -q "notify FAILED: HTTP 000" "$SCRATCH/err"; then
  pass "a webhook nobody answers is said out loud and fails the run: exit 1, 'notify FAILED'"
else
  fail "webhook failure: exit $rc, stderr: $(cat "$SCRATCH/err")"
fi
out=$(tools/kf2-ban-queue.sh 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && pass "nothing queued: silent, exit 0, the normal case every five minutes" || fail "empty queue run exited $rc: $out"

echo; echo "--- the read-back notices what the server did not keep"
fake_set 76561198000000001 drop-on-start
out=$(tools/kf2-ban.sh add 76561198000000001 2>&1); rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q "^NOT BANNED after add: the server dropped 76561198000000001"; then
  pass "an id the server dropped at startup is reported as NOT BANNED, exit 1"
else
  fail "dropped-id add exited $rc: $out"
fi
wait_ready
tools/kf2-ban.sh list | grep -q "^76561198000000001$" && fail "list still shows the dropped id" || pass "and list does not show it"

echo; echo "--- unban"
out=$(tools/kf2-ban.sh remove 76561198042335367 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$out" = "unbanned 76561198042335367" ] && pass "remove on an empty server: 'unbanned', read back" || fail "remove exited $rc: $out"
wait_ready
before=$(starts)
out=$(tools/kf2-ban.sh remove 76561198042335367 2>&1); rc=$?
[ "$rc" = 3 ] && [ "$out" = "not in the ban list" ] && pass "removing it again: 'not in the ban list', exit 3" || fail "second remove exited $rc: $out"
[ "$(starts)" = "$before" ] && pass "and nothing to change means no restart: the list was read first" || fail "a no-op remove restarted the server: $before -> $(starts)"
out=$(tools/kf2-ban.sh add 76561198045356622 2>&1); rc=$?
[ "$rc" = 3 ] && [ "$(starts)" = "$before" ] && pass "same for a ban already in the file" || fail "a no-op add exited $rc or restarted: $out"
fake_set 1 players
before=$(starts)
out=$(tools/kf2-ban.sh remove 76561198045356622 2>&1); rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q "1 player(s) are on" && [ "$(starts)" = "$before" ] && pass "remove with 1 on: refused, no restart" || fail "remove with a player on exited $rc: $out"
out=$(tools/kf2-ban.sh remove 76561198045356622 --force 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$out" = "unbanned 76561198045356622" ] && pass "--force: applied at once, with a player on, because it was asked twice" || fail "forced remove exited $rc: $out"
wait_ready
fake_set 0 players

echo; echo "--- the file's own line endings"
# The fixture is LF; make it CRLF the way a file written on Windows would be,
# and prove that took before asserting anything about it.
compose run --rm --no-deps -T --user 1000:1000 --entrypoint python3 kf2-server - "$INI" <<'PY' >/dev/null 2>&1
import sys
p = sys.argv[1]
with open(p, "rb") as f: b = f.read()
with open(p, "wb") as f: f.write(b.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n"))
PY
total=$(ini_cat | wc -l | tr -d ' '); crlf=$(ini_cat | grep -c $'\r$')
[ "$total" = "$crlf" ] && [ "$total" -gt 0 ] && pass "the file is CRLF throughout before the edit ($crlf of $total)" || fail "the fixture did not become CRLF: $crlf of $total"
out=$(tools/kf2-ban.sh add 76561198042335367 2>&1); rc=$?
[ "$rc" = 0 ] && pass "add on a CRLF file: banned" || fail "add on a CRLF file exited $rc: $out"
wait_ready
total=$(ini_cat | wc -l | tr -d ' '); crlf=$(ini_cat | grep -c $'\r$')
[ "$total" = "$crlf" ] && [ "$total" -gt 0 ] && pass "every line still ends in CRLF, the new one included ($crlf of $total)" || fail "CRLF lines after the edit: $crlf of $total"

echo; echo "--- an edit that cannot be made"
compose run --rm --no-deps -T --user 1000:1000 --entrypoint sh kf2-server -c "printf '[Engine.GameInfo]\nMaxPlayers=6\n' > $INI" >/dev/null 2>&1
out=$(tools/kf2-ban.sh add 76561198000000003 2>&1); rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q "could not find \[Engine.AccessControl\]" && pass "no [Engine.AccessControl]: said plainly, exit 1" || fail "add without the section exited $rc: $out"
wait_ready && pass "and the server it stopped for the edit is running again" || fail "the server was left stopped after a failed edit"

echo; echo "--- is it listed? Steam's answer, parsed"
printf '{"response":{"success":true,"servers":[{"addr":"203.0.113.5:27015","gmsindex":65534,"steamid":"90000000000000001","appid":232130,"gamedir":"kf2","region":-1,"secure":true,"lan":false,"gameport":7777,"specport":0}]}}' > "$SCRATCH/listed.json"
printf '{"response":{"success":true}}' > "$SCRATCH/none.json"
printf '<html>503 Service Unavailable</html>' > "$SCRATCH/broken.json"
KF2_STEAM_API_URL="file://$SCRATCH/listed.json" tools/kf2-listed.sh 203.0.113.5 27015 >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && pass "listed on the query port asked about: exit 0" || fail "listed.json on 27015 exited $rc"
KF2_STEAM_API_URL="file://$SCRATCH/listed.json" tools/kf2-listed.sh 203.0.113.5 27020 >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && pass "listed, but not on that port: exit 1" || fail "listed.json on 27020 exited $rc"
KF2_STEAM_API_URL="file://$SCRATCH/none.json" tools/kf2-listed.sh 203.0.113.5 >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && pass "Steam knows no server at the address: exit 1" || fail "none.json exited $rc"
KF2_STEAM_API_URL="file://$SCRATCH/broken.json" tools/kf2-listed.sh 203.0.113.5 >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && pass "a body that is not Steam's list: exit 2, which is not 'not listed'" || fail "broken.json exited $rc"

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
