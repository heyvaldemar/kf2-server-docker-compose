#!/bin/bash
# kf2-idle-reset.sh - restart an EMPTY server in the one state where a
# restart is the only way back. Run it from a timer, every five minutes.
#
#   tools/kf2-idle-reset.sh            restart if the rule says so
#   tools/kf2-idle-reset.sh --dry-run  go as far as deciding, never restart
#
# A server is never restarted with anybody on it, and a player count the
# query could not read is not zero: tools/kf2-a2s.sh is asked, and silence
# means "do not touch", exit 1, the same as tools/kf2-refresh.sh.
#
# THE RULE: EMPTY AND CLOSED TO TAKEOVER. Killing Floor 2 lets a matchmaking
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
# and closed again within an hour of the last reset, the config is not
# bringing it back, and restarting every quarter of an hour would hide that.
# It says so and exits 1 on every run inside that hour, without restarting,
# so the failed timer is there for somebody to look at.
#
# A SECOND RULE WAS HERE UP TO v1.4, AND IS GONE. It restarted an empty
# server after eight hours up, because the two crashes with a log on that
# server had both been the game segfaulting on a map change after a long run,
# 16 h and 12.8 h. The third crash came 45 minutes after that rule had
# restarted the server, so uptime was not the variable, and one restart it
# ordered had taken twenty minutes to come back (npm, see the compose file).
# It was removed rather than defended. What was found instead is in
# config/kf2server.cfg: a directory the Linux server never makes.
#
# A CRASH, AND DOCKER'S OWN RESTARTS. Two more things are watched on every
# run, before the rule above:
#   the game gone from a running container: LinuxGSM started it and nothing
#     stopped it (its started lock is there, no update, start or stop is
#     under way), and no game process is left. In this image process 1 is
#     the entrypoint, which keeps running when the game dies: the container
#     stays up, Docker restarts nothing, and the health check goes red and
#     stays red, with nobody able to join, until someone restarts it. A dead
#     game is an empty server in the one state a restart is the only way out
#     of, so it is restarted and said; a second time within an hour of the
#     last one is said, exit 1, and not restarted, as the rule above does.
#   Docker restarting the container (its RestartCount, on the host, where
#     this runs): said once, with the exit code and the reason from Docker's
#     die and oom events (a restarted container's own state says exit 0 and
#     not killed for memory again); 3 or more in 24 hours exit 1. The first
#     run only writes the count down; a new container id, or a count that
#     went down (`docker restart`, and so this script's own restarts, set it
#     to 0), starts afresh.
#
# tests/e2e-idle-reset.sh proves the decisions against the moderation
# stand-in, tests/restarts.sh the restart watch on real containers, and the
# real-server workflow the crash, on the real game. One reading can be
# supplied instead of asked for:
#   KF2_TAKEOVER  True or False, in place of reading Launch.log; set but
#                 empty means "not in the log"
#
# READ WHOLE BEFORE IT RUNS. bash reads a script as it executes it and, after
# each command, reads on from the same byte offset in whatever the file holds
# by then. On the server this template comes from, a timer started a script
# while its file was being edited in place: a syntax error and a failed
# unit. The body is one brace group, which bash parses in full before the
# first line runs, and it ends in exit, so nothing past the closing brace is
# ever read. Every script in tools/ is built the same way, and
# tests/read-whole.sh rewrites this file under a running copy both ways. (A
# git checkout, and so update.sh, writes a new file rather than this one,
# which a running copy never sees; an editor that saves in place does not.)
{
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
STATE=${KF2_IDLE_RESET_STATE:-.kf2-idle-reset}
LAUNCH=/data/serverfiles/KFGame/Logs/Launch.log
compose() { docker compose -f "$COMPOSE_FILE" -p "$PROJECT" "$@"; }
say() { echo "$(date '+%F %T') $*"; }
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

id="$(compose ps -q --status running kf2-server 2>/dev/null)"
[ -n "$id" ] || { say "the server is not running; nothing to reset"; exit 0; }

now=$(date +%s)
when() { date -d "@$1" '+%F %T' 2>/dev/null || date -r "$1" '+%F %T' 2>/dev/null || echo "$1"; }

# ------------------------------------------------------------- the game gone
# Read inside the container: the started lock LinuxGSM writes at start and
# removes at stop, the locks of an update, start or stop under way, and the
# game's process. Nothing printed is not a crash: no lock, a lock of
# something under way, a running game, or an exec that failed.
# shellcheck disable=SC2016   # expanded by the container's sh, on purpose
gone="$(compose exec -T kf2-server sh -c 'L=/app/lgsm/lock
  [ -f "$L/kf2server-started.lock" ] || exit 0
  for f in update updating kf2server-starting kf2server-stopping; do [ -f "$L/$f.lock" ] && exit 0; done
  pgrep -f "[K]FGameSteamServer.bin" >/dev/null && exit 0
  echo gone' 2>/dev/null)"
if [ "$gone" = gone ]; then
  lastc="$(cat "$STATE.crash" 2>/dev/null || echo 0)"
  case "$lastc" in ''|*[!0-9]*) lastc=0 ;; esac
  if [ $(( now - lastc )) -lt 3600 ]; then
    say "the game is gone from its running container again, within an hour of the last restart for that (at $(when "$lastc")): not restarting it again inside that hour. docker compose -p $PROJECT logs --tail 200 kf2-server" >&2
    exit 1
  fi
  restart "the game was gone from its running container (LinuxGSM started it, nothing stopped it: a crash), and the health check cannot bring it back" || exit 1
  $DRY || echo "$now" >"$STATE.crash"
  exit 0
fi

# ------------------------------------------------------------- Docker's restarts
for f in "$STATE.restarts" "$STATE.crashes"; do
  [ -L "$f" ] && { say "$f is a symlink; refusing to use it"; exit 1; }
done
if ! info=$(docker inspect "$id" --format '{{.Name}} {{.Id}} {{.RestartCount}} {{.State.FinishedAt}} {{.State.StartedAt}}' 2>/dev/null) || [ -z "$info" ]; then
  say "cannot read the restart count of kf2-server; nothing written"
  exit 1
fi
read -r rname rid rcount rfin rstart <<<"$info"
case ${rcount:-} in ''|*[!0-9]*) say "cannot read the restart count of kf2-server ($rcount); nothing written"; exit 1 ;; esac
bname=""; bid=""; bcount=""; bsince=""
read -r bname bid bcount bsince 2>/dev/null <"$STATE.restarts" || true
case ${bcount:-} in ''|*[!0-9]*) bcount="" ;; esac
case ${bsince:-} in ''|*[!0-9]*) bsince=$now ;; esac
if [ "$bname" = "$rname" ] && [ "$bid" = "$rid" ] && [ -n "$bcount" ] && [ "$rcount" -gt "$bcount" ]; then
  more=$(( rcount - bcount ))
  # WHY, when it can tell, from Docker's events, read from a minute before
  # the last run to two seconds from now: an "until" of this very second
  # missed a die of this very second (measured), a moment ahead waits for it.
  ev=$(docker events --since $(( bsince - 60 )) --until $(( $(date +%s) + 2 )) --filter "container=$rid" --filter event=die --filter event=oom \
    --format '{{.Action}} {{index .Actor.Attributes "exitCode"}}' 2>/dev/null)
  rexit=$(awk '$1 == "die" { c = $2 } END { print c }' <<<"$ev")
  case "$rexit" in
    134) rexit="134 (SIGABRT)" ;; 137) rexit="137 (SIGKILL)" ;; 139) rexit="139 (SIGSEGV)" ;; 143) rexit="143 (SIGTERM)" ;;
  esac
  why=""
  if grep -q '^oom' <<<"$ev"; then
    why="killed for memory (oom event, exit ${rexit:-?})"
  else
    # The last crash line before Docker started it again; anything 24
    # characters or longer is masked.
    why=$(docker logs --until "$rstart" --tail 400 "$rid" 2>&1 | grep -a -i -E 'fatal|segmentation|core dumped|panic|abort' | tail -1 \
      | sed -E 's/[A-Za-z0-9+\/=_-]{24,}/<masked>/g' | tr -d '\r' | cut -c1-200)
    [ -n "$why" ] && why="its log before that: $why"
  fi
  crashed="the server restarted $more time$( [ "$more" = 1 ] || echo s) since $(when "$bsince"), last exit code ${rexit:-?}, last finished ${rfin:-?}${why:+; $why}"
  before=0
  [ -f "$STATE.crashes" ] && before=$(awk -v t=$(( now - 86400 )) '$1 > t { n += $2 } END { print n + 0 }' "$STATE.crashes")
  recent=$(( before + more ))
  if ! $DRY; then
    echo "$now $more" >>"$STATE.crashes"
    echo "$rname $rid $rcount $now" >"$STATE.restarts"
  fi
  say "$crashed ($recent in 24 h)"
  [ "$recent" -ge 3 ] && exit 1
elif [ "$bname" != "$rname" ] || [ "$bid" != "$rid" ] || [ -z "$bcount" ] || [ "$rcount" -lt "$bcount" ]; then
  $DRY || echo "$rname $rid $rcount $now" >"$STATE.restarts"
fi

# The last thing the server told matchmaking. It is logged when it changes,
# so the newest line is the current value however long ago it was written.
if [ -n "${KF2_TAKEOVER+x}" ]; then takeable=$KF2_TAKEOVER; else
  takeable="$(compose exec -T kf2-server sh -c "grep -a 'Advertising: bAvailableForTakeover=' $LAUNCH | tail -1" 2>/dev/null \
              | grep -oE '(True|False)' | tail -1)"
fi

# The removed uptime rule's clock, left by v1.4 and before.
rm -f "$STATE.uptime"

if [ "$takeable" = False ]; then
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
if [ -n "$takeable" ]; then say "open to takeover: nothing to do"; else say "no takeover advertisement in the log yet: nothing to do"; fi
exit
}
