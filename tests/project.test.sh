#!/usr/bin/env bash
# Per-project toolchain selection: the matrix, overridden by a project's .cbde
# (team) and .cbde.local (personal), linked into a container-local bin dir so
# containers on different projects sharing one volume never share a choice.
. "$(dirname "$0")/harness.sh"
. "$REPO/lib/matrix.sh"
export PATH="$STUBS:$PATH"
export CBDE_LIB="$REPO/lib/matrix.sh"
export CBDE_MATRIX_DIR="$FIXTURES/matrices"
export CBDE_IMAGE_VERSION=0.2.0
export CBDE_LEAN=leanprover/lean4:v4.24.0 CBDE_GHC=9.6.7 CBDE_CABAL=3.10.3.0 CBDE_HLS= CBDE_PLUSTAN_GHC=9.6.7
INNER="$REPO/cbde"

# A fake volume with GHC 9.6.6 and 9.6.7, cabal 3.10.3.0 and 3.12.1.0, and
# HLS 2.9.0.0 with servers for both GHCs; a project at $T/proj; this
# container's bin dir at $T/active.
fake_volume() {
  local g="$T/nix/cbde/.ghcup" v b
  export GHCUP_INSTALL_BASE_PREFIX="$T/nix/cbde" CBDE_MOUNTS_FILE="$T/mounts"
  export CBDE_SEED_DIR="$T/no-seed" CBDE_ACTIVE_BIN="$T/active"
  export CBDE_PROJECT="$T/proj"
  printf 'vol /nix ext4 rw 0 0\n' > "$T/mounts"
  mkdir -p "$g/bin" "$T/proj"
  for v in 9.6.6 9.6.7; do
    mkdir -p "$g/ghc/$v/bin"
    for b in "ghc-$v" "ghc-pkg-$v" "haddock-ghc-$v"; do printf '#!/bin/sh\necho %s\n' "$b" > "$g/ghc/$v/bin/$b"; chmod +x "$g/ghc/$v/bin/$b"; done
    ln -s "ghc-$v" "$g/ghc/$v/bin/ghc"; ln -s "ghc-pkg-$v" "$g/ghc/$v/bin/ghc-pkg"
    : > "$g/bin/haskell-language-server-$v~2.9.0.0"; chmod +x "$g/bin/haskell-language-server-$v~2.9.0.0"
  done
  for v in 3.10.3.0 3.12.1.0; do : > "$g/bin/cabal-$v"; chmod +x "$g/bin/cabal-$v"; done
  : > "$g/bin/haskell-language-server-wrapper-2.9.0.0"; chmod +x "$g/bin/haskell-language-server-wrapper-2.9.0.0"
}
mounted_project() { printf 'ws %s ext4 rw 0 0\n' "$CBDE_PROJECT" >> "$T/mounts"; }
link_of() { readlink "$CBDE_ACTIVE_BIN/$1"; }

# ---- resolution ------------------------------------------------------------

test_a_project_is_a_mount_or_a_dir_with_project_files() {
  fake_volume
  assert_eq "$(project_root_here)" "" "a bare, unmounted dir is not a project"
  mounted_project
  assert_eq "$(project_root_here)" "$T/proj" "the mounted workspace is"
  printf 'vol /nix ext4 rw 0 0\n' > "$T/mounts"
  : > "$T/proj/.cbde.local"
  assert_eq "$(project_root_here)" "$T/proj" "so is a dir with .cbde.local"
  CBDE_PROJECT="$T/missing" run project_root_here
  assert_eq "$out" ""
}

test_local_beats_cbde_beats_matrix() {
  fake_volume
  assert_eq "$(selected_version "$T/proj" ghc)" 9.6.7
  assert_eq "$(selected_source "$T/proj" ghc)" matrix
  printf 'matrix=0.2.0\nghc=9.6.6\ncabal=3.12.1.0\n' > proj/.cbde
  assert_eq "$(selected_version "$T/proj" ghc)" 9.6.6
  assert_eq "$(selected_source "$T/proj" ghc)" .cbde
  printf '# mine\n  ghc = 9.6.5 \n' > proj/.cbde.local
  assert_eq "$(selected_version "$T/proj" ghc)" 9.6.5
  assert_eq "$(selected_source "$T/proj" ghc)" .cbde.local
  assert_eq "$(selected_version "$T/proj" cabal)" 3.12.1.0 "untouched keys fall through to .cbde"
  assert_eq "$(selected_version "$T/proj" hls)" "" "not pinned anywhere"
  assert_eq "$(selected_version "" ghc)" 9.6.7 "no project: the matrix"
}

test_a_value_that_is_not_a_version_is_ignored_with_a_warning() {
  fake_volume
  printf 'ghc=9.6.6\n' > proj/.cbde
  printf 'ghc=$(rm -rf /)\n' > proj/.cbde.local
  run selected_version "$T/proj" ghc
  assert_contains "$out" "ignoring ghc="
  assert_contains "$out" "9.6.6"
}

test_pfile_set_adds_replaces_removes_and_cleans_up() {
  mkdir p
  pfile_set p .cbde.local ghc 9.6.6
  assert_eq "$(pfile_get p .cbde.local ghc)" 9.6.6
  pfile_set p .cbde.local cabal 3.12.1.0
  pfile_set p .cbde.local ghc 9.6.5
  assert_eq "$(grep -c '^ghc=' p/.cbde.local)" 1
  assert_eq "$(pfile_get p .cbde.local ghc)" 9.6.5
  pfile_set p .cbde.local ghc ""
  assert_eq "$(pfile_get p .cbde.local ghc)" ""
  assert_eq "$(pfile_get p .cbde.local cabal)" 3.12.1.0
  pfile_set p .cbde.local cabal ""
  assert_no_file p/.cbde.local "nothing but the comment left: removed"
  printf 'matrix=0.2.0\n' > p/.cbde
  pfile_set p .cbde ghc 9.6.6; pfile_set p .cbde ghc ""
  assert_eq "$(cat p/.cbde)" "matrix=0.2.0" "other keys survive"
}

# ---- linking ---------------------------------------------------------------

test_active_link_points_at_the_selected_versions() {
  fake_volume
  printf 'ghc=9.6.6\nhls=2.9.0.0\n' > proj/.cbde
  active_link "$T/proj"
  local g="$T/nix/cbde/.ghcup"
  assert_eq "$(link_of ghc)" "$g/ghc/9.6.6/bin/ghc"
  assert_eq "$(link_of ghc-9.6.6)" "$g/ghc/9.6.6/bin/ghc-9.6.6"
  assert_eq "$(link_of haddock-ghc-9.6.6)" "$g/ghc/9.6.6/bin/haddock-ghc-9.6.6"
  assert_eq "$(link_of cabal)" "$g/bin/cabal-3.10.3.0" "cabal from the matrix"
  assert_eq "$(link_of haskell-language-server-wrapper)" "$g/bin/haskell-language-server-wrapper-2.9.0.0"
  assert_eq "$(link_of haskell-language-server-9.6.6)" "$g/bin/haskell-language-server-9.6.6~2.9.0.0"
  assert_eq "$("$CBDE_ACTIVE_BIN/ghc")" "ghc-9.6.6" "the link runs"
}

test_relinking_replaces_the_old_selection() {
  fake_volume
  printf 'ghc=9.6.6\n' > proj/.cbde.local
  active_link "$T/proj"
  rm proj/.cbde.local
  active_link "$T/proj"
  assert_eq "$(link_of ghc)" "$T/nix/cbde/.ghcup/ghc/9.6.7/bin/ghc"
  assert_no_file "$CBDE_ACTIVE_BIN/ghc-9.6.6"
  assert_no_file "$CBDE_ACTIVE_BIN.new"
}

test_a_missing_version_fails_loudly_instead_of_falling_through() {
  fake_volume
  printf 'ghc=9.4.8\ncabal=3.8.1.0\n' > proj/.cbde.local
  active_link "$T/proj"
  run "$CBDE_ACTIVE_BIN/ghc" --version
  assert_rc "$rc" 127
  assert_contains "$out" "this project selects GHC 9.4.8, which is not installed"
  assert_contains "$out" "cbde sync"
  run "$CBDE_ACTIVE_BIN/cabal" --version
  assert_rc "$rc" 127
}

test_no_project_links_the_matrix() {
  fake_volume
  printf 'ghc=9.6.6\n' > proj/.cbde.local
  active_link "$T/proj"
  active_link ""
  assert_eq "$(link_of ghc)" "$T/nix/cbde/.ghcup/ghc/9.6.7/bin/ghc"
  assert_eq "$(link_of cabal)" "$T/nix/cbde/.ghcup/bin/cabal-3.10.3.0"
  assert_no_file "$CBDE_ACTIVE_BIN/ghc-9.6.6"
}

test_two_containers_on_two_projects_keep_their_own_ghc() {
  fake_volume
  mkdir -p a b
  printf 'ghc=9.6.6\n' > a/.cbde.local
  : > b/.cbde
  CBDE_ACTIVE_BIN="$T/active-a" active_link "$T/a"
  CBDE_ACTIVE_BIN="$T/active-b" active_link "$T/b"
  assert_eq "$(readlink "$T/active-a/ghc")" "$T/nix/cbde/.ghcup/ghc/9.6.6/bin/ghc"
  assert_eq "$(readlink "$T/active-b/ghc")" "$T/nix/cbde/.ghcup/ghc/9.6.7/bin/ghc"
  # A switch in a relinks a only.
  printf 'ghc=9.6.7\n' > a/.cbde.local
  printf 'ghc=9.6.6\n' > b/.cbde.local
  CBDE_ACTIVE_BIN="$T/active-b" active_link "$T/b"
  assert_eq "$(readlink "$T/active-a/ghc")" "$T/nix/cbde/.ghcup/ghc/9.6.6/bin/ghc"
  assert_eq "$(readlink "$T/active-b/ghc")" "$T/nix/cbde/.ghcup/ghc/9.6.6/bin/ghc"
}

# ---- verdict ---------------------------------------------------------------

test_a_difference_the_project_declares_is_declared_not_custom() {
  fake_volume
  printf 'ghc=9.6.6\n' > proj/.cbde.local
  STUB_GHC=9.6.6 run matrix_status "$FIXTURES/matrices/0.2.0.env"
  assert_rc "$rc" 2
  assert_match "$out" "^GHC	9\\.6\\.7	9\\.6\\.6	declared	\\.cbde\\.local$"
  assert_match "$out" "^cabal	3\\.10\\.3\\.0	3\\.10\\.3\\.0	ok$"
  assert_eq "$(STUB_GHC=9.6.6 matrix_verdict "$FIXTURES/matrices/0.2.0.env")" declared
  assert_eq "$(STUB_GHC=9.6.5 matrix_verdict "$FIXTURES/matrices/0.2.0.env")" custom "undeclared drift"
  assert_eq "$(STUB_GHC=9.6.6 STUB_CABAL=3.12.1.0 matrix_verdict "$FIXTURES/matrices/0.2.0.env")" custom \
    "one declared, one not: custom"
  rm proj/.cbde.local
  assert_eq "$(matrix_verdict "$FIXTURES/matrices/0.2.0.env")" verified
}

# ---- the in-container verbs --------------------------------------------------

test_ghc_switch_in_a_project_writes_cbde_and_relinks() {
  fake_volume; mounted_project; mkrepo proj >/dev/null
  printf 'matrix=0.2.0\n' > proj/.cbde
  run "$INNER" ghc 9.6.6
  assert_rc "$rc" 0 "$out"
  assert_contains "$out" "GHC 9.6.6 is now this project's choice (.cbde — commit it)"
  assert_eq "$(cat proj/.cbde)" $'matrix=0.2.0\nghc=9.6.6'
  assert_no_file proj/.cbde.local "cbde never creates .cbde.local unasked"
  assert_no_file proj/.gitignore
  assert_eq "$(link_of ghc)" "$T/nix/cbde/.ghcup/ghc/9.6.6/bin/ghc"
  assert_not_contains "$(cat "$STUB_LOG" 2>/dev/null)" "ghcup set"
  run "$INNER" ghc 9.6.5 --bogus
  assert_rc "$rc" 2
  run "$INNER" ghc 9.6.5 --team
  assert_rc "$rc" 2 "--team is gone: .cbde is the default"
  run "$INNER" ghc 9.6.5 --global
  assert_rc "$rc" 2 "--global is gone"
}

test_local_flag_writes_cbde_local_and_gitignores_it() {
  fake_volume; mounted_project; mkrepo proj >/dev/null
  printf 'ghc=9.6.6\n' > proj/.cbde
  run "$INNER" ghc 9.6.7 --local
  assert_rc "$rc" 0 "$out"
  assert_contains "$out" "GHC 9.6.7 is now active for you in this project (.cbde.local)"
  assert_eq "$(pfile_get proj .cbde.local ghc)" 9.6.7 "differs from .cbde's 9.6.6: recorded"
  assert_eq "$(cat proj/.cbde)" "ghc=9.6.6" ".cbde untouched"
  assert_eq "$(link_of ghc)" "$T/nix/cbde/.ghcup/ghc/9.6.7/bin/ghc"
  assert_contains "$out" "added .cbde.local to .gitignore"
  (cd proj && git check-ignore -q .cbde.local) || fail ".cbde.local is not ignored"
  # Back to what .cbde says: the personal pin goes.
  run "$INNER" ghc 9.6.6 --local
  assert_no_file proj/.cbde.local
}

test_gitignore_is_left_alone_when_it_already_ignores_local() {
  fake_volume; mounted_project; mkrepo proj >/dev/null
  printf 'dist-newstyle\n.cbde.local' > proj/.gitignore
  run "$INNER" ghc 9.6.6 --local
  assert_rc "$rc" 0 "$out"
  assert_not_contains "$out" "added .cbde.local"
  assert_eq "$(cat proj/.gitignore)" $'dist-newstyle\n.cbde.local'
}

test_switching_back_to_the_matrix_drops_the_pin() {
  fake_volume; mounted_project
  run "$INNER" ghc 9.6.6
  run "$INNER" ghc 9.6.7
  assert_rc "$rc" 0 "$out"
  assert_contains "$out" "GHC 9.6.7, the matrix's, is this project's again"
  assert_no_file proj/.cbde
  assert_eq "$(link_of ghc)" "$T/nix/cbde/.ghcup/ghc/9.6.7/bin/ghc"
}

test_a_project_switch_reports_a_personal_override() {
  fake_volume; mounted_project
  printf 'matrix=0.2.0\n' > proj/.cbde
  printf 'cabal=3.10.3.0\nghc=9.6.7\n' > proj/.cbde.local
  run "$INNER" cabal 3.12.1.0
  assert_rc "$rc" 0 "$out"
  assert_contains "$out" "cabal 3.12.1.0 is now this project's choice (.cbde"
  assert_contains "$out" "your .cbde.local still selects cabal 3.10.3.0"
  assert_eq "$(cat proj/.cbde)" $'matrix=0.2.0\ncabal=3.12.1.0'
  assert_eq "$(cat proj/.cbde.local)" $'cabal=3.10.3.0\nghc=9.6.7' ".cbde.local untouched"
  assert_eq "$(link_of cabal)" "$T/nix/cbde/.ghcup/bin/cabal-3.10.3.0" "personal still wins"
}

test_outside_a_project_the_toolchain_is_the_matrix_and_does_not_switch() {
  fake_volume
  run "$INNER" ghc 9.6.6
  assert_rc "$rc" 1
  assert_contains "$out" "outside a project the toolchain is matrix 0.2.0's"
  assert_not_contains "$(cat "$STUB_LOG" 2>/dev/null)" "ghcup set"
  assert_not_contains "$(cat "$STUB_LOG" 2>/dev/null)" "ghcup install"
  run "$INNER" ghc
  assert_rc "$rc" 0
  assert_contains "$out" "(the matrix's: no project at $T/proj)"
}

test_show_names_where_the_version_comes_from() {
  fake_volume; mounted_project
  printf 'ghc=9.6.6\n' > proj/.cbde.local
  STUB_GHC=9.6.6 run "$INNER" ghc
  assert_rc "$rc" 0 "$out"
  assert_contains "$out" "(from .cbde.local; matrix: 9.6.7)"
  run "$INNER" cabal
  assert_contains "$out" "(the matrix's)"
}

test_a_missing_version_installs_under_the_lock_without_set() {
  fake_volume; mounted_project
  run "$INNER" ghc 9.4.8 --local
  assert_rc "$rc" 0 "$out"
  assert_contains "$(cat "$STUB_LOG")" "ghcup install ghc 9.4.8"
  assert_not_contains "$(cat "$STUB_LOG")" "--set"
  assert_not_contains "$(cat "$STUB_LOG")" "ghcup set"
  command -v flock >/dev/null 2>&1 && assert_file "$T/nix/cbde/.provision.lock"
  return 0
}

test_sync_installs_what_the_project_selects_and_relinks() {
  fake_volume; mounted_project
  printf 'ghc=9.4.8\n' > proj/.cbde
  run "$INNER" sync
  assert_rc "$rc" 0 "$out"
  assert_contains "$(cat "$STUB_LOG")" "ghcup install ghc 9.4.8"
  assert_contains "$out" "GHC    9.4.8 (.cbde)"
  assert_contains "$out" "cabal  3.10.3.0 (matrix)"
  # The stub ghcup installs nothing, so ghc is the "not installed" stand-in.
  run "$CBDE_ACTIVE_BIN/ghc"; assert_rc "$rc" 127
}

test_matrix_reset_drops_cbde_picks_and_reports_local_ones() {
  fake_volume; mounted_project
  printf 'matrix=0.2.0\nghc=9.6.6\ncabal=3.12.1.0\n' > proj/.cbde
  printf 'cabal=3.12.1.0\n' > proj/.cbde.local
  run "$INNER" matrix reset
  assert_contains "$out" "dropped ghc=9.6.6 from .cbde"
  assert_contains "$out" "your .cbde.local still selects: cabal 3.12.1.0 (.cbde.local)"
  assert_eq "$(cat proj/.cbde)" "matrix=0.2.0" "the matrix pin stays"
  assert_eq "$(cat proj/.cbde.local)" "cabal=3.12.1.0" ".cbde.local is never edited by reset"
  assert_eq "$(link_of ghc)" "$T/nix/cbde/.ghcup/ghc/9.6.7/bin/ghc"
  assert_not_contains "$(cat "$STUB_LOG")" "ghcup set"
}

test_matrix_show_calls_a_declared_difference_declared() {
  fake_volume; mounted_project
  printf 'ghc=9.6.6\n' > proj/.cbde
  STUB_GHC=9.6.6 run "$INNER" matrix
  assert_contains "$out" "GHC    pinned 9.6.7, active 9.6.6 (declared in .cbde)"
  assert_contains "$out" "declared: differs from matrix 0.2.0 only where this project says so"
  assert_not_contains "$out" "custom:"
}

test_matrix_show_blames_the_project_file_for_a_missing_version() {
  fake_volume; mounted_project
  printf 'ghc=9.4.8\n' > proj/.cbde.local
  STUB_GHC= run "$INNER" matrix
  assert_contains "$out" "GHC    .cbde.local selects 9.4.8, not installed (run: cbde sync)"
  assert_not_contains "$out" "pinned 9.6.7, not installed"
}

run_tests
