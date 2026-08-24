# syntax=docker/dockerfile:1

# CBDE — Container Based Development Environment
# Base image: Ubuntu 24.04 + IOG crypto libs + Nix + tools; the Haskell and
# Lean toolchains are provisioned into a persistent volume, not baked in.
# Design rationale and lessons: see PLAN.md (esp. §3-§5, §9).

# Versions are global ARGs so the same pin reaches several stages.
ARG CBDE_GHC=9.6.7
ARG CBDE_CABAL=3.10.3.0
ARG GHCUP_VERSION=0.2.6.2
ARG LEAN_TOOLCHAIN=leanprover/lean4:v4.24.0
# Bump whenever the /nix layout changes: a volume records the version that
# created it, and cbde-provision warns when the two disagree (Docker only
# seeds *empty* volumes, so old volumes otherwise shadow new image content).
ARG CBDE_IMAGE_VERSION=0.2.0

# ---------------------------------------------------------------------------
# Stage 1: build the Cardano crypto C libraries from source.
#   - IOG libsodium fork: upstream libsodium lacks crypto_vrf_*_batchcompat.
#   - NEVER install distro libsodium-dev in the final image, or -lsodium
#     resolves to the wrong library and linking cardano-crypto-praos fails.
#   - blst >= 0.3.14: cardano-crypto-class checks `pkg-config libblst >= 0.3.14`;
#     distro packages are older.
# ---------------------------------------------------------------------------
FROM ubuntu:24.04 AS crypto-builder

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential autoconf automake autotools-dev libtool pkg-config \
      ca-certificates curl git \
    && rm -rf /var/lib/apt/lists/*

# IOG libsodium fork (iohk-stable-vmm), pinned as in cardano-node docs.
ARG LIBSODIUM_REV=dbb48cce5429cb6585c9034f002568964f1ce567
RUN git clone https://github.com/input-output-hk/libsodium /tmp/libsodium \
    && cd /tmp/libsodium && git checkout "$LIBSODIUM_REV" \
    && ./autogen.sh \
    # autogen.sh's download of config.guess/config.sub can return a bogus
    # page; replace with the distro copies.
    && cp /usr/share/misc/config.guess /usr/share/misc/config.sub build-aux/ \
    && ./configure --prefix=/usr/local \
    && make -j"$(nproc)" && make install

# libsecp256k1, pinned as in cardano-node docs.
ARG SECP256K1_REV=ac83be33d0956faf6b7f61a60ab524ef7d6a473a
RUN git clone https://github.com/bitcoin-core/secp256k1 /tmp/secp256k1 \
    && cd /tmp/secp256k1 && git checkout "$SECP256K1_REV" \
    && ./autogen.sh \
    && ./configure --prefix=/usr/local --enable-module-schnorrsig --enable-experimental \
    && make -j"$(nproc)" && make install

# blst v0.3.14 (static lib + headers + pkg-config file; upstream ships no .pc).
ARG BLST_TAG=v0.3.14
RUN git clone --depth 1 --branch "$BLST_TAG" https://github.com/supranational/blst /tmp/blst \
    && cd /tmp/blst && ./build.sh \
    && install -Dm644 libblst.a /usr/local/lib/libblst.a \
    && install -Dm644 bindings/blst.h bindings/blst_aux.h -t /usr/local/include \
    && { \
         echo 'prefix=/usr/local'; \
         echo 'exec_prefix=${prefix}'; \
         echo 'libdir=${exec_prefix}/lib'; \
         echo 'includedir=${prefix}/include'; \
         echo ''; \
         echo 'Name: libblst'; \
         echo 'Description: BLS12-381 signature library'; \
         echo 'Version: 0.3.14'; \
         echo 'Libs: -L${libdir} -lblst'; \
         echo 'Cflags: -I${includedir}'; \
       } > /usr/local/lib/pkgconfig/libblst.pc

# ---------------------------------------------------------------------------
# Stage 2: base — system layer. Carries ghcup itself but NO GHC and NO HLS.
# ---------------------------------------------------------------------------
FROM ubuntu:24.04 AS base

ARG DEBIAN_FRONTEND=noninteractive

# Cardano crypto libs (runtime .so + headers + pkg-config).
COPY --from=crypto-builder /usr/local /usr/local
RUN ldconfig

# Toolchain + project system deps.
# NOTE: intentionally NO libsodium-dev / libsecp256k1-dev / libblst-dev here.
# These build tools are NOT removable from the final image: plustan shells out
# to `cabal build` in the analyzed project, so a C toolchain and the -dev
# headers are runtime requirements, not build-only ones.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential curl git pkg-config ca-certificates xz-utils \
      libffi-dev libgmp-dev libncurses-dev libtinfo6 libnuma-dev \
      zlib1g-dev libsystemd-dev liblmdb-dev \
      nodejs npm jq \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ghcup, as the standalone binary rather than get-ghcup.haskell.org.
# The bootstrap script installs a GHC (and tests BOOTSTRAP_HASKELL_INSTALL_HLS
# with `[ -n ... ]`, so even `=0` installs HLS — 2.5 GB by accident). We want
# neither in the image: cbde-provision installs them into the volume.
ARG GHCUP_VERSION
RUN curl -fsSL -o /opt/cbde-ghcup \
      "https://downloads.haskell.org/~ghcup/${GHCUP_VERSION}/x86_64-linux-ghcup-${GHCUP_VERSION}" \
    && install -Dm755 /opt/cbde-ghcup /opt/cbde/ghcup && rm /opt/cbde-ghcup \
    && /opt/cbde/ghcup --version \
    # Bake ghcup's release metadata (663 KB) so the first provision needs no
    # metadata fetch. Taken from the haskell.org mirror rather than
    # raw.githubusercontent.com, which rate-limits (HTTP 429) and broke a build.
    && curl -fsSL -o /opt/cbde/ghcup-0.1.0.yaml \
         https://www.haskell.org/ghcup/data/ghcup-0.1.0.yaml

# ghcup root lives in the volume: /nix/cbde/.ghcup, a sibling of cabal/ and
# elan/. Unlike cabal (~/.cabal) and elan (~/.elan), whose paths are hardcoded
# and therefore need symlinks, ghcup takes this as an environment variable.
ARG CBDE_GHC
ARG CBDE_CABAL
ARG CBDE_IMAGE_VERSION
ENV GHCUP_INSTALL_BASE_PREFIX=/nix/cbde \
    GHCUP_SKIP_UPDATE_CHECK=1 \
    PATH=/nix/cbde/.ghcup/bin:$PATH \
    CBDE_GHC=${CBDE_GHC} \
    CBDE_CABAL=${CBDE_CABAL} \
    CBDE_HLS= \
    CBDE_IMAGE_VERSION=${CBDE_IMAGE_VERSION}

# Nix (single-user, no daemon — containers have no systemd).
# sandbox=false: nix sandboxing needs privileges most containers don't have.
# NOTE: /nix must stay a REAL directory (Nix refuses a symlinked store path),
# so the single-volume layout puts the OTHER caches inside /nix instead.
RUN mkdir -m 0755 /nix \
    && mkdir -p /etc/nix \
    && { \
         echo 'experimental-features = nix-command flakes'; \
         echo 'sandbox = false'; \
         echo 'build-users-group ='; \
         echo 'extra-substituters = https://cache.iog.io https://sc-testing-tools.cachix.org'; \
         echo 'extra-trusted-public-keys = hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ= sc-testing-tools.cachix.org-1:EdJM0ldUx5PeP16xc1fjZ5oCGgryZJxf/Q1MHQ40M8s='; \
         echo 'accept-flake-config = true'; \
       } > /etc/nix/nix.conf \
    && curl -L https://nixos.org/nix/install | sh -s -- --no-daemon \
    && /root/.nix-profile/bin/nix --version
ENV PATH=/root/.nix-profile/bin:$PATH

# pkg-config must see /usr/local (blst, libsodium, secp256k1).
ENV PKG_CONFIG_PATH=/usr/local/lib/pkgconfig

# cabal's store must land in the volume. /root/.cabal has to EXIST (as a
# symlink is fine) before cabal first runs: its presence is what makes cabal
# 3.10 choose the legacy layout (~/.cabal/store) over ~/.local/state/cabal.
RUN mkdir -p /nix/cbde/cabal && ln -s /nix/cbde/cabal /root/.cabal

# Repository stanza used only to warm the CHaP index (projects declare their
# own). Kept out of ~/.cabal/config so we never fight a project's cabal.project.
RUN mkdir -p /opt/cbde/warm-index \
    && { \
         echo 'repository cardano-haskell-packages'; \
         echo '  url: https://chap.intersectmbo.org/'; \
         echo '  secure: True'; \
         echo '  root-keys:'; \
         echo '    3e0cce471cf09815f930210f7827266fd09045445d65923e6d0238a6cd15126f'; \
         echo '    443abb7fb497a134c343faf52f0b659bd7999bc06b7f63fa76dc99d631f9bea1'; \
         echo '    a86a1f6ce86c449c46666bda44268677abf29b5b2d2eb5ec7af903ec2f117a82'; \
         echo '    bcec67e8e99cabfa7764d75ad9b158d72bfacf70ca1d0ec8bc6b4406d1bf8413'; \
         echo '    c00aae8461a256275598500ea0e187588c35a5d5d7454fb57eac18d9edb86a56'; \
         echo '    d4a35cd3121aa00d18544bb0ac01c3e1691d618f462c46129271bccf39f7e8ee'; \
       } > /opt/cbde/warm-index/cabal.project

WORKDIR /workspace
CMD ["bash"]

# ---------------------------------------------------------------------------
# Stage 2b: toolchain — base with the pinned GHC/cabal materialized into the
# image layer, for the build stages that need a compiler. Uses the exact same
# provisioning code path as the runtime, so the two cannot drift.
# ---------------------------------------------------------------------------
FROM base AS toolchain
# Only the provisioner, so that edits to the `cbde` CLI or the entrypoint do
# not invalidate this stage and force plu-stan to rebuild from scratch.
COPY cbde-provision /usr/local/bin/
RUN CBDE_FORCE_PROVISION=1 cbde-provision \
    && ghc --version && cabal --version

# ---------------------------------------------------------------------------
# Stage 3: build plu-stan.
#   -f-fixtures: skips the plutus-based fixture library, so no Cardano crypto
#   libs are needed to build the tool itself (same as upstream release CI).
#   NOTE: plustan reads .hie files, which are locked to the exact GHC patch
#   version — its build GHC IS the only GHC it can analyze projects under, and
#   is recorded as CBDE_PLUSTAN_GHC in the final image.
# ---------------------------------------------------------------------------
FROM toolchain AS plustan-builder

ARG PLUSTAN_REPO=https://github.com/input-output-hk/plu-stan
ARG PLUSTAN_REF=main
RUN git clone --depth 1 --branch "$PLUSTAN_REF" "$PLUSTAN_REPO" /opt/plu-stan

WORKDIR /opt/plu-stan
# NOTE: --flags must be passed to list-bin as well — a flag-less invocation
# re-solves with +fixtures (default) and pulls in the plutus fixture deps.
# The cabal store is a BuildKit cache mount, so editing cbde-provision (which
# this stage depends on, deliberately, to keep build-time and run-time
# provisioning identical) does not mean recompiling every dependency again.
RUN --mount=type=cache,target=/nix/cbde/cabal/store,sharing=locked \
    cabal build --flags=-fixtures exe:plustan exe:stan \
    && install -Dm755 "$(cabal list-bin --flags=-fixtures exe:plustan)" /out/plustan \
    && install -Dm755 "$(cabal list-bin --flags=-fixtures exe:stan)" /out/stan

# ---------------------------------------------------------------------------
# Stage 3b: fetch the Aiken compiler (static musl binary, zero runtime deps).
# ---------------------------------------------------------------------------
FROM base AS aiken-dl

ARG AIKEN_VERSION=v1.1.23
RUN curl -fsSL \
      "https://github.com/aiken-lang/aiken/releases/download/${AIKEN_VERSION}/aiken-x86_64-unknown-linux-musl.tar.gz" \
      | tar -xz -C /tmp \
    && install -Dm755 /tmp/aiken-x86_64-unknown-linux-musl/aiken /out/aiken \
    && /out/aiken --version

# ---------------------------------------------------------------------------
# Stage 3c: Blaster (Lean 4 SMT backend).
#   - Z3 4.15.2 built from source (repo recommends exactly this tag).
#   - Lean toolchain via elan, pinned by the repo's lean-toolchain (v4.24.0).
#   - Blaster itself is a lake dependency in user projects; we clone + build it
#     here as a smoke test and to warm the lake cache.
#   Deliberately NOT derived from `base`: nothing here needs the Haskell side,
#   and this stage is expensive (Z3 from source), so keeping it independent
#   means Haskell-side changes don't invalidate its cache.
# ---------------------------------------------------------------------------
FROM ubuntu:24.04 AS blaster-builder

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential git curl ca-certificates python3 libgmp-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

ARG Z3_TAG=z3-4.15.2
RUN git clone --depth 1 --branch "$Z3_TAG" https://github.com/Z3Prover/z3 /tmp/z3 \
    && cd /tmp/z3 && python3 scripts/mk_make.py --prefix=/usr/local \
    && cd build && make -j"$(nproc)" && make install

ARG LEAN_TOOLCHAIN
RUN curl -sSfL https://elan.lean-lang.org/elan-init.sh \
      | sh -s -- -y --default-toolchain "$LEAN_TOOLCHAIN" \
    && /root/.elan/bin/lean --version
ENV PATH=/root/.elan/bin:$PATH

ARG BLASTER_REPO=https://github.com/input-output-hk/Lean-blaster
ARG BLASTER_REF=main
RUN git clone --depth 1 --branch "$BLASTER_REF" "$BLASTER_REPO" /opt/blaster \
    && cd /opt/blaster \
    && lake build \
    && lake build z3check && lake exe z3check

# ---------------------------------------------------------------------------
# Stage 4: final image = base + tool binaries.
# ---------------------------------------------------------------------------
FROM base AS final

# Mounted project dirs are owned by the host user; let git (and nix flakes,
# which shell out to libgit2) operate on them regardless.
RUN git config --system --add safe.directory '*'

# A non-root user for the runtime. HOME is deliberately /root, not /home/cbde:
# that keeps ~/.cabal and ~/.elan — and therefore cabal's legacy store layout
# and the exact toolchain path /opt/blaster's .lake artifacts were built
# against — identical whichever user ends up running. cbde-entrypoint retargets
# this user's uid/gid to whoever owns the mounted project at run time, so one
# published image serves every host uid.
# Ubuntu 24.04 ships an `ubuntu` user on uid 1000; we need that id free.
RUN userdel -r ubuntu >/dev/null 2>&1 || true; \
    groupadd -g 1000 cbde \
    && useradd -u 1000 -g 1000 -M -d /root -s /bin/bash cbde

COPY cbde-provision cbde-entrypoint cbde /usr/local/bin/

# The devcontainer template, so `cbde devcontainer` can drop it into a project
# from inside the container and `cbde doctor` can tell whether a project's copy
# is current. Stamped with the image version at build time.
COPY .devcontainer/devcontainer.json /opt/cbde/devcontainer.json
ARG CBDE_IMAGE_VERSION
RUN sed -i "s/\"\/\/cbde-template\": \"dev\"/\"\/\/cbde-template\": \"${CBDE_IMAGE_VERSION}\"/" \
      /opt/cbde/devcontainer.json \
    && grep -q "\"${CBDE_IMAGE_VERSION}\"" /opt/cbde/devcontainer.json

COPY --from=plustan-builder /out/plustan /out/stan /usr/local/bin/
COPY --from=aiken-dl /out/aiken /usr/local/bin/

# The GHC plustan was compiled against — the only one whose .hie files it can
# read. `cbde ghc` and `cbde doctor` warn when the active GHC differs.
ARG CBDE_GHC
ENV CBDE_PLUSTAN_GHC=${CBDE_GHC}

# Blaster: elan + Z3 + the pre-built Blaster checkout.
#
# Only elan's bin/ ships in the image (13 MB — seven hardlinks to one binary
# that dispatches on argv[0]). The Lean toolchain itself is 2.3 GB and is
# provisioned into the volume by cbde-provision, exactly like GHC.
#
# /root/.elan stays a symlink rather than switching to ELAN_HOME: the .lake
# artifacts in /opt/blaster were built with the toolchain resolved through that
# path, so keeping it identical is what makes the prebuilt checkout usable.
ARG LEAN_TOOLCHAIN
ENV CBDE_LEAN=${LEAN_TOOLCHAIN}
COPY --from=blaster-builder /root/.elan/bin /opt/cbde/elan-bin
COPY --from=blaster-builder /usr/local/bin/z3 /usr/local/bin/z3
COPY --from=blaster-builder /usr/local/lib/libz3.so* /usr/local/lib/
COPY --from=blaster-builder /usr/local/include/z3* /usr/local/include/
COPY --from=blaster-builder /opt/blaster /opt/blaster
RUN ldconfig && mkdir -p /nix/cbde/elan && ln -s /nix/cbde/elan /root/.elan
ENV PATH=/root/.elan/bin:$PATH

# Single-volume layout: the user mounts ONE named volume at /nix and Docker
# initializes the empty volume from the image content at that path
# (named-volume copy-up). All big mutable state is in there:
#   /nix/store        (nix store; /nix itself must be a real dir — Nix refuses
#                      a symlinked store path, which is why the layout is this
#                      way around and not /nix -> elsewhere)
#   /nix/cbde/.ghcup  GHC / cabal / HLS, installed on first use, switchable
#   /nix/cbde/elan    Lean toolchains, likewise
#   /nix/cbde/cabal   -> /root/.cabal  (cabal store + package indices)

# Hand /root to the cbde user at build time. /root is image content, so a
# runtime chown never persists into the next container — which meant an explicit
# `docker run --user 1000:1000` could not read its own HOME (mode 700, root's)
# and bash failed on /root/.bash_profile. Doing it here makes the common case
# (host uid 1000) work with or without --user, and makes the entrypoint's chown
# a no-op rather than real work.
RUN chown -R cbde:cbde /root && chmod 755 /root

WORKDIR /workspace

# Provisions the toolchain into the volume, then execs the command.
ENTRYPOINT ["/usr/local/bin/cbde-entrypoint"]

# Self-describing Dev Container metadata: when a project references this image
# (devcontainer.json "image"), VS Code merges these fragments — extensions and
# settings get installed container-side automatically. onCreateCommand is a
# belt-and-braces provision in case the tooling replaces our ENTRYPOINT.
LABEL devcontainer.metadata='[{ \
  "remoteUser": "cbde", \
  "updateRemoteUserUID": true, \
  "onCreateCommand": "cbde-provision", \
  "customizations": { \
    "vscode": { \
      "extensions": [ \
        "haskell.haskell", \
        "IOG.vscode-plustan", \
        "IOG.pbt-extension", \
        "leanprover.lean4", \
        "TxPipe.aiken" \
      ], \
      "settings": { \
        "plustan.binaryPath": "/usr/local/bin/plustan" \
      } \
    } \
  } \
}]'

CMD ["bash"]
