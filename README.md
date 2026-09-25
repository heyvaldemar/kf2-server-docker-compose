# Killing Floor 2 server using Docker Compose

[![Deployment Verification](https://github.com/heyvaldemar/kf2-server-docker-compose/actions/workflows/deployment-verification.yml/badge.svg?branch=main)](https://github.com/heyvaldemar/kf2-server-docker-compose/actions/workflows/deployment-verification.yml)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/14892/badge)](https://www.bestpractices.dev/projects/14892)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A Killing Floor 2 co-op server on LinuxGSM, pinned by digest, with the port rule that cost an evening, the health check that spent seventeen hours green over a dead server, and moderation for an engine that has no rcon.

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

**WebAdmin is bound to localhost, and its password stays empty.** Killing Floor 2 has no rcon; this small web application is the entire administrative interface, so publishing it to the internet puts a login form guarding a reconfigurable game server on the open internet. It answers on the host only unless `.env` names a LAN address. Both times an `AdminPassword` was set on the machine this template comes from, the server advertised itself as password protected and dropped every client that did not answer the prompt; two days later it did the same with no password set anywhere, after the engine lost its Steam session (`Can't start an online game in state 0` in its log). A password is a second, avoidable way into that state. It stays empty, nobody can log in, and moderation does not depend on WebAdmin at all.

**A ban is a line in a file the server rewrites.** With no rcon and no WebAdmin login, a ban is one line under `[Engine.AccessControl]` in `LinuxServer-KFGame.ini`, the Steam id split into two 32-bit halves. The engine rewrites that file on the way out and again on the way up: an edit made while it runs is thrown away at the next stop, silently, and an edit it does not accept is gone by the time it answers a query. So `tools/kf2-ban.sh` stops the server, edits the file as the server's own user, starts it, and reports success only after finding the id in the file the server just rewrote. A zero exit from the edit is not that.

**A ban that cannot be applied now is queued, not dropped.** A restart ends the round for everyone playing, for a ban that only bites on the next connection anyway. The first version refused while anyone was on and told the moderator to come back later; twice in three days nobody did, and the person who had earned the ban kept their place. So with players on, the id is written to `.kf2-ban-queue`, and `tools/kf2-ban-queue.sh` applies it the moment the server is empty. An unanswered query is not an empty server: silence is when a restart is least welcome, and both scripts ask one probe, `tools/kf2-a2s.sh`, so they cannot disagree about what empty means.

**Whether players can find the server is a question only Steam can answer.** Container running, process alive, health check green, A2S answering every probe, and for nineteen hours the server took one player where the same window normally brings a hundred and thirty: it had dropped out of Steam's list. Two local signals were tried as a fix and both cost restarts. The A2S password flag fired three times in an afternoon while five people were playing through it, and the age of the server's last re-publication said broken while Steam, asked directly, listed the server forty-eight times in a row. `tools/kf2-listed.sh` asks Steam's own list, which needs no key, and restarts nothing.

**The volume is external**, so `docker compose down -v` cannot delete 25 GB of game content and the server's state with it.

## Administration

```bash
# LinuxGSM's own commands, as the linuxgsm user inside the container
docker compose -p kf2 exec --user linuxgsm kf2-server ./kf2server details
docker compose -p kf2 exec --user linuxgsm kf2-server ./kf2server update
docker compose -p kf2 exec --user linuxgsm kf2-server ./kf2server console
```

WebAdmin answers at `http://127.0.0.1:8080` on the host running the stack, and nobody can log in to it: an admin password closes the server to players (above), so this template leaves it empty and moderates through the file instead (below). Difficulty and length are two variables in `config/kf2server.cfg`, so a change survives the next restart; set only in the running server, it reverted silently.

## Moderation without rcon

Killing Floor 2 has no rcon, and WebAdmin cannot be used without a password that closes the server. What is left is the ini, a restart, and the server's own query port. Three scripts, and one of them asks the only question that matters:

```bash
tools/kf2-a2s.sh players                 # how many are on, or nothing at all if the server did not answer
tools/kf2-a2s.sh who                     # names, score and minutes; A2S carries no ids
tools/kf2-ban.sh list                    # who is banned, as Steam community ids
tools/kf2-ban.sh add 76561198042335367   # or 0x0110000104E44887, as the chat log writes it
tools/kf2-ban.sh remove 76561198042335367
tools/kf2-ban.sh queue                   # what is waiting for an empty server
tools/kf2-ban-queue.sh --dry-run         # what the applier would do right now
```

`add` on an empty server stops the game, writes the line as the server's own user, starts it, waits for it to answer and reads the ban list back out of the file it rewrote. On a server with people on it, or one that does not answer, `add` queues the id and says so; `--force` after the id applies at once, whoever is on, because sometimes a person should not be allowed to finish the round they are in. `remove` needs a restart too and is refused while anyone is on, with `--force` as the way past. Neither kicks. A ban is checked at connection, a player already on stays until they leave, and this engine has no kick from outside the game; nothing here pretends otherwise. A number that is not a player id is refused rather than written into a list it would never match.

The queue needs something to run it every five minutes: the units in `systemd/`, after editing the two paths in the service file to where this repository is checked out,

```bash
sudo cp systemd/kf2-ban-queue.service systemd/kf2-ban-queue.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now kf2-ban-queue.timer
```

or one line in the crontab of a user who can run `docker compose`:

```
*/5 * * * * cd /opt/kf2-server-docker-compose && tools/kf2-ban-queue.sh
```

Nothing queued is silent. A ban that applies, and a ban that fails and stays queued, are both printed, and both are posted to `KF2_MODERATION_WEBHOOK` when `.env` names a Mattermost or Slack incoming webhook: the news belongs where the request came from, not in a host log. A webhook that does not answer is reported and fails the run rather than being assumed delivered.

**Where the id comes from.** A2S carries names only. The id a ban needs is in the chat log the server writes under `KFGame/Logs/Chatlog_*.log` inside the volume, one tab-separated line per message with the player's id as `0x0110000104E44887`, which `add` accepts as it is. That log exists only when two switches in `KFWebAdmin.ini` are both on, `bChatLog` under `[WebAdmin.WebAdmin]` and `bEnabled` under `[WebAdmin.Chatlog]`; the second alone writes nothing, and the log needs no WebAdmin login. On the machine this template comes from, a bot follows that log into a chat channel and posts a card with a ban button; the button runs `tools/kf2-ban.sh add` with the id from the line, and the queue's own message closes the loop in the same channel.

**Is it listed?** `tools/kf2-listed.sh <public address> [query port]` asks Steam whether a server at that address is in its list: exit 0 listed, 1 not listed, 2 Steam did not answer, which is not the same thing as not listed. Steam drops a server for a minute or two after any restart, including the one `kf2-ban.sh` does, so one miss means nothing; look for several in a row before acting on it, and cap whatever acts.

## Hiding your home address

If you run this at home and want nothing listening on your router, put the game container in the network namespace of a WireGuard sidecar that dials out to a cheap relay: [game-server-wireguard-relay-docker-compose](https://github.com/heyvaldemar/game-server-wireguard-relay-docker-compose). Forward 7777, the query port and 20560 through the relay; never WebAdmin.

## Updating

The pin lives in the `x-images` block at the top of the compose file, as an interpolation default, so a `git pull` delivers the image this repository has tested. The tag is the game's name because LinuxGSM publishes every game under one image name and no version: the digest is the version, the image rebuilds weekly, and the daily freshness check goes red when it does. The game itself updates through SteamCMD inside the volume, on `./kf2server update` or at start. `./update.sh` does that on purpose: it moves to the latest release tag, refuses to cross a major unattended, and names any new required variable before anything has moved.

## Testing

`tests/e2e-healthcheck.sh` runs five assertions against a real container and needs no game download: the bracketed check is green with the game running, the plain one is green too, and after the game is killed the bracketed one goes red while the plain one stays green with LinuxGSM's wrapper still standing.

`tests/e2e-moderation.sh` runs the moderation tools against the pinned image, with `tests/fixtures/fake-kf2.py` on the query port where the game would be: the same python3 the tools use in production, a volume laid out the way LinuxGSM lays it out, and the same `docker compose stop`, `run` and `exec` the tools issue against the real compose file. It asserts the whole cycle, negatives included: stop, edit, start, read back; the wrong id refused; a ban queued while people are on and nobody restarted; a silent server not restarted either; the queue applied when the server empties, one restart per ban; an id the server drops at startup reported as dropped; a missing section reported and the server started again; a CRLF file left CRLF; a webhook nobody answers reported and failing the run.

CI runs both on every push alongside shell and workflow linting, a Trivy scan of the pinned image, and a daily check that the pin still resolves to what upstream publishes.

CI does not boot the game. The first start is a 25 GB download, and a test that pretends a runner does that in time is a test that never runs.

---

## About the maintainer

<div align="center">

**Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** · Docker Captain · IBM Champion · AWS Community Builder

[YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

</div>
