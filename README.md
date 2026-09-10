# CBDE — Container Based Development Environment

Every Cardano smart-contract tool, in one container, without installing a
compiler on your machine. You need Docker. That is the whole prerequisite list.

```bash
cbde cabal build all        # build a Haskell/Plinth project
cbde plustan analyze        # static analysis on Plinth on-chain code
cbde aiken check            # check an Aiken project
cbde lean --version         # Lean 4 + Z3, for Blaster proofs
cbde doctor                 # is everything wired up correctly?
```

Those run in the container against the project in your current directory. No
`docker` in sight — but that is exactly what they are, and
[How it works](#how-it-works) shows you the command each one expands to.

- **[Install](#install)** · **[How it works](#how-it-works)** · **[Quick start](#quick-start)**
- **[What's in the box](#whats-in-the-box)** — every pinned version
- **[The tools, one by one](#the-tools-one-by-one)** — Haskell/Plinth · plustan · Aiken · Blaster · Nix · PBT
- **[Switching versions](#switching-toolchain-versions)** · **[VS Code](#vs-code-dev-containers)** · **[Your own user](#running-as-your-own-user)**
- **[macOS (Apple Silicon)](#macos-apple-silicon)** · **[Updating and removing](#updating-and-removing)** · **[Gotchas](#gotchas)** · **[Reference](#reference)**

## Install

> 🚧 **Placeholder.** The one-liner below is the shape of the installer, not a
> live URL — the repo is not published yet, so nothing is served at that
> address. Until it is, use [from a checkout](#install-from-a-checkout).

```bash
curl -fsSL https://raw.githubusercontent.com/input-output-hk/cbde/main/install.sh | sh
```

That will drop the `cbde` launcher into `~/.local/bin`, pull the image, and
create the volume. Then:

```bash
cbde doctor       # confirm it works
```

To remove everything again — launcher, image, and the volume with every cached
toolchain in it — there is one verb, and it means what it says:

```bash
cbde self-destruct
```

> 🚧 Also a placeholder. `cbde self-destruct` and `cbde upgrade` currently
> print what they _will_ do plus the manual commands to do it today. See
> [Updating and removing](#updating-and-removing).

### Install from a checkout

```bash
git clone <this repo> ~/iog/cbde
cd ~/iog/cbde
ln -s "$PWD/bin/cbde" ~/.local/bin/cbde    # put the launcher on PATH
cbde pull                                  # ghcr.io/input-output-hk/cbde:latest -> cbde:latest
cbde doctor
```

The image is multi-arch (amd64 and arm64); `docker pull` picks your host's.
Building it yourself instead (`cbde build`, ~15–30 min) works on either.

## How it works

Three facts explain every behaviour in this README. If you read nothing else,
read these.

### 1. `cbde` is a thin wrapper around `docker run`

The launcher exists so that daily use is four words instead of forty. Every
command has a plain-Docker equivalent, and you can always use it instead:

```bash
cbde cabal build all
```

is exactly:

```bash
docker run --rm -it \
  -v cbde-data:/nix \
  -v "$PWD:/workspace" -w /workspace \
  cbde:latest cabal build all
```

What the wrapper adds is only convenience: it picks the directory to mount,
attaches the volume, passes `-it` only when you actually have a terminal, and
forwards `CBDE_*` variables.

**Which directory it mounts** is the one rule worth reading twice. If you are
inside a git repository it mounts the **repository root**, not your current
directory, and preserves where you were standing:

```bash
-v "$(git rev-parse --show-toplevel):/workspace" -w /workspace/packages/foo
```

That is deliberate: run `cabal build` from `packages/foo/src` and a `$PWD`-only
mount would hide the `cabal.project`, the `.hie` directory, sibling packages and
submodules the build needs. Outside a repository it falls back to `$PWD`.

The catch is that it searches _upwards_, so a parent repository wins — in a
monorepo you mount the whole monorepo, and if your `$HOME` is itself a git
repository (a common dotfiles pattern) you would mount your entire home
directory. `cbde info` always tells you what it resolved, so check it if a
project is not where you expect:

```console
$ cbde info
image      cbde:latest
volume     cbde-data
project    /home/you/work/my-contract  ->  /workspace
workdir    /workspace
```

Two containers, one name: `cbde` on your host is the launcher; `cbde` **inside**
the container is a version manager for the toolchains. The launcher forwards
the version verbs (`ghc`, `hls`, `lean`, `list`, `doctor`, `devcontainer`,
`update`) to the inner one, and treats everything else as a command to run.
So `cbde ghc 9.6.6` switches GHC, while `cbde cabal build` builds. The one
casualty of that rule is cabal: since `cabal` has to stay the tool, switching
cabal _versions_ from the host is `cbde cabal-version 3.12.1.0`.

### 2. You need one persistent volume, mounted at `/nix`

**This is not optional for Haskell or Lean work.** Neither toolchain is baked
into the image — together they were 8 GB — so without somewhere persistent to
put them, there is nowhere to install them at all. You get a clear error rather
than a mystery.

Everything worth keeping lives under `/nix`: the Nix store, GHC, cabal, the
Lean toolchain, the cabal package store, and the Hackage/CHaP indices. One
named volume covers all of it:

```bash
-v cbde-data:/nix
```

The launcher does this for you. Use a **named volume** (a bare name like
`cbde-data`), not a host path — a host bind mount will not do, because Nix
refuses to work through a symlinked or foreign-owned store.

```bash
cbde volume info     # where it is, how big it has grown
cbde volume rm       # delete it (asks first) — everything re-downloads
```

Sizing: it starts at 6.5 GB after the first run and grows with use — the Nix
store and the compiled cabal dependencies of your projects both land there. A
volume that has built `sc-testing-tools` a few times can reach 25–30 GB. It is
a cache, so deleting it costs time, never data.

Skipping the volume is fine only for the tools that need no toolchain: `aiken`,
`z3` and `nix` run happily without it.

### 3. The first run downloads the pinned toolchains

The image ships version _pins_, not the toolchains themselves. The first
container start against an empty volume installs exactly what those pins ask
for, then never does it again. It is idempotent, holds a lock so two containers
can share one volume, and is silent when there is nothing to do.

| Installed on first run                    | Pinned version             | Why it is not in the image                                   |
| ----------------------------------------- | -------------------------- | ------------------------------------------------------------ |
| **GHC**                                   | 9.6.7                      | 2.6 GB installed; also the version users most want to change |
| **cabal**                                 | 3.10.3.0                   | pairs with the GHC pin                                       |
| **Lean toolchain** (`lean`, `lake`)       | `leanprover/lean4:v4.24.0` | 2.3 GB installed                                             |
| **Hackage index**                         | latest                     | ~1 GB, and rewriting it copies the whole layer               |
| **CHaP index** (Cardano Haskell Packages) | latest                     | same                                                         |
| **HLS** (language server)                 | _on request only_          | 2.5 GB; run `cbde hls` when you want IDE support             |

Measured on a fresh volume: **136 seconds**, after which the volume holds
**6.5 GB** — GHC and cabal 2.6 GB, the Lean toolchain 2.3 GB, the two package
indices 1.2 GB, the image's Nix store the rest. Once, ever. Every later start
costs about half a second.

If you never touch Blaster, skip the Lean install entirely with `-e CBDE_LEAN=`
and save 2.3 GB and about a minute.

Because the pins live in the _image_, pulling a newer CBDE against an existing
volume installs whatever it newly needs — you do not have to recreate anything.

## Quick start

```bash
cd ~/my-plinth-project

cbde doctor                       # first run: installs the toolchains, ~3 min
cbde cabal build all              # build
cbde plustan analyze --report     # analyse the on-chain code, writes stan.html
cbde                              # or just get a shell and poke around
```

Inside the shell everything is on `PATH`: `cabal`, `ghc`, `plustan`,
`aiken`, `lean`, `lake`, `z3`, `nix`, `node`, `jq`.

## What's in the box

Image `cbde:0.2.0` — **505 MB to pull, 1.79 GB unpacked** (budget ~2.3 GB of
disk: Docker's containerd snapshotter keeps the compressed layers too).

|                      | Version                                                                | Notes                                                                                                            |
| -------------------- | ---------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| **plustan**          | Stan 0.2.5.0 (`6971d58`)                                               | built from [plu-stan](https://github.com/input-output-hk/plu-stan) `main` against GHC 9.6.7, flags `-f-fixtures` |
| **Aiken**            | v1.1.23                                                                | static musl binary, no dependencies                                                                              |
| **Blaster**          | [Lean-blaster](https://github.com/input-output-hk/Lean-blaster) `main` | prebuilt checkout at `/opt/blaster`                                                                              |
| **Z3**               | 4.15.2                                                                 | built from source; Blaster's SMT backend                                                                         |
| **Lean / Lake**      | 4.24.0 / 5.0.0                                                         | _installed into the volume on first run_                                                                         |
| **GHC**              | 9.6.7                                                                  | _installed into the volume on first run_                                                                         |
| **cabal**            | 3.10.3.0                                                               | _installed into the volume on first run_                                                                         |
| **HLS**              | latest for your GHC                                                    | _on request:_ `cbde hls`                                                                                         |
| **ghcup**            | 0.2.6.2                                                                | `ghcup tui` works if you prefer it                                                                               |
| **Nix**              | 2.35.2                                                                 | single-user, flakes on, `cache.iog.io` + `sc-testing-tools.cachix.org`                                           |
| **Node.js** / **jq** | 18.19.1 / 1.7                                                          | for tooling scripts (PBT test discovery)                                                                         |
| **libsodium**        | IOG fork `dbb48cc`                                                     | upstream lacks `crypto_vrf_*_batchcompat`                                                                        |
| **libsecp256k1**     | `ac83be3`                                                              | IOG-pinned revision                                                                                              |
| **blst**             | v0.3.14                                                                | `cardano-crypto-class` requires ≥ 0.3.14                                                                         |
| system deps          | —                                                                      | build-essential, libsystemd, liblmdb, zlib, gmp, ffi, ncurses, numa                                              |

**Plinth** is deliberately absent from that list as a binary, because it is not
one: it is the `plutus-tx-plugin` GHC plugin, so "having Plinth" means having
GHC 9.6 + cabal + CHaP + the crypto libraries above. That is precisely what
this image is.

## The tools, one by one

### Haskell, Plinth, cabal

Ordinary cabal, with the Cardano system dependencies already solved — the
libsodium fork, secp256k1 and blst that otherwise cost an afternoon.

```bash
cbde cabal update              # refresh the package index
cbde cabal build all
cbde cabal test all
cbde cabal repl
cbde run cabal build --builddir=dist-newstyle-docker   # see the note below
```

The compiled dependency store lives in the volume, so a `--rm` container is
still incremental: the second build reuses the first one's work.

**If you also build on the host**, give the container its own build directory.
`dist-newstyle` is shared through the bind mount, but the two sides use
different GHC installs and will invalidate each other's build plan on every
alternation:

```bash
cbde cabal build all --builddir=dist-newstyle-docker
```

A project pinning a different compiler needs no ceremony — `cbde ghc 9.6.6`
installs it, and cabal honours the project's own `with-compiler:` because
ghcup also provides a versioned `ghc-9.6.6` binary.

### plustan — Plinth static analysis

`plustan` reads the `.hie` files GHC emits and reports findings on your
on-chain code. It drives `cabal build` in the project itself, so point it at a
project and go:

```bash
cbde plustan analyze                    # human-readable findings
cbde plustan analyze --report           # also writes stan.html
cbde plustan analyze --json             # machine-readable
cbde plustan analyze --module MyScript.OnChain    # one module
cbde plustan list-onchain               # what it considers on-chain code
```

| Flag            | Effect                                          |
| --------------- | ----------------------------------------------- |
| `--report`      | write `stan.html`                               |
| `--browse`      | open the report (implies `--report`)            |
| `--json`        | machine-readable output                         |
| `--module NAME` | analyse one on-chain module, by GHC module name |
| `--project DIR` | change into `DIR` first                         |
| `--hiedir DIR`  | where the `.hie` files are (default `.hie`)     |

**The one rule to remember**: plustan can only analyse code built by the GHC it
was compiled against — **9.6.7** here — because the `.hie` format is locked to
the exact GHC patch version. If a project carries `.hie` files built by another
GHC (typically because you built on the host first), plustan fails with
`fromHieName: unknown known-key unique`. Fix it by clearing them:

```bash
cbde run rm -rf .hie dist-newstyle
```

`cbde ghc <other-version>` warns you about this when you switch.

### Aiken

A standalone compiler with no dependencies — this one works with or without the
volume.

```bash
cbde aiken new myorg/myproject
cd myproject
cbde aiken check
cbde aiken build
cbde aiken --version
```

`cd` on your host, as usual — the container's working directory follows yours,
so `cbde <anything>` runs where you are standing.

### Blaster — Lean 4 proofs with an SMT backend

The image carries a prebuilt Blaster at `/opt/blaster` plus Z3 4.15.2. Smoke
test that the pair works:

```console
$ cbde run lake --dir=/opt/blaster exe z3check
Successfully ran z3:
Z3 version 4.15.2 - 64 bit
```

To use the `blaster` tactic in **your own** Lean project, copy the checkout
into your project and depend on the copy. The copy is required — `/opt/blaster`
is root-owned and Lake needs to write lock files into a dependency, so
requiring it directly fails with `permission denied … lakefile.olean.lock`:

```bash
mkdir -p vendor                               # on your host
cbde run cp -r /opt/blaster vendor/blaster    # ~272 MB, once
```

```lean
-- lakefile.lean
import Lake
open Lake DSL

require Blaster from "vendor/blaster"

package «demo» where

@[default_target]
lean_lib «Demo» where
```

Your `lean-toolchain` must match the toolchain Blaster was built with, or Lake
will fetch a second one:

```bash
cbde run cp /opt/blaster/lean-toolchain .
```

Then the tactic works, with Z3 doing the actual proving:

```lean
import Blaster

example (a b : Int) : a + b = b + a := by blaster
-- ✅ Valid
-- warning: declaration uses 'blasterProven' (SMT-verified, no proof term)
```

```bash
cbde lake build
```

If you switch Lean with `cbde lean`, the prebuilt artifacts no longer match —
rebuild your vendored copy: `cd vendor/blaster && cbde lake build`.

### Nix mode

Some projects — notably `sc-testing-tools` — only officially support building
inside `nix develop`. Nix works inside the container (single-user, flakes
enabled, IOG substituters configured), and `cbde nix` is the shorthand:

```bash
cbde nix cabal build all       # = nix develop -c cabal build all
cbde nix cabal test all
cbde run nix develop           # interactive dev shell
cbde run nix flake show
```

The same volume persists the Nix store, so the dependency closure is downloaded
once rather than on every `--rm` run. Configured substituters make the
difference between minutes and hours: `cache.iog.io` and
`sc-testing-tools.cachix.org`.

### PBT (sc-testing-tools)

PBT is a set of Haskell _libraries_, not a CLI — you consume it from your own
`cabal.project`. What the image provides is the toolchain, the system
dependencies, and Nix for the project's supported path, plus the Node.js and
jq its scripts need.

Test discovery (used by the VS Code extension) needs each project's own Node
dependencies installed once, since they live in the workspace rather than the
image:

```bash
cbde run ./scripts/pre-fetch.sh install
cbde run ./scripts/pre-fetch.sh --check-health   # reports what's missing
```

`sc-testing-tools` pins GHC **9.6.6** in its `cabal.project`. Install it and
cabal will pick it up on its own:

```bash
cbde ghc 9.6.6
cbde nix cabal test all
```

## Switching toolchain versions

`cbde` is the front end for anything version-shaped. Everything it installs
lands in the volume, so it is downloaded once and shared by every later
container.

```bash
cbde list                            # what's installed, what's active
cbde ghc                             # which GHC am I using?
cbde ghc 9.6.6                       # install if needed, then switch
cbde cabal-version 3.12.1.0          # same for cabal (note the verb)
cbde hls                             # language server for the active GHC
cbde lean                            # which Lean toolchain is active?
cbde lean leanprover/lean4:v4.24.0   # install/switch Lean
cbde update                          # refresh ghcup's list of available versions
cbde doctor                          # check this container and volume
```

Known pins worth having on hand:

| Project                     | Wants                                               |
| --------------------------- | --------------------------------------------------- |
| plu-stan / plustan analysis | GHC 9.6.7 (the image default)                       |
| sc-testing-tools            | GHC 9.6.6 (`with-compiler:` in its `cabal.project`) |

Two version constraints fail confusingly, so both are worth knowing:

- **plustan is locked to the GHC that built it** (9.6.7) — see
  [plustan](#plustan--plinth-static-analysis).
- **HLS ships one server binary per GHC version**, and a given HLS release
  covers only some of them: HLS 2.14 has a server for 9.6.7 but _not_ 9.6.6.
  `cbde hls` and `cbde doctor` tell you when the pair cannot work.

Prefer a TUI? `ghcup tui` is in there too — `cbde` is a convenience layer over
ghcup, not a replacement for it.

## VS Code Dev Containers

VS Code can attach directly into the container, with the extensions installed
container-side. From inside your project:

```bash
cbde devcontainer          # writes .devcontainer/devcontainer.json
```

Then in VS Code: **Ctrl+Shift+P → Dev Containers: Reopen in Container**.

The file is version-stamped, never overwritten silently (it asks, and keeps a
`.bak`), and `cbde doctor` tells you when your project's copy is older than the
image's. The `/nix` volume is already wired up in the template.

| Extension            | For                                                        |
| -------------------- | ---------------------------------------------------------- |
| `haskell.haskell`    | HLS — run `cbde hls` first, it is not installed by default |
| `IOG.vscode-plustan` | plu-stan                                                   |
| `IOG.pbt-extension`  | PBT / sc-testing-tools — needs **VS Code ≥ 1.118**         |
| `leanprover.lean4`   | Lean / Blaster                                             |
| `TxPipe.aiken`       | Aiken                                                      |

The same list is baked into the image as a `devcontainer.metadata` label, so the
image is self-describing even without the template file.

For PBT test discovery, remember the per-project Node dependencies
(`./scripts/pre-fetch.sh install`, see [PBT](#pbt-sc-testing-tools)).

> **Caveat, honestly**: dev-container mode uses the documented
> `remoteUser` + `updateRemoteUserUID` mechanism, but has not yet been verified
> in a real VS Code session. If the uid mapping misbehaves, please report it —
> CLI mode is the well-tested path today. Known limit: `updateRemoteUserUID`
> only acts on Linux hosts, so on macOS the dev container always runs as
> `cbde` (uid 1000). That is fine there — see [macOS](#macos-apple-silicon).

## Running as your own user

Everything the container writes into your project — `dist-newstyle`, `.hie`,
Aiken's `build/`, `.lake` — comes out owned by **you**, not by root. Nothing to
pass, nothing to configure:

```bash
cbde cabal build      # the files it creates are yours
```

The container starts as root, reads the uid/gid owning the mounted project,
takes ownership of the volume once, then drops to that user before running your
command. The uid is discovered at run time and never baked into the image, so
one published image serves everybody.

- `-e CBDE_UID=1234 -e CBDE_GID=1234` overrides the detection.
- `--user "$(id -u):$(id -g)"` is honoured as-is, but skips the automatic path,
  so the volume must already be owned by that user. Prefer the automatic path.
- With **no** project mounted, the container stays root.
- The first run on a volume prints `handing /nix to uid …` and takes a moment
  (it is thousands of files). It is recorded and never repeated.
- On Docker Desktop, Colima and OrbStack (macOS/Windows) ownership is
  _virtualised_: the mount looks root-owned from inside, yet any uid may write
  to it and files come out as you on the host. There the container adopts the
  image's `cbde` user (uid 1000) instead — not root — so that CLI runs and the
  VS Code dev container (which always runs as `cbde` on macOS) share one owner
  of the volume. `cbde doctor` reports this as "ownership is virtualised".
- A root-owned mount that uid 1000 _cannot_ write to is a Linux host really
  running as root (CI, say); the container stays root there.

`cbde doctor` reports which user you are and whether new files will be yours.

## macOS (Apple Silicon)

The image is native arm64 on Apple Silicon (and any aarch64 Linux host): GHC,
cabal, plustan, aiken, Lean, Z3 and Nix all run at full speed, nothing is
emulated. Docker picks the right architecture on `pull`; `cbde build` builds
the native one in ~30 minutes.

**Nix and the IOG caches.** Nix runs natively as `aarch64-linux`, and IOG's
binary caches (`cache.iog.io`, `sc-testing-tools.cachix.org`) publish
`x86_64-linux` only. A project that depends on them — `sc-testing-tools` — would
build its whole GHC closure from source natively. Instead, tell Nix to use the
x86_64 closure:

```bash
cbde run nix develop --system x86_64-linux -c cabal build all
```

The arm64 image's `nix.conf` has `extra-platforms = x86_64-linux aarch64-linux`,
so Nix accepts that, substitutes everything from the caches, and the x86_64
binaries run through the Docker VM's Rosetta binfmt — GHC included, at roughly
half native speed for your own code. That needs **Rosetta enabled in your
Docker runtime**; it is not always the default:

| Runtime        | Rosetta                                                                             |
| -------------- | ----------------------------------------------------------------------------------- |
| Docker Desktop | Settings → General → _Use Rosetta for x86_64/amd64 emulation on Apple Silicon_       |
| Colima         | `colima stop && colima start --vm-type vz --vz-rosetta` (Colima defaults to `rosetta: false`) |
| OrbStack       | on by default                                                                       |

`cbde doctor` runs a tiny x86_64 probe and reports under **Platform** whether
this works. Without it everything native still works; only `--system x86_64-linux`
is unavailable. (Nix's seccomp filter cannot load under Rosetta, so the image
sets `filter-syscalls = false`; that only affects setuid bits inside builds.)

**Give the VM enough memory and CPUs.** The container lives in a Linux VM sized
by the runtime, not by your Mac. Colima's default is **2 CPUs / 2 GB**, Docker
Desktop's often 4 GB — both too small. Building the plutus dependencies needs
8 GB; compiling your own `plutus-tx-plugin` modules needs more — a single GHC
process on a real validator was measured at 10.7 GB and OOM-killed in a 12 GB
VM. Give it 16 GB or more:

```bash
colima stop && colima start --cpu 8 --memory 16      # Docker Desktop: Settings → Resources
```

The virtual disk must hold the image (~2.3 GB) plus the volume (6.5 GB after the
first run, 25–30 GB after building `sc-testing-tools` a few times). `cbde doctor`
reports what the container actually sees and fails under 8 GB. If a build dies
with "The build process was killed (i.e. SIGKILL)", it was the VM's OOM killer:
more memory, or `cabal build -j1`.

Smaller things:

- **Bind mounts are slow.** Your project is shared into the VM over VirtioFS;
  `dist-newstyle` and `.hie` there are the slow path. `--builddir=dist-newstyle-docker`
  helps (you want it anyway if you also build on the host — [gotcha 3](#gotchas)).
  The `/nix` volume is native to the VM and fast.
- **Ownership is virtualised** on the mount: the container adopts uid 1000 and
  files come out as you. See [Running as your own user](#running-as-your-own-user).
- **`cbde volume info` prints a mountpoint inside the VM.** It does not exist on
  the Mac; cosmetic.
- **Docker Desktop shares only some directories** by default (`/Users`, `/Volumes`,
  `/private`, `/tmp`, `/var/folders`); a project elsewhere fails with "mounts
  denied" — add its parent under Settings → Resources → File sharing. Colima
  shares `$HOME` (`mounts:` in its config), and nothing else: `/tmp` is not shared.
- **Symlinked paths.** macOS's `/tmp` and `/var` are symlinks into `/private`; the
  launcher resolves them (`pwd -P`) so `cbde info`'s `workdir` is right.
- **`CBDE_PLATFORM=linux/amd64`** runs the x86_64 image under Rosetta instead.
  It works (`cbde doctor` says so), it is just 2–3× slower; only useful for
  reproducing an x86_64-only problem.

## Updating and removing

> 🚧 **Both verbs below are placeholders.** They print what they will do and
> the manual equivalent; the real implementation lands in a future release.

```bash
cbde upgrade          # update the launcher, pull the newest image
cbde self-destruct    # remove the launcher, the image, and the volume
```

`cbde upgrade` will re-run the installer and `docker pull` the current image
tag. Note that it is _not_ `cbde update`, which is the in-container verb for
refreshing ghcup's list of installable versions — different thing entirely.

`cbde self-destruct` will take the whole thing with it: the `cbde` launcher on
your PATH, the `cbde:*` images, and the `cbde-data` volume with every cached
toolchain, Nix store path and compiled dependency in it. It will ask first. It
will not touch your projects.

Meanwhile, by hand:

```bash
# update
cbde pull                        # ghcr.io/input-output-hk/cbde:latest -> cbde:latest
cd ~/iog/cbde && git pull        # for the launcher (and `cbde build` on Linux)

# remove
docker rmi cbde:latest cbde:base
docker volume rm cbde-data
rm ~/.local/bin/cbde
```

Note that upgrading the image against an existing volume is safe and expected:
the new image's pins are provisioned on the next start.

## Gotchas

1. **Docker only seeds _empty_ volumes.** A `cbde-data` volume created by an
   older image keeps shadowing the new image's `/nix` content forever. GHC,
   cabal and Lean self-heal (they are provisioned, not baked), but baked
   content — the 489 MB Nix store in the image — does not. The container
   records which version created the volume and warns on a mismatch; the fix is
   `cbde volume rm`.
2. **cabal's legacy layout depends on a live symlink.** `/root/.cabal` is a
   symlink into the volume, so cabal uses `/root/.cabal/store`, not
   `~/.local/state/cabal`. If that symlink ever dangles, cabal 3.10 silently
   switches layouts to paths _inside_ the container, which `--rm` throws away —
   the symptom is a 1 GB index re-download and a full rebuild on every run. The
   usual cause is mounting the wrong volume at `/nix`. `cbde doctor` checks it.
3. **Host/container `dist-newstyle` sharing invalidates cabal plans** — use
   `--builddir=dist-newstyle-docker` when you also build on the host.
4. **Stale `.hie` files break plustan** — `rm -rf .hie dist-newstyle`, or give
   container runs their own git worktree.
5. **Blaster cannot be required straight from `/opt/blaster`** — it is
   root-owned and Lake writes lock files into dependencies. Copy it into your
   project first; see [Blaster](#blaster--lean-4-proofs-with-an-smt-backend).
6. **Never install upstream `libsodium-dev`** in a derived image — it outranks
   the IOG fork and breaks `cardano-crypto-praos` linking with missing
   `crypto_vrf_*_batchcompat` symbols.
7. **`cabal list-bin` re-runs the solver** — pass matching `--flags=-fixtures`
   when querying plustan paths.

## Reference

### Environment variables

| Variable                | Default                    | Effect                                                                |
| ----------------------- | -------------------------- | --------------------------------------------------------------------- |
| `CBDE_GHC`              | `9.6.7`                    | GHC version provisioned on start                                      |
| `CBDE_CABAL`            | `3.10.3.0`                 | cabal version provisioned on start                                    |
| `CBDE_HLS`              | _(empty)_                  | when set, HLS version provisioned on start                            |
| `CBDE_LEAN`             | `leanprover/lean4:v4.24.0` | Lean toolchain provisioned on start; empty to skip its 2.3 GB install |
| `CBDE_UID` / `CBDE_GID` | _(from the mount)_         | user to run as; overrides detection                                   |
| `CBDE_SKIP_PROVISION`   | —                          | `1` skips provisioning entirely (CI)                                  |
| `CBDE_FORCE_PROVISION`  | —                          | `1` provisions even with no volume mounted                            |

Launcher-side (host):

| Variable           | Default       | Effect                                                          |
| ------------------ | ------------- | --------------------------------------------------------------- |
| `CBDE_IMAGE`       | `cbde:latest` | which image to run                                              |
| `CBDE_VOLUME`      | `cbde-data`   | which volume to mount at `/nix`                                 |
| `CBDE_PLATFORM`    | _(native)_    | force a platform on `docker run`/`pull`/`build`, e.g. `linux/amd64` on Apple Silicon (emulated) |
| `CBDE_REGISTRY`    | `ghcr.io/input-output-hk/cbde` | where `cbde pull` fetches from                 |
| `CBDE_DOCKER_ARGS` | —             | extra `docker run` flags, e.g. `'-p 8080:8080 -v ~/data:/data'` |

### Launcher commands

| Command                                       | Does                                                         |
| --------------------------------------------- | ------------------------------------------------------------ |
| `cbde`                                        | interactive shell in the container                           |
| `cbde <cmd> …`                                | run a command (`cbde cabal build all`)                       |
| `cbde run <cmd> …`                            | same, explicit — use when `<cmd>` collides with a verb below |
| `cbde nix <cmd> …`                            | run inside `nix develop`                                     |
| `cbde list` / `doctor` / `update`             | forwarded to the in-container `cbde`                         |
| `cbde ghc` / `hls` / `lean` / `cabal-version` | version switching                                            |
| `cbde devcontainer`                           | write `.devcontainer/devcontainer.json` here                 |
| `cbde pull [tag]`                             | pull `$CBDE_REGISTRY:<tag>` and name it `cbde:latest`        |
| `cbde build [docker args]`                    | build the image from the checkout, for the host's architecture |
| `cbde volume [info\|rm]`                      | inspect or delete the volume                                 |
| `cbde info`                                   | show resolved image, registry, volume, platform and paths    |
| `cbde upgrade` / `self-destruct`              | 🚧 placeholders, see [above](#updating-and-removing)         |

### Building the image yourself

```bash
docker build --target base -t cbde:base .   # system layer only
docker build -t cbde:latest .               # everything
cbde build                                  # same, from anywhere
```

The Dockerfile is multi-arch: it builds natively for `amd64` and `arm64`
(`TARGETARCH` selects the ghcup and aiken downloads; everything else compiles
from source). Cross-building with `--platform` works but runs the compilers
under emulation for hours — build native and let CI produce the other half.
CI (`.github/workflows/docker.yml`) builds both on native runners and pushes a
multi-arch manifest to `ghcr.io/input-output-hk/cbde:<version>` and `:latest` on
every push to `main` — the GHCR package has to be public for `cbde pull` to
work without `docker login ghcr.io`.

| Image         | To pull | Unpacked |
| ------------- | ------- | -------- |
| `cbde:latest` | 505 MB  | 1.79 GB  |
| `cbde:base`   | 361 MB  | 1.31 GB  |

`cbde:base` is a build convenience (`--target base`), not something users pull:
the final image is built `FROM base`, so base's layers are already the first
layers of `cbde:latest`. Pulling `cbde:latest` gets everything in one download.

Pins are build arguments — `--build-arg CBDE_GHC=9.6.6`,
`--build-arg AIKEN_VERSION=v1.1.24`, and so on; see the `ARG`s at the top of the
`Dockerfile`.

---
