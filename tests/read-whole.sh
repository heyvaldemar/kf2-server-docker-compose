#!/bin/bash
# Every script in tools/ is read whole before it runs, and that is what keeps
# a run alive through an edit of its own file.
#
# bash reads a script as it executes it: after each command it reads on from
# the same byte offset, in whatever the file holds by then. Timers start
# tools/kf2-idle-reset.sh and tools/kf2-ban-queue.sh every five minutes, and
# the queue runs tools/kf2-ban.sh for a minute or more. On the server this
# template comes from, a timer started a script while its file was being
# edited in place: a syntax error and a failed unit. So each script's body is
# one brace group, which bash parses in full before the first line runs,
# ending in exit.
#
#   the shape    every tools/*.sh: the line after its header comment is "{",
#                its last line "}", the line before that an exit
#   both ways    a copy of the idle reset, paused inside its first docker call
#                while its own file is rewritten in place with "exit 9" at
#                the offset bash would read next: wrapped, it finishes as if
#                nothing happened; unwrapped, it runs the new text
# shellcheck disable=SC2015   # pass and fail always exit 0, so "A && pass || fail" is if-then-else here
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASSED=0; FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

echo "=== the shape ==="
echo
for f in tools/*.sh; do
  first="$(awk 'NR > 1 && !/^#/ {print; exit}' "$f")"
  last="$(tail -1 "$f")"
  before="$(tail -2 "$f" | head -1)"
  if [ "$first" = "{" ] && [ "$last" = "}" ] && [[ $before == exit* ]] && bash -n "$f"; then
    pass "$f: one brace group, ending in \"$before\""
  else
    fail "$f: first command line \"$first\", ends \"$before\" / \"$last\""
  fi
done

echo
echo "=== both ways: the idle reset's own file rewritten under a running copy ==="
echo
# A copy of the script, a docker that takes two seconds to say a container is
# running, and the takeover flag supplied, so the run ends in "nothing to do".
mkdir -p "$T/tools" "$T/bin"
printf '#!/bin/sh\nsleep 2\necho 0123456789ab\n' >"$T/bin/docker"
cp tools/kf2-idle-reset.sh "$T/tools/wrapped.sh"
# The same script without its braces: what every script here was before.
awk -v n="$(wc -l <tools/kf2-idle-reset.sh)" 'NR == n { next } !done && $0 == "{" { done = 1; next } { print }' tools/kf2-idle-reset.sh >"$T/tools/unwrapped.sh"
chmod +x "$T/bin/docker" "$T/tools/wrapped.sh" "$T/tools/unwrapped.sh"
grep -qx '{' "$T/tools/unwrapped.sh" && fail "the unwrapped copy still has its brace" || true

rewritten() {  # script: run it, and rewrite its file in place while it waits
  local f="$T/tools/$1" off
  # Just past the line that asks docker: where bash reads next.
  off="$(LC_ALL=C awk '{ off += length($0) + 1 } /^id="\$\(compose ps/ { print off; exit }' "$f")"
  PATH="$T/bin:$PATH" KF2_TAKEOVER=True KF2_IDLE_RESET_STATE="$T/state" bash "$f" >"$T/out" 2>&1 &
  local pid=$!
  sleep 1
  { head -c "$off" "$f"; echo 'echo "INJECTED: read from the file after it started"; exit 9'; tail -c +"$(( off + 1 ))" "$f"; } >"$T/new"
  cat "$T/new" >"$f"   # in place: same file, same inode, as an editor that saves in place
  wait "$pid"
}

rewritten wrapped.sh; rc=$?
out="$(cat "$T/out")"
[ "$rc" = 0 ] && grep -q "open to takeover: nothing to do" <<<"$out" && ! grep -q INJECTED <<<"$out" \
  && pass "wrapped: rewritten mid-run, it ran the text it started with and exited 0 (${out#* * })" \
  || fail "wrapped: exit $rc, $out"
rewritten unwrapped.sh; rc=$?
out="$(cat "$T/out")"
[ "$rc" = 9 ] && grep -q INJECTED <<<"$out" \
  && pass "unwrapped: the same rewrite, and it ran the new text, exit 9: what the braces prevent" \
  || fail "unwrapped: exit $rc, $out (the fault this guards against did not happen)"

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
