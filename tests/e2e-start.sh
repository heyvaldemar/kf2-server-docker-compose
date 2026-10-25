#!/bin/bash
# Does every start do the two things the template adds to it, against the
# pinned image: make KFGame/Cache once the game is installed and never before,
# and start without waiting for an npm registry that does not answer?
#
# KFGame/Cache comes from a block in config/kf2server.cfg, which LinuxGSM
# sources before every command. So the image's own entrypoint is run, under
# the same no-new-privileges, against a volume laid out the way an installed
# server lays it out, and the directory must appear, owned by the game's user.
# Two negatives: with the block taken out it must not appear, or the image
# makes it itself and the block can go; and with the block's guard taken out,
# a fresh volume must look installed to the entrypoint, or the guard's comment
# is wrong.
#
# The npm wait needs no game either. The entrypoint runs `npm install` in
# /app/lgsm on every start; here the module LinuxGSM installs there is
# installed once with the registry reachable, then the registry's name points
# at a listener that accepts every connection and never answers, which is how
# it looked on the server this template comes from. With the compose file's
# NPM_CONFIG_* settings, read from the compose file, the same `npm install`
# must finish within fifteen seconds. With npm's defaults it must still be
# waiting at ninety, or the settings are not what saves the start.
#
# The game itself is not installed: that is a 25 GB download.
# shellcheck disable=SC2015   # pass and fail always exit 0, so "A && pass || fail" is if-then-else here
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASSED=0; FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }

IMAGE="$(grep -m1 -oE '\$\{KF2_SERVER_IMAGE_TAG:-.*' kf2-server-docker-compose.yml | sed -E -e ':a' -e 's/\$\{[A-Z0-9_]+:-([^{}]*)\}/\1/' -e 'ta')"
[ -n "$IMAGE" ] || { echo "could not read the pinned image from the compose file"; exit 1; }
SCRATCH="$(mktemp -d)"
VOLUME="kf2-starttest-$$"
cleanup() { docker volume rm -f "$VOLUME" >/dev/null 2>&1; rm -rf "$SCRATCH"; }
trap cleanup EXIT

# The entrypoint chowns everything under /data, the mounted config included,
# so it gets copies, never the repository's file.
cp config/kf2server.cfg "$SCRATCH/shipped.cfg"
# shellcheck disable=SC2016   # ${serverfiles} is the config's own text, matched as written
sed '/^if \[ -d "${serverfiles}\/KFGame" \]; then$/,/^fi$/d' config/kf2server.cfg >"$SCRATCH/without.cfg"
# shellcheck disable=SC2016
sed 's/^if \[ -d "${serverfiles}\/KFGame" \]; then$/if true; then/' config/kf2server.cfg >"$SCRATCH/unguarded.cfg"
if cmp -s "$SCRATCH/shipped.cfg" "$SCRATCH/without.cfg" || cmp -s "$SCRATCH/shipped.cfg" "$SCRATCH/unguarded.cfg"; then
  echo "the KFGame/Cache block in config/kf2server.cfg is not in the shape this test edits"; exit 1
fi

fresh()   { docker volume rm -f "$VOLUME" >/dev/null 2>&1; docker volume create "$VOLUME" >/dev/null; }
in_vol()  { docker run --rm -v "$VOLUME:/data" --entrypoint sh "$IMAGE" -c "$1" 2>/dev/null; }
# The image's own entrypoint, as the compose file runs it, with one LinuxGSM
# command in place of the server: `details` sources the config and starts
# nothing.
entry()   { # config, extra docker args...
  local cfg=$1; shift
  docker run --rm --security-opt no-new-privileges:true -e GAMESERVER=kf2server -e UID=1000 -e GID=1000 \
    -v "$VOLUME:/data" -v "$SCRATCH/$cfg:/data/config-lgsm/kf2server/kf2server.cfg" "$@" "$IMAGE" details 2>&1
}
installed() { in_vol 'mkdir -p /data/serverfiles/KFGame/Config /data/serverfiles/Binaries/Win64'; }

docker pull -q "$IMAGE" >/dev/null 2>&1 || { echo "cannot pull $IMAGE"; exit 1; }
echo "    $IMAGE"
echo
echo "=== KFGame/Cache, through the image's own entrypoint ==="
echo

# 1. An installed server, the shipped config: the directory is made, as the
#    game's user, so the game can write into it.
fresh; installed
entry shipped.cfg >"$SCRATCH/1.log"
owner="$(in_vol 'stat -c %u:%g /data/serverfiles/KFGame/Cache')"
[ "$owner" = "1000:1000" ] && pass "installed, shipped config: KFGame/Cache made, owned by 1000:1000" \
  || fail "installed, shipped config: KFGame/Cache ${owner:-missing}; $(tail -3 "$SCRATCH/1.log")"

# 2. The same without the block: the image does not make it. If this ever
#    fails, upstream fixed the gap and the block can go.
fresh; installed
entry without.cfg >/dev/null
[ -z "$(in_vol 'ls -d /data/serverfiles/KFGame/Cache')" ] && pass "without the block: no KFGame/Cache, the gap is the image's" \
  || fail "without the block the image made KFGame/Cache itself: the block is no longer needed"

# 3. A fresh volume, and LinuxGSM sourcing the config BEFORE the entrypoint
#    decides whether to install (developer mode does that; so does a branch
#    other than master): nothing is made, and the entrypoint still knows the
#    game is not installed.
fresh
out="$(entry shipped.cfg -e LGSM_DEV=true)"
held="$(in_vol 'ls -A /data/serverfiles 2>/dev/null')"
[ -z "$held" ] && grep -q "is not installed yet" <<<"$out" && pass "fresh volume, config sourced first: serverfiles still empty, still to be installed" \
  || fail "fresh volume: serverfiles holds [${held//$'\n'/ }]; $(grep -m1 'not installed' <<<"$out")"

# 4. The guard taken out: the same fresh volume now looks installed, so a
#    real first start would skip its install. The guard is what prevents it.
fresh
out="$(entry unguarded.cfg -e LGSM_DEV=true)"
held="$(in_vol 'ls -A /data/serverfiles 2>/dev/null')"
[ -n "$held" ] && ! grep -q "is not installed yet" <<<"$out" && pass "without the guard: a fresh volume looks installed (serverfiles holds ${held//$'\n'/ })" \
  || fail "without the guard a fresh volume still read as not installed: the guard's comment is wrong"

echo
echo "=== npm at start, with a registry that never answers ==="
echo

# The compose file's own settings, not a copy of them.
docker compose -f kf2-server-docker-compose.yml config --format json 2>/dev/null \
  | python3 -c 'import json,sys
env=json.load(sys.stdin)["services"]["kf2-server"].get("environment") or {}
for k,v in sorted(env.items()):
    if k.startswith("NPM_CONFIG_"): print(f"{k}={v}")' >"$SCRATCH/npm.env"
echo "    from the compose file: $(cut -d= -f1 "$SCRATCH/npm.env" | tr '\n' ' ')"
grep -q '^NPM_CONFIG_AUDIT=false$' "$SCRATCH/npm.env" && pass "the compose file turns npm's audit off" \
  || fail "the compose file does not set NPM_CONFIG_AUDIT=false"

# What check_gamedig.sh does on a first start, then the registry goes quiet.
# `timeout` is the image's, so the measurement does not depend on the host.
cat >"$SCRATCH/npm.sh" <<'PROBE'
set -u
cd /app/lgsm && chown linuxgsm:linuxgsm /app/lgsm
gosu linuxgsm curl -sfL -o package.json https://raw.githubusercontent.com/GameServerManagers/LinuxGSM/master/package.json || { echo "first: no package.json"; exit 0; }
gosu linuxgsm env HOME=/data npm install >/dev/null 2>&1 || { echo "first: npm install failed with the registry up"; exit 0; }
echo "first: installed"
python3 -c '
import socket
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 443)); s.listen(64); held = []
while True: held.append(s.accept()[0])' &
echo "127.0.0.1 registry.npmjs.org" >>/etc/hosts
sleep 1
args=(); while IFS= read -r kv; do args+=("$kv"); done </probe/npm.env
s=$(date +%s); timeout 60 gosu linuxgsm env HOME=/data "${args[@]}" npm install >/tmp/with.log 2>&1; rc=$?
echo "with: $rc $(( $(date +%s) - s )) $(tail -1 /tmp/with.log)"
s=$(date +%s); timeout 90 gosu linuxgsm env HOME=/data npm install >/dev/null 2>&1; rc=$?
echo "without: $rc $(( $(date +%s) - s ))"
PROBE
out="$(docker run --rm -v "$SCRATCH:/probe:ro" --entrypoint bash "$IMAGE" /probe/npm.sh 2>/dev/null)"
if ! grep -q "^first: installed" <<<"$out"; then
  fail "could not install LinuxGSM's npm module with the registry up: $(grep '^first:' <<<"$out")"
else
  read -r _ rc secs rest <<<"$(grep '^with:' <<<"$out")"
  [ "$rc" = 0 ] && [ "${secs:-99}" -le 15 ] && pass "with the compose file's settings: done in ${secs}s, registry silent ($rest)" \
    || fail "with the compose file's settings: exit ${rc:-?} after ${secs:-?}s against a silent registry"
  read -r _ rc secs <<<"$(grep '^without:' <<<"$out")"
  [ "$rc" = 124 ] && pass "with npm's defaults: still waiting at ${secs}s, so the settings are what saves the start" \
    || fail "with npm's defaults it did not wait (exit ${rc:-?} after ${secs:-?}s): the settings are not what this test says"
fi

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
