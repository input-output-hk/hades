#!/usr/bin/env bash
# Consistency of the repository itself: the matrix files, the Dockerfile
# defaults, the template, the workflow. No stubs needed.
. "$(dirname "$0")/harness.sh"
. "$REPO/lib/matrix.sh"
export CBDE_MATRIX_DIR="$REPO/matrices"

test_there_is_a_matrix_and_all_validate() {
  [ -n "$(matrix_list)" ] || fail "no matrices in $REPO/matrices"
  local f
  for f in "$REPO"/matrices/*.env; do run matrix_validate "$f"; assert_rc "$rc" 0 "$f: $out"; done
}

test_dockerfile_defaults_mirror_the_newest_matrix() {
  local f line key val
  f="$REPO/matrices/$(matrix_newest).env"
  for line in $(matrix_pairs "$f"); do
    key="${line%%=*}"; val="${line#*=}"
    grep -q "^ARG $key=$val\$" "$REPO/Dockerfile" \
      || fail "Dockerfile: expected 'ARG $key=$val' (matrix $(matrix_newest) says so); found: $(grep "^ARG $key=" "$REPO/Dockerfile" || echo nothing)"
  done
}

test_every_matrix_key_is_consumed_by_the_dockerfile() {
  # Otherwise `cbde build` passes a --build-arg nothing reads and docker warns.
  local f key
  for f in "$REPO"/matrices/*.env; do
    for key in $(matrix_pairs "$f" | cut -d= -f1); do
      grep -Eq "^ARG $key(=|\$)" "$REPO/Dockerfile" || fail "$key from $(basename "$f") is not a Dockerfile ARG"
    done
  done
}

test_dockerfile_ships_the_library_and_the_matrices() {
  assert_contains "$(cat "$REPO/Dockerfile")" "COPY lib/matrix.sh /usr/local/lib/cbde/matrix.sh"
  assert_contains "$(cat "$REPO/Dockerfile")" "COPY matrices /opt/cbde/matrices"
  assert_contains "$(cat "$REPO/Dockerfile")" "matrix_check_env"
}

test_dockerfile_builds_and_ships_the_toolchain_seed() {
  local d; d="$(cat "$REPO/Dockerfile")"
  assert_contains "$d" 'ghcup prefetch -d /opt/cbde/seed ghc "$CBDE_GHC"'
  assert_contains "$d" 'ghcup prefetch -d /opt/cbde/seed cabal "$CBDE_CABAL"'
  assert_contains "$d" "CBDE_SEED_STRICT=1 cbde-provision"
  assert_contains "$d" "COPY --from=toolchain /opt/cbde/seed /opt/cbde/seed"
  assert_contains "$d" "COPY --from=blaster-builder /opt/cbde/seed /opt/cbde/seed"
  assert_contains "$d" 'xz -T0 -6 > "/opt/cbde/seed/lean-$d.tar.xz"'
  assert_contains "$d" "xz -T0 -6 > /opt/cbde/seed/cabal-packages.tar.xz"
  assert_contains "$d" "--exclude='*/01-index.tar.gz'"
  # The name the Dockerfile derives must be the one the library derives.
  assert_contains "$d" "sed 's|/|--|g; s|:|---|g'"
  assert_contains "$(cat "$REPO/lib/matrix.sh")" "sed 's|/|--|g; s|:|---|g'"
  # The provisioner sources the library, so the toolchain stage must ship it.
  local stage; stage="$(sed -n '/^FROM base AS toolchain/,/^FROM /p' "$REPO/Dockerfile")"
  assert_contains "$stage" "COPY lib/matrix.sh /usr/local/lib/cbde/matrix.sh"
  assert_contains "$stage" "COPY cbde-provision /usr/local/bin/"
}

test_devcontainer_template_targets_latest_and_is_stamped() {
  local dc="$REPO/.devcontainer/devcontainer.json"
  assert_contains "$(cat "$dc")" '"image": "cbde:latest"'
  assert_contains "$(cat "$dc")" '"//cbde-template": "dev"'
  assert_contains "$(cat "$dc")" 'source=cbde-data,target=/nix,type=volume'
}

test_workflow_gates_the_build_on_the_tests() {
  local wf="$REPO/.github/workflows/docker.yml"
  assert_contains "$(cat "$wf")" "run: tests/run"
  assert_contains "$(cat "$wf")" "needs: test"
  assert_contains "$(cat "$wf")" "build-args:"
  assert_contains "$(cat "$wf")" "macos-latest"
}

test_scripts_parse_and_are_executable() {
  local s
  for s in bin/cbde cbde cbde-entrypoint cbde-provision tests/run; do
    [ -x "$REPO/$s" ] || fail "$s is not executable"
    run bash -n "$REPO/$s"; assert_rc "$rc" 0 "$s: $out"
  done
  run bash -n "$REPO/lib/matrix.sh"; assert_rc "$rc" 0 "$out"
}

test_host_side_scripts_avoid_bash_4_features() {
  # The launcher and the library run on macOS's bash 3.2.
  local s
  for s in bin/cbde lib/matrix.sh; do
    # Comments stripped first: they are allowed to mention the features.
    run bash -c "sed 's/#.*//' '$REPO/$s' | grep -nE 'declare -A|mapfile|readarray|\\$\\{[A-Za-z_]+(,,|\\^\\^)\\}|&>>|\\|&'"
    assert_rc "$rc" 1 "$s uses a bash 4 feature: $out"
  done
}

test_matrices_and_tests_are_in_the_right_docker_context() {
  assert_contains "$(cat "$REPO/.dockerignore")" "tests"
  assert_not_contains "$(cat "$REPO/.dockerignore")" "matrices"
  assert_not_contains "$(cat "$REPO/.dockerignore")" "lib"
}

run_tests
