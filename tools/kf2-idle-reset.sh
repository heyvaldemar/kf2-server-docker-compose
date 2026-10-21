#!/bin/bash
# kf2-idle-reset.sh - restart an EMPTY server in the two states where a
# restart is the only way back. Run it from a timer, every five minutes.
#
#   tools/kf2-idle-reset.sh            restart if one of the rules says so
#   tools/kf2-idle-reset.sh --dry-run  go as far as deciding, never restart
#
# A server is never restarted with anybody on it, and a player count the
# query could not read is not zero: tools/kf2-a2s.sh is asked, and silence
# means "do not touch", exit 1, the same as tools/kf2-refresh.sh.
#
# RULE ONE: EMPTY AND CLOSED TO TAKEOVER. Killing Floor 2 lets a matchmaking
# party take over an empty dedicated server and choose its map, mode,
# difficulty and length, which is where a public server gets most of its
# players. The server tells matchmaking whether it may be taken over in its
# advertisement, logged as "Advertising: bAvailableForTakeover=True|False",
# and when a party leaves it usually flips back to True within two minutes.
# Sometimes it does not. On the server this template comes from, a party
# switched it to Versus and left, and it advertised False with every seat
# open for 21.9 hours: in the 22.6 hours before, someone was on in 146 of 271
# five-minute samples, in the same span after, 9 of 272, and not one new
# takeover. A restart brings it back on what config/kf2server.cfg says. Empty,
# closed to takeover, for KF2_IDLE_RESET_AFTER seconds (900) -> restart. An
# empty server that is open to takeover is only quiet, and is left alone.
#
# A RESET THAT DID NOT TAKE MUST NOT BECOME A LOOP. If the server is empty
# and closed again within an hour of this rule's last reset, the config is
# not bringing it back, and restarting every quarter of an hour would hide
# that. It says so and exits 1 on every run inside that hour, without
# restarting, so the failed timer is there for somebody to look at.
#
# RULE TWO: A LONG UPTIME, RESET WHILE NOBODY IS ON. The two crashes with a
# log on that server were both the game segfaulting on a map change after a
# long run, 16 h and 12.8 h, the second with five people on, at the same
# fault address as an older crash nobody had explained. Memory was not the
# cause: about 900 MB of the 4 GB limit both times. Up KF2_MAX_UPTIME seconds
# (28800, 8 h, well short of 12.8 h; 0 turns the rule off) and empty for
# KF2_UPTIME_EMPTY_FOR seconds (300) -> restart. Two crashes are a hypothesis,
# not a cause: restarting an empty server costs nobody anything, and whether
# it stops the crashes is for the log to show. It keeps its own clock, apart
# from rule one's loop guard: a party that took the fresh server and left at
# once must not read as "closed again after a reset". It cannot loop by
# itself, because the restart resets the uptime it keys on.
#
# "Up" is the container's, from `docker inspect`: a game that crashed and was
# restarted by Docker counts from the restart. An uptime that cannot be read
# counts as zero, so the rule waits rather than guesses.
#
# tests/e2e-idle-reset.sh proves the decisions against the moderation
# stand-in. Two readings can be supplied instead of asked for:
#   KF2_TAKEOVER  True or False, in place of reading Launch.log; set but
#                 empty means "not in the log"
#   KF2_UPTIME    seconds, in place of asking Docker
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

DRY=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=true ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

COMPOSE_FILE=${KF2_COMPOSE_FILE:-kf2-server-docker-compose.yml}
PROJECT=${COMPOSE_PROJECT_NAME:-kf2}
IDLE=${KF2_IDLE_RESET_AFTER:-900}
MAX_UP=${KF2_MAX_UPTIME:-28800}
UP_EMPTY=${KF2_UPTIME_EMPTY_FOR:-300}
STATE=${KF2_IDLE_RESET_STATE:-.kf2-idle-reset}
LAUNCH=/data/serverfiles/KFGame/Logs/Launch.log
compose() { docker compose -f "$COMPOSE_FILE" -p "$PROJECT" "$@"; }
say() { echo "$(date '+%F %T') $*"; }

id="$(compose ps -q --status running kf2-server 2>/dev/null)"
[ -n "$id" ] || { say "the server is not running; nothing to reset"; exit 0; }

# The last thing the server told matchmaking. It is logged when it changes,
# so the newest line is the current value however long ago it was written.
if [ -n "${KF2_TAKEOVER+x}" ]; then takeable=$KF2_TAKEOVER; else
  takeable="$(compose exec -T kf2-server sh -c "grep -a 'Advertising: bAvailableForTakeover=' $LAUNCH | tail -1" 2>/dev/null \
              | grep -oE '(True|False)' | tail -1)"
fi

if [ -n "${KF2_UPTIME+x}" ]; then up=$KF2_UPTIME; else
  started="$(docker inspect -f '{{.State.StartedAt}}' "$id" 2>/dev/null)"
  since="$(date -u -d "$started" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%S' "${started%%.*}" +%s 2>/dev/null)"
  up=$(( $(date +%s) - ${since:-$(date +%s)} ))
fi

players() {
  local n
  n="$(tools/kf2-a2s.sh players 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) echo "?" ;; *) echo "$n" ;; esac
}
restart() {  # why
  if $DRY; then say "would restart: $1"; return 0; fi
  compose restart kf2-server >/dev/null 2>&1 || { say "FAILED to restart ($1): docker compose -p $PROJECT logs --tail 200 kf2-server" >&2; return 1; }
  say "restarted: $1"
}
now=$(date +%s)
hours() { echo "$(( $1 / 3600 ))h"; }

if [ "$takeable" = False ]; then
  rm -f "$STATE.uptime"
  n="$(players)"
  if [ "$n" = "?" ]; then say "closed to takeover, and the server did not answer the player query; not acting on a guess" >&2; exit 1; fi
  if [ "$n" -gt 0 ]; then rm -f "$STATE"; say "closed to takeover with $n player(s) on: their game, left alone"; exit 0; fi
  [ -s "$STATE" ] || echo "$now" >"$STATE"
  idle=$(( now - $(cat "$STATE") ))
  if [ "$idle" -lt "$IDLE" ]; then say "empty and closed to takeover for ${idle}s; resetting after ${IDLE}s"; exit 0; fi
  last="$(cat "$STATE.last" 2>/dev/null || echo 0)"
  if [ $(( now - last )) -lt 3600 ]; then
    say "empty and closed to takeover again within an hour of a reset: the configured mode is not bringing it back, or a party took it and left at once. Not restarting it again inside that hour" >&2
    exit 1
  fi
  restart "empty and closed to takeover for $(( idle / 60 )) min, so matchmaking could not reach it" || exit 1
  $DRY || { echo "$now" >"$STATE.last"; rm -f "$STATE"; }
  exit 0
fi
rm -f "$STATE"

if [ "$MAX_UP" -gt 0 ] && [ "$up" -ge "$MAX_UP" ]; then
  n="$(players)"
  if [ "$n" = "?" ]; then say "up $(hours "$up"), and the server did not answer the player query; not acting on a guess" >&2; exit 1; fi
  if [ "$n" -gt 0 ]; then rm -f "$STATE.uptime"; say "up $(hours "$up") with $n player(s) on: waiting for an empty server"; exit 0; fi
  [ -s "$STATE.uptime" ] || echo "$now" >"$STATE.uptime"
  empty=$(( now - $(cat "$STATE.uptime") ))
  if [ "$empty" -lt "$UP_EMPTY" ]; then say "up $(hours "$up"), empty for ${empty}s; restarting after ${UP_EMPTY}s"; exit 0; fi
  restart "up $(hours "$up") and empty for $(( empty / 60 )) min, ahead of the long-uptime map-change crash" || exit 1
  $DRY || rm -f "$STATE.uptime"
  exit 0
fi
rm -f "$STATE.uptime"
say "${takeable:+open to takeover, }up $(hours "$up"): nothing to do"
