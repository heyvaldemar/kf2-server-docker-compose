#!/bin/bash
# kf2-ban-queue.sh - apply the Killing Floor 2 bans that could not be applied
# when they were asked for.
#
#   tools/kf2-ban-queue.sh             apply what is due, say what was applied
#   tools/kf2-ban-queue.sh --dry-run   say what it would do, change nothing
#
# Run it every five minutes: systemd/kf2-ban-queue.timer, or one crontab line
# (README, "Moderation without rcon"). Nothing queued is the normal case and is
# silent, so the timer's journal stays empty until there is news.
#
# WHY THIS EXISTS. Killing Floor 2 has no rcon and no usable WebAdmin, so the
# only way to ban somebody is to edit an ini the server rewrites at startup,
# which means a restart, which ends the round for everyone currently playing.
# kf2-ban.sh therefore does not apply a ban while people are on, and the first
# version of it left things there: the moderator was told to come back later,
# and twice in three days nobody did. The person who had earned the ban kept
# their place because banning them would have cost a bystander their game.
#
# That trade was never necessary. A Killing Floor ban does not remove anyone
# already connected, it bites on the NEXT connection, and by the time a human
# reads the report the offender has usually left. Waiting for an empty server
# costs almost nothing; ending a stranger's round buys almost nothing. So the
# ban is written down, and this applies it the moment the server is empty.
#
# THE SAME QUESTION kf2-ban.sh ASKS, through the same file (tools/kf2-a2s.sh),
# so the two cannot disagree about what "empty" means. And an UNANSWERED QUERY
# IS NOT AN EMPTY SERVER: a server that has stopped replying is exactly when a
# restart is least welcome, so silence leaves everything queued.
#
# ONE RESTART PER BAN, on purpose. kf2-ban.sh owns the whole stop, edit, start,
# read-back sequence, including the part that proves the server kept the id;
# saving a restart on an empty server by splitting that apart would mean two
# files that both know the ini format.
#
# A BAN THAT FAILS STAYS QUEUED. A ban nobody is coming back to do by hand is
# the whole reason this file exists, so it is tried again five minutes later
# rather than dropped, and the failure is said out loud every time, with a
# non-zero exit so the timer shows it.
#
# NEWS GOES WHERE THE REQUEST CAME FROM. With KF2_MODERATION_WEBHOOK set in
# .env (a Mattermost or Slack incoming webhook), each applied or failed ban is
# posted there. The first version announced applied bans in the host's health
# feed, next to disk temperatures, while the request sat in the moderation
# channel with nobody told what became of it. A moderator should not have to
# read a host log to learn whether the thing they asked for happened. And a
# webhook that fails is said on stderr and fails this run: "delivered" is a
# claim too, and `curl -s` without checking the status code makes it for you.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

QUEUE=${KF2_BAN_QUEUE:-.kf2-ban-queue}
BAN=tools/kf2-ban.sh
A2S=tools/kf2-a2s.sh
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

[ -s "$QUEUE" ] || exit 0

# ONE AT A TIME. The timer will not overlap itself, but a hand run while the
# timer's is in flight would, and both rewrite the queue.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$QUEUE.lock" || exit 1
  flock -n 9 || { echo "another run holds the lock, skipping"; exit 0; }
fi

env_get() { sed -n "s/^$1=//p" .env 2>/dev/null | tail -1; }
# From the environment when it is set there, even to nothing: the test suite
# runs this against a stand-in server and must never reach a real channel.
if [ -n "${KF2_MODERATION_WEBHOOK+x}" ]; then HOOK=$KF2_MODERATION_WEBHOOK; else HOOK=$(env_get KF2_MODERATION_WEBHOOK); fi

# Escapes a string for a JSON literal: backslash, quote, newline. The messages
# here are ids, minutes and one line of a script's output; nothing else.
json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }'; }

notify() {   # title body -> 0 delivered, 1 not delivered (and says so)
  [ -n "$HOOK" ] || return 0
  local payload code
  payload=$(printf '{"text": "**%s**\\n%s"}' "$(json_escape "$1")" "$(json_escape "$2")")
  code=$(curl -sS --max-time 25 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d "$payload" "$HOOK" 2>/dev/null)
  case "$code" in 200|201|204) return 0 ;; esac
  echo "notify FAILED: HTTP ${code:-000} from the moderation webhook; the news above was not delivered" >&2
  return 1
}

n=$("$A2S" players)
queued=$(grep -c . "$QUEUE")
case "$n" in
  '') echo "the server did not answer, so it is not proven empty: $queued ban(s) stay queued"; exit 0 ;;
  *[!0-9]*) echo "unexpected answer from the probe: '$n'; $queued ban(s) stay queued" >&2; exit 1 ;;
esac
if [ "$n" -gt 0 ]; then
  echo "$n player(s) on: $queued ban(s) stay queued"
  exit 0
fi

# A restart that never comes back would otherwise hold this run, and the lock
# with it, for good. coreutils' timeout is on every Linux host; without it the
# systemd unit's TimeoutStartSec is the bound.
T=""
command -v timeout >/dev/null 2>&1 && T="timeout 900"

applied=""; failed=""
while read -r sid ts; do
  [ -n "${sid:-}" ] || continue
  waited=$(( ( $(date +%s) - ${ts:-0} ) / 60 ))
  if [ "$DRY_RUN" = 1 ]; then
    echo "DRY_RUN: would ban $sid (queued ${waited} min ago)"
    continue
  fi
  # shellcheck disable=SC2086   # $T is either empty or "timeout 900", by design
  out=$($T "$BAN" add "$sid" 2>&1); rc=$?
  # Success is the id read back out of the rewritten file ("banned <id>"), or
  # a ban somebody applied by hand in the meantime ("already banned").
  if printf '%s\n' "$out" | grep -qx "banned $sid" || { [ "$rc" -eq 3 ] && printf '%s\n' "$out" | grep -qx "already banned"; }; then
    applied="$applied$sid (waited ${waited} min)"$'\n'
  else
    failed="$failed$sid: $(printf '%s\n' "$out" | tail -1)"$'\n'
  fi
done < "$QUEUE"

[ "$DRY_RUN" = 1 ] && exit 0

status=0
if [ -n "$applied" ]; then
  # Rewrite the queue with only what did not get applied. kf2-ban.sh drops an
  # id it has proven on its own; this is the same rule applied once more from
  # this side, so a queue never carries a ban that is already in the file.
  tmp=$(mktemp)
  while read -r sid ts; do
    [ -n "${sid:-}" ] || continue
    printf '%s' "$applied" | grep -q "^$sid " || printf '%s %s\n' "$sid" "$ts" >> "$tmp"
  done < "$QUEUE"
  mv "$tmp" "$QUEUE"
  echo "applied:"; printf '%s' "$applied"
  notify "Queued Killing Floor 2 ban(s) applied" "The server emptied, so the ban(s) asked for earlier went in and were read back out of the file the server rewrote at startup:
$(printf '%s' "$applied")
Nobody was playing, so nothing was interrupted." || status=1
fi
if [ -n "$failed" ]; then
  echo "failed, still queued:"; printf '%s' "$failed"
  notify "A queued Killing Floor 2 ban did not apply" "The server was empty and the ban was attempted anyway:
$(printf '%s' "$failed")
It stays queued and will be tried again in five minutes." || true
  status=1
fi
exit "$status"
