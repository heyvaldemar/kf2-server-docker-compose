#!/bin/bash
# operator-password.sh - passwords set where an operator sets them, for tests/secret-probe.sh.
#
# Killing Floor 2 reads its passwords from the server's ini, not from the
# compose file: GamePassword, which players are asked for, and AdminPassword,
# WebAdmin's (this template leaves both empty). LinuxGSM's `details`, which
# the image runs after every start, prints what it finds there. The probe
# plants only what the compose file passes, which here is nothing, so this
# gives both a random value of its own, writes them into the ini, and adds
# them to the probe's values file under the names below.
#
# THE SERVER MUST BE STOPPED. It rewrites the ini on its way out, so an edit
# made while it runs is lost; tools/kf2-ban.sh edits the same file the same
# way. The values travel on stdin, never on a command line, and in GitHub
# Actions the runner masks them in the job's log.
#
#   tests/fixtures/operator-password.sh     (PROBE_VALUES as the probe reads it)
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
VALUES="${PROBE_VALUES:-${RUNNER_TEMP:-/tmp}/secret-probe.values}"
COMPOSE_FILE=${KF2_COMPOSE_FILE:-kf2-server-docker-compose.yml}
PROJECT=${COMPOSE_PROJECT_NAME:-kf2}
compose() { docker compose -f "$COMPOSE_FILE" -p "$PROJECT" "$@"; }

[ -f "$VALUES" ] && [ ! -L "$VALUES" ] || { echo "operator-password: no values file ($VALUES); run tests/secret-probe.sh plant first" >&2; exit 2; }
[ -z "$(compose ps -q --status running kf2-server 2>/dev/null)" ] || { echo "operator-password: the server is running; stop it first" >&2; exit 2; }

g="g$(openssl rand -hex 10)"; a="a$(openssl rand -hex 10)"
[ "${GITHUB_ACTIONS:-}" = true ] && printf '::add-mask::%s\n' "$g" "$a"
umask 077
printf 'KF2_INI_GAME_PASSWORD\t%s\nKF2_INI_ADMIN_PASSWORD\t%s\n' "$g" "$a" >>"$VALUES"

# The program and its two values, on the one-off container's stdin.
{
  printf 'g=%s\na=%s\n' "$g" "$a"
  cat <<'SH'
ini=/data/serverfiles/KFGame/Config/kf2server/LinuxServer-KFGame.ini
[ -f "$ini" ] || { echo "operator-password: no $ini"; exit 1; }
out=""; sg=0; sa=0
while IFS= read -r line || [ -n "$line" ]; do
  case "${line%$'\r'}" in
    GamePassword=*) line="GamePassword=$g"; sg=1 ;;
    AdminPassword=*) line="AdminPassword=$a"; sa=1 ;;
  esac
  out+="$line"$'\n'
done <"$ini"
[ "$sg" = 1 ] && [ "$sa" = 1 ] || { echo "operator-password: the ini has no GamePassword= or AdminPassword= line"; exit 1; }
printf '%s' "$out" >"$ini" || exit 1
hg=0; ha=0
while IFS= read -r line || [ -n "$line" ]; do
  [ "${line%$'\r'}" = "GamePassword=$g" ] && hg=1
  [ "${line%$'\r'}" = "AdminPassword=$a" ] && ha=1
done <"$ini"
[ "$hg" = 1 ] && [ "$ha" = 1 ] || { echo "operator-password: the ini does not read back"; exit 1; }
echo "operator-password: GamePassword and AdminPassword set in ${ini##*/}"
SH
} | compose run --rm --no-deps -T --user "${KF2_SERVER_UID:-1000}" --entrypoint bash kf2-server -s
