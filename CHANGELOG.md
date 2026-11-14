# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **A kill for memory is named even when Docker stores its oom event late.** On a GitHub runner (Docker 29.4.2) the oom event of 1 kill in 20 was not there when the die event was, and was ten seconds later ([run 43623563645 in l4d2-server-docker-compose](https://github.com/heyvaldemar/l4d2-server-docker-compose/actions/runs/43623563645)), so the idle reset's restart watch called a kill for memory a plain SIGKILL. A 137 with no oom event yet is now read again, for up to ten seconds (the same watch: 20 of 20 named, [run 43624152790](https://github.com/heyvaldemar/l4d2-server-docker-compose/actions/runs/43624152790)).

### Changed

- **The secret probe** names the selftest's container from the workflow, reaches the log through any process sharing process 1's output, and prints a leaked line with Steam IDs and addresses replaced.

## [1.8.0] - 2026-11-14

### Security

- **The passwords in the server's ini are no longer in `docker compose logs`.** LinuxGSM's `details`, which the image runs after every start, prints the passwords it finds in `LinuxServer-KFGame.ini` in clear: `GamePassword` as "Server password", `AdminPassword` as "Admin password" and "Web Interface password". This template leaves both empty, but a server with a join password had it in its logs on every start (CI, with both set in the ini on v1.7.1: both in `docker compose logs`, [run 43617936849](https://github.com/heyvaldemar/kf2-server-docker-compose/actions/runs/43617936849)). `tools/start.sh` is now the entrypoint: it runs the image's own entrypoint behind a filter that masks the value on any line whose label says "pass", in any case, and of any `…Password=` setting, and stays process 1 so that Docker's stop still reaches LinuxGSM's `stop`. **If you set a password in the ini and posted this server's logs anywhere, change it**: docker keeps earlier starts' output in its log files until they rotate out.
- **The moderation webhook's address is no longer on a command line.** `tools/kf2-ban-queue.sh` gave it to curl as an argument, where every process on the host could read it in `ps` for as long as curl ran, and the address of an incoming webhook is its key. curl now reads it from stdin (`--config -`). `tests/e2e-moderation.sh` posts to a listener on the runner and checks the address was not among curl's arguments.
- **CI looks for both passwords everywhere they could leak to.** `tests/secret-probe.sh` with `tests/fixtures/operator-password.sh`, which sets a value of its own for each in the ini the way an operator does: it fails on either in `docker compose logs`, LinuxGSM's logs and the game's `Launch.log`, any command line in the container or the host's `ps`, after the start and after a restart, and names the place, never the value. Red on v1.7.1, green with this release ([run 43617934701](https://github.com/heyvaldemar/kf2-server-docker-compose/actions/runs/43617934701)).
- **`gameservermanagers/gameserver:kf2` was rebuilt upstream**; the pin moved from `sha256:0fb3a9819446…` to `sha256:6e35af1b5ca2…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.

### Fixed

- **A crashed game comes back.** In this image process 1 is the entrypoint, which keeps running when the game dies: the container stays up, Docker restarts nothing, and the health check goes red and stays red, with nobody able to join, until someone restarts it by hand (CI on v1.7.1: SIGSEGV to the game, four minutes later the container still running, unhealthy, restart count 0, [run 43617936849](https://github.com/heyvaldemar/kf2-server-docker-compose/actions/runs/43617936849)). `tools/kf2-idle-reset.sh`, on its five-minute timer, now sees LinuxGSM's started lock with no game process (and no update, start or stop under way), restarts the server and says so; a second time within the hour it says so, exits 1 and leaves it. It also reports Docker's own restarts of the container once each, with the exit code and the reason from Docker's die and oom events, and exits 1 at three in a day. On the real server: SIGSEGV to the game, the next timer run restarted it, it answered A2S again, and the run after said nothing ([run 43617934701](https://github.com/heyvaldemar/kf2-server-docker-compose/actions/runs/43617934701)). `tests/e2e-idle-reset.sh` and `tests/restarts.sh` cover the decisions and Docker's restarts.
- **The health check could cut its own request in two.** bash writes printf's output line by line, so the query echoing the server's challenge went out as two datagrams whenever the challenge held a newline byte (0x0a), and that try went unanswered; one check in a few thousand, which the retries covered. The request now goes to a file first and out in one write. `tests/e2e-healthcheck.sh` proves it against a stand-in whose challenge holds one: the old check sends 26 and 3 bytes and stays unhealthy, this one one datagram of 29.
- **The real-server test no longer ignores the check it runs after the first green.** It ran the health check once more and exited 0 whatever that said; once, the second after Docker first called the server healthy, nothing was bound to the query port ([run 43616055520](https://github.com/heyvaldemar/kf2-server-docker-compose/actions/runs/43616055520)). The server must now answer within three minutes of that first green, and what it does meanwhile is printed.
- **An index pushed again over the same build is no longer reported as drift.** The daily pin check compared each pin with the digest the tag's index has now and failed on any difference, so a publisher re-pushing the index over the very same images (a platform added, an attestation rewritten) turned it red for an image nobody rebuilt, and no pin would ever move to turn it green. It now also compares the linux/amd64 build under both digests, the one CI runs and proves: the same build passes with a notice naming both digests, a new build fails as drift exactly as before, and a build that cannot be read still fails.

### Changed

- **A stop is measured.** `tests/clean-stop.sh` times `docker compose stop` on the real server: 6 seconds of the 60-second grace period, exit 0, no SIGKILL; LinuxGSM's `stop` runs as before (7 seconds on v1.7.1). Killing Floor 2 keeps no world to save.

## [1.7.1] - 2026-11-09

### Security

- **`gameservermanagers/gameserver:kf2` was rebuilt upstream**; the pin moved from `sha256:48929a3d7e6b…` to `sha256:0fb3a9819446…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.

## [1.7.0] - 2026-11-08

### Changed

- **The health check asks the server, not its process.** It was pgrep for `KFGameSteamServer.bin`, which a hung or stopped server keeps. `tools/healthcheck.sh`, mounted read-only, now sends A2S_INFO to the query port and is healthy only on the server's reply (challenge handled, two tries, within 7 seconds; the timeout is 10 seconds instead of 5 to hold it). A dead server has no socket and fails at once, so the floor on noticing it stays thirty seconds. It asks from inside the container, so it does not prove the ports are published on the host or open in a firewall; the README says so.
- **A new workflow, Real Server, boots the game and proves the check against it.** Red while SteamCMD downloads 25 GB with nothing bound, green on the server's A2S answer, red with the server stopped by SIGSTOP while the old pgrep check stays green, green again after SIGCONT. It runs on a push or pull request that touches the check, its test, the compose file, `.env.example`, the instance config or the workflow, every Monday, and by hand. Every push runs the check in the pinned image against a stand-in.
- **The README names Docker Engine 29.4.2.** That release alone stops SteamCMD, which this image runs to install and update the game (measured on this template's pinned image in tf2-server-docker-compose run 42496129688): upgrade to 29.4.3 or later, which reverted the rule, or point the daemon's `seccomp-profile` at the profile 29.4.3 ships. Ubuntu 26.04's own `docker.io` (27.5.1) never had it; on GitHub Actions the ubuntu-26.04 runner image ships it ([actions/runner-images#14790](https://github.com/actions/runner-images/issues/14790), moving to 29.7.2 in [#15205](https://github.com/actions/runner-images/pull/15205)). Documentation only.
## [1.6.8] - 2026-11-07

### Security

- **`gameservermanagers/gameserver:kf2` was rebuilt upstream**; the pin moved from `sha256:016e05bcbb3a…` to `sha256:48929a3d7e6b…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.

## [1.6.7] - 2026-11-06

### Security

- **`gameservermanagers/gameserver:kf2` was rebuilt upstream**; the pin moved from `sha256:01586342139d…` to `sha256:016e05bcbb3a…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.

## [1.6.6] - 2026-11-02

### Fixed

- **Steam's silence is tolerated, as v1.6.0 said it would be.** `tools/kf2-refresh.sh` took Steam to be quiet when LinuxGSM's `check-update` printed a local build without a remote one. LinuxGSM never prints that: it prints "Local build" and "Remote build" together, after it has asked Steam, and when Steam gives no build it stops at `[ FAIL ] ... Checking remote build` and exits 1, printing neither (LinuxGSM v26.4.0 in the pinned image, run with SteamCMD answering nothing). The tests handed the script the one-build shape through `KF2_BUILDS`, so they passed while a quiet Steam failed every real run at once with "could not read both builds". The failure line is now what says Steam is quiet, the installed build comes from the app manifest, and an exec that ends with 125 or more (Docker failing, or the exec killed) is said to be that, not counted as either. `tests/e2e-refresh.sh` cases 11 to 13 run LinuxGSM's own `check-update` in the pinned image with SteamCMD stubbed; the released script fails case 12.

## [1.6.5] - 2026-11-02

### Fixed

- **Docker's own failure is no longer read as the server's answer.** When an exec fails, Docker can print its error where the program's output goes: on Docker 29, a container that stops between the check and the exec gives "cannot exec in a stopped state" on stdout with exit 128, and an exec cut off by a restart ends with 137 after part of its output. `tools/kf2-a2s.sh who` dropped that line as its header and reported "nobody is on", `players` printed it as the count, and `tools/kf2-ban.sh` took any output as the server answering after a restart. The probe now takes nothing from an exec that did not end with 0 and checks each answer's shape, and the ban's read-back after a restart no longer reports "unbanned" from a read that failed. On the server this template comes from, a chat bot read the same line as part of a game's log. `tests/docker-failure.sh` plays the measured shapes through a fake `docker`; the released probe fails 9 of its 17 checks.

## [1.6.4] - 2026-11-01

### Changed

- **`tests/timers.sh` checks the fall-back on Berlin time (2026-10-25).** Any zone with a fall-back shows the same skip; the timers themselves are unchanged.

## [1.6.3] - 2026-11-01

### Fixed

- **The timers keep running the night the clocks go back.** `kf2-ban-queue.timer` (`*:0/5`) and `kf2-idle-reset.timer` (`*:2/5`) were local-time calendars, and the night the clocks went back, the server this template comes from ran none of its local-time timers for an hour: systemd took the repeated hour as already gone. They are now in UTC, with an `OnUnitActiveSec` net a little longer than the period and `AccuracySec=1s`. `tests/timers.sh` reproduces a fall-back night with `systemd-analyze` and fails on a local-time calendar. Reinstall the units after updating: `sudo cp systemd/*.timer /etc/systemd/system/ && sudo systemctl daemon-reload`.

### Changed

- **The KFGame/Cache note, corrected.** LinuxGSM's maintainer tested the KF2 wiki's note on a fresh install of build 10897 ([GameServerManagers/LinuxGSM#5108](https://github.com/GameServerManagers/LinuxGSM/pull/5108#issuecomment-6545539391)): the server makes the directory itself on its first Workshop download, and the crash the maintainer reproduced comes from a Workshop map set as the starting map before it is downloaded. This template starts on a stock map, so the README and the config no longer credit the directory with the quiet days after it was made. The directory is still made; it is harmless.

## [1.6.2] - 2026-10-31

### Security

- **`gameservermanagers/gameserver:kf2` was rebuilt upstream**; the pin moved from `sha256:9fc0e681902a…` to `sha256:01586342139d…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.

### Changed

- **The crash record in the README is current.** The game crashed again on 2026-10-28, on a map change, after the cache directory had cut crashes about tenfold. The README now gives the measured pattern (3 crashes in about 300 map changes with players moving, none in about 200 on an empty server, stock maps, no mutators) and how to read a crash log: during a map change the server counts 0 players and closes every connection, so the players a crash dropped are the ones whose connections were cleaned up as the old map shut down. Documentation only.

## [1.6.1] - 2026-10-27

### Fixed

- **Every script in `tools/` is read whole before it runs.** bash reads a script as it executes it and, after each command, reads on from the same byte offset in whatever the file holds by then. The timers start `tools/kf2-idle-reset.sh` and `tools/kf2-ban-queue.sh` every five minutes, and the queue runs `tools/kf2-ban.sh` for a minute or more; on the server this template comes from, a timer started a script while its file was being edited in place, and the run died on a syntax error. Each script's body is now one brace group, parsed in full before its first line runs, ending in `exit`. `tests/read-whole.sh` checks every script's shape and rewrites the idle reset's file under a running copy: wrapped, it finishes as it started; unwrapped, it runs the new text. A `git pull` or `./update.sh` was never the risk: git writes a new file, which a running copy does not see.

## [1.6.0] - 2026-10-27

### Changed

- **`tools/kf2-refresh.sh` tolerates Steam's silence for three hours, not for a number of runs.** When Steam does not say which build it ships, the script used to exit 1 on every run. On the machine this template comes from, Steam stopped answering SteamCMD's build query for about five hours while nothing on the host was wrong; its monitoring tolerated "three failures in a row", written for one caller every three hours, and a second caller landed three strikes in 67 minutes and reported the host down. The script now notes when Steam went quiet in `.kf2-refresh-steam-silent` and exits 0 until it has been quiet for `KF2_REFRESH_STEAM_TOLERANCE` seconds (10800), however often it runs in between, then exits 1; the first answer from Steam starts the span over. An installed build that cannot be read still exits 1 at once. A start time in the future is re-anchored to now, a silence that cannot be recorded is not tolerated, and a symlink in place of the file is refused. `tests/e2e-refresh.sh` shows all three cases.
- **`tools/kf2-listed.sh` and the README advise a span of time, not a count of misses,** before anything acts on a server missing from Steam's list.

## [1.5.0] - 2026-10-25

### Fixed

- **`KFGame/Cache` exists.** The KF2 wiki lists it as a known Linux issue: the server never creates the directory it uses when it loads a map, and it has to exist. On the server this template comes from it was missing while the game segfaulted on three map changes in four days; in the 75 hours after it was made, to 2026-10-25, the game did not crash once. A documented gap closed, not a proven cure. `config/kf2server.cfg` makes it, since LinuxGSM sources that file as the game's user before every command, so it comes back after every reinstall, and only once `KFGame` exists: made before the install, it would make a fresh volume look installed. `tests/e2e-start.sh` shows both through the image's own entrypoint, and that the image does not make it without the block.
- **A start no longer waits for npm's registry.** The image's entrypoint runs `npm install` on every start, and npm sends its audit request to the registry even when nothing needs installing. The night the registry did not answer, npm waited its default five minutes, and a start took twenty. The compose file now sets `NPM_CONFIG_AUDIT=false` and bounds the rest (`NPM_CONFIG_*`: no fund or update notice, cached metadata first, thirty seconds, one retry); a start took twenty-five seconds after. Against a registry that accepts every connection and never answers, `npm install` finishes in a second with these settings and is still waiting at ninety without them.

### Removed

- **The uptime rule in `tools/kf2-idle-reset.sh`.** Since v1.4.0 it restarted an empty server after eight hours up, because the two crashes with a log had both come on a map change after a long run. The third came 45 minutes after that rule had restarted the server, so uptime was not the variable, and the rule had already cost a twenty-minute outage, the npm wait above. It was removed rather than defended. `KF2_MAX_UPTIME` and `KF2_UPTIME_EMPTY_FOR` now do nothing, and the clock file it kept (`.kf2-idle-reset.uptime`) is removed on the next run. The takeover rule is unchanged.

## [1.4.1] - 2026-10-24

### Security

- **`gameservermanagers/gameserver:kf2` was rebuilt upstream**; the pin moved from `sha256:c7f4d92c88fb…` to `sha256:9fc0e681902a…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.

## [1.4.0] - 2026-10-21

### Added

- **`tools/kf2-idle-reset.sh`, with `systemd/kf2-idle-reset.timer` every five minutes: a restart for the two states only a restart ends, on an empty server only.** Closed to takeover: the server advertised itself unavailable to matchmaking with every seat open for 21.9 hours once, on the server this template comes from; empty and closed for 15 minutes, it restarts into the configured mode, and closed again within an hour of its own reset it stops and exits 1 instead of looping. Up too long: two crashes there were segfaults on a map change after 16 and 12.8 hours, memory at about 900 MB of 4 GB; up 8 hours and empty for 5 minutes, it restarts, a mitigation on a hypothesis, with its own clock so it never trips the takeover rule's guard. An unanswered player query is never zero: it waits and exits 1. `tests/e2e-idle-reset.sh` asserts fourteen decisions against the moderation stand-in, both rules restarting it once for real; with silence read as zero 3 checks fail, with the two rules sharing a stamp 2 do.

## [1.3.0] - 2026-10-20

### Added

- **`tools/kf2-refresh.sh`, an update path that works.** From cron, every hour or so: it reads the installed and the remote build from LinuxGSM's `check-update`, and when the server is behind restarts it so LinuxGSM fetches the new build on start, only if `tools/kf2-a2s.sh` says nobody is on. An unanswered query waits and exits 1. `tests/e2e-refresh.sh` asserts seven decisions against the moderation stand-in; with "cannot count" read as zero, the silent case restarts instead (2 checks fail).

### Fixed

- **`KF2_SERVER_UPDATE_CHECK` never did anything, and is gone.** The image's entrypoint installs LinuxGSM's hourly `kf2server update` cron job from it, and under this template's `no-new-privileges` that install always failed: crontab is setgid, the hardening ignores the bit, "mkstemp: Permission denied", and the entrypoint carried on. A server between restarts never updated, and the evening a patch ships Steam turns every player away from a server on the old build. The compose file now sets `UPDATE_CHECK: "0"` on purpose, so the job stays off the day either side changes, and `tools/kf2-refresh.sh` is the update path. `tests/e2e-refresh.sh` shows the install failing under the hardening and working without it, against the pinned image; it failed first on the old compose file, which did not set 0. Found on the server this template comes from, where the same image ran with the same hardening.

## [1.2.9] - 2026-10-20

### Fixed

- **A ban the queue could not record no longer says "queued".** `tools/kf2-ban.sh add` appended to the queue without checking the write and printed "queued: <id>", exit 0, whatever happened. `touch` caught a read-only mount, but not an append that failed after it (a full disk, a path that is a directory). On the server this template comes from, a moderation bot said "queued" for five weeks while every append failed and nothing was recorded. The append is now checked and the id read back; otherwise it says "NOT banned" and exits 1. `tests/e2e-moderation.sh` plants a queue path that is a directory; on the old script that case got exit 0. 47 of 47 now.
- **The applier says so when it cannot rewrite the queue**, instead of an unchecked `mv`; the applied bans then stay listed and are found already banned on the next run.

## [1.2.8] - 2026-10-19

### Security

- **`gameservermanagers/gameserver:kf2` was rebuilt upstream**; the pin moved from `sha256:e6d43cc5fa42…` to `sha256:c7f4d92c88fb…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.

## [1.2.7] - 2026-10-17

### Security

- **`gameservermanagers/gameserver:kf2` was rebuilt upstream**; the pin moved from `sha256:6fdd2ecba904…` to `sha256:e6d43cc5fa42…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.

## [1.2.6] - 2026-10-10

### Security

- **`gameservermanagers/gameserver:kf2` was rebuilt upstream**; the pin moved from `sha256:31e2aa692321…` to `sha256:6fdd2ecba904…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.

## [1.2.5] - 2026-10-06

### Changed

- **A crashed server reads unhealthy in thirty seconds, not three minutes.** The health check ran every 60s with three retries, so a dead game
  stayed healthy for three minutes, and a watchdog polling on top of that left a full server unable to rejoin for longer. A missing
  process needs no debouncing and `pgrep` costs nothing: `interval: 10s`, `timeout: 5s`, `retries: 3`. `start_period` is unchanged, so
  the first SteamCMD install still has its hour. `tests/e2e-healthcheck.sh` measures it against a fixture whose wrapper outlives the game.

### Fixed

- **`update.sh` no longer stops without a word when a release adds a variable and no compose file requires one.** The search for `${VAR:?}` came back empty, and under `pipefail` that empty result ended the script with status 1 right after it listed the new variables.
- **`update.sh` stops on a `.env` it cannot read, before the checkout.** It used to fall through: every new required variable read as "not set", or, with none, the tree moved to the new tag and `docker compose up` failed on the permission. Now it names the file, its owner and mode, and changes nothing.

### Security

- **`gameservermanagers/gameserver:kf2` was rebuilt upstream**; the pin moved from `sha256:788843c1ab39…` to `sha256:31e2aa692321…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.

## [1.2.4] - 2026-10-04

### Security

- **`gameservermanagers/gameserver:kf2` was rebuilt upstream**; the pin moved from `sha256:06beda610c9e…` to `sha256:788843c1ab39…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.

## [1.2.3] - 2026-10-03

### Security

- **`gameservermanagers/gameserver:kf2` was rebuilt upstream**; the pin moved from `sha256:ceb4710bfc84…` to `sha256:06beda610c9e…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.

## [1.2.2] - 2026-09-26

### Security

- **`gameservermanagers/gameserver:kf2` was rebuilt upstream**; the pin moved from `sha256:6d1130d02554…` to `sha256:ceb4710bfc84…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.

### Changed

- **The freshness check has its own workflow, Pin Freshness.** It ran inside Deployment Verification, whose badge is the one at the top of this README. Across the fleet, nine red runs in ten were a pin one version behind - which the fleet's triage moves within the day - and a reader cannot tell that from a stack that does not boot. The badge now says whether the stack boots. The job itself is unchanged.

## [1.2.1] - 2026-09-19

### Security

- **`gameservermanagers/gameserver:kf2` was rebuilt upstream**; the pin moved from `sha256:52beab070566…` to `sha256:6d1130d02554…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.

## [1.2.0] - 2026-09-13

### Added

- **Moderation without rcon.** `tools/kf2-ban.sh` bans and unbans by editing
  `[Engine.AccessControl]` in the server's ini as the server's own user, with
  a restart, and reports success only after reading the id back out of the
  file the server rewrote at startup. With players on, or a server that does
  not answer, the ban is queued in `.kf2-ban-queue` instead of dropped, and
  `tools/kf2-ban-queue.sh` applies it the moment the server is empty, from
  `systemd/kf2-ban-queue.timer` or one crontab line. Both ask one probe,
  `tools/kf2-a2s.sh`, so they cannot disagree about what empty means, and an
  unanswered query is not an empty server. A ban already in the file, or an
  unban of an id that is not, costs no restart. Applied and failed bans are
  posted to `KF2_MODERATION_WEBHOOK` (Mattermost or Slack) when `.env` names
  one; a webhook that does not answer fails the run rather than being assumed
  delivered.
- **`tools/kf2-a2s.sh`**: `players`, `info` and `who`, asked from inside the
  container so the answer is the same behind a relay as on a bridge. Names
  only: A2S carries no ids, and the README says where the id comes from.
- **`tools/kf2-listed.sh`**: is the server in Steam's list, asked of Steam.
  Nineteen hours of every local signal green while nobody could find the
  server is the reason; the two signals that looked exact and both cost
  restarts are written down beside it. Exit 2 for "Steam did not answer" is
  not exit 1.
- **`tests/e2e-moderation.sh`**: 46 assertions against the pinned image,
  with `tests/fixtures/fake-kf2.py` on the query port where the game would
  be: stop, edit, start, read back; the wrong id refused; a ban queued while
  people are on and nobody restarted; a silent server not restarted either;
  the queue applied when the server empties, one restart per ban; an id the
  server drops at startup reported as dropped; a missing section reported and
  the server started again; a CRLF file left CRLF; a webhook nobody answers
  reported and failing the run. CI runs it on every push.
- **`KF2_SERVER_UPDATE_CHECK`**: how often LinuxGSM asks Steam for a game
  update, in minutes (the image's default, 60; 0 turns it off). Steam
  enforces a version match: the evening a patch ships, every client updates
  itself and a server still on the old build stops accepting them.

### Changed

- **The admin password stays empty, and the README says why.** Both times one
  was set on the machine this template comes from, the server advertised
  itself as password protected and dropped every client that did not answer
  the prompt; "set it through WebAdmin on first use" is gone.
- ShellCheck now covers every script in the repository, from the lint job.

### Fixed

- The 1.0.0 entry below had lost its heading and its first line to an edit.

## [1.1.1] - 2026-09-12

### Security

- **`gameservermanagers/gameserver:kf2` was rebuilt upstream**; the pin moved from `sha256:5a5c228f0059…` to `sha256:52beab070566…`. Same version, same tag, a rebuilt base image — the usual shape of a security fix in a base layer.

## [1.1.0] - 2026-09-07

### Added

- **`update.sh`: move between release tags on purpose.** It updates to the latest release (a combination this repository's CI has booted and smoke-tested), refuses to cross a major version unattended, refuses to run over local changes, and names any new required variable before anything has moved. `--dry-run` says what would happen.

## [1.0.0] - 2026-09-07

### Added

- **A Killing Floor 2 co-op server on LinuxGSM**, image pinned by digest as an
  interpolation default, so `git pull` delivers the build this repository has
  tested and `.env` overrides survive it. The tag is the game's name because
  LinuxGSM publishes every game under one image and no version: the digest is
  the version.
- **The query port carried under the same number inside and out**, written in
  both the instance config and the compose file, with the evening it cost
  recorded beside it: a remap on the outside sends Steam's directory to a
  port where another game answers, the handshake fails, and the server logs
  `Add unverified connection` and a timeout one second later.
- **A health check on the game binary with a bracket in the pattern.**
  `pgrep -f` matches the shell running the check, so the unbracketed form
  passed for every pattern ever given to it — measured — and a server that
  crashed with a core dump reported healthy for seventeen hours. The first
  version also matched LinuxGSM's wrapper and was green while SteamCMD was
  still downloading the game. `tests/e2e-healthcheck.sh` proves the bracket
  against a real container.
- **Six players as the engine's number, not a choice**, with the three ways
  eight was refused written down.
- **Survival, not versus**, and difficulty and length as their own variables
  in the instance config so a change survives the next restart.
- **The instance config outside the volume**, where git records it and
  LinuxGSM's own update cannot overwrite it.
- **WebAdmin bound to localhost**: the game has no rcon, and this form is the
  whole administrative interface.
- **The volume declared external**, so `docker compose down -v` cannot delete
  25 GB of game content and the server's state.
- **Deployment Verification CI**: shell and workflow linting, a Trivy scan of
  the pinned image, a daily freshness check on the pin, and the health-check
  suite. It deliberately does not boot the game: the first start is a 25 GB
  download.

[Unreleased]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.8.0...HEAD
[1.8.0]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.7.1...v1.8.0
[1.7.1]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.7.0...v1.7.1
[1.7.0]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.6.8...v1.7.0
[1.6.8]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.6.7...v1.6.8
[1.6.7]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.6.6...v1.6.7
[1.6.6]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.6.5...v1.6.6
[1.6.5]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.6.4...v1.6.5
[1.6.4]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.6.3...v1.6.4
[1.6.3]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.6.2...v1.6.3
[1.6.2]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.6.1...v1.6.2
[1.6.1]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.6.0...v1.6.1
[1.6.0]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.4.1...v1.5.0
[1.4.1]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.2.9...v1.3.0
[1.2.9]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.2.8...v1.2.9
[1.2.8]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.2.7...v1.2.8
[1.2.7]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.2.6...v1.2.7
[1.2.6]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.2.5...v1.2.6
[1.2.5]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.2.4...v1.2.5
[1.2.4]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.2.3...v1.2.4
[1.2.3]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.2.2...v1.2.3
[1.2.2]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/heyvaldemar/kf2-server-docker-compose/releases/tag/v1.0.0
