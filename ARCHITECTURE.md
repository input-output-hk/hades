# CBDE: System Architecture and Design

Input Output Group (IOG)
Container-Based Development Environment (CBDE)

| Field                    | Value                                                                                 |
| ------------------------ | ------------------------------------------------------------------------------------- |
| Document owner           | Bogdan Manole                                                                         |
| Status                   | Draft 0.2, October 9, 2026, for internal review                                       |
| Companion to             | 'Container-Based Development Environment', product requirements document, version 2.0 |
| Research prototype       | CBDE repository, compatibility matrix 0.2.0                                           |

## Summary

CBDE gives a Plinth developer a verified toolchain behind one command. Docker is the only thing to install.

The design rests on three parts that stay separate on purpose: a small launcher on the host, one immutable image per verified set of tools, and one persistent volume that caches the heavy toolchains. A compatibility matrix, a short file of version pins, is the single source of truth. It drives the image build, travels inside the image, and is checked against the running toolchain on every start.

Editors attach through the Dev Container standard. The portfolio's editor extensions install inside the container, next to the binaries they drive. Images are built natively for amd64 and arm64 Linux and published to a container registry under immutable tags.

The design is grounded in a research prototype that exercises it end to end on Linux and macOS. The body of this document describes the target system as one piece; section 27 separates what the research prototype validated from what remains to be built, and section 25 lists the points left open on purpose, each with the constraint that will decide it.

## How to read this document

Four parts, each building on the previous one.

- **Part I** shows the environment as a developer sees it. Few concepts, no internals.
- **Part II** opens the box: the matrix, the image, the volume, the start sequence, projects, tools, editors, and Nix.
- **Part III** covers production: how an image is built, tested, published, installed, and composed into profiles.
- **Part IV** is reference: requirements traceability, design clarifications, decisions, open points, risks, what the research prototype validated, and a glossary.

Sizes and timings in the body are baseline figures measured in the research prototype at matrix 0.2.0 (GHC 9.6, Lean 4.24). They are expectations for a matrix of that generation and become budgets only where the requirements of section 22 say so.

Command names and options, `cbde matrix`, `cbde ghc`, `cbde devcontainer`, and the rest, are shown as they were used in the research prototype. They illustrate responsibilities, not a final command surface: commands may be changed, merged, or removed through future change requests. Section 10 maps them to the PRD's verbs, and section 25 keeps the naming open.

Five terms carry the document. A **compatibility matrix** (or matrix) is a named, versioned set of tool versions verified to work together, stored as one file. An **image** is the container image built from one matrix. The **volume** is the persistent Docker volume that caches installed toolchains. A **seed** is a compressed installer carried inside the image. The **launcher** is the `cbde` script on the host. The glossary in section 28 has the rest.

---

# Part I. The environment from the developer's seat

## 1. One command

A developer installs Docker and one shell script. From then on, every tool runs inside a container against the project in the current directory:

```bash
cbde cabal build all        # build a Plinth project
cbde plustan analyze        # static analysis of the on-chain code
cbde lake build             # Lean 4, for Blaster proofs
cbde aiken check            # an Aiken project
cbde doctor                 # is everything wired up?
```

Nothing from the toolchain lands on the host: no GHC, no cabal, no Nix, no Lean. What does land is the project's own build output, owned by the developer, exactly as if the tools had run locally.

The script arrives with one line and does nothing until it is used:

```bash
curl -fsSL https://raw.githubusercontent.com/input-output-hk/hades/main/install.sh | sh
cbde doctor                 # first run: pulls the image, fills the volume
```

The first command pulls the image and fills the volume. From the second command on, a container starts in about half a second.

Why this matters: the setup burden the PRD describes can only be removed at the host. The container is where version alignment lives, and the developer never has to reason about it.

## 2. Three facts that explain everything else

### 2.1 The launcher is a thin wrapper around `docker run`

`cbde cabal build all` is exactly:

```bash
docker run --rm -it \
  -v cbde-data:/nix \
  -v "$PWD:/workspace" -w /workspace \
  cbde:0.2.0 cabal build all
```

The launcher adds convenience only. It picks the directory to mount, attaches the volume, passes a terminal only when there is one, forwards `CBDE_*` settings, chooses the image the project is pinned to, and names the container after its matrix so parallel runs are told apart in `docker ps`. Anyone can bypass it and call Docker directly; the behavior is identical. That is a design goal: nothing to learn blindly, nothing to trust blindly.

```
 host                                          container
 ──────────────────────────────────────────    ─────────────────────────────────────
 cbde cabal build all
   │ resolve: project root, pin -> image,
   │          volume, platform
   ▼
 docker run --rm -it
   -v cbde-data:/nix                   ────►   /nix         the cache volume
   -v <project root>:/workspace        ────►   /workspace   the project, as your user
   cbde:0.2.0 cabal build all          ────►   entrypoint:  adopt uid, provision, exec
```

### 2.2 One persistent volume holds everything heavy

The image does not contain GHC, cabal, or the Lean toolchain. Together they weigh about 8 GB unpacked, and baking them in would make every pull, every update, and every profile pay that price. Instead they live in one named Docker volume mounted at `/nix`, together with the Nix store, the cabal package store, and the package indices. The launcher attaches it on every run.

The volume is a cache. Nothing in it is precious: every start may rebuild any part of it from the image, and deleting it costs time, never data. It holds about 6.5 GB after the first start and grows with the projects built in it.

### 2.3 The first start unpacks pinned toolchains from the image, with no network

The image carries the compressed installers, the seeds, of its own matrix: the GHC and cabal distributions, the Lean toolchain, and the Hackage and CHaP package indices at the matrix's pinned snapshot dates. About 680 MB in the image; about 6 GB in the volume once unpacked. The first start against an empty volume installs exactly what the matrix pins, from the image, and never again. A fresh volume comes up verified with networking disabled. Only the project's own dependencies download, on the first `cabal build`, as they would anywhere.

| Installed on first start        | Example (matrix 0.2.0)              | Source             | In the volume       | Time       |
| ------------------------------- | ----------------------------------- | ------------------ | ------------------- | ---------- |
| GHC                             | 9.6.7                               | image, 203 MB seed | 2.6 GB (with cabal) | about 45 s |
| cabal                           | 3.10.3.0                            | image, 5 MB seed   |                     | seconds    |
| Lean toolchain (`lean`, `lake`) | `leanprover/lean4:v4.24.0`          | image, 390 MB seed | 2.3 GB              | seconds    |
| Hackage and CHaP indices        | states of 2026-09-21 and 2026-09-16 | image, 61 MB seed  | 1.2 GB              | seconds    |
| HLS (language server)           | on request                          | download, 2.5 GB   |                     | minutes    |

The first start on an empty volume, with networking disabled, takes about a minute. Every later start takes about half a second.

## 3. Your editor, inside the container

CBDE ships no editor and needs no editor plugin of its own. It follows the Dev Container standard, which VS Code, Cursor, JetBrains, and GitHub Codespaces implement. From a project:

```bash
cbde devcontainer           # writes .devcontainer/devcontainer.json
```

then 'Reopen in Container' in the editor. The editor starts the same image, mounts the same volume, and installs the portfolio's extensions inside the container, where the binaries, the `.hie` files, and the toolchain are.

| Extension            | Drives                                                            |
| -------------------- | ----------------------------------------------------------------- |
| `IOG.vscode-plustan` | plustan, the Plinth static analyzer                               |
| `IOG.pbt-extension`  | PBT, the property-based testing tools                             |
| the FVT extension    | formal verification with Blaster                                  |
| `haskell.haskell`    | the Haskell language server, installed on request with `cbde hls` |
| `leanprover.lean4`   | Lean 4                                                            |
| `TxPipe.aiken`       | Aiken                                                             |

The extension list and its settings travel inside the image as Dev Container metadata, so a project that merely references the image gets them even without the generated file. The generated file is version-stamped: `cbde doctor` reports when a project's copy is older than the image's, and the generator never overwrites it silently. Section 12 has the full tool and extension model.

## 4. Versions you can trust

The question a developer actually asks is not 'is GHC installed' but 'do these versions work together'. CBDE answers it with a compatibility matrix: a named set of pins, verified as a set, shipped as one image. `cbde:0.2.0` is matrix 0.2.0, and `cbde:latest` is the newest one.

```console
$ cbde matrix
project    /home/you/work/my-contract
pinned     none, running cbde:latest (pin with: cbde matrix <name>)
image      cbde:latest

Compatibility matrix 0.2.0 (this image)
  baked into the image:
    plustan <ref>   blaster <ref>   aiken v1.1.23   z3 z3-4.15.2   ghcup 0.2.6.2
  in the volume, switchable:
  ✓ GHC    9.6.7
  ✓ cabal  3.10.3.0
    HLS    not pinned
  ✓ Lean   leanprover/lean4:v4.24.0

  ✓ verified: the active toolchain is exactly matrix 0.2.0
```

The verdict has three values. **Verified**: the active toolchain is exactly the matrix. **Declared**: the project asked for a difference in a committed file, and the verdict names the component and the file. **Custom**: a difference no file explains. `cbde matrix reset` returns to the verified set from the image's seeds, with no network.

A project records the matrix it was written against:

```bash
cbde matrix 0.1.0           # pulls cbde:0.1.0 if needed, writes .cbde, updates devcontainer.json
cbde matrix list            # every matrix: local images and the registry's tags
cbde matrix unpin           # back to cbde:latest
```

The pin is one line, `matrix=0.1.0`, in a `.cbde` file at the project root. Committed, it makes every teammate run the same image, pulled on first use. A personal choice that should not reach the team goes into `.cbde.local`, which is gitignored.

## 5. Where it runs

| Host                 | How                                                                | Notes                                                        |
| -------------------- | ------------------------------------------------------------------ | ------------------------------------------------------------ |
| Linux, x86_64        | native amd64 image                                                 | the reference platform                                       |
| Linux, aarch64       | native arm64 image                                                 |                                                              |
| macOS, Apple Silicon | arm64 image in the Linux VM of Docker Desktop, Colima, or OrbStack | nothing emulated for the Plinth path; see section 13 for Nix |
| macOS, Intel         | amd64 image in the Linux VM                                        |                                                              |
| Windows              | amd64 image through Docker Desktop with WSL 2                      | not a primary target                                         |

The images are Linux images in both architectures. On macOS the container runs inside a Linux virtual machine, so the executables a project produces are Linux executables for the VM's architecture, never macOS binaries. The VM also sets the limits: Plinth builds need 8 GB of memory at minimum and 16 GB comfortably (one GHC process compiling a real validator can exceed 10 GB). `cbde doctor` reports the architecture, whether emulation is in play, and how much memory the container actually sees.

---

# Part II. How it works

This part follows the chain of dependency. The matrix is the truth. The image is built from it. The volume is filled from the image. The start sequence does the filling. Then come the two command-line interfaces, how projects pin their choices, how each tool and its editor extension are delivered, and finally Nix.

## 6. The compatibility matrix: the single source of truth

A matrix is one file, `matrices/<version>.env`, of `KEY=VALUE` lines. Values are restricted to letters, digits, and `._:/+~@-`. The file is read as data, never executed. A matrix file, abridged, with values of the 0.2.0 generation:

```
CBDE_IMAGE_VERSION=0.2.0

# Provisioned into the volume on first start; switchable at run time.
CBDE_GHC=9.6.7
CBDE_CABAL=3.10.3.0
CBDE_HLS=
CBDE_LEAN=leanprover/lean4:v4.24.0
CBDE_INDEX_STATE=2026-09-21T04:01:53Z
CBDE_CHAP_INDEX_STATE=2026-09-16T23:53:07Z

# Baked into the image; change only by changing image.
GHCUP_VERSION=0.2.6.2
AIKEN_VERSION=v1.1.23
Z3_TAG=z3-4.15.2
PLUSTAN_REF=<tag or commit>
BLASTER_REF=<tag or commit>
LIBSODIUM_REV=dbb48cce...
SECP256K1_REV=ac83be33...
BLST_TAG=v0.3.14
```

Three groups of keys: the identity (the version, which is also the image tag), the volume-side pins (what the first start unpacks), and the image-side pins (what the build compiles or fetches). The two index-state keys are pins too: they name the Hackage and CHaP snapshots the set was verified against, and the image ships exactly those snapshots.

Four rules hold the matrix together.

1. **A published matrix is immutable.** Moving any pin, the index-states included, is a new matrix with a new version. Older matrices stay buildable and pullable forever.
2. **The Dockerfile mirrors the newest matrix and fails on drift.** Its argument block repeats the pins; the final build stage compares them with the matrix file the image claims to be and refuses to build if they differ. The build tooling passes every line of the matrix as a build argument, which is how an older matrix is built from the same Dockerfile.
3. **The image carries its matrices and compares itself to them.** Every matrix file known at build time is copied into the image, and a running container compares its active toolchain with its own matrix. That comparison produces the verdicts of section 4.
4. **Every pin is an immutable reference**: a version, a tag, or a commit hash. A tool whose upstream does not tag releases is pinned by commit hash, never by branch.

This file is what the PRD calls the manifest: the versioned lockfile that declares, per release, the exact versions of GHC, the cabal index-state, Plinth, and every portfolio tool. It is deliberately a flat file: the host launcher reads it on macOS's bash 3.2, the in-container tools read it on bash 5, the CI workflow reads it, and a catalog website could read it with no code shared between them.

What the matrix pins, and what it does not. It pins tools. It does not pin project libraries such as Plinth itself or the PBT libraries: a project's own cabal files resolve those, and the index-states define what is resolvable. The matrix additionally records the Plinth version the conformance suite verified against, as information for scaffolding and the catalog rather than as something installed.

## 7. Anatomy of the image

One image is built per matrix and architecture, and the two architectures are published under one tag; Docker picks the right one at pull time. Inside, the image has five kinds of content.

| Content          | What is there                                                                                                                                                                              | Why                                                                                                                                                                                                           |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| System layer     | Ubuntu 24.04; the Cardano cryptography libraries built from source (the IOG fork of libsodium, libsecp256k1, blst 0.3.14); C toolchain and development headers; Node.js, npm, jq           | The distribution packages of the crypto libraries are missing or too old. The C toolchain is a run-time requirement: plustan drives `cabal build` in the analyzed project. Node and jq serve the PBT scripts. |
| Tool binaries    | `plustan` and `stan`, built from source against the matrix's GHC; `aiken`, a static release binary; `z3`, built from the pinned tag; Blaster, prebuilt; elan's binaries                    | The parts of the matrix that are not switchable. plustan in particular reads `.hie` files, whose format is tied to the exact GHC patch version, so 'matrix 0.2.0' also means 'the plustan built for 9.6.7'.   |
| Seeds            | The GHC and cabal bindists, the Lean toolchain, the two package indices, all compressed, under `/opt/cbde/seed`; the ghcup binary and its release metadata                                 | What the first start unpacks into the volume with no network.                                                                                                                                                 |
| Self-description | Every matrix file; the dev container template, stamped with the image version; the image version in the environment; the Dev Container metadata label with the extension list and settings | The image can explain itself offline: `cbde matrix`, `cbde doctor`, and any editor read these.                                                                                                                |
| Scripts          | the entrypoint, the provisioner, the in-container `cbde`, and their shared library                                                                                                         | Section 9 and section 10.                                                                                                                                                                                     |

Expected sizes, for a matrix of the 0.2.0 generation:

|                              | Compressed (what is pulled) | Unpacked               |
| ---------------------------- | --------------------------- | ---------------------- |
| Image                        | about 1.1 GB                | about 3.7 GB           |
| of which seeds               | about 680 MB                | they become the volume |
| Volume after the first start |                             | about 6.5 GB           |

Nix is part of the system layer as a single-user installation with no daemon; its store lives in the volume. Section 13 explains its role.

## 8. Anatomy of the volume

One named volume, mounted at `/nix`:

```
/nix
├── store/                Nix store. Must be a real directory: Nix refuses a
│                         symlinked store path, which is why the whole cache
│                         lives under /nix and not the other way around.
└── cbde/
    ├── .ghcup/           GHC, cabal, and HLS installations (ghcup's root)
    ├── elan/             Lean toolchains            (/root/.elan points here)
    ├── cabal/            cabal store and the Hackage and CHaP indices
    │                                                 (/root/.cabal points here)
    ├── .cbde-version     the image version that initialized this volume
    ├── .cbde-owner       the uid:gid that owns it
    └── .provision.lock   serializes concurrent provisioners
```

Everything expensive persists here: the toolchains, the Nix store, the compiled dependencies of every project built so far, and the indices. One volume serves every matrix and every project on the machine: an older matrix's GHC lands next to the newer one, and both stay warm. What does not live here is the per-container selection of section 11, which is container-local on purpose.

Three consequences follow from 'the volume is a cache'. Anything in it may be rebuilt from the image on any start. Nothing in it is backed up or migrated. And a user-facing command to delete it (`cbde volume rm`) is safe to offer, because the cost is time only.

It must be a named Docker volume, not a bind mount of a host directory: Nix refuses a store it does not own, and bind-mounted toolchains on macOS would run through the slow file-sharing path.

## 9. A container start, step by step

Every start runs two scripts before the requested command: the entrypoint settles identity, the provisioner settles the toolchain. Both are idempotent, and a warm start spends about half a second in them.

**Identity.** The container starts as root and ends as the developer.

1. Whoever owns the mounted project directory is who the container should be. The entrypoint reads that uid and gid. On a Linux host it is the developer's own id.
2. Docker Desktop, Colima, and OrbStack virtualize ownership: the mount looks root-owned from inside, yet any uid may write to it and files come out as the developer on the host. When the entrypoint sees a root-owned mount that uid 1000 can nevertheless write, it adopts the image's `cbde` user (uid 1000). That keeps command-line runs and the editor's dev container, which always runs as `cbde` on macOS, on one owner of the volume.
3. A root-owned mount that uid 1000 cannot write is a Linux host really running as root, such as a CI runner. The container stays root. So does a container with no project mounted.
4. The image's `cbde` user is re-targeted to the chosen ids, the volume is handed over once per volume and user (recorded in `.cbde-owner`), and privileges are dropped before anything else runs.

`CBDE_UID` and `CBDE_GID` override the detection. The home directory stays `/root` for every user, deliberately: cabal's store layout and the paths the prebuilt Blaster artifacts were compiled against both depend on it being the same path whoever runs.

**Toolchain.** The provisioner then makes the volume match the matrix and the project.

1. If nothing is mounted at `/nix`, it says so, shows the mount to add, and lets the container continue: the tools that need no toolchain still work.
2. It takes a lock on the volume. Two containers sharing a volume, or a dev container plus a command-line run, never install into the same directory at once.
3. It records the image version in the volume's stamp. Volumes are shared between images by design, so a stamp from another image is information for `doctor`, not a warning on every start.
4. ghcup and its release metadata are copied from the image: no install script, no download.
5. GHC and cabal: if the matrix's versions are missing, they are unpacked from the seed; a version the image does not seed is downloaded. The default is set only on a fresh install, so a developer's deliberate switch survives restarts.
6. HLS is installed only when the matrix pins one. Otherwise it is on request.
7. The project's own selection (section 11) is read; anything it asks for and the volume lacks is installed, from seed or download; the active links are rebuilt.
8. Lean: elan's binaries come from the image, the toolchain from the seed. An empty `CBDE_LEAN` skips Lean altogether and saves 2.3 GB.
9. The Hackage and CHaP indices are unpacked from the seed at the pinned states; without a seed, `cabal update` is run at those same states.

Two properties protect the cache. Every installer unpacks beside its target and renames into place, so an interrupted start never leaves a half-installed toolchain that a later probe would report as present. Downloads retry three times; a failure is reported, not fatal, so a developer without network still gets a shell and `cbde doctor` explains what is missing.

|                | Empty volume, image present                                        | Warm volume  |
| -------------- | ------------------------------------------------------------------ | ------------ |
| Identity       | once per volume and user: hand over the volume, thousands of files | milliseconds |
| GHC and cabal  | about 45 s from the seed                                           | stat calls   |
| Lean toolchain | seconds from the seed                                              | stat calls   |
| Indices        | seconds from the seed                                              | stat calls   |
| Total          | about 60 s                                                         | about 0.5 s  |

## 10. Two command-line interfaces, one name

Two programs are called `cbde`. The one on the host is the launcher; the one inside the container manages toolchains. They have different jobs and share a forwarding rule.

**The launcher** (host, POSIX-portable bash) owns everything that needs Docker or the host filesystem:

- resolving the project root and the working directory to mount;
- resolving the image: the project's pin, else `latest`, pulled on first use when a pinned image is absent;
- attaching the volume, forwarding settings, choosing the platform;
- `pull`, `build`, `volume`, `info`, and the registry commands;
- running any command, or an interactive shell, in the container.

**The manager** (inside the container, bash 5) owns everything that needs the volume or the project files from the inside:

- showing or switching GHC, cabal, HLS, and Lean for the project;
- `sync`, which installs whatever the project selects and relinks;
- `matrix` (show, list, reset), `list`, `doctor`, and writing the dev container file.

**The forwarding rule.** The launcher forwards the version verbs (`ghc`, `cabal-version`, `hls`, `lean`, `sync`, `list`, `matrix`, `doctor`, `devcontainer`) to the manager and treats everything else as a command to run in the container. So `cbde ghc 9.6.6` switches GHC while `cbde cabal build` builds. The one casualty is cabal: because `cabal` must remain the tool, switching cabal versions from the host is `cbde cabal-version`.

**Settings** resolve in one order everywhere: environment variable, then the per-user file `~/.config/cbde/config` (`registry=`, `volume=`, `platform=`), then the built-in default. `cbde info` prints every resolved value and where it came from.

**The PRD's verbs.** The PRD names six commands. The responsibilities map as follows; the names are indicative, see section 25.

| PRD verb | Responsibility                                                          | Design                                                                                                                                                                                                                   |
| -------- | ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `init`   | environment configuration into a project, optionally a project skeleton | writes the dev container file and the matrix pin and, for a new project, the skeleton of section 12; the two halves remain available separately as `devcontainer` and `matrix <name>`                                    |
| `up`     | start the environment, attach the editor                                | no long-running container exists in command-line use: each command is its own container, and the editor starts its own. `up` is therefore 'open this project in the editor's dev container'; whether to offer it is open |
| `doctor` | verify tools, disk, architecture, drift                                 | platform and emulation, memory, the volume, the toolchain and indices, the matrix verdict, IDE support, workspace ownership, dev container template currency, every tool                                                 |
| `update` | move a project to a newer release, report breaking changes              | `matrix <newer>` performs the move; the breaking-change report compares the two matrices' pins and names what moved. Refreshing ghcup's release metadata gets a name of its own                                          |
| `tools`  | list and add portfolio tools                                            | `list` shows installed and active versions; adding a tool follows the composition model of section 20                                                                                                                    |
| `export` | emit a CI snippet for the current configuration                         | emits a workflow snippet for the current matrix and profile, with the CI profile of section 20                                                                                                                           |

## 11. Projects and pins

A project states what it needs in two small files at its root.

| File          | Who           | Committed      | Keys                                |
| ------------- | ------------- | -------------- | ----------------------------------- |
| `.cbde`       | the team      | yes            | `matrix=`, `ghc=`, `cabal=`, `hls=` |
| `.cbde.local` | one developer | no, gitignored | the same                            |

Precedence is image matrix, then `.cbde`, then `.cbde.local`, the last one winning. `matrix=` selects the image and is read by the launcher. The other keys select versions on top of that image's matrix and are read by the provisioner on every start.

Two rules keep the files honest. CBDE writes `.cbde` only when asked: `cbde ghc 9.6.6` records the choice there, `cbde matrix 0.1.0` records the pin, `cbde matrix reset` clears the version keys. It never creates or edits the file on its own. With `--local` the same commands write `.cbde.local` instead and add it to the project's gitignore. Outside a project, the links are the matrix and a switch is refused.

**Per-container selection.** The selected versions are installed into the shared volume but linked into a directory inside the container, first on `PATH`. Two containers on two projects sharing one volume therefore each see their own GHC while sharing every installed version. Nothing is ever removed from the volume, so switching back and forth costs nothing after the first install.

**A scenario.** A vendor project pins GHC 9.6.6 in its cabal project while the matrix ships 9.6.7. Its `.cbde` says `ghc=9.6.6`; the first start installs 9.6.6 from the network (the image seeds only 9.6.7) next to the matrix's GHC; `cbde matrix` reports **declared**; `cbde doctor` adds that plustan, built for 9.6.7, cannot read this project's `.hie` files. That is the intended behavior: the difference is visible, named, and attributed, and the conformance suite of section 19 is where such portfolio-level conflicts are caught before a release.

`doctor` also warns when a `with-compiler:` line in a cabal project names a GHC other than the selected one, because cabal resolves that name through ghcup's own directory and bypasses the links.

## 12. The tools and their editor faces

Every portfolio tool has two faces: a command-line face in the image and an editor face as an extension. The matrix pins both, and the two are verified against each other. This section defines how each tool is delivered and what the rules are.

**Four delivery classes.**

| Class            | What                                                                                                                   | Examples                                                                     | Pinned by                                                           |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| Baked binary     | an executable compiled or fetched at image build                                                                       | plustan, stan, aiken, z3, elan, the Blaster CLI                              | a tag or commit in the matrix                                       |
| Seeded toolchain | a large, versioned toolchain unpacked into the volume on first start                                                   | GHC, cabal, the Lean toolchain, the package indices; HLS on request          | a version in the matrix                                             |
| Project library  | code the project's own build files consume; the environment supplies the toolchain and indices that make it resolvable | Plinth (plutus-tx via CHaP), the PBT libraries, Blaster as a Lake dependency | the project's cabal or Lake files, within the matrix's index-states |
| Editor extension | installed inside the container by the editor, from the image's Dev Container metadata                                  | the six extensions of section 3                                              | the matrix, as `publisher.name@version`                             |

**The portfolio, by face.**

| Tool                          | Command-line face                                                                                                                                         | Editor face                                                                            |
| ----------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| plustan (static analysis)     | baked binary, tied to the matrix GHC                                                                                                                      | `IOG.vscode-plustan`, pointed at the binary by a setting in the metadata               |
| PBT (property-based testing)  | project libraries; the vendor's supported build path is `nix develop`; test discovery needs the project's own Node dependencies, installed by scaffolding | `IOG.pbt-extension`, VS Code 1.118 or newer                                            |
| Formal verification (Blaster) | the `blaster` command as a baked binary, plus the Blaster Lean library as a Lake dependency, prebuilt in the image together with Z3                       | the FVT extension, driving the `blaster` command; `leanprover.lean4` for the Lean side |
| Aiken                         | baked static binary                                                                                                                                       | `TxPipe.aiken`                                                                         |
| Haskell and Plinth            | seeded GHC, cabal, and indices                                                                                                                            | `haskell.haskell`, with HLS installed on request                                       |
| Lean 4                        | seeded toolchain through elan                                                                                                                             | `leanprover.lean4`                                                                     |

**Five rules.**

1. **Extensions are part of the matrix.** An unversioned extension list would let the marketplace move an extension under a frozen image. The matrix carries one pin per extension, the metadata label carries `publisher.name@version`, and the conformance suite checks each extension against the binary it drives: the plustan extension against the plustan binary, the FVT extension against the Blaster CLI.
2. **The image is self-describing.** The extension list and settings live in the image's Dev Container metadata, so any compliant editor gets them without CBDE knowing which editor it is. That is how the IDE requirement is met with no plugin of our own.
3. **Extensions install container-side, never on the host.** They need the binaries, the `.hie` files, and the volume, so they run where those are. The host needs Docker and the editor's dev container client, nothing else.
4. **Per-project setup an extension needs belongs to tooling, not to documentation.** PBT's Node dependencies and Blaster's `lean-toolchain` match are the two known cases. They are steps of project scaffolding or of the provisioner, so that 'Reopen in Container' is enough.
5. **A tool that gains a binary changes class.** Blaster is the first case: with the `blaster` command it is a baked binary like plustan, while the Lean toolchain it needs stays a seed and the library stays available for projects that use the tactic directly.

**Blaster's two paths.** The image carries Blaster in both forms. The `blaster` command serves the FVT extension and headless use in CI. The Lean library serves projects that use the tactic directly: such a project depends on a copy of the prebuilt checkout (Lake writes lock files into dependencies, and the image copy is read-only) and keeps its `lean-toolchain` equal to the one Blaster was built with; scaffolding does both. Until the vendor ships the command, the library path is the supported route.

**Scaffolding.** Project scaffolding has two halves. The environment half writes the dev container file and the matrix pin and, where a tool needs it, runs the per-project setup of rule 4; it never touches existing code. The project half generates a compilable Plinth skeleton with cabal files pinned to the matrix's toolchain and a minimal validator, for new projects only.

**HLS.** The language server is the single largest install (2.5 GB, one bindist for six GHC versions) and useless without an editor. It is on request by default (`cbde hls`), the matrix may pin a version for a profile that wants it preinstalled, and `doctor` checks that the installed server actually supports the active GHC, which is not a given after a switch.

## 13. Nix

The PRD restates its goal as removing developer exposure to Nix, not Nix itself. The design meets that for the Plinth path and keeps Nix available where a vendor requires it.

**Role.** The Plinth path needs no Nix at all: the pinned GHC and cabal, the CHaP and Hackage snapshots, and the cryptography libraries in the image resolve and build a Plinth project with plain `cabal build`. Nix is present for two reasons. The PBT libraries officially build only inside `nix develop`, with the IOG binary caches. And any project that ships a flake can use it (`cbde nix <command>` runs a command inside `nix develop`).

**Configuration.** Single-user installation, no daemon (containers have no init system). Sandboxing is off, since it needs privileges containers do not have. The IOG caches are preconfigured as substituters. The store lives in the volume.

**Apple Silicon.** Nix runs natively as `aarch64-linux` there. Some projects nevertheless need `x86_64-linux`, because parts of their library stack are available or supported for that system only. For them the arm64 image declares `x86_64-linux` as an extra platform: `nix develop --system x86_64-linux` resolves the x86_64 closure and runs its binaries through the VM's Rosetta translation, GHC included, at roughly half native speed. This requires Rosetta to be enabled in the Docker runtime, and `cbde doctor` probes whether it is. Nothing else in the environment depends on it: the native Plinth path runs at full speed regardless.

**The pipeline.** The image build does not use Nix. Each stage uses ghcup and cabal directly, and the Lean side uses elan and Lake. The PRD's position ('Nix runs inside the pipeline, the output is a standard OCI image') is met in its intent, a standard image and no Nix for the developer, and inverted in its mechanism, since the pipeline is Nix-free too.

Whether a developer-facing `cbde nix` stays part of the surface long term, or whether the PBT vendor ships a cabal-only path instead, is an open point (O-2, section 25).

---

# Part III. Producing, publishing, and composing

This part is for the people who build and release CBDE. It describes how an image is built from a matrix, how it is tested, how it reaches a registry and a developer's machine, and how images are composed into the profiles of the PRD.

## 14. Building an image from a matrix

The Dockerfile is one file with seven stages. Each stage has one job, so a change in one place rebuilds as little as possible.

| Stage             | Job                                                                                                                                                                            | Cost (native)                               |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------- |
| `crypto-builder`  | builds the IOG libsodium fork, libsecp256k1, and blst from the pinned revisions                                                                                                | minutes                                     |
| `base`            | Ubuntu 24.04, system packages, the ghcup binary and its metadata, Nix, the `cbde` user, the volume layout                                                                      | minutes                                     |
| `toolchain`       | runs the real provisioner against the seed in strict mode, which both proves the offline path and materializes GHC and cabal for the stages that compile; packs the index seed | minutes                                     |
| `plustan-builder` | clones and compiles plustan against the matrix GHC; the cabal store is a build cache                                                                                           | the long one                                |
| `aiken-dl`        | fetches the pinned Aiken release binary                                                                                                                                        | seconds                                     |
| `blaster-builder` | builds Z3 from source, installs the pinned Lean toolchain, builds Blaster, packs the Lean seed; independent of the Haskell side so Haskell changes never invalidate it         | the second longest: Z3 compiles from source |
| `final`           | assembles binaries, seeds, matrices, template, and scripts; runs the drift check against the matrix file                                                                       | a couple of minutes                             |

Three properties matter more than the stage list.

- **Build-time and run-time provisioning are the same code.** The `toolchain` stage installs GHC and cabal with the same provisioner a container runs on start, in strict mode: a broken seed fails the build, not the first user.
- **Every pin arrives as a build argument.** `cbde build` and the CI workflow pass the matrix file line by line. The Dockerfile's defaults mirror the newest matrix only, and the drift check in `final` rejects an image whose arguments do not match the matrix it claims to be.
- **Each architecture builds natively.** Emulating a GHC toolchain build takes hours. The amd64 image builds on an x86_64 machine, the arm64 image on an Apple Silicon or aarch64 Linux machine, and the two are joined afterwards (section 15).

A full build takes from a few minutes to a few tens of minutes depending on the machine, from our experience with the research prototype. A change to the scripts alone rebuilds only the final stage, a small fraction of that, because the stages that compile depend only on the provisioner and its library, not on the launcher or the manager.

## 15. Tests and continuous integration

Two tiers of tests, with different speeds and different jobs.

**The fast tier** runs in seconds with no Docker: plain bash tests, one suite per component (the launcher, the manager, the matrix library, project selection, the seeded installers, the installer script, and the repository's own consistency). `docker`, `ghcup`, `elan`, `ghc`, `cabal`, and the HLS wrapper are stubs that record their arguments, so a test asserts on the exact `docker run` line the launcher would execute, on what `cbde matrix` prints for a given fake volume, on what the seeded installers do with a fake seed, and on the repository itself: every matrix validates, the Dockerfile mirrors the newest one, every matrix key is a Dockerfile argument, the launcher uses no bash feature newer than 3.2. CI runs this tier on Linux and on macOS; macOS is the only place to prove the launcher runs on the stock shell.

**The slow tier** uses a real image and a scratch volume with networking disabled. Every provisioning line must say the toolchain came from the image, and the verdict must be 'verified'. A second check starts two containers on one scratch volume with two projects, one selecting another GHC through `.cbde.local`, and expects each to report its own compiler. Stubs cannot catch a wrong assumption about a real tool's behavior, so this tier is mandatory after any change to the provisioner, the seeds, or project selection, and it is the first stage of the conformance suite (section 19).

**The workflow.** On every push and pull request:

```
matrices/<v>.env
      │
      ├─► tests on Linux ─┐
      ├─► tests on macOS ─┤
      │                   ▼
      ├─► build amd64 (x86_64 runner)  ─┐   pushed by digest
      └─► build arm64 (arm64 runner)   ─┴─► manifest: <v>, and latest if <v> is the newest
                                               │
                                               ▼
                                     registry (GHCR by default)
```

The workflow resolves the matrix to build (the newest, or one named by hand), validates it, turns its lines into build arguments, builds each platform on a native runner with a per-platform layer cache, pushes each image by digest, and finally writes one multi-architecture manifest under the version tag. `latest` moves only when the newest matrix was built, so rebuilding an old matrix never rolls users back. Pull requests build but do not push.

## 16. Registry and tags

The image lives in an OCI registry; GitHub Container Registry (GHCR) is the default, which settles the PRD's open decision D1 unless a reason to move appears. The registry is a setting with the usual precedence (environment, per-user file, default), so a team mirror or a local test registry is a one-line change.

**Tag layout.**

| Tag                                  | Meaning                                                                                                     | Mutable                                     |
| ------------------------------------ | ----------------------------------------------------------------------------------------------------------- | ------------------------------------------- |
| `<version>`                          | matrix `<version>`, a multi-architecture index over amd64 and arm64                                         | never                                       |
| `latest`                             | the newest matrix                                                                                           | moves only when a newer matrix is published |
| `<version>-amd64`, `<version>-arm64` | the single-architecture sources of `<version>` when it was published from developer machines rather than CI | replaced only by the same architecture      |

The architecture tags exist because a local image is one architecture (amd64 when built on Linux, arm64 on Apple Silicon) while the published tag is both. A plain push of `cbde:0.2.0` would replace whatever the registry holds with the pusher's architecture. `cbde registry push` therefore pushes the local image under its architecture tag, looks up which architecture tags exist, rewrites the version tag as an index over all of them, and reads it back. Two machines can push in either order; the first makes a single-architecture tag, the second completes it. CI reaches the same layout directly from digests.

**Listing.** `cbde matrix list` merges the local `cbde:<version>` images, whose pins are read from the images themselves, with the registry's tag list, read live. It never consults a catalog baked into an image, which would be stale the day the next matrix ships. Offline, it still lists everything local. The GHCR tag listing works anonymously for a public package.

**A local registry for rehearsal.** `cbde registry up` starts a standard registry on the developer's machine and points `cbde` at it; `push`, `list`, `rm`, `status`, and `down` complete the set. The whole pull, pin, and switch flow can be rehearsed end to end without touching the real registry, and the published layout is the same.

**Pull rates.** The requirement is sufficient, not unlimited. An image is pulled once per developer machine and once per CI job without a cache, about 1.1 GB each time. GHCR serves anonymous pulls of public packages, and CI jobs can authenticate with their own token. The decision is revisited only if pull failures appear in practice.

## 17. Installing and updating on a developer's machine

**The launcher.** The installer is a POSIX shell script fetched over HTTPS and piped to `sh`. It copies one file, the launcher, to `~/.local/bin` (or a directory given by flag or variable), reports if that directory is not on `PATH`, and stops. Running the same line again updates the launcher in place. A `--try` mode opens a shell where `cbde` is a function and installs nothing, for people who want to look first. Branch and source overrides exist so an unmerged change can be tested the same way users will install it.

**The image.** Images are pulled on demand. A project pinned to a matrix whose image is absent triggers a pull on first use; a fresh clone of a pinned project just works. `CBDE_PULL=never` turns that off for air-gapped use. A newer CBDE pulled against an existing volume installs whatever it newly needs and reuses the rest; no volume has to be recreated.

**Moving a project forward** is pinning a newer matrix: `cbde matrix 0.3.0`. The breaking-change report the PRD asks for compares the two matrices' pins and names what moved.

**Removal** is three Docker objects: the launcher file, the images, and the volume. One command removes all three.

## 18. Releasing a matrix

Releasing a matrix is a short procedure. The pipeline automates it and gates it.

**The procedure.**

1. Copy the newest matrix file to the new version and change the pins that move. Keep the others.
2. Mirror the changed lines in the Dockerfile's argument block.
3. Run the fast tier; the repository tests confirm the file validates and the mirror is exact.
4. Build, run the slow tier.
5. Push. CI tests, builds both architectures from the file, and tags the manifest; `latest` follows if this is the newest matrix.

**The pipeline.** Each stage maps to the PRD's section 7.

| Stage                  | Design                                                                                                                                                                            |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Manifest               | the matrix file, section 6                                                                                                                                                        |
| Triggers               | a push to a matrix file; an upstream release detected by polling the vendors' release feeds; a nightly run to catch drift in anything not pinned by hash                          |
| Version bumps          | a dependency bot opens a pull request with a candidate matrix when a vendor tags a release; nothing merges while conformance fails. This requires tagged upstream releases (O-12) |
| Build matrix           | native amd64 and arm64, section 15                                                                                                                                                |
| Conformance gate       | section 19                                                                                                                                                                        |
| Channels               | `edge` on every green build of the newest matrix; `beta` and `stable` promoted by moving tags over immutable version tags; cadence to be decided (O-8)                            |
| Signing and provenance | a cosign signature and a software bill of materials generated in the `manifest` job and attached to the version tag                                                               |
| Retention and rollback | version tags are never deleted within a declared window, so a pinned project keeps working and a rollback is `cbde matrix <previous>`; the window is to be decided (O-8)          |
| Vendor notification    | when the gate fails on a vendor's component, the failing output is posted to that vendor's repository as an issue                                                                 |

Channels fit the tag layout without changing it: a channel is a moving tag over the immutable version tags, exactly as `latest` is.

## 19. The conformance suite

The conformance suite is the release gate: no image is promoted without a full pass. It also doubles as integration testing for the whole portfolio, which is the second thing the PRD sells. The PRD lists six checks; here each becomes a concrete artifact and a place where it runs.

| Check (PRD)                                         | Artifact                                                                                           | Where it runs                                                      |
| --------------------------------------------------- | -------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| Compile a reference set of Plinth contracts         | a reference repository with a handful of contracts covering common patterns, pinned to the matrix  | a container of the candidate image, in CI                          |
| Run the static analyzer and match expected findings | the same contracts with a committed set of expected plustan findings                               | the same container                                                 |
| Execute a property-based testing run                | a reference PBT project with its vendor's supported path                                           | the same container, with the Nix path where the vendor requires it |
| Execute a formal verification run                   | a Lean project proving a known-good specification with Blaster                                     | the same container                                                 |
| Measure cold start                                  | first start on an empty volume with the image present and networking disabled; image pull excluded | a standard GitHub-hosted runner, both architectures                |
| Measure image size                                  | compressed size of the pushed image and volume size after first start                              | the `manifest` job                                                 |

Three additions beyond the PRD's list: the slow tier of section 15 (toolchain from the image, verdict verified, parallel containers), the extension-to-binary checks of section 12, and a dev container smoke test (build the dev container from the template and run `doctor` inside it).

**Definition of cold start.** Cold start means the first container start against an empty volume, image already present, with no network: it includes unpacking the seeds and excludes the pull. Measured on a standard CI runner, not a developer's machine, and reported per architecture.

**What it catches.** Two portfolio tools disagreeing about the compiler, for instance a PBT release pinned to GHC 9.6.6 next to a plustan built against 9.6.7. Without the gate, a developer discovers it from `doctor`. With it, the vendor discovers it from a failing pull request before anyone pulls the image.

Ownership (the PRD's decision D2) is open (O-7). The suite can be seeded from the reference projects whatever the answer; the question is who maintains the expected findings as tools evolve.

## 20. Profiles and composition

The PRD asks for curated profiles and modular features, because a verification engineer and a developer iterating on business logic want different things and one large image wastes disk for everyone. The volume model changes the arithmetic, and this section says how.

**What a profile is.** A profile is a matrix plus three selections: which binaries are baked, which seeds ship, and which extensions the metadata lists. The toolchains themselves are shared through the volume, so two profiles pulled on one machine share GHC, cabal, and the indices, and the difference between profiles is binaries and seeds only. Pulling a second profile costs its own layers, not another toolchain.

**The first profile is one image** holding the whole portfolio. For the portfolio as it stands, that image is `cbde-full`, and `cbde-test` plus `cbde-verify` together equal it, until the profiler and the load testing tool exist. Further profiles are introduced when the size measurements of the conformance suite justify them.

**Three mechanisms**, which combine.

| Mechanism                       | How                                                                                                                              | Gains                                                                              | Costs                                                                                                                                                              |
| ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Start-time toggles              | a setting skips a seed, for example `CBDE_LEAN=` for the 2.3 GB Lean toolchain                                                   | no new images; a developer saves volume space and a minute                         | the image still carries every seed                                                                                                                                 |
| Image variants on a shared base | one `final` stage per profile selecting which binaries and seeds to copy; tags `cbde:<version>-<profile>` share all other layers | smaller pulls; a stripped CI variant; each variant still verified as a matrix      | more tags to publish and to gate; the tag scheme is indicative                                                                                                     |
| Dev container features          | one feature per baked tool, installed by the editor when the container is built                                                  | arbitrary composition; a new portfolio tool reaches developers without a new image | features install at container build time, before the volume exists, so they suit binaries, not seeded toolchains; slower cold start; a second verification surface |

**The CI profile.** A CI job has no persistent volume, so a job on the regular image pays the cold start every time. The CI variant inverts the cache: its image carries the toolchain unpacked, exactly what the `toolchain` stage already materializes, trading a larger pull (cached by the runner's registry proximity) for a start of seconds. A published GitHub Action wraps it: pick a matrix, run a command. The same variant serves workshops and air-gapped use, where 'offline from the first command' matters more than image size. This is the PRD's `cbde-ci` and F12.

**Project dependencies offline.** The one thing no profile can seed is a project's own dependencies; cabal downloads them on the first build. For reference contracts and workshops, a profile can additionally ship a prebuilt cabal store for a known dependency set, which the conformance suite builds anyway. Whether the size is worth it is open (O-11).

The profile list itself, and the names, are open (O-1).

## 21. Security, isolation, and supply chain

**Who the container is.** Commands run as the developer's own user, never as root, through the identity steps of section 9. No capabilities are added, no privileged mode is used. On runtimes that virtualize ownership, the container runs as an unprivileged fixed user.

**What the container can reach.** The project directory and the volume, nothing else from the host. The project directory is the git repository root rather than the current directory, because builds need the cabal project file, sibling packages, and submodules above the current directory. The launcher searches upwards for that root, so a home directory that is itself a git repository (a common dotfiles pattern) would be mounted whole; the launcher refuses to mount the home directory unless explicitly overridden. `cbde info` always prints what was resolved.

**Network.** The environment does not restrict egress: cabal, Nix, and ghcup download what the project asks for. It also never phones home; there is no telemetry in this design.

**Nix.** Sandboxing is off because containers lack the privileges it needs, and the syscall filter is off because Rosetta cannot load it. Both are build-isolation features for untrusted builds, which is not the threat model of a developer's own environment.

**Supply chain.** Every tool is fetched or built from a pinned version, tag, or commit. The seeds are verified during the build by installing from them in strict mode. The CHaP repository's root keys are baked in, so the package index is authenticated. Images are published under immutable tags and signed with provenance (section 18). The launcher itself arrives over HTTPS from the project repository; the `--try` mode lets a cautious user inspect before installing.

---

# Part IV. Traceability, decisions, and open points

## 22. Requirements traceability

Each requirement of the PRD, where this design covers it, and its status. Status words: **Validated** (exercised in the research prototype), **Planned** (specified here, to be built), **Open** (decision pending, section 25). 'Partly' names which part is which.

**Functional requirements**

| ID  | Requirement                                                   | Priority | Where  | Status                                                                                                                                              |
| --- | ------------------------------------------------------------- | -------- | ------ | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| F1  | Environment setup, one command                                | Must     | 1, 2   | Validated                                                                                                                                         |
| F2  | Version alignment, recorded in a lockfile                     | Must     | 6      | Validated                                                                                                                                         |
| F3  | Integrated tooling: PBT, static analysis, formal verification | Must     | 12     | Partly: plustan, the PBT library path, and the Blaster library path Validated; the Blaster CLI and the FVT extension Planned, vendor deliverables |
| F4  | Curated profiles                                              | Must     | 20     | Planned; the list is Open                                                                                                                           |
| F5  | Modular composition (features)                                | Should   | 20     | Open                                                                                                                                                |
| F6  | IDE integration through the Dev Container standard            | Must     | 3, 12  | Validated; extension version pins Planned                                                                                                         |
| F7  | Catalog and configurator website                              | Must     | 16, 23 | Out of scope for this phase; data interface defined: the matrix files and the registry tag list                                                        |
| F8  | Automated build pipeline                                      | Must     | 15, 18 | Partly: manifest-driven multi-arch build Validated; triggers and the dependency bot Planned                                                       |
| F9  | Conformance gate                                              | Must     | 19     | Planned; the unit tests, the strict seed install, and the drift check gate releases until then                                                      |
| F10 | Release channels with immutable tags                          | Should   | 16, 18 | Partly: immutable version tags and `latest` Validated; `edge`, `beta`, `stable` Planned                                                           |
| F11 | Supply chain attestation                                      | Should   | 18, 21 | Planned                                                                                                                                             |
| F12 | CI integration, a GitHub Action                               | Should   | 20     | Planned, with the CI profile                                                                                                                        |
| F13 | Telemetry                                                     | Could    | 21, 23 | Out of scope for this phase; no telemetry in this design                                                                                               |

**Non-functional requirements**

| ID  | Requirement                                              | Where      | Status                                                                                       | Proposed PRD wording                                                                                                             |
| --- | -------------------------------------------------------- | ---------- | -------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| N1  | Cold start under 60 s on a warm image cache              | 2.3, 9, 19 | Validated at about 60 s; CI measurement Planned                                            | define cold start as in section 19                                                                                               |
| N2  | Image size: base under 3 GB, full under 8 GB compressed  | 7          | Validated at about 1.1 GB compressed for the whole portfolio                               | budget both the compressed image (what is pulled) and the volume after first start (what is stored)                              |
| N3  | Native amd64 and arm64, no emulation in the default path | 5, 13      | Validated; on arm64, a project whose libraries need x86_64 can request it under Nix, through Rosetta             | add 'Linux images; macOS through the runtime's VM'                                                                               |
| N4  | Isolation: no host access beyond the workspace           | 21         | Partly: non-root and workspace-only mount Validated; the home-directory guard Planned      | state that the workspace is the repository root                                                                                  |
| N5  | Offline once pulled                                      | 2.3, 9     | Validated for the toolchain; a project's own dependencies download on first build          | 'the toolchain needs no network after the first start; project dependencies are cached in the volume after their first download' |
| N6  | Several environments side by side                        | 9, 11      | Validated: a volume lock, per-container selection, unique container names; no ports in use |                                                                                                                                  |
| N7  | Byte-identical tool versions per tag, indefinitely       | 6, 16      | Validated: immutable tags, toolchain unpacked from identical seeds                         |                                                                                                                                  |
| N8  | Upstream release to promoted `edge` within 24 hours      | 18         | Planned; depends on the triggers                                                             |                                                                                                                                  |

## 23. Design clarifications

Questions that arise when the PRD is read against this design, with the answer and where the document covers it.

| Question | Answer | Where |
| ------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- |
| Should HLS be in the base profile?                                                                           | HLS is on request by default, because it is 2.5 GB and useless without an editor. A matrix may pin a version, and a profile may preinstall it. Which profile does is part of the profile decision.                                                                                                                                                   | 12, 20    |
| How does 'offline' square with Plinth being a library that cabal downloads, and with projects that start from arbitrary versions? | The image seeds the Hackage and CHaP indices at pinned snapshot dates, so dependency resolution works offline; the packages themselves download on the first build and are cached. A project with its own versions is reported as 'declared' or 'custom', never silently accepted. A prebuilt dependency store for reference contracts is an option. | 6, 11, 20 |
| Does cardano-cli belong in the image? | It is not part of the initial tool set. It would be a baked binary, one matrix slot. Whether it belongs is a tool-list decision. | 12, 25 |
| What does project scaffolding include, and how does it differ from a generic project generator? | Two halves: environment configuration (dev container file, matrix pin, per-project tool setup), which never touches code, and an optional project skeleton pinned to the matrix's toolchain. The environment half is what a generic generator lacks. | 12 |
| What does the full profile contain while the profiler and the load testing tool do not exist? | Both are matrix slots. Until they exist, full equals test plus verify. | 20 |
| Where do the catalog website and the configurator fit? | Out of scope for this phase. The data interface is defined so they can be added later: the matrix files are the compatibility matrix, the registry tag list is the catalog, and the configurator's output is exactly what `init` writes. | 16, 22 |
| Does the cold start include downloading GHC, cabal, and Lean, and where is it measured? | It downloads nothing: the toolchain is unpacked from the image. Measured on a standard GitHub-hosted runner, per architecture, as a conformance check. | 2.3, 19 |
| Do the size budgets include the installed toolchains, and where does the weight sit? | The compressed image is about 1.1 GB with the whole portfolio; the volume after first start is about 6.5 GB, almost all of it GHC, Lean, and the indices. The weight is in the base toolchain, not in the portfolio tools, and N2 should budget both numbers. | 7, 22 |
| What do the produced executables target on macOS? | Linux binaries for the VM's architecture; the container always runs a Linux image. | 5 |
| Does 'offline' mean off-chain Haskell code is built outside the environment? | No. The environment builds both on-chain and off-chain code. 'Offline' means the toolchain needs no network; any project's dependencies download once, then stay cached. N5 should say so. | 22 |
| How is portfolio tool usage inside CBDE measured without telemetry? | It is not measurable without telemetry, which is out of scope for this phase and not in this design. Proxies exist: registry pulls (noisy), committed `.cbde` and dev container files in public repositories (searchable), and CI profile usage. | 21, 25 |
| Does the registry need unlimited pull rates? | No. One pull per developer machine and per uncached CI job. GHCR's anonymous pulls and per-job tokens are sufficient until shown otherwise. | 16 |
| How does this document relate to the roadmap? | It orders work by dependency, not by date (section 27). Phasing and schedule belong to the product owner. | 25, 27 |

## 24. Decisions

Short records of what this design fixes.

| ID    | Decision                                                                                                                  | Why                                                                                                                 | Consequence                                                                                                      |
| ----- | ------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| AD-1  | The compatibility matrix file is the manifest                                                                             | one flat file every tool and platform can read; drift is detectable at build time                                   | every pin lives there; a pin moved anywhere else fails the build                                                 |
| AD-2  | One matrix, one image, one immutable tag                                                                                  | a verified set must stay verifiable; users pin to it                                                                | `latest` and channels are moving tags over immutable ones; nothing is ever republished under an existing version |
| AD-3  | Toolchains live in a volume, seeded from the image                                                                        | an 8 GB toolchain in every image defeats pulls, updates, and profiles; a seed is a tenth of the size and verifiable | the first start costs about a minute; the volume is a cache and may be deleted at any time                       |
| AD-4  | Native images for amd64 and arm64 Linux; no emulation in the default path                                                 | a large share of users run Apple Silicon; emulated GHC is too slow to use                                           | each architecture builds on its own machine; one tag serves both                                                 |
| AD-5  | The container adopts the host user                                                                                        | files written into the project must belong to the developer                                                         | the uid is discovered at run time; one image serves everybody; HOME stays fixed                                  |
| AD-6  | The launcher mounts the repository root                                                                                   | builds need the cabal project file, sibling packages, and submodules                                                | a guard against mounting a home directory                                                                        |
| AD-7  | Editor integration through the Dev Container standard only; extensions install container-side; the image carries the list | no plugin to maintain; four editors supported at once; extensions sit next to the binaries                          | extensions are matrix pins                                                                                       |
| AD-8  | Every pin is an immutable reference                                                                                       | reproducibility                                                                                                     | a tool without tagged releases is pinned by commit hash                                                          |
| AD-9  | The image is self-describing                                                                                              | `matrix`, `doctor`, and editors must work offline                                                                   | matrices, the template, the metadata, and the version travel inside the image                                    |
| AD-10 | Two command-line programs share the name `cbde`, split by what needs Docker and what needs the volume                     | the developer sees one command; each half runs where its dependencies are                                           | the forwarding rule; `cabal-version` for switching cabal                                                         |
| AD-11 | Project selection is matrix, then `.cbde`, then `.cbde.local`; CBDE never creates or edits these files unasked            | team choices are committed, personal ones are not, and nothing moves silently                                       | every start re-resolves; the verdict names the source of any difference                                          |
| AD-12 | Nix is present as a tool, not required for the Plinth path, and not used in the image build                               | the PBT vendor builds under Nix; Plinth does not need it; a Nix-based pipeline would double the maintenance         | arm64 offers an x86_64 Nix path under Rosetta for projects whose libraries need it; the policy question stays open (O-2)                               |

## 25. Deliberately open

Each item names the options and the constraint that decides. Nothing here blocks the core of the design; several block a specific planned item, which is noted.

| ID   | Open point                                        | Options                                                                                                                                     | Decided by                                                                         | Blocks                                                    |
| ---- | ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- | --------------------------------------------------------- |
| O-1  | Profile list, names, and mechanism                | toggles only; image variants; features; a combination                                                                                       | the portfolio's final tool list and the size measurements of the conformance suite | F4, F5, the tag scheme                                    |
| O-2  | Nix policy for developers                         | keep `cbde nix` as a documented path; hide it; require vendors to ship cabal-only builds                                                    | whether the PBT vendor supports a cabal-only path                                  | nothing in the core                                       |
| O-3  | Version switching policy                          | supported feature; escape hatch with warnings; removed in favor of one image per Plinth version                                             | the Plinth version window (O-6) and conformance cost                               | nothing in the core                                       |
| O-4  | Command verb names                                | adopt the PRD's six verbs as the public surface and keep the current verbs as lower-level commands; keep the current verbs; a mix           | user testing with the first external developers                                    | documentation, the installer text                         |
| O-5  | Tool list                                         | cardano-cli in or out; the profiler and load tester when they exist; Aiken kept as a non-Plinth tool or dropped under the Plinth-only scope | product scope                                                                      | profile contents                                          |
| O-6  | Supported Plinth version window (PRD D6)          | one version; the latest two; a time window                                                                                                  | product and the maintenance budget                                                 | the build matrix size, the retention window, O-3          |
| O-7  | Conformance suite ownership (PRD D2)              | the high assurance team; the vendors; shared, with the team owning the gate and vendors owning expected results                             | the vendor engagements                                                             | the gate's maintenance                                    |
| O-8  | Channel cadence and retention window              | weekly beta and monthly stable as the PRD suggests, or aligned to Plinth releases; retention of 12 or 24 months                             | O-6 and the registry's storage cost                                                | the channel and retention rows of section 18              |
| O-9  | Blaster CLI and FVT extension                     | delivered by the vendor on a date; or built by this team from the Lean library                                                              | the vendor engagement                                                              | the formal verification part of F3 and the extension pins |
| O-10 | Website, configurator, telemetry | out of scope for this phase | product scope and budget | F7, F13 |
| O-11 | Prebuilt dependency store for reference contracts | ship in a workshop or CI profile; do not ship                                                                                               | measured size against the time saved                                               | nothing in the core                                       |
| O-12 | Upstream vendors tagging releases                 | tags on every release; or CBDE pins commits itself                                                                                          | the vendor engagements                                                             | the dependency bot                                        |

## 26. Risks

| Risk                                                              | Effect                                                                               | Mitigation in this design                                                                                                  |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------- |
| Volume growth                                                     | 25 to 30 GB after building a large project several times; surprising on laptops      | `cbde volume info` and a safe `volume rm`; a `doctor` warning on free disk                                                 |
| Upstream tools without tagged releases                            | a pin by commit is harder to track than a version; automation cannot detect releases | AD-8 until the vendors tag releases (O-12)                                                                                 |
| Two portfolio tools disagree on the compiler                      | a developer sees 'declared' and a `doctor` warning instead of a working pair         | the conformance gate turns this into a vendor notification before release                                                  |
| User id mapping inside editor dev containers on Linux hosts       | files owned by the wrong user, or a volume the editor's user cannot write            | the dev container smoke test in the conformance suite; the command-line path does not depend on the editor's mapping       |
| Rosetta dependency for projects that need `x86_64-linux` under Nix on Apple Silicon | `nix develop --system x86_64-linux` fails without Rosetta enabled in the runtime | `doctor` probes it and names the setting; the native path does not depend on it                                            |
| Docker runtime memory defaults on macOS                           | builds killed for lack of memory                                                     | `doctor` fails under 8 GB and says what to change                                                                          |
| `with-compiler` in a cabal project bypasses the per-project links | the wrong GHC runs silently                                                          | a `doctor` warning                                                                                                         |
| Maintenance ownership after the current project phase | the pipeline stops, images freeze | a risk the PRD names; everything here is scripted and documented so a small team can run it, but ownership is a product decision |
| The installer is a `curl` to `sh` pipe                            | trust in the download channel                                                        | HTTPS from the project repository, a `--try` mode, and a one-file launcher that can be read before use                     |

## 27. What the research prototype validated

This is the only section that talks about what exists. The design draws on a research prototype, the CBDE repository at compatibility matrix 0.2.0, which is where the sizes and timings in this document were measured. Everything above describes the target system; this section says how far the prototype goes, so that the work ahead can be planned.

| Section                      | Validated in the research prototype                                                                                                                                                                     | To build                                                                                                               |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| 1, 2 Launcher, volume, seeds | launcher, volume layout, seeded first start (about 60 s with no network; warm start about 0.5 s)                                                                                                        |                                                                                                                        |
| 3 Editor                     | dev container template, metadata label, extension list, `doctor` currency check                                                                                                                         | validation in a real editor session on a Linux host; extension version pins; the FVT extension (vendor)                |
| 4 Matrix verdicts and pins   | verdicts, pinning, `matrix list` from local images and the registry                                                                                                                                     |                                                                                                                        |
| 5 Platforms                  | Linux amd64 and arm64, Apple Silicon                                                                                                                                                                    | Windows validation                                                                                                     |
| 6 Matrix                     | file format, validation, drift check, rules 1 to 3                                                                                                                                                      | rule 4 for plustan and Blaster, pinned to branches until their upstreams tag releases; the verified Plinth version key |
| 7, 8 Image and volume        | as described                                                                                                                                                                                            |                                                                                                                        |
| 9 Start sequence             | identity adoption, provisioner, locking, atomic installs, retries                                                                                                                                       | stamp mismatch moved from a start-up warning to a `doctor` note                                                        |
| 10 Command-line interfaces   | both programs, the forwarding rule, settings precedence; verbs `devcontainer`, `matrix`, `ghc`, `cabal-version`, `hls`, `lean`, `sync`, `list`, `doctor`, `pull`, `build`, `volume`, `info`, `registry` | `init`, `export`, the breaking-change report, the rename of the ghcup metadata refresh                                 |
| 11 Projects and pins         | both files, precedence, per-container links, `sync`                                                                                                                                                     | the `with-compiler` warning                                                                                            |
| 12 Tools and extensions      | plustan, Aiken, Haskell, Lean, the PBT library path, the Blaster library path, HLS on request                                                                                                           | the Blaster CLI and the FVT extension (vendor deliverables), extension pins, scaffolding, automated per-project setup  |
| 13 Nix                       | as described, including the x86_64 path on arm64                                                                                                                                                        |                                                                                                                        |
| 14 Build                     | the seven stages, build from any matrix                                                                                                                                                                 | profile variants                                                                                                       |
| 15 Tests and CI              | 150 tests in seven suites on Linux and macOS; native multi-arch build and manifest in CI                                                                                                                | the slow tier automated as part of the conformance suite                                                               |
| 16 Registry                  | tag layout, two-machine publish, live listing, local registry                                                                                                                                           | the first public release                                                                                               |
| 17 Install and update        | installer, update in place, on-demand pull, `--try`                                                                                                                                                     | the breaking-change report, the single removal command                                                                 |
| 18 Release                   | the procedure, the manifest, the build matrix                                                                                                                                                           | triggers, dependency bot, conformance gate, channels, signing, retention policy, vendor notification                   |
| 19 Conformance               | unit tests, strict seed install at build, drift check                                                                                                                                                   | the suite itself and its reference projects                                                                            |
| 20 Profiles                  | start-time toggles                                                                                                                                                                                      | image variants, the CI profile and its GitHub Action; features pending O-1                                             |
| 21 Security                  | non-root execution, mount scope, pins, authenticated index                                                                                                                                              | the home-directory guard, signing                                                                                      |

## 28. Glossary

| Term                          | Meaning                                                                                                                               |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Aiken                         | a smart contract language and compiler for Cardano, shipped as a static binary                                                        |
| Blaster                       | the formal verification tool: a Lean 4 tactic with an SMT backend (Z3), from the IOG high assurance portfolio                         |
| CHaP                          | Cardano Haskell Packages, the package repository for Cardano-specific Haskell libraries                                               |
| Compatibility matrix (matrix) | a named, versioned set of tool versions verified to work together, stored as one file; one matrix is one image                        |
| Dev Container                 | an open specification for defining a containerized development environment, implemented by VS Code, Cursor, JetBrains, and Codespaces |
| Dev Container feature         | an installable unit that a dev container composes in at build time                                                                    |
| elan                          | the Lean toolchain manager, the equivalent of ghcup for Lean                                                                          |
| Entrypoint                    | the script that runs first in every container: identity, then provisioning, then the command                                          |
| FVT                           | the formal verification tool's editor extension, the editor face of Blaster                                                           |
| ghcup                         | the Haskell toolchain installer, used to install GHC, cabal, and HLS into the volume                                                  |
| HLS                           | the Haskell Language Server, the engine behind Haskell editor support                                                                 |
| Image                         | the container image built from one matrix, for one architecture; two architectures publish under one tag                              |
| Index-state                   | a timestamp naming a snapshot of a package index; pinning it makes dependency resolution reproducible                                 |
| Lake                          | Lean's build system                                                                                                                   |
| Launcher                      | the `cbde` script on the host: a wrapper around `docker run`                                                                          |
| Manager                       | the `cbde` program inside the container: version switching, matrix verdicts, `doctor`                                                 |
| Matrix verdict                | verified, declared, or custom: how the active toolchain relates to the image's matrix                                                 |
| PBT                           | the property-based testing tools (sc-testing-tools), Haskell libraries plus an editor extension                                       |
| Pin                           | a recorded choice: a matrix in `.cbde`, or a tool version in a matrix file                                                            |
| Plinth                        | formerly Plutus Tx, the smart contract language for Cardano                                                                           |
| plustan                       | the Plinth static analyzer, built on stan                                                                                             |
| PRD | the product requirements document: 'Container-Based Development Environment', version 2.0, the companion to this document; it states what the product must do, and this document traces its requirement IDs (F, N, D) |
| Profile                       | a matrix plus a selection of baked binaries, seeds, and extensions, published as an image                                             |
| Provisioner                   | the script that makes the volume match the matrix and the project on every start                                                      |
| Seed                          | a compressed installer carried in the image and unpacked into the volume on first start                                               |
| Volume                        | the named Docker volume mounted at `/nix` that caches toolchains, stores, and indices                                                 |
