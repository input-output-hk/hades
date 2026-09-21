#!/usr/bin/env bash
# `cbde` as it runs inside the container: matrix verbs, with ghcup, elan and
# the toolchain binaries stubbed and the volume faked.
. "$(dirname "$0")/harness.sh"
export PATH="$STUBS:$PATH"
export CBDE_LIB="$REPO/lib/matrix.sh"
export CBDE_MATRIX_DIR="$FIXTURES/matrices"
export CBDE_IMAGE_VERSION=0.2.0
export CBDE_LEAN=leanprover/lean4:v4.24.0 CBDE_GHC=9.6.7 CBDE_CABAL=3.10.3.0 CBDE_PLUSTAN_GHC=9.6.7
INNER="$REPO/cbde"

# A fake /nix volume: ghcup root with the pinned cabal but no GHC yet.
fake_volume() {
  export GHCUP_INSTALL_BASE_PREFIX="$T/nix/cbde" CBDE_MOUNTS_FILE="$T/mounts"
  mkdir -p "$T/nix/cbde/.ghcup/bin" "$T/nix/cbde/.ghcup/ghc"
  printf 'vol /nix ext4 rw 0 0\n' > "$T/mounts"
  : > "$T/nix/cbde/.ghcup/bin/cabal-3.10.3.0"; chmod +x "$T/nix/cbde/.ghcup/bin/cabal-3.10.3.0"
}

test_matrix_list_stars_this_image() {
  run "$INNER" matrix list
  assert_rc "$rc" 0 "$out"
  assert_match "$out" '^ +0\.1\.0 +GHC 9\.6\.6 '
  assert_match "$out" '^ +\* 0\.2\.0 +GHC 9\.6\.7 .*<- this image$'
}

test_matrix_show_is_verified_when_the_toolchain_matches() {
  run "$INNER" matrix
  assert_rc "$rc" 0 "$out"
  assert_contains "$out" "Compatibility matrix 0.2.0 (this image)"
  assert_contains "$out" "plustan main"
  assert_contains "$out" "verified: the active toolchain is exactly matrix 0.2.0"
}

test_matrix_show_is_custom_after_a_switch() {
  STUB_GHC=9.6.6 run "$INNER" matrix show
  assert_rc "$rc" 0 "$out"
  assert_contains "$out" "GHC    pinned 9.6.7, active 9.6.6"
  assert_contains "$out" "custom: the active toolchain differs from matrix 0.2.0"
  assert_contains "$out" "cbde matrix reset"
}

test_matrix_show_another_matrix_is_read_only() {
  run "$INNER" matrix show 0.1.0
  assert_rc "$rc" 0 "$out"
  assert_contains "$out" "Compatibility matrix 0.1.0 (this container is 0.2.0)"
  assert_contains "$out" "GHC    9.6.6"
  assert_not_contains "$out" "verified"
}

test_switching_to_another_matrix_means_another_image() {
  run "$INNER" matrix 0.1.0
  assert_rc "$rc" 2
  assert_contains "$out" "matrix 0.1.0 ships as its own image, cbde:0.1.0"
  assert_contains "$out" "On the host:   cbde matrix 0.1.0"
  run "$INNER" matrix 9.9.9
  assert_rc "$rc" 1; assert_contains "$out" "no such matrix: 9.9.9"
  run "$INNER" matrix 'rm -rf /'
  assert_rc "$rc" 2; assert_contains "$out" "unknown matrix subcommand"
}

test_matrix_reset_installs_what_is_missing_and_sets_the_rest() {
  fake_volume; export CBDE_SEED_DIR="$T/no-seed"
  STUB_LEAN= run "$INNER" matrix reset
  assert_rc "$rc" 0 "$out"
  local log; log="$(cat "$STUB_LOG")"
  assert_contains "$log" "ghcup install ghc 9.6.7"
  assert_contains "$log" "ghcup set ghc 9.6.7"
  assert_not_contains "$log" "ghcup install cabal"
  assert_contains "$log" "ghcup set cabal 3.10.3.0"
  assert_contains "$log" "elan toolchain install leanprover/lean4:v4.24.0"
  assert_contains "$log" "elan default leanprover/lean4:v4.24.0"
}

test_matrix_reset_uses_the_image_seed_when_it_has_the_version() {
  fake_volume
  export CBDE_SEED_DIR="$T/seed"; mkdir -p "$T/seed"
  : > "$T/seed/ghc-9.6.7-x86_64-ubuntu22_04-linux.tar.xz"
  run "$INNER" matrix reset
  assert_rc "$rc" 0 "$out"
  assert_contains "$out" "installing ghc 9.6.7 from the image (no download)"
  assert_contains "$(cat "$STUB_LOG")" "ghcup --offline --cache install ghc 9.6.7"
  assert_not_contains "$(cat "$STUB_LOG")" "ghcup install ghc"
}

test_matrix_reset_unpacks_lean_from_the_seed() {
  command -v xz >/dev/null 2>&1 || return 0
  fake_volume; mkdir -p "$T/nix/cbde/.ghcup/ghc/9.6.7"
  export CBDE_SEED_DIR="$T/seed" CBDE_ELAN_DIR="$T/nix/cbde/elan"
  mkdir -p "$T/seed" "$T/pack/leanprover--lean4---v4.24.0/bin"
  tar -C "$T/pack" -c leanprover--lean4---v4.24.0 | xz > "$T/seed/lean-leanprover--lean4---v4.24.0.tar.xz"
  STUB_LEAN= run "$INNER" matrix reset
  assert_rc "$rc" 0 "$out"
  assert_contains "$out" "installing Lean leanprover/lean4:v4.24.0 from the image (no download)"
  assert_file "$T/nix/cbde/elan/toolchains/leanprover--lean4---v4.24.0"
  assert_not_contains "$(cat "$STUB_LOG")" "elan toolchain install"
}

test_ghc_switch_to_an_unseeded_version_downloads() {
  fake_volume
  export CBDE_SEED_DIR="$T/seed"; mkdir -p "$T/seed"
  run "$INNER" ghc 9.6.6
  assert_rc "$rc" 0 "$out"
  assert_contains "$(cat "$STUB_LOG")" "ghcup install ghc 9.6.6"
  assert_not_contains "$(cat "$STUB_LOG")" "--offline"
}

test_matrix_reset_is_idempotent_when_already_verified() {
  fake_volume; mkdir -p "$T/nix/cbde/.ghcup/ghc/9.6.7"
  run "$INNER" matrix reset
  assert_rc "$rc" 0 "$out"
  assert_not_contains "$(cat "$STUB_LOG")" "install"
  assert_contains "$out" "verified"
}

test_own_matrix_by_name_is_the_same_as_reset() {
  fake_volume; mkdir -p "$T/nix/cbde/.ghcup/ghc/9.6.7"
  run "$INNER" matrix 0.2.0
  assert_rc "$rc" 0 "$out"; assert_contains "$out" "verified"
}

test_missing_matrix_file_for_this_image_is_reported() {
  CBDE_IMAGE_VERSION=7.7.7 run "$INNER" matrix
  assert_rc "$rc" 1; assert_contains "$out" "no such matrix: 7.7.7"
}

test_ghc_switch_warns_about_plustan() {
  fake_volume; mkdir -p "$T/nix/cbde/.ghcup/ghc/9.6.6"
  run "$INNER" ghc 9.6.6
  assert_rc "$rc" 0 "$out"
  assert_contains "$out" "plustan was built against GHC 9.6.7"
  assert_contains "$(cat "$STUB_LOG")" "ghcup set ghc 9.6.6"
}

test_help_and_unknown_verb() {
  run "$INNER" help;    assert_rc "$rc" 0; assert_contains "$out" "cbde matrix reset"
  run "$INNER" bogus;   assert_rc "$rc" 2; assert_contains "$out" "unknown command bogus"
}

run_tests
