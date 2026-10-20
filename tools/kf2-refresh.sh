#!/bin/bash
# kf2-refresh.sh - keep the server on the build Steam ships, and only ever
# restart an empty one. Run it from cron or a timer, every hour or so.
#
#   tools/kf2-refresh.sh             update if behind and nobody is on
#   tools/kf2-refresh.sh --check     say whether it is behind, change nothing
#   tools/kf2-refresh.sh --dry-run   go as far as deciding, change nothing
#   tools/kf2-refresh.sh --force     restart even with players on, or unknown
#
# WHY THIS AND NOT LINUXGSM'S OWN HOURLY CHECK. The image's entrypoint installs
# an hourly `kf2server update` cron job, which restarts the server whoever is
# on. Under this template's no-new-privileges it never installs at all:
# crontab is setgid, the hardening ignores that bit, and the install fails with
# "mkstemp: Permission denied" while the entrypoint carries on as if it had
# worked. Up to v1.2 this template offered KF2_SERVER_UPDATE_CHECK=60 for it,
# a setting that did nothing. Steam enforces a version match, so a server that
# is behind turns every player away the evening a patch ships, while its
# container stays healthy. This is the update path that works:
# LinuxGSM fetches the new build when the server starts, so the fix is a
# restart, and this decides when one is due and when one would hurt somebody.
#
# BOTH BUILD NUMBERS ARE LINUXGSM'S, READ, NEVER ASSUMED: `check-update` prints
# the installed one ("Local build") and Steam's ("Remote build"). An update
# counts only when the local build afterwards is the remote one.
#
# AN UNANSWERED QUERY IS NOT AN EMPTY SERVER. Players are counted by
# tools/kf2-a2s.sh, the one probe every tool here uses, which prints nothing
# when the server does not answer. Nothing is "?", skipped like a full server,
# and this exits 1: a probe that can never tell is a probe somebody should
# look at.
#
# tests/e2e-refresh.sh proves the decisions against the moderation stand-in.
#   KF2_BUILDS   "<local> <remote>", in place of asking LinuxGSM (tests); set
#                but empty means "could not be read"
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

MODE=""
FORCE=false
for arg in "$@"; do
  case "$arg" in
    --check) MODE=check ;;
    --dry-run) MODE=dry-run ;;
    --force) FORCE=true ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

COMPOSE_FILE=${KF2_COMPOSE_FILE:-kf2-server-docker-compose.yml}
PROJECT=${COMPOSE_PROJECT_NAME:-kf2}
compose() { docker compose -f "$COMPOSE_FILE" -p "$PROJECT" "$@"; }
say() { echo "$(date '+%F %T') $*"; }
# timeout(1) is GNU coreutils: without it (macOS) the command runs unbounded
# rather than not at all.
limit() { if command -v timeout >/dev/null 2>&1; then timeout "$@"; else shift; "$@"; fi; }

[ -n "$(compose ps -q --status running kf2-server 2>/dev/null)" ] || { say "the server is not running; nothing to refresh"; exit 0; }

builds() {
  if [ -n "${KF2_BUILDS+x}" ]; then echo "$KF2_BUILDS"; return; fi
  local out
  out="$(limit 300 docker compose -f "$COMPOSE_FILE" -p "$PROJECT" exec -T --user linuxgsm kf2-server ./kf2server check-update 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
  echo "$(grep -oE 'Local build: *[0-9]+' <<<"$out" | grep -oE '[0-9]+$' | tail -1) $(grep -oE 'Remote build: *[0-9]+' <<<"$out" | grep -oE '[0-9]+$' | tail -1)"
}

installed=""; latest=""
for attempt in 1 2; do
  read -r installed latest <<<"$(builds)"
  [ -n "$installed" ] && [ -n "$latest" ] && break
  [ "$attempt" = 1 ] && [ -z "${KF2_BUILDS+x}" ] && sleep 20
done
if [ -z "$installed" ] || [ -z "$latest" ]; then
  say "could not read both builds from LinuxGSM: installed '${installed:-?}', Steam '${latest:-?}'; nothing changed" >&2
  exit 1
fi
if [ "$installed" = "$latest" ]; then
  say "up to date: build $installed"
  exit 0
fi
if [ "$MODE" = check ]; then
  say "behind: running build $installed, Steam ships $latest"
  exit 0
fi

players="$(tools/kf2-a2s.sh players 2>/dev/null)"
case "$players" in ''|*[!0-9]*) players="?" ;; esac
if [ "$players" = "?" ] && [ "$FORCE" != "true" ]; then
  say "behind ($installed -> $latest), and the server did not answer the player query, so nobody can say who is on; not restarting. --force restarts anyway" >&2
  exit 1
fi
if [ "$players" != "?" ] && [ "$players" -gt 0 ] && [ "$FORCE" != "true" ]; then
  say "behind ($installed -> $latest), but $players player(s) are on; trying again next run"
  exit 0
fi
if [ "$MODE" = dry-run ]; then
  say "would restart to update ($installed -> $latest): players online: $players$([ "$FORCE" = "true" ] && echo ', forced')"
  exit 0
fi

say "behind ($installed -> $latest), players online: $players; restarting so LinuxGSM fetches it"
compose restart kf2-server >/dev/null
now=""
for _ in $(seq 1 90); do
  sleep 10
  read -r now _ <<<"$(builds)"
  [ "$now" = "$latest" ] && break
done
if [ "$now" = "$latest" ]; then
  say "updated: build $installed -> $now"
  exit 0
fi
say "FAILED: still on build ${now:-unknown} fifteen minutes after the restart; players on the new client cannot join until it updates. docker compose -p $PROJECT logs --tail 200 kf2-server" >&2
exit 1
