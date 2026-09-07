# Killing Floor 2 server using Docker Compose

[![Deployment Verification](https://github.com/heyvaldemar/kf2-server-docker-compose/actions/workflows/deployment-verification.yml/badge.svg?branch=main)](https://github.com/heyvaldemar/kf2-server-docker-compose/actions/workflows/deployment-verification.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A Killing Floor 2 co-op server on LinuxGSM, pinned by digest, with the port rule that cost an evening and the health check that spent seventeen hours green over a dead server.

```bash
git clone https://github.com/heyvaldemar/kf2-server-docker-compose
cd kf2-server-docker-compose
cp .env.example .env                          # nothing in it is required
docker volume create kf2-server-data          # see "the volume", below
docker compose -f kf2-server-docker-compose.yml -p kf2 up -d
```

The first start is a 25 GB SteamCMD download into the volume; LinuxGSM installs the server and then runs it. Watch it:

```bash
docker compose -p kf2 logs -f kf2-server
docker compose -p kf2 ps          # healthy once KFGameSteamServer.bin is up
```

Players connect from the in-game browser or with `open your-address:7777` in the console.

## What this file knows that a fresh one does not

**The query port carries the same number inside and outside.** Steam records a server by the port the server binds, not the one a router publishes. A first version kept 27015 inside and published 27020 because another game held 27015 outside, and nobody could join: Steam's directory sent clients to 27015, where the other game answered. The game connection reached 7777 correctly, the Steam handshake then failed against a different game, and the server logged `Add unverified connection` followed one second later by `clean up connection by handshake timeout`. Direct A2S worked throughout, which is exactly what made it look like a client-side problem. The number lives in `config/kf2server.cfg` and in `.env`; change both or neither.

**The health check watches the game, not the wrapper.** A first version also accepted `pgrep -f kf2server`, which matches LinuxGSM's own supervising script, so the container reported healthy while SteamCMD was still downloading twenty-five gigabytes and no server existed at all. A check that passes before the thing it checks exists is worse than none, because it is believed.

**The bracket in the check is load-bearing.** `pgrep -f` searches full command lines, and the shell running the check has the pattern in its own — so written without the bracket, `pgrep -f KFGameSteamServer.bin` passed for every pattern ever given to it, including one naming a process that does not exist. Measured in the container: `pgrep -f "ZZZ_no_such_process"` exits 0; with the first letter in a character class it exits 1. A server crashed with a core dump, two people were dropped mid-game, and the check reported healthy for the whole of it. `tests/e2e-healthcheck.sh` proves the bracket against a real container: with the game killed, the bracketed form goes red and the plain form stays green.

**Six players is the engine's number.** Eight was tried three ways: as a URL option the server launched with `MaxPlayers=8` and answered 6 to A2S; written into the ini the server rewrote it back to 6 twenty-four seconds after start; submitted through WebAdmin the form returned 200 and the field came back 6. `KFGameInfo_Survival` clamps to 6; the 12 seen elsewhere belongs to Versus, which is 6-on-6. More seats need a mutator, not a setting.

**Co-op, not versus.** LinuxGSM's default game mode is `VersusSurvival`, where one side plays the zeds. `config/kf2server.cfg` sets `Survival`, the wave mode where everyone is on the same side.

**The settings live outside the volume.** `_default.cfg` is overwritten on every LinuxGSM update and says so at the top. The instance config is mounted from this repository, so git records every change to it and a backup that skips 25 GB of replaceable game files still has it.

**WebAdmin is bound to localhost.** Killing Floor 2 has no rcon; this small web application is the entire administrative interface, so publishing it to the internet puts a login form guarding a reconfigurable game server on the open internet. It answers on the host only unless `.env` names a LAN address.

**The volume is external**, so `docker compose down -v` cannot delete 25 GB of game content and the server's state with it.

## Administration

```bash
# LinuxGSM's own commands, as the linuxgsm user inside the container
docker compose -p kf2 exec --user linuxgsm kf2-server ./kf2server details
docker compose -p kf2 exec --user linuxgsm kf2-server ./kf2server update
docker compose -p kf2 exec --user linuxgsm kf2-server ./kf2server console
```

WebAdmin is at `http://127.0.0.1:8080` on the host running the stack; the admin password is set through it on first use. Difficulty and length are two variables in `config/kf2server.cfg`, so a change survives the next restart — set only in the running server, it reverted silently.

## Hiding your home address

If you run this at home and want nothing listening on your router, put the game container in the network namespace of a WireGuard sidecar that dials out to a cheap relay: [game-server-wireguard-relay-docker-compose](https://github.com/heyvaldemar/game-server-wireguard-relay-docker-compose). Forward 7777, the query port and 20560 through the relay; never WebAdmin.

## Updating

The pin lives in the `x-images` block at the top of the compose file, as an interpolation default, so a `git pull` delivers the image this repository has tested. The tag is the game's name because LinuxGSM publishes every game under one image name and no version: the digest is the version, the image rebuilds weekly, and the daily freshness check goes red when it does. The game itself updates through SteamCMD inside the volume, on `./kf2server update` or at start.

## Testing

`tests/e2e-healthcheck.sh` runs five assertions against a real container and needs no game download: the bracketed check is green with the game running, the plain one is green too, and after the game is killed the bracketed one goes red while the plain one stays green with LinuxGSM's wrapper still standing.

CI runs it on every push alongside shell and workflow linting, a Trivy scan of the pinned image, and a daily check that the pin still resolves to what upstream publishes.

CI does not boot the game. The first start is a 25 GB download, and a test that pretends a runner does that in time is a test that never runs.

---

## About the maintainer

<div align="center">

**Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** · Docker Captain · IBM Champion · AWS Community Builder

[YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

</div>
