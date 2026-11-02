#!/bin/bash
# tools/kf2-a2s.sh never passes Docker's own failure off as the server's answer.
#
# When an exec fails, Docker can print its error where the program's output
# goes. Measured on Docker 29.7.2 with Compose 5.5.1, against a container being
# restarted under a loop of execs:
#
#   stopped   "cannot exec in a stopped state" on STDOUT, exit 128
#   killed    the output printed so far, then exit 137 (SIGKILL), stderr empty
#   missing   "OCI runtime exec failed: ..." on STDOUT, exit 126 or 127
#   refused   "unable to upgrade to tcp, received 409" on stderr, exit 1
#
# A fake `docker` early in PATH plays each of those, and the real answers too,
# so the probe's three modes are checked against every shape without a game
# server. Before this test, `who` read "stopped" as "nobody is on" and
# `players` printed the error text as the player count.
# shellcheck disable=SC2015   # pass and fail always exit 0, so "A && pass || fail" is if-then-else here
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASSED=0; FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }

BIN=$(mktemp -d)
trap 'rm -rf "$BIN"' EXIT
cat > "$BIN/docker" <<'SH'
#!/bin/bash
cat >/dev/null                      # the program on stdin, as exec -T reads it
case "$FAKE" in
  stopped)  echo "cannot exec in a stopped state"; exit 128 ;;
  killed)   printf '%b' "$FAKE_OUT"; exit 137 ;;
  missing)  echo 'OCI runtime exec failed: exec failed: unable to start container process: exec: "python3": executable file not found in $PATH'; exit 126 ;;
  refused)  echo "unable to upgrade to tcp, received 409" >&2; exit 1 ;;
  answer)   printf '%b' "$FAKE_OUT"; exit 0 ;;
esac
exit 99
SH
chmod +x "$BIN/docker"
export KF2_QUERY_PORT=27015

# probe <mode> <fake> [output]: prints "<exit>|<stdout>"
probe() {
  local out rc
  out=$(PATH="$BIN:$PATH" FAKE="$2" FAKE_OUT="${3:-}" tools/kf2-a2s.sh "$1" 2>/dev/null); rc=$?
  printf '%s|%s' "$rc" "$out"
}

echo "== players: a number, or nothing"
[ "$(probe players answer '3\n')" = "0|3" ] && pass "a real answer of 3 is 3" || fail "a real answer of 3 read as '$(probe players answer '3\n')'"
[ "$(probe players answer '0\n')" = "0|0" ] && pass "a real answer of 0 is 0" || fail "a real 0 read as '$(probe players answer '0\n')'"
for f in stopped missing refused; do
  [ "$(probe players $f)" = "0|" ] && pass "$f: nothing, not a count" || fail "$f read as '$(probe players $f)'"
done
[ "$(probe players killed '3\n')" = "0|" ] && pass "killed after printing 3: nothing, the exec did not finish" || fail "killed read as '$(probe players killed '3\n')'"

echo "== info: one record of five fields, or not answering"
rec='A server\tKF-BioticsLab\t2\t6\topen\n'
[ "$(probe info answer "$rec")" = "0|$(printf '%b' "${rec%\\n}")" ] && pass "a real record is printed" || fail "a real record read as '$(probe info answer "$rec")'"
for f in stopped missing refused; do
  [ "$(probe info $f)" = "1|" ] && pass "$f: not answering" || fail "$f read as '$(probe info $f)'"
done
[ "$(probe info killed "$rec")" = "1|" ] && pass "killed after the record: not answering" || fail "killed read as '$(probe info killed "$rec")'"

echo "== who: a roster, nobody, or not answering"
[ "$(probe who answer 'answered\n')" = "0|nobody is on" ] && pass "a real empty roster is nobody" || fail "a real empty roster read as '$(probe who answer 'answered\n')'"
[ "$(probe who answer 'answered\nsomeone\t40\t12\n')" = "0|$(printf 'someone\t40\t12')" ] && pass "a real roster is printed" || fail "a real roster read as '$(probe who answer 'answered\nsomeone\t40\t12\n')'"
for f in stopped missing refused; do
  [ "$(probe who $f)" = "1|" ] && pass "$f: not answering, not 'nobody is on'" || fail "$f read as '$(probe who $f)'"
done
[ "$(probe who killed 'answered\n')" = "1|" ] && pass "killed after the header: not answering" || fail "killed read as '$(probe who killed 'answered\n')'"

echo
echo "passed $PASSED, failed $FAILED"
[ "$FAILED" -eq 0 ]
