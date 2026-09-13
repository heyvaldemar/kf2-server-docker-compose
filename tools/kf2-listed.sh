#!/bin/bash
# kf2-listed.sh - can a player actually FIND this server? Ask Steam, not the
# server.
#
#   tools/kf2-listed.sh <public address> [query port]
#   exit 0: listed   1: not listed   2: Steam did not answer, which says nothing
#
# WHY THIS IS NOT ANOTHER A2S CHECK. Everything else here asks the server
# about itself: the health check asks the container, kf2-a2s.sh asks the
# game. All of it can be green while the thing that matters is broken,
# because a player does not query your server. They look at a list Steam
# keeps, and a server missing from that list may as well be switched off. On
# the machine this template comes from, Killing Floor 2 spent nineteen hours
# in exactly that state: container running, process alive, health check
# green, A2S answering every probe, and one player joined where the same
# window normally brings a hundred and thirty.
#
# TWO SIGNALS THAT LOOKED EXACT AND WERE NOT. The first fix watched the A2S
# "password protected" flag, on the theory that the flag hid the server. It
# fired three times in one afternoon while five people were playing through
# it: the engine raises that flag within seconds of nearly every start and
# goes on taking players. The second watched how long since the server last
# re-published itself to Steam, 1369 minutes in the broken run against a
# couple in a healthy one. It restarted the server three times in one night
# while Steam, asked directly forty-eight times over the same hours, listed
# the server every time: an idle server stops re-publishing because nothing
# about it has changed. Whether players can find a server is a question only
# Steam can answer, so this asks Steam.
#
# ISteamApps/GetServersAtAddress needs no API key and answers for one address,
# which is what a home server behind one relay has.
#
# LOOK, THEN DECIDE. Steam drops a server from the list for a minute or two
# after any restart, including the one kf2-ban.sh does, so one miss means
# nothing and this script restarts nothing. The nineteen-hour outage would
# have shown as miss after miss after miss; anything automated on top of this
# should wait for several in a row and cap how often it may react. Both CS2
# servers on that machine flapped in and out of Steam's list three times in
# an hour once, answering every query throughout, and each restart that
# followed fixed nothing that was not fixing itself.
set -uo pipefail

ADDR=${1:-}; PORT=${2:-}
[ -n "$ADDR" ] || { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
API=${KF2_STEAM_API_URL:-"https://api.steampowered.com/ISteamApps/GetServersAtAddress/v1/?addr=$ADDR"}

body=$(curl -sS --max-time 25 "$API" 2>/dev/null) || body=""

# A BROKEN ANSWER AND AN EMPTY ONE MUST NOT LOOK THE SAME. Steam answers with
# no "servers" key at all when it knows nothing about the address, which is a
# real and alarming answer; a truncated or non-JSON body is not an answer.
case "$body" in
  *'"response"'*) ;;
  *) echo "Steam did not answer, or did not answer with its list; this says nothing about the server" >&2; exit 2 ;;
esac

# addr is "<ip>:<query port>" per listed server; gamedir names the game.
# Separate -e expressions, because BSD sed reads everything after `t` as the
# label; GNU sed and macOS then agree on the same file.
listed=$(printf '%s' "$body" | tr -d '\n' | grep -oE '\{[^{}]*"addr":"[^"]+"[^{}]*\}' \
         | sed -E -e 's/.*"addr":"([^"]+)".*"gamedir":"([^"]*)".*/\1 \2/' -e 't' -e 's/.*"addr":"([^"]+)".*/\1 ?/')

if [ -z "$listed" ]; then
  echo "not listed: Steam knows no server at $ADDR"
  exit 1
fi
if [ -n "$PORT" ]; then
  if printf '%s\n' "$listed" | grep -q "^$ADDR:$PORT "; then
    echo "listed: $ADDR:$PORT ($(printf '%s\n' "$listed" | grep "^$ADDR:$PORT " | cut -d' ' -f2))"
    exit 0
  fi
  echo "not listed: Steam lists $(printf '%s\n' "$listed" | wc -l | tr -d ' ') server(s) at $ADDR, none on query port $PORT:"
  printf '%s\n' "$listed" | sed 's/^/  /'
  exit 1
fi
echo "listed at $ADDR:"
printf '%s\n' "$listed" | sed 's/^/  /'
exit 0
