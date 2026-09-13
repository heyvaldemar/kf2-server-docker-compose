#!/bin/bash
# kf2-ban.sh - ban and unban on Killing Floor 2 without rcon and without
# WebAdmin, and never at the cost of somebody else's round.
#
#   tools/kf2-ban.sh list                        who is banned, as Steam community ids
#   tools/kf2-ban.sh add <steam community id>    ban; queued if anyone is playing
#   tools/kf2-ban.sh remove <steam community id> unban; refused if anyone is playing
#   tools/kf2-ban.sh queue                       the bans waiting for an empty server
#
# Either form of the id is accepted: 76561198042335367, or 0x0110000104E44887
# as the server's own chat log writes it. --force after the id applies at once
# whoever is on.
#
# WHERE A BAN LIVES. One line per banned player under [Engine.AccessControl] in
# LinuxServer-KFGame.ini, with the 64-bit id split into its two 32-bit halves:
#     BannedIDs=(Uid=(A=<low 32 bits>,B=<high 32 bits>))
# 76561198042335367 is A=82069639, B=17825793. B is 17825793 for every player
# account there is, which is how a number that is not a player id gets refused
# here rather than written into a list it would never match.
#
# THE FILE IS ONLY SAFE TO TOUCH WHILE THE SERVER IS STOPPED. The engine
# rewrites this ini on the way out, so an edit made while it runs is thrown
# away at the next stop, silently, which is the worst way to lose a ban. So a
# ban is stop, edit, start.
#
# AND READ BACK FROM THE FILE THE SERVER REWROTE. It rewrites the ini again as
# it starts, so anything it did not accept is gone by the time it answers a
# query. That is the only proof there is, and it cannot be had before the
# restart. Success here means the id was found in the list afterwards, never
# that the edit returned zero.
#
# A BAN DOES NOT KICK. It is checked when somebody connects; a person already
# on the server stays until they leave. There is no kick on this engine at all
# without WebAdmin, and this script does not pretend otherwise.
#
# QUEUED, NOT DROPPED. Applying a ban means a restart, and a restart ends the
# round for everyone playing, for a ban that only bites on the next connection
# anyway. The first version of this refused while anyone was on and told the
# moderator to come back later; twice in three days nobody did, and the person
# who had earned the ban kept their place. Both times they had already left,
# which is the normal case. So the ban is written down instead, and
# kf2-ban-queue.sh applies it the moment the server is empty.
#
# NOT PROVEN EMPTY IS NOT EMPTY. An unanswered query, or a container still in
# its start period, queues the ban too. Silence is when a restart is least
# welcome, and a server that is mid-install is not one to restart on a guess.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

COMPOSE_FILE=${KF2_COMPOSE_FILE:-kf2-server-docker-compose.yml}
PROJECT=${COMPOSE_PROJECT_NAME:-kf2}
INI=${KF2_BAN_INI:-/data/serverfiles/KFGame/Config/kf2server/LinuxServer-KFGame.ini}
QUEUE=${KF2_BAN_QUEUE:-.kf2-ban-queue}
A2S=tools/kf2-a2s.sh
# How long a restarted server gets to answer before the read-back is declared
# unproven. A warm start takes about a minute; a server that also has a Steam
# update to apply can take longer.
WAIT=${KF2_BAN_WAIT:-300}

env_get() { sed -n "s/^$1=//p" .env 2>/dev/null | tail -1; }
# The uid and gid the server runs as: .env if set there, the image's default
# otherwise. The edit is made as that user so the file stays the server's.
uid=${KF2_SERVER_UID:-$(env_get KF2_SERVER_UID)}; uid=${uid:-1000}
gid=${KF2_SERVER_GID:-$(env_get KF2_SERVER_GID)}; gid=${gid:-1000}
RUN_AS="$uid:$gid"

compose() { docker compose -f "$COMPOSE_FILE" -p "$PROJECT" "$@"; }

# "running healthy", "running starting", "exited none", or nothing at all
# when no container exists yet.
container_state() {
  local id
  id=$(compose ps -q kf2-server 2>/dev/null | head -1)
  [ -n "$id" ] || return 0
  docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id" 2>/dev/null
}

# A python program from stdin, run against the volume AS THE SERVER'S OWN
# USER in a one-off container from the same pinned image. The main container
# is stopped at that moment, so exec is not an option; and the edit lands with
# the uid the game runs as, so the game can rewrite the file afterwards. The
# container's own entrypoint chowns /data on every start as well, but an edit
# should not need repairing to begin with.
# Compose narrates container creation on stderr; that is kept for the failure
# case and dropped otherwise, because a moderator reading "banned" does not
# need three lines about a container being created and removed.
in_volume() {
  local err rc
  err=$(mktemp) || return 1
  compose run --rm --no-deps -T --user "$RUN_AS" --entrypoint python3 kf2-server - "$@" 2>"$err"
  rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || sed 's/^/  compose: /' "$err" >&2
  rm -f "$err"
  return "$rc"
}

# Reads the ban list wherever the file is: through the running container when
# there is one, through a one-off container when there is not.
ini_list() {
  local prog='
import re, sys
try:
    text = open(sys.argv[1], encoding="utf-8", errors="surrogateescape").read()
except FileNotFoundError:
    raise SystemExit(2)
for a, b in re.findall(r"BannedIDs=\(Uid=\(A=(-?\d+),B=(-?\d+)\)\)", text):
    print((int(b) << 32) | (int(a) & 0xFFFFFFFF))
'
  if [ "${1:-}" = "--running" ]; then
    printf '%s' "$prog" | compose exec -T kf2-server python3 - "$INI" 2>/dev/null
  else
    printf '%s' "$prog" | in_volume "$INI"
  fi
}

ini_edit() {   # add|remove <steamid64>
  in_volume "$INI" "$1" "$2" <<'PY'
import os, re, sys
path, action, sid = sys.argv[1], sys.argv[2], int(sys.argv[3])
a, b = sid & 0xFFFFFFFF, sid >> 32
# A is written the way the engine writes it: as a SIGNED 32-bit integer. The
# low half of a player id is the account number, and account numbers are past
# two billion, so the top bit of that half is about to matter. A positive
# number there is a form the engine's own parser was never handed before.
if a >= 2 ** 31:
    a -= 2 ** 32
want = "BannedIDs=(Uid=(A=%d,B=%d))" % (a, b)
try:
    # newline="" keeps the file's own line endings on the way in; the default
    # would quietly turn every CRLF into LF and the write below would keep it
    # that way, which is a change the engine never asked for.
    with open(path, encoding="utf-8", errors="surrogateescape", newline="") as f:
        text = f.read()
except FileNotFoundError:
    print("no server config at %s: the server has not finished its first install" % path)
    raise SystemExit(2)
# The line ending the file already uses, whichever it is; an engine that
# rewrites the file on every start is not one to hand a mixed file to.
nl = "\r\n" if "\r\n" in text else "\n"
lines = text.splitlines(True)
def ident(s):
    m = re.fullmatch(r"BannedIDs=\(Uid=\(A=(-?\d+),B=(-?\d+)\)\)", s)
    return ((int(m.group(2)) << 32) | (int(m.group(1)) & 0xFFFFFFFF)) if m else None
have = any(ident(l.rstrip("\r\n")) == sid for l in lines)
if action == "add" and have:
    print("already banned"); raise SystemExit(3)
if action == "remove" and not have:
    print("not in the ban list"); raise SystemExit(3)
out, sec, done = [], None, False
def insert_here():
    # At the end of the section but before the blank lines that separate it
    # from the next one, so the file keeps its shape.
    k = len(out)
    while k > 0 and out[k - 1].strip() == "":
        k -= 1
    if k > 0 and not out[k - 1].endswith(("\n", "\r\n")):
        out[k - 1] += nl
    out.insert(k, want + nl)
for l in lines:
    s = l.rstrip("\r\n")
    if s.startswith("["):
        if sec == "[Engine.AccessControl]" and action == "add" and not done:
            insert_here(); done = True
        sec = s
    if action == "remove" and ident(s) == sid:
        done = True
        continue
    out.append(l)
if sec == "[Engine.AccessControl]" and action == "add" and not done:
    insert_here(); done = True
if not done:
    print("could not find [Engine.AccessControl] in %s" % path); raise SystemExit(1)
tmp = path + ".kf2-ban.tmp"
with open(tmp, "w", encoding="utf-8", errors="surrogateescape", newline="") as f:
    f.write("".join(out))
os.replace(tmp, path)
print("A=%d B=%d" % (a, b))
PY
}

players() { "$A2S" players; }

dequeue() {   # drop an id from the queue file, if it is there
  [ -f "$QUEUE" ] || return 0
  grep -q "^$1 " "$QUEUE" || return 0
  local tmp; tmp=$(mktemp) || return 1
  grep -v "^$1 " "$QUEUE" > "$tmp"   # exit 1 here means the file is now empty, which is fine
  mv "$tmp" "$QUEUE"
}

case "${1:-}" in
  list)
    case "$(container_state)" in
      "running healthy"|"running unhealthy") ids=$(ini_list --running) ;;
      *) ids=$(ini_list) ;;
    esac
    rc=$?
    if [ "$rc" -eq 2 ]; then echo "no server config yet at $INI: the server has not finished its first install" >&2; exit 2; fi
    if [ "$rc" -ne 0 ]; then echo "could not read the ban list" >&2; exit "$rc"; fi
    if [ -z "$ids" ]; then echo "nobody is banned"; else printf '%s\n' "$ids"; fi
    exit 0 ;;
  queue)
    if [ -s "$QUEUE" ]; then
      now=$(date +%s)
      while read -r sid ts; do
        [ -n "${sid:-}" ] || continue
        echo "$sid  (waiting $(( (now - ${ts:-now}) / 60 )) min)"
      done < "$QUEUE"
    else
      echo "nothing is queued"
    fi
    exit 0 ;;
  add|remove) ;;
  *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

ACTION=$1
SID=${2:-}
FORCE=0
[ "${3:-}" = "--force" ] && FORCE=1
case "$SID" in
  0x*|0X*)
    hex=${SID#0[xX]}
    case "$hex" in ''|*[!0-9A-Fa-f]*) echo "not a Steam community id: $SID" >&2; exit 1 ;; esac
    [ "${#hex}" -le 16 ] || { echo "not a Steam community id: $SID" >&2; exit 1; }
    SID=$((16#$hex)) ;;
esac
case "$SID" in ''|*[!0-9]*) echo "not a Steam community id: ${2:-}" >&2; exit 1 ;; esac
[ "${#SID}" -le 19 ] || { echo "not a Steam community id: $SID" >&2; exit 1; }
# Universe 1, type 1 (an individual account), instance 1: the high half of
# every player id. Anything else the ban list would accept and never match.
if [ $((SID >> 32)) -ne 17825793 ]; then
  echo "$SID is not the id of a player account (its high 32 bits are $((SID >> 32)), a player's are 17825793)" >&2
  echo "the ban list would take it and it would never match anyone, so it was not written" >&2
  exit 1
fi

state=$(container_state)
n=$(players)
apply=0; why=""
if [ "$FORCE" = 1 ]; then
  apply=1
elif [ "${state%% *}" != "running" ]; then
  apply=1; why="not running"
elif [ "$n" = "0" ] && [ "${state#* }" != "starting" ]; then
  apply=1
elif [ -z "$n" ] || [ "${state#* }" = "starting" ]; then
  why="not answering"
else
  why="$n player(s) are on"
fi

if [ "$apply" != 1 ]; then
  if [ "$ACTION" = add ]; then
    touch "$QUEUE" || exit 1
    if grep -q "^$SID " "$QUEUE"; then
      echo "already queued: $SID, it will be banned when the server empties"
    else
      printf '%s %s\n' "$SID" "$(date +%s)" >> "$QUEUE"
      if [ "$why" = "not answering" ]; then
        echo "queued: $SID, the server is not answering (starting, installing, or down), so it is not proven empty; it will be banned when it is"
      else
        echo "queued: $SID, $why, so it will be banned when the server empties"
      fi
    fi
    exit 0
  fi
  if [ "$why" = "not answering" ]; then
    echo "the server is not answering, so it is not proven empty. Lifting a ban needs a" >&2
  else
    echo "$why. Lifting a ban needs a restart and that ends their round. Run again with" >&2
  fi
  echo "--force, or wait until the server is empty." >&2
  exit 1
fi

was_running=0
[ "${state%% *}" = "running" ] && was_running=1

# NOTHING TO CHANGE MEANS NO RESTART. The editor refuses a ban that is already
# in the file and an unban of an id that is not, but by then the server would
# already be stopped for it. Reading the list first costs one query and
# spares everyone a restart that changes nothing.
if [ "$was_running" = 1 ]; then current=$(ini_list --running); else current=$(ini_list); fi
rc=$?
if [ "$rc" -eq 2 ]; then echo "no server config yet at $INI: the server has not finished its first install" >&2; exit 2; fi
if [ "$rc" -eq 0 ]; then
  if [ "$ACTION" = add ] && printf '%s\n' "$current" | grep -qx "$SID"; then dequeue "$SID"; echo "already banned"; exit 3; fi
  if [ "$ACTION" = remove ] && ! printf '%s\n' "$current" | grep -qx "$SID"; then echo "not in the ban list"; exit 3; fi
fi

if [ "$was_running" = 1 ]; then
  compose stop kf2-server >/dev/null 2>&1 || { echo "could not stop the server; nothing was changed" >&2; exit 1; }
fi
out=$(ini_edit "$ACTION" "$SID"); rc=$?
if [ "$rc" -ne 0 ]; then
  printf '%s\n' "$out"
  [ "$rc" -eq 3 ] && [ "$ACTION" = add ] && dequeue "$SID"
  [ "$was_running" = 1 ] && compose start kf2-server >/dev/null 2>&1
  exit "$rc"
fi
if [ "$was_running" != 1 ] && [ "$FORCE" != 1 ]; then
  # Written, not proven: the proof is the file the server rewrites at
  # startup, and starting a server the operator stopped is not this
  # script's call to make.
  echo "written ($out); the server is not running, so it has not read the file yet. It will at its next start; check with: tools/kf2-ban.sh list"
  [ "$ACTION" = add ] && dequeue "$SID"
  exit 0
fi
compose start kf2-server >/dev/null 2>&1 || { echo "the edit is in the file but the server did not start; check: docker compose -p $PROJECT logs kf2-server" >&2; exit 1; }

# Wait for the server to answer, then read the file it rewrote on the way up.
answered=0
end=$(( $(date +%s) + WAIT ))
while [ "$(date +%s)" -lt "$end" ]; do
  sleep 5
  [ -n "$(players)" ] && { answered=1; break; }
done
if [ "$answered" != 1 ]; then
  echo "the server has not answered within ${WAIT}s after the restart; the edit is in the file but not yet proven. Check later with: tools/kf2-ban.sh list" >&2
  exit 4
fi
if ini_list --running | grep -qx "$SID"; then
  if [ "$ACTION" = add ]; then dequeue "$SID"; echo "banned $SID"; exit 0; fi
  echo "STILL BANNED after remove: the server kept $SID" >&2; exit 1
else
  if [ "$ACTION" = remove ]; then echo "unbanned $SID"; exit 0; fi
  echo "NOT BANNED after add: the server dropped $SID when it rewrote its config" >&2; exit 1
fi
