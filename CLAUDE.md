# CLAUDE.md — working notes for Claude Code in this repo

This is CBDE, the Container Based Development Environment for Cardano/Plinth
tooling. The repo is the **tool**, not a Cardano project: never run
`cbde matrix <name>` or `cbde devcontainer` inside this checkout (it would pin
the tool to itself), and it has no `.devcontainer/` of its own on purpose.

Read `README.md` → "Developing CBDE" before changing anything; it is the
authoritative description of layout, release flow and conventions. What
follows is the short version plus the things that bit us.

## Ground rules

- **The matrix file is the truth.** Every pin lives in `matrices/<version>.env`.
  The Dockerfile's `ARG` block mirrors only the newest matrix and the build
  fails on drift. Never change a pin in one place only. Moving any pin
  (including `CBDE_INDEX_STATE` / `CBDE_CHAP_INDEX_STATE`) means a new matrix
  file, never editing a published one.
- **One matrix = one image = one tag.** `cbde:<version>` is immutable;
  `latest` only moves when the newest matrix is built. Older matrices stay
  buildable: `cbde build --matrix <version>`.
- **The volume is a cache.** Anything under `/nix` may be rebuilt from the
  image on any start. Installers unpack beside the target and rename, so an
  interrupted start never leaves a half toolchain.
- **Seeds, not downloads.** GHC, cabal, Lean and the package indices come from
  `/opt/cbde/seed` in the image (`ghcup_install`, `lean_install`,
  `cabal_index_install` in `lib/matrix.sh`). A fresh volume with
  `--network none` must come up verified. Only project dependencies download.
- **Host scripts are bash 3.2.** `bin/cbde` and `lib/matrix.sh` run on macOS's
  stock bash: no `declare -A`, no `${var,,}`, no `mapfile`; empty arrays as
  `${a[@]+"${a[@]}"}`. Everything under `set -euo pipefail`: a failing
  command inside `$(...)` aborts silently — append `|| true` where failure is
  acceptable (this has bitten three times).
- **Matrix files are data**, read with `matrix_get`, never sourced.
- **Registry precedence**: `CBDE_REGISTRY` env → `~/.config/cbde/config`
  (`registry=`) → `ghcr.io/input-output-hk/cbde`. `cbde registry up/down`
  writes/removes the config line. `cbde matrix list` on the host merges local
  `cbde:*` images with the registry's tag list; it never asks an image.

## Before you say "done"

1. `tests/run` — all five suites, seconds, no Docker. Add a test for every
   behaviour you add; stubs live in `tests/stubs`, fixtures in `tests/fixtures`.
2. If you touched the Dockerfile, the provisioner or `lib/matrix.sh`, run the
   slow tier by hand:
   `docker run --rm --network none -v cbde-scratch:/nix cbde:latest bash -c 'ghc --version; lean --version; cbde matrix'`
   Every line must say "from the image (no download)"; verdict "verified".
   The stubs cannot catch a wrong assumption about a real tool (the Lean
   probe once read the wrong `elan` command; only a real run showed it).
3. `docker build --check .` lints the Dockerfile without building.
4. A full `cbde build` is 30–45 min; the final stage alone is ~2 min. Say
   which one you are starting and run it in the background.

## Working with Bogdan

- Discuss before building when the request is a question ("tell me", "don't
  act"). Act when asked, and say what you did in a few lines. Short answers.
- Don't commit or push unless asked; propose the message and wait.
- `install.sh` is POSIX sh (runs under `curl | sh`); `shellcheck -s sh` it.
- Private working docs are `*.ignore.*` (gitignored): the PRD copy,
  `DISCUSSION.ignore.md`, test dumps. This file is gitignored too.
- His registry/volume state on this machine is real: don't wipe `cbde-data`
  or the local registry without saying so; use `cbde-scratch` volumes.

## State snapshot (2026-09-22, evening)

Refresh this section when it drifts; `git log`, `tests/run`, `docker images cbde`
and `cbde registry status` are the sources.

- Branch `feat/curl-install` (installer work, off `feat/v2-allignment` at b7b0c27),
  recent commits:
  b7b0c27 refact: add .cbde into .gitignore
  d7df730 feat: local dev registry, per-user config, live matrix list
  a82b112 feat: compatibility matrices, image-seeded toolchains, unit tests
  1d16fd9 feat(macos): native multi-arch image, Rosetta only for nix x86_64
- Tests: 115 across six suites (`inner`, `install`, `launcher`, `matrix`, `repo`,
  `seed`). On this Mac two fail for reasons unrelated to the launcher
  (`matrix: test_validate_rejects_malformed_files` — `[!A-Z_]` accepts a
  lowercase key under the UTF-8 locale; `seed: test_index_corrupt_seed_falls_back_unless_strict`
  — a corrupt `.tar.xz` is not caught by the seed path); CI on Linux is the
  reference. shellcheck is not installed here. Sizes: `bin/cbde` ~700 lines,
  `cbde` ~575, `lib/matrix.sh` ~310, `cbde-provision` ~215.
- `cbde registry push` is multi-arch aware: pushes `cbde:T` as `$REGISTRY:T-<arch>`
  (arch from `docker image inspect`), probes `T-amd64`/`T-arm64` with
  `docker buildx imagetools inspect`, rewrites `T` with `imagetools create`
  from every arch tag present, reads it back. Prints a plan and asks; `--yes`
  when stdin is not a tty. `registry list` nests arch tags, `is_version`
  rejects them so `matrix list` ignores them. Local `cbde:<v>-<arch>` tags
  (from a `cbde pull 0.2.0-arm64`) are never pushed.
- Matrices: `0.2.0` (GHC 9.6.7, the real one) and `0.1.0` (GHC 9.6.6, exists
  to exercise switching; never becomes `latest`). Both differ only in GHC.
- Local images: `cbde:0.2.0` = `cbde:latest` and `cbde:0.1.0`, each 3.7 GB
  unpacked / ~1.14 GB compressed, seeds included. `cbde:base`, `cbde:next`
  and `cbde:pre-slim` (16.7 GB) are leftovers from before the matrices and
  can be removed.
- Local dev registry is **not running** and `~/.config/cbde/config` does not
  exist (cbde uses GHCR); its blobs are in volume `cbde-registry-data`
  (holds `0.2.0` index + `0.2.0-arm64` from the 2026-09-22 check). **Port 5000
  is taken by AirPlay Receiver on this Mac** (Control Center answers 403):
  use `CBDE_LOCAL_REGISTRY_PORT=5001` for `registry up/push/list/down`;
  `registry up` warns about it.
  The amd64 `0.2.0` is on GHCR, pushed from Linux before the multi-arch
  push existed; the arm64 side has not been pushed (Bogdan does that after
  review, with `CBDE_REGISTRY=ghcr.io/input-output-hk/cbde cbde registry push 0.2.0`).
- `.cbde` and `CLAUDE.md` are gitignored in this repo. The devcontainer
  template lives at `templates/devcontainer.json`; no `.devcontainer/` here.
- A fresh volume with `--network none` provisions GHC, cabal, Lean and the
  package indices from the image in ~60 s and reports verified (last checked
  2026-09-21 on `cbde:0.2.0`).

## Open decisions (as of 2026-09-22)

- Matrix should win on every start (provisioner `set`s pinned versions unless
  a "custom" marker exists) so switching images does not report custom.
- The volume-stamp warning ("initialized by CBDE x, image is y") is noise
  with shared volumes; downgrade or drop.
- Nix is not pinned in the matrix; its store path is shared via the volume.
- `cbde update` name collides with the PRD's meaning; rename pending.
- `install.sh` defaults to `input-output-hk/hades@main` (public). README's
  Install section deliberately carries the `feat/curl-install` URLs +
  `CBDE_REF=feat/curl-install` so testers can copy-paste; **before merging to
  main, change both back to `main` and drop `CBDE_REF=`** (grep
  `feat/curl-install` in README.md).
- Testers running `cbde doctor` will hit `ghcr.io/input-output-hk/cbde:latest`,
  which does not exist yet: nothing is published. Either publish first or tell
  them to build from a checkout.
- Remote pins for unpulled matrices in `cbde matrix list` could come from
  `docker buildx imagetools inspect` without pulling.
