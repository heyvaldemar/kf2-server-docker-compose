# port-owner.sh <port>: run inside the server's container (sh -s). Prints the
# pid and comm of the process that owns the UDP socket bound to <port>: the
# process that answers the query, which is the one the SIGSTOP plant stops.
# A name match is not enough: LinuxGSM's tmux carries the game's name in its
# command line, and stopping it stops nothing that answers.
h=$(printf '%04X' "$1")
ino=$(awk -v h=":$h" '$2 ~ (h "$") { print $10; exit }' /proc/net/udp)
[ -n "$ino" ] || { echo "nothing is bound to UDP $1" >&2; exit 1; }
for d in /proc/[0-9]*; do
  for f in "$d"/fd/*; do
    if [ "$(readlink "$f" 2>/dev/null)" = "socket:[$ino]" ]; then
      echo "${d#/proc/} $(cat "$d/comm" 2>/dev/null)"
      exit 0
    fi
  done
done
echo "no process this user can see owns UDP $1 (socket inode $ino)" >&2
exit 1
