#!/bin/bash
# start.sh - the image's own entrypoint, with no password in `docker compose logs`.
#
# LinuxGSM's `details`, which the image runs after every start, prints the
# passwords it finds in the server's ini in clear: "Server password:" from
# GamePassword, "Admin password:" and "Web Interface password:" from
# AdminPassword. This template leaves both empty, but a server for a group of
# friends often has a join password, and logs get pasted into issues. So
# everything the image prints passes through a filter on its way to Docker's
# log: on a line whose label says "pass", in any case ("Server password:"),
# the value is masked, and so is the value of any setting whose name says it
# ("GamePassword=..."). An empty value and LinuxGSM's "NOT SET" stay as they
# are, so the log still tells whether a password is set.
#
# PROCESS 1 STAYS THIS SCRIPT. The image's entrypoint runs as its child, so
# that its output can pass the filter; the kernel kills everything left in a
# container the moment process 1 exits, so it has to be this script, which
# waits for the last lines. Docker's SIGTERM (and INT and QUIT) is handed to
# the entrypoint, which answers it as it always has, by running LinuxGSM's
# `stop`. When that is done, the image's tail of the log files, which nothing
# else ends, is stopped, the filter is given the last lines, and this exits
# with the entrypoint's status.
#
# Read whole before it runs: one brace group, ending in exit
# (tools/kf2-idle-reset.sh, "READ WHOLE BEFORE IT RUNS", says why).
{
set -u
filter() {
  exec sed -u -E \
    -e '/^[^:=]*pass[^:=]*:[[:space:]]*(NOT SET)?[[:space:]]*$/Ib' \
    -e 's/^([^:=]*pass[^:=]*:[[:space:]]*)[^[:space:]].*$/\1********/I' \
    -e 's/(pass[a-z_]*[[:space:]]*=[[:space:]]*"?)[^[:space:]"?&]+/\1********/Ig'
}
exec 4> >(filter)
fpid=$!
# The entrypoint, as its own process: bash starts a background job with INT
# and QUIT ignored, and the image's handler for them needs them back.
( trap - INT QUIT; exec /bin/bash /app/entrypoint.sh "$@" ) >&4 2>&1 4>&- &
child=$!
exec 4>&-
trap 'kill -TERM "$child" 2>/dev/null' TERM
trap 'kill -INT "$child" 2>/dev/null' INT
trap 'kill -QUIT "$child" 2>/dev/null' QUIT
while kill -0 "$child" 2>/dev/null; do wait "$child"; done
wait "$child"; rc=$?
# What still holds the filter's pipe: the image's tail of the log files and
# the shell that waits for it. The server itself is stopped by now.
for p in /proc/[0-9]*; do
  p=${p#/proc/}
  [ "$p" = "$$" ] || [ "$p" = "$fpid" ] || kill -KILL "$p" 2>/dev/null
done
for _ in $(seq 1 50); do kill -0 "$fpid" 2>/dev/null || break; sleep 0.1; done
exit "$rc"
}
