# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.2.1...HEAD
[1.2.1]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/heyvaldemar/kf2-server-docker-compose/releases/tag/v1.0.0
