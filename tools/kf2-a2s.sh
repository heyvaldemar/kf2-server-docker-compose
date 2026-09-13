#!/bin/bash
# kf2-a2s.sh - ask the running Killing Floor 2 server about itself, over A2S,
# from inside its own container.
#
#   tools/kf2-a2s.sh players   the number of people on, or NOTHING when the
#                              server did not answer
#   tools/kf2-a2s.sh info      name, map, players, max, visibility (tab-separated)
#   tools/kf2-a2s.sh who       who is on: name, score, minutes, one per line
#
# ONE PROBE, ASKED ONE WAY. Two scripts here decide whether a restart would
# throw somebody out of a game: kf2-ban.sh when a ban is asked for, and
# kf2-ban-queue.sh every five minutes after that. If each carried its own copy
# of the question they could disagree about what "empty" means, and the copy
# that was wrong would be the one that restarts. So there is one copy, and
# both of them call it.
#
# FROM INSIDE THE CONTAINER, so 127.0.0.1 and the query port are the server
# itself whatever the network looks like outside: published on the host,
# behind a WireGuard relay, or on a bridge nobody has mapped. python3 is in
# the LinuxGSM image because LinuxGSM itself depends on it, and
# tests/e2e-moderation.sh runs against the pinned image, so a rebuild that
# dropped it would fail CI before it reached anyone.
#
# NO ANSWER IS NOT AN EMPTY SERVER. `players` prints nothing at all when the
# query goes unanswered, and every caller treats nothing and zero as different
# things. A server that has stopped replying is exactly when a restart is
# least welcome, and a caller that read silence as zero would restart it
# blind.
#
# NAMES ONLY. A2S does not carry Steam ids, and without WebAdmin there is no
# other live roster, so `who` cannot hand you the id a ban needs. That comes
# from the chat log the server writes (see README: "Where the id comes from").
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

COMPOSE_FILE=${KF2_COMPOSE_FILE:-kf2-server-docker-compose.yml}
PROJECT=${COMPOSE_PROJECT_NAME:-kf2}
# The port the server BINDS, from the file the server reads it from. The same
# number is published in .env, but it is this one the game listens on.
PORT=${KF2_QUERY_PORT:-$(sed -n 's/^queryport="\{0,1\}\([0-9]*\).*/\1/p' config/kf2server.cfg | tail -1)}
PORT=${PORT:-27015}

compose() { docker compose -f "$COMPOSE_FILE" -p "$PROJECT" "$@"; }

# Runs a python program from stdin inside the game container. Fails, quietly,
# when there is no running container: that is one of the "did not answer"
# cases and the caller decides what silence means.
in_server() { compose exec -T kf2-server python3 - "$@" 2>/dev/null; }

case "${1:-}" in
  players)
    in_server "$PORT" <<'PY'
import socket, sys
port = int(sys.argv[1])
q = b"\xff\xff\xff\xffTSource Engine Query\x00"
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(4)
    s.sendto(q, ("127.0.0.1", port)); d = s.recvfrom(4096)[0]
    if d[4:5] == b"A":                       # a challenge: ask again, carrying it
        s.sendto(q + d[5:9], ("127.0.0.1", port)); d = s.recvfrom(4096)[0]
    if d[4:5] != b"I":
        raise SystemExit
    b = d[6:]
    for _ in range(4):                       # name, map, folder, game
        b = b[b.index(b"\x00") + 1:]
    print(b[2])                              # after the 16-bit app id
except Exception:
    pass                                     # nothing printed: unanswered
PY
    exit 0 ;;
  info)
    out=$(in_server "$PORT" <<'PY'
import socket, sys
port = int(sys.argv[1])
q = b"\xff\xff\xff\xffTSource Engine Query\x00"
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(4)
    s.sendto(q, ("127.0.0.1", port)); d = s.recvfrom(4096)[0]
    if d[4:5] == b"A":
        s.sendto(q + d[5:9], ("127.0.0.1", port)); d = s.recvfrom(4096)[0]
    if d[4:5] != b"I":
        raise SystemExit
    b = d[6:]; p = b.split(b"\x00", 4)
    rest = p[4]
    # Tab-separated: a server's own name can carry a pipe, and a record split
    # on pipes then prints the map where the name belongs.
    print("%s\t%s\t%d\t%d\t%s" % (p[0].decode("utf-8", "ignore"), p[1].decode("utf-8", "ignore"),
                                  rest[2], rest[3], "password" if rest[7] else "open"))
except Exception:
    pass
PY
    )
    if [ -z "$out" ]; then
      echo "the server is not answering on 127.0.0.1:$PORT inside the container: it may be starting, installing, or down" >&2
      exit 1
    fi
    printf '%s\n' "$out" ;;
  who)
    out=$(in_server "$PORT" <<'PY'
import socket, struct, sys
port = int(sys.argv[1])
q = b"\xff\xff\xff\xffU\xff\xff\xff\xff"
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(4)
    s.sendto(q, ("127.0.0.1", port)); d = s.recvfrom(8192)[0]
    if d[4:5] == b"A":
        s.sendto(b"\xff\xff\xff\xffU" + d[5:9], ("127.0.0.1", port)); d = s.recvfrom(8192)[0]
    if d[4:5] != b"D":
        raise SystemExit
    n, b = d[5], d[6:]
    print("answered")
    for _ in range(n):
        b = b[1:]                            # index byte
        j = b.index(b"\x00"); name = b[:j].decode("utf-8", "replace"); b = b[j + 1:]
        score, secs = struct.unpack_from("<if", b, 0); b = b[8:]
        print("%s\t%d\t%d" % (name, score, int(secs // 60)))
except Exception:
    pass
PY
    )
    if [ -z "$out" ]; then
      echo "the server is not answering on 127.0.0.1:$PORT inside the container: it may be starting, installing, or down" >&2
      exit 1
    fi
    roster=$(printf '%s\n' "$out" | sed 1d)
    if [ -z "$roster" ]; then echo "nobody is on"; else printf '%s\n' "$roster"; fi ;;
  *)
    sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
