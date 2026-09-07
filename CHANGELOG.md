# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

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

[Unreleased]: https://github.com/heyvaldemar/kf2-server-docker-compose/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/heyvaldemar/kf2-server-docker-compose/releases/tag/v1.0.0
