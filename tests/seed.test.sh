#!/usr/bin/env bash
# ghcup_install: the matrix's toolchain comes from the image's seed when it has
# the version, and from the network otherwise.
. "$(dirname "$0")/harness.sh"
. "$REPO/lib/matrix.sh"
export PATH="$STUBS:$PATH"

setup() {
  export GHCUP_INSTALL_BASE_PREFIX="$T/nix/cbde" CBDE_SEED_DIR="$T/seed"
  mkdir -p "$T/seed" "$T/nix/cbde/.ghcup/cache"
  : > "$T/seed/ghc-9.6.7-x86_64-ubuntu22_04-linux.tar.xz"
  : > "$T/seed/cabal-install-3.10.3.0-x86_64-linux-ubuntu22.04.tar.xz"
}

test_seed_files_match_exact_version_only() {
  setup
  assert_eq "$(seed_files ghc 9.6.7)" "$T/seed/ghc-9.6.7-x86_64-ubuntu22_04-linux.tar.xz"
  assert_eq "$(seed_files cabal 3.10.3.0)" "$T/seed/cabal-install-3.10.3.0-x86_64-linux-ubuntu22.04.tar.xz"
  assert_eq "$(seed_files ghc 9.6.6)" "" "other version"
  assert_eq "$(seed_files ghc 9.6)" "" "prefix of a version is not a match"
  assert_eq "$(seed_files hls 2.9.0.0)" ""
  assert_eq "$(CBDE_SEED_DIR=/nonexistent seed_files ghc 9.6.7)" "" "no seed dir at all"
}

test_seeded_version_installs_offline_and_cleans_the_cache() {
  setup
  run ghcup_install ghc 9.6.7 --set
  assert_rc "$rc" 0 "$out"
  assert_contains "$out" "installing ghc 9.6.7 from the image (no download)"
  local log; log="$(cat "$STUB_LOG")"
  assert_contains "$log" "ghcup --offline --cache install ghc 9.6.7 --set"
  assert_contains "$log" "cache: ghc-9.6.7-x86_64-ubuntu22_04-linux.tar.xz" "bindist was staged in the cache during the call"
  assert_not_contains "$log" "ghcup install ghc"
  assert_no_file "$T/nix/cbde/.ghcup/cache/ghc-9.6.7-x86_64-ubuntu22_04-linux.tar.xz"
  assert_file "$T/seed/ghc-9.6.7-x86_64-ubuntu22_04-linux.tar.xz" "seed itself is untouched"
}

test_unseeded_version_goes_online() {
  setup
  run ghcup_install ghc 9.6.6 --set
  assert_rc "$rc" 0 "$out"
  assert_not_contains "$out" "from the image"
  assert_eq "$(grep -c '^ghcup' "$STUB_LOG")" 1
  assert_contains "$(cat "$STUB_LOG")" "ghcup install ghc 9.6.6 --set"
  assert_not_contains "$(cat "$STUB_LOG")" "--offline"
}

test_offline_failure_falls_back_to_online() {
  setup
  STUB_GHCUP_FAIL=--offline run ghcup_install ghc 9.6.7 --set
  assert_rc "$rc" 0 "$out"
  assert_contains "$out" "offline install from the seed failed, downloading instead"
  assert_contains "$(cat "$STUB_LOG")" "ghcup --offline --cache install ghc 9.6.7 --set"
  assert_contains "$(cat "$STUB_LOG")" "ghcup install ghc 9.6.7 --set"
  assert_no_file "$T/nix/cbde/.ghcup/cache/ghc-9.6.7-x86_64-ubuntu22_04-linux.tar.xz" "cache cleaned even on failure"
}

test_strict_mode_does_not_fall_back() {
  setup
  STUB_GHCUP_FAIL=--offline CBDE_SEED_STRICT=1 run ghcup_install ghc 9.6.7 --set
  assert_rc "$rc" 1
  assert_contains "$out" "not falling back"
  assert_eq "$(grep -c '^ghcup' "$STUB_LOG")" 1 "only the offline attempt"
}

test_existing_cache_file_is_not_overwritten_or_removed() {
  setup
  printf 'user-cached' > "$T/nix/cbde/.ghcup/cache/ghc-9.6.7-x86_64-ubuntu22_04-linux.tar.xz"
  run ghcup_install ghc 9.6.7
  assert_rc "$rc" 0 "$out"
  assert_eq "$(cat "$T/nix/cbde/.ghcup/cache/ghc-9.6.7-x86_64-ubuntu22_04-linux.tar.xz")" "user-cached"
}

# ---- Lean ------------------------------------------------------------------
# Needs xz on the host; macOS runners may lack it, in which case these skip.
have_xz() { command -v xz >/dev/null 2>&1; }

lean_setup() {
  export CBDE_SEED_DIR="$T/seed" CBDE_ELAN_DIR="$T/nix/cbde/elan"
  mkdir -p "$T/seed" "$T/nix/cbde/elan" "$T/pack/leanprover--lean4---v4.24.0/bin"
  printf '#!/bin/sh\necho fake lean\n' > "$T/pack/leanprover--lean4---v4.24.0/bin/lean"
  have_xz && tar -C "$T/pack" -c leanprover--lean4---v4.24.0 | xz > "$T/seed/lean-leanprover--lean4---v4.24.0.tar.xz"
}

test_elan_toolchain_dir_naming() {
  assert_eq "$(elan_toolchain_dir leanprover/lean4:v4.24.0)" "leanprover--lean4---v4.24.0"
  assert_eq "$(elan_toolchain_dir leanprover/lean4:nightly-2026-01-01)" "leanprover--lean4---nightly-2026-01-01"
}

test_lean_seeded_toolchain_is_unpacked_and_set_default() {
  have_xz || return 0
  lean_setup
  run lean_install leanprover/lean4:v4.24.0
  assert_rc "$rc" 0 "$out"
  assert_contains "$out" "installing Lean leanprover/lean4:v4.24.0 from the image (no download)"
  assert_file "$T/nix/cbde/elan/toolchains/leanprover--lean4---v4.24.0/bin/lean"
  assert_contains "$(cat "$STUB_LOG")" "elan default leanprover/lean4:v4.24.0"
  assert_not_contains "$(cat "$STUB_LOG")" "elan toolchain install"
  assert_eq "$(ls -A "$T/nix/cbde/elan/toolchains")" "leanprover--lean4---v4.24.0" "no unpack leftovers"
}

test_lean_unseeded_toolchain_downloads() {
  lean_setup
  run lean_install leanprover/lean4:v4.22.0
  assert_rc "$rc" 0 "$out"
  assert_not_contains "$out" "from the image"
  assert_contains "$(cat "$STUB_LOG")" "elan toolchain install leanprover/lean4:v4.22.0"
  assert_contains "$(cat "$STUB_LOG")" "elan default leanprover/lean4:v4.22.0"
}

test_lean_corrupt_seed_falls_back_unless_strict() {
  lean_setup
  printf 'not an xz file' > "$T/seed/lean-leanprover--lean4---v4.24.0.tar.xz"
  run lean_install leanprover/lean4:v4.24.0
  assert_rc "$rc" 0 "$out"
  assert_contains "$out" "Lean install from the seed failed, downloading instead"
  assert_contains "$(cat "$STUB_LOG")" "elan toolchain install leanprover/lean4:v4.24.0"
  assert_eq "$(ls -A "$T/nix/cbde/elan/toolchains")" "" "no half-unpacked toolchain left behind"
  : > "$STUB_LOG"
  CBDE_SEED_STRICT=1 run lean_install leanprover/lean4:v4.24.0
  assert_rc "$rc" 1
  assert_not_contains "$(cat "$STUB_LOG")" "elan toolchain install"
}

# ---- package indices ---------------------------------------------------------
index_setup() {
  export CBDE_SEED_DIR="$T/seed" CBDE_CABAL_DIR="$T/nix/cbde/cabal" CBDE_WARM_INDEX="$T/warm"
  export CBDE_INDEX_STATE=2026-09-21T04:01:53Z CBDE_CHAP_INDEX_STATE=2026-09-16T23:53:07Z
  mkdir -p "$T/seed" "$T/nix/cbde/cabal" "$T/warm" "$T/pack/hackage.haskell.org" "$T/pack/cardano-haskell-packages"
  printf 'repository cardano-haskell-packages\n' > "$T/warm/cabal.project"
  : > "$T/pack/hackage.haskell.org/01-index.tar"; : > "$T/pack/hackage.haskell.org/01-index.cache"
  : > "$T/pack/cardano-haskell-packages/01-index.tar"
  have_xz && tar -C "$T/pack" -c hackage.haskell.org cardano-haskell-packages | xz > "$T/seed/cabal-packages.tar.xz"
}

test_index_seeded_is_unpacked_without_cabal_update() {
  have_xz || return 0
  index_setup
  run cabal_index_install
  assert_rc "$rc" 0 "$out"
  assert_contains "$out" "installing the package indices from the image (no download)"
  assert_file "$T/nix/cbde/cabal/packages/hackage.haskell.org/01-index.tar"
  assert_file "$T/nix/cbde/cabal/packages/cardano-haskell-packages/01-index.tar"
  assert_not_contains "$(cat "$STUB_LOG" 2>/dev/null)" "cabal update"
  assert_eq "$(ls -A "$T/nix/cbde/cabal/packages" | sort | tr '\n' ' ')" "cardano-haskell-packages hackage.haskell.org " "no unpack leftovers"
}

test_index_unseeded_runs_cabal_update_at_the_pinned_states() {
  index_setup; rm -f "$T/seed/cabal-packages.tar.xz"
  run cabal_index_install
  assert_rc "$rc" 0 "$out"
  assert_contains "$(cat "$STUB_LOG")" "cabal update hackage.haskell.org,2026-09-21T04:01:53Z cardano-haskell-packages,2026-09-16T23:53:07Z"
  assert_eq "$(ls -A "$T/warm")" "cabal.project" "warm-index project itself untouched"
}

test_index_without_pinned_states_runs_plain_cabal_update() {
  index_setup; rm -f "$T/seed/cabal-packages.tar.xz"; unset CBDE_INDEX_STATE CBDE_CHAP_INDEX_STATE
  run cabal_index_install
  assert_rc "$rc" 0 "$out"
  assert_match "$(cat "$STUB_LOG")" '^cabal update$'
}

test_index_corrupt_seed_falls_back_unless_strict() {
  index_setup
  printf 'not xz' > "$T/seed/cabal-packages.tar.xz"
  run cabal_index_install
  assert_rc "$rc" 0 "$out"
  assert_contains "$out" "index install from the seed failed, downloading instead"
  assert_contains "$(cat "$STUB_LOG")" "cabal update hackage.haskell.org,"
  assert_eq "$(ls -A "$T/nix/cbde/cabal/packages")" "" "nothing half-unpacked"
  : > "$STUB_LOG"
  CBDE_SEED_STRICT=1 run cabal_index_install
  assert_rc "$rc" 1
  assert_not_contains "$(cat "$STUB_LOG")" "cabal update"
}

run_tests
