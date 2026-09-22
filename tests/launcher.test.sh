#!/usr/bin/env bash
# bin/cbde, the host launcher, against a stubbed docker. Every test asserts on
# the docker command line the launcher would have run.
. "$(dirname "$0")/harness.sh"
export PATH="$STUBS:$PATH"
CBDE="$REPO/bin/cbde"
export STUB_IMAGES="cbde:latest"
unset CBDE_IMAGE CBDE_PLATFORM CBDE_DOCKER_ARGS CBDE_GHC CBDE_CABAL CBDE_HLS CBDE_LEAN CBDE_REGISTRY CBDE_VOLUME 2>/dev/null || true
# Never read the developer's real ~/.config/cbde/config; registry tests set their own.
export XDG_CONFIG_HOME=/nonexistent/cbde-tests

last_docker() { tail -n 1 "$STUB_LOG"; }

test_default_image_is_latest_and_unpinned() {
  mkrepo p && cd p
  run "$CBDE" info
  assert_rc "$rc" 0 "$out"
  assert_contains "$out" "image      cbde:latest"
  assert_contains "$out" "matrix     (not pinned"
  assert_contains "$out" "project    $(pwd -P)  ->  /workspace"
  assert_contains "$out" "workdir    /workspace"
}

test_pin_file_selects_the_matrix_image() {
  mkrepo p && cd p
  printf 'matrix=0.1.0\n' > .cbde
  run "$CBDE" info
  assert_contains "$out" "image      cbde:0.1.0  (not pulled)"
  assert_contains "$out" "matrix     0.1.0"
  STUB_IMAGES="cbde:0.1.0" run "$CBDE" cabal --version
  assert_rc "$rc" 0 "$out"
  assert_match "$(last_docker)" ' cbde:0.1.0 cabal --version$'
}

test_pin_file_tolerates_whitespace_and_comments() {
  mkrepo p && cd p
  printf '# settings\n\n  matrix = 0.1.0  \n' > .cbde
  run "$CBDE" info
  assert_contains "$out" "image      cbde:0.1.0"
}

test_env_image_overrides_the_pin() {
  mkrepo p && cd p
  printf 'matrix=0.1.0\n' > .cbde
  CBDE_IMAGE=cbde:dev STUB_IMAGES=cbde:dev run "$CBDE" true
  assert_rc "$rc" 0 "$out"
  assert_match "$(last_docker)" ' cbde:dev true$'
}

test_invalid_pin_is_refused() {
  mkrepo p && cd p
  printf 'matrix=../evil\n' > .cbde
  run "$CBDE" info
  assert_rc "$rc" 1; assert_contains "$out" "invalid matrix name"
}

test_git_root_is_mounted_and_workdir_mirrors_the_subdirectory() {
  mkrepo p && mkdir -p p/pkgs/foo/src && cd p/pkgs/foo/src
  local root; root="$(cd ../../.. && pwd -P)"
  run "$CBDE" cabal build
  assert_rc "$rc" 0 "$out"
  assert_contains "$(last_docker)" " -v $root:/workspace -w /workspace/pkgs/foo/src "
  assert_contains "$(last_docker)" " -v cbde-data:/nix "
  assert_contains "$(last_docker)" " --rm "
}

test_outside_a_repository_pwd_is_mounted() {
  mkdir -p plain/sub && cd plain/sub
  run "$CBDE" info
  assert_contains "$out" "project    $(pwd -P)  ->  /workspace"
  assert_contains "$out" "workdir    /workspace"
}

test_toolchain_verbs_are_forwarded_to_the_inner_cbde() {
  mkrepo p && cd p
  run "$CBDE" ghc 9.6.6;                assert_match "$(last_docker)" ' cbde:latest cbde ghc 9.6.6$'
  run "$CBDE" cabal-version 3.12.1.0;   assert_match "$(last_docker)" ' cbde:latest cbde cabal 3.12.1.0$'
  run "$CBDE" doctor;                   assert_match "$(last_docker)" ' cbde:latest cbde doctor$'
  run "$CBDE" matrix reset;             assert_match "$(last_docker)" ' cbde:latest cbde matrix reset$'
}

test_everything_else_runs_as_a_command() {
  mkrepo p && cd p
  run "$CBDE" cabal build all;          assert_match "$(last_docker)" ' cbde:latest cabal build all$'
  run "$CBDE" run doctor;               assert_match "$(last_docker)" ' cbde:latest doctor$'
  run "$CBDE" nix cabal test all;       assert_match "$(last_docker)" ' cbde:latest nix develop -c cabal test all$'
  run "$CBDE";                          assert_match "$(last_docker)" ' cbde:latest bash$'
  run "$CBDE" run
  assert_rc "$rc" 1; assert_contains "$out" "run: needs a command"
}

test_missing_image_says_how_to_get_it() {
  mkrepo p && cd p
  STUB_IMAGES= run "$CBDE" cabal --version
  assert_rc "$rc" 1; assert_contains "$out" "image cbde:latest not found"; assert_contains "$out" "cbde pull"
  printf 'matrix=0.1.0\n' > .cbde
  STUB_IMAGES= run "$CBDE" cabal --version
  assert_contains "$out" "cbde pull 0.1.0"; assert_contains "$out" "cbde build --matrix 0.1.0"
}

test_platform_docker_args_and_pins_are_passed_through() {
  mkrepo p && cd p
  CBDE_PLATFORM=linux/amd64 CBDE_DOCKER_ARGS='-p 8080:8080 -v /data:/data' CBDE_GHC=9.6.6 run "$CBDE" true
  assert_rc "$rc" 0 "$out"
  assert_contains "$(last_docker)" " --platform linux/amd64 "
  assert_contains "$(last_docker)" " -p 8080:8080 -v /data:/data "
  assert_contains "$(last_docker)" " -e CBDE_GHC=9.6.6 "
  assert_contains "$(last_docker)" " -e CBDE_HOST_OS=$(uname -s) -e CBDE_HOST_ARCH=$(uname -m) "
}

test_matrix_pin_pulls_the_image_when_absent() {
  mkrepo p && cd p
  STUB_IMAGES= STUB_IMAGE_VERSION=0.1.0 run "$CBDE" matrix 0.1.0
  assert_rc "$rc" 0 "$out"
  assert_contains "$(cat "$STUB_LOG")" "docker pull ghcr.io/input-output-hk/cbde:0.1.0"
  assert_contains "$(cat "$STUB_LOG")" "docker tag ghcr.io/input-output-hk/cbde:0.1.0 cbde:0.1.0"
  assert_eq "$(grep -c 'docker tag' "$STUB_LOG")" 1 "one tag, deduplicated"
  assert_eq "$(sed -n 's/^matrix=//p' .cbde)" "0.1.0"
  assert_contains "$out" "pinned to matrix 0.1.0"
}

test_matrix_pin_skips_the_pull_when_present() {
  mkrepo p && cd p
  STUB_IMAGES="cbde:0.1.0" run "$CBDE" matrix 0.1.0
  assert_rc "$rc" 0 "$out"
  assert_not_contains "$(cat "$STUB_LOG")" "docker pull"
  assert_eq "$(sed -n 's/^matrix=//p' .cbde)" "0.1.0"
}

test_matrix_pin_failure_to_pull_points_at_build() {
  mkrepo p && cd p
  STUB_IMAGES= STUB_PULL_FAIL=1 run "$CBDE" matrix 0.1.0
  assert_rc "$rc" 1; assert_contains "$out" "cbde build --matrix 0.1.0"
  assert_no_file .cbde
}

test_matrix_pin_rewrites_existing_pin_and_keeps_other_keys() {
  mkrepo p && cd p
  printf 'other=1\nmatrix=0.1.0\n' > .cbde
  STUB_IMAGES="cbde:0.2.0" run "$CBDE" matrix 0.2.0
  assert_rc "$rc" 0 "$out"
  assert_eq "$(cat .cbde)" $'other=1\nmatrix=0.2.0'
}

test_matrix_pin_updates_the_devcontainer_image() {
  mkrepo p && cd p
  mkdir .devcontainer
  printf '{\n  "name": "CBDE",\n  "image": "cbde:latest",\n  "remoteUser": "cbde"\n}\n' > .devcontainer/devcontainer.json
  STUB_IMAGES="cbde:0.1.0" run "$CBDE" matrix 0.1.0
  assert_rc "$rc" 0 "$out"
  assert_eq "$(cat .devcontainer/devcontainer.json)" $'{\n  "name": "CBDE",\n  "image": "cbde:0.1.0",\n  "remoteUser": "cbde"\n}'
  assert_contains "$out" "devcontainer.json now uses cbde:0.1.0"
}

test_matrix_pin_leaves_a_foreign_devcontainer_alone() {
  mkrepo p && cd p
  mkdir .devcontainer
  printf '{ "image": "mcr.microsoft.com/devcontainers/base" }\n' > .devcontainer/devcontainer.json
  STUB_IMAGES="cbde:0.1.0" run "$CBDE" matrix 0.1.0
  assert_eq "$(cat .devcontainer/devcontainer.json)" '{ "image": "mcr.microsoft.com/devcontainers/base" }'
}

test_matrix_unpin() {
  mkrepo p && cd p
  printf '# CBDE project settings\nmatrix=0.1.0\n' > .cbde
  run "$CBDE" matrix unpin
  assert_rc "$rc" 0 "$out"; assert_no_file .cbde
  printf 'other=1\nmatrix=0.1.0\n' > .cbde
  run "$CBDE" matrix unpin
  assert_eq "$(cat .cbde)" "other=1"
  run "$CBDE" matrix unpin
  assert_rc "$rc" 0 "unpin twice is fine"
}

test_matrix_show_reports_host_side_then_forwards() {
  mkrepo p && cd p
  run "$CBDE" matrix
  assert_rc "$rc" 0 "$out"
  assert_contains "$out" "pinned     none"
  assert_match "$(last_docker)" ' cbde:latest cbde matrix show$'
  printf 'matrix=0.1.0\n' > .cbde
  : > "$STUB_LOG"
  STUB_IMAGES= run "$CBDE" matrix
  assert_rc "$rc" 0 "not pulled is not an error: $out"
  assert_contains "$out" "pinned     matrix 0.1.0"
  assert_contains "$out" "(not pulled)"
  assert_not_contains "$(cat "$STUB_LOG")" "docker run"
}

test_pull_tags_latest_and_the_version_it_really_is() {
  mkrepo p && cd p
  STUB_IMAGE_VERSION=0.2.0 run "$CBDE" pull
  assert_rc "$rc" 0 "$out"
  assert_contains "$(cat "$STUB_LOG")" "docker pull ghcr.io/input-output-hk/cbde:latest"
  assert_contains "$(cat "$STUB_LOG")" "docker tag ghcr.io/input-output-hk/cbde:latest cbde:latest"
  assert_contains "$(cat "$STUB_LOG")" "docker tag ghcr.io/input-output-hk/cbde:latest cbde:0.2.0"
  assert_contains "$out" "matrix 0.2.0"
}

test_pull_of_a_version_never_moves_latest() {
  mkrepo p && cd p
  STUB_IMAGE_VERSION=0.1.0 run "$CBDE" pull 0.1.0
  assert_rc "$rc" 0 "$out"
  assert_contains "$(cat "$STUB_LOG")" "docker tag ghcr.io/input-output-hk/cbde:0.1.0 cbde:0.1.0"
  assert_not_contains "$(cat "$STUB_LOG")" "cbde:latest"
  assert_eq "$(grep -c 'docker tag' "$STUB_LOG")" 1
}

test_pull_of_a_fork_ref_is_verbatim() {
  mkrepo p && cd p
  CBDE_REGISTRY=localhost:5000/cbde STUB_IMAGE_VERSION=0.2.0 run "$CBDE" pull
  assert_contains "$(cat "$STUB_LOG")" "docker pull localhost:5000/cbde:latest"
  run "$CBDE" pull ghcr.io/someone/cbde:dev
  assert_contains "$(cat "$STUB_LOG")" "docker pull ghcr.io/someone/cbde:dev"
  assert_contains "$(cat "$STUB_LOG")" "docker tag ghcr.io/someone/cbde:dev cbde:dev"
}

test_build_passes_the_newest_matrix_as_build_args() {
  mkrepo p && cd p
  run "$CBDE" build
  assert_rc "$rc" 0 "$out"
  local line; line="$(last_docker)"
  assert_match "$line" '^docker build '
  assert_contains "$line" " --build-arg CBDE_IMAGE_VERSION=0.2.0 "
  assert_contains "$line" " --build-arg CBDE_GHC=9.6.7 "
  assert_contains "$line" " --build-arg CBDE_HLS= "
  assert_contains "$line" " -t cbde:0.2.0 -t cbde:latest "
  assert_match "$line" " $REPO\$"
  assert_contains "$out" "matrix 0.2.0"
}

test_build_of_a_named_matrix_and_extra_docker_args() {
  mkrepo p && cd p
  run "$CBDE" build --matrix 0.2.0 --no-cache
  assert_rc "$rc" 0 "$out"
  assert_contains "$(last_docker)" " -t cbde:0.2.0 -t cbde:latest --no-cache $REPO"
  run "$CBDE" build --matrix 9.9.9
  assert_rc "$rc" 1; assert_contains "$out" "no such matrix: 9.9.9"
}

test_build_in_a_pinned_project_builds_the_pin() {
  mkrepo p && cd p
  printf 'matrix=0.1.0\n' > .cbde
  run "$CBDE" build
  assert_rc "$rc" 0 "$out"
  assert_contains "$(last_docker)" " --build-arg CBDE_GHC=9.6.6 "
  assert_contains "$(last_docker)" " -t cbde:0.1.0 "
  assert_not_contains "$(last_docker)" " -t cbde:latest " "an older matrix never moves latest"
  printf 'matrix=9.9.9\n' > .cbde
  run "$CBDE" build
  assert_rc "$rc" 1; assert_contains "$out" "no such matrix: 9.9.9"
}

test_help_and_unknown_flags() {
  run "$CBDE" help
  assert_rc "$rc" 0; assert_contains "$out" "cbde matrix <name>"
  run "$CBDE" --help
  assert_rc "$rc" 0
}

# ---- local registry and the config file ------------------------------------
with_cfg() { export XDG_CONFIG_HOME="$T/xdg"; CFG="$T/xdg/cbde/config"; }

test_registry_up_starts_registry_and_writes_config() {
  with_cfg; mkrepo p && cd p
  run "$CBDE" registry up
  assert_rc "$rc" 0 "$out"
  assert_contains "$(cat "$STUB_LOG")" "docker run -d --name cbde-registry --restart unless-stopped -p 5000:5000 -v cbde-registry-data:/var/lib/registry -e REGISTRY_STORAGE_DELETE_ENABLED=true registry:2"
  assert_eq "$(sed -n 's/^registry=//p' "$CFG")" "localhost:5000/cbde"
  assert_contains "$out" "registry is now localhost:5000/cbde"
  run "$CBDE" info
  assert_contains "$out" "registry   localhost:5000/cbde  (from: $CFG)"
}

test_registry_up_restarts_a_stopped_one_and_is_idempotent() {
  with_cfg; mkrepo p && cd p
  STUB_CONTAINERS="cbde-registry:stopped" run "$CBDE" registry up
  assert_rc "$rc" 0 "$out"
  assert_contains "$(cat "$STUB_LOG")" "docker start cbde-registry"
  assert_not_contains "$(cat "$STUB_LOG")" "docker run -d"
  : > "$STUB_LOG"
  STUB_CONTAINERS="cbde-registry" run "$CBDE" registry up
  assert_rc "$rc" 0 "$out"
  assert_contains "$out" "already running"
  assert_not_contains "$(cat "$STUB_LOG")" "docker run -d"
}

test_config_registry_is_used_by_pull_and_pin_and_env_wins() {
  with_cfg; mkrepo p && cd p
  mkdir -p "$T/xdg/cbde"; printf 'registry=localhost:5000/cbde\n' > "$CFG"
  STUB_IMAGE_VERSION=0.2.0 run "$CBDE" pull
  assert_contains "$(cat "$STUB_LOG")" "docker pull localhost:5000/cbde:latest"
  : > "$STUB_LOG"
  STUB_IMAGES= STUB_IMAGE_VERSION=0.1.0 run "$CBDE" matrix 0.1.0
  assert_contains "$(cat "$STUB_LOG")" "docker pull localhost:5000/cbde:0.1.0"
  : > "$STUB_LOG"
  CBDE_REGISTRY=ghcr.io/other/cbde STUB_IMAGE_VERSION=0.2.0 run "$CBDE" pull
  assert_contains "$(cat "$STUB_LOG")" "docker pull ghcr.io/other/cbde:latest"
  CBDE_REGISTRY=ghcr.io/other/cbde run "$CBDE" info
  assert_contains "$out" "registry   ghcr.io/other/cbde  (from: CBDE_REGISTRY)"
}

test_config_volume_and_platform_are_honoured() {
  with_cfg; mkrepo p && cd p
  mkdir -p "$T/xdg/cbde"; printf 'volume=my-vol\nplatform=linux/amd64\n' > "$CFG"
  run "$CBDE" true
  assert_rc "$rc" 0 "$out"
  assert_contains "$(last_docker)" " --platform linux/amd64 "
  assert_contains "$(last_docker)" " -v my-vol:/nix "
}

test_registry_down_removes_container_and_restores_default() {
  with_cfg; mkrepo p && cd p
  mkdir -p "$T/xdg/cbde"; printf 'registry=localhost:5000/cbde\nvolume=keep-me\n' > "$CFG"
  run "$CBDE" registry down
  assert_rc "$rc" 0 "$out"
  assert_contains "$(cat "$STUB_LOG")" "docker rm -f cbde-registry"
  assert_not_contains "$(cat "$STUB_LOG")" "docker volume rm"
  assert_eq "$(cat "$CFG")" "volume=keep-me" "only the registry line goes; other settings stay"
  run "$CBDE" info
  assert_contains "$out" "registry   ghcr.io/input-output-hk/cbde  (from: default)"
  run "$CBDE" registry down --purge
  assert_contains "$(cat "$STUB_LOG")" "docker volume rm cbde-registry-data"
}

test_registry_down_leaves_a_foreign_registry_setting_alone() {
  with_cfg; mkrepo p && cd p
  mkdir -p "$T/xdg/cbde"; printf 'registry=ghcr.io/myfork/cbde\n' > "$CFG"
  run "$CBDE" registry down
  assert_eq "$(sed -n 's/^registry=//p' "$CFG")" "ghcr.io/myfork/cbde"
}

test_registry_push_tags_and_pushes_local_images() {
  with_cfg; mkrepo p && cd p
  mkdir -p "$T/xdg/cbde"; printf 'registry=localhost:5000/cbde\n' > "$CFG"
  STUB_IMAGES="cbde:0.2.0 cbde:0.1.0 cbde:latest" STUB_TAGS="0.1.0 0.2.0 latest base" run "$CBDE" registry push
  assert_rc "$rc" 0 "$out"
  local log; log="$(cat "$STUB_LOG")"
  assert_contains "$log" "docker tag cbde:0.1.0 localhost:5000/cbde:0.1.0"
  assert_contains "$log" "docker push localhost:5000/cbde:0.2.0"
  assert_contains "$log" "docker push localhost:5000/cbde:latest"
  assert_not_contains "$log" "cbde:base" "only version tags and latest"
  : > "$STUB_LOG"
  STUB_IMAGES="cbde:0.2.0" run "$CBDE" registry push 0.2.0
  assert_eq "$(grep -c 'docker push' "$STUB_LOG")" 1
  STUB_IMAGES= run "$CBDE" registry push 9.9.9
  assert_rc "$rc" 1; assert_contains "$out" "no local image cbde:9.9.9"
}

test_registry_status_and_unknown_subcommand() {
  with_cfg; mkrepo p && cd p
  run "$CBDE" registry
  assert_rc "$rc" 0 "$out"
  assert_contains "$out" "registry   ghcr.io/input-output-hk/cbde  (from: default)"
  assert_contains "$out" "local      not running"
  run "$CBDE" registry bogus
  assert_rc "$rc" 1; assert_contains "$out" "unknown registry subcommand"
}

test_registry_list_prints_tags_version_sorted() {
  with_cfg; mkrepo p && cd p
  mkdir -p "$T/xdg/cbde"; printf 'registry=localhost:5000/cbde\n' > "$CFG"
  STUB_TAGS_JSON='{"name":"cbde","tags":["latest","0.10.0","0.2.0"]}' run "$CBDE" registry list
  assert_rc "$rc" 0 "$out"
  assert_eq "$out" $'localhost:5000/cbde:0.2.0\nlocalhost:5000/cbde:0.10.0\nlocalhost:5000/cbde:latest'
  assert_contains "$(cat "$STUB_LOG")" "http://localhost:5000/v2/cbde/tags/list"
  STUB_TAGS_JSON='{"tags":[]}' run "$CBDE" registry list
  assert_contains "$out" "no tags in localhost:5000/cbde"
}

test_registry_rm_deletes_by_digest_and_garbage_collects() {
  with_cfg; mkrepo p && cd p
  mkdir -p "$T/xdg/cbde"; printf 'registry=localhost:5000/cbde\n' > "$CFG"
  STUB_TAGS_JSON='{"tags":["0.1.0","0.2.0","latest"]}' STUB_DIGESTS="0.1.0=sha256:111 0.2.0=sha256:222 latest=sha256:222" \
    run "$CBDE" registry rm 0.1.0
  assert_rc "$rc" 0 "$out"
  assert_contains "$(cat "$STUB_LOG")" "curl -sS --max-time 10 -o /dev/null -w %{http_code} -X DELETE http://localhost:5000/v2/cbde/manifests/sha256:111"
  assert_contains "$(cat "$STUB_LOG")" "docker exec cbde-registry registry garbage-collect --delete-untagged"
  assert_contains "$out" "removed localhost:5000/cbde:0.1.0"
  assert_not_contains "$out" "shares its image"
}

test_registry_rm_refuses_shared_manifest_without_yes() {
  with_cfg; mkrepo p && cd p
  mkdir -p "$T/xdg/cbde"; printf 'registry=localhost:5000/cbde\n' > "$CFG"
  STUB_TAGS_JSON='{"tags":["0.2.0","latest"]}' run "$CBDE" registry rm 0.2.0
  assert_rc "$rc" 1
  assert_contains "$out" "0.2.0 shares its image with: latest"
  assert_contains "$out" "cbde registry rm 0.2.0 --yes"
  assert_not_contains "$(cat "$STUB_LOG")" "DELETE"
  STUB_TAGS_JSON='{"tags":["0.2.0","latest"]}' run "$CBDE" registry rm 0.2.0 --yes
  assert_rc "$rc" 0 "$out"
  assert_contains "$out" "removed localhost:5000/cbde:0.2.0 (and latest )"
}

test_registry_rm_errors_are_explained() {
  with_cfg; mkrepo p && cd p
  mkdir -p "$T/xdg/cbde"; printf 'registry=localhost:5000/cbde\n' > "$CFG"
  STUB_DIGESTS="9.9.9=none" run "$CBDE" registry rm 9.9.9
  assert_rc "$rc" 1; assert_contains "$out" "no tag 9.9.9"
  STUB_TAGS_JSON='{"tags":["0.1.0"]}' STUB_DELETE_CODE=405 run "$CBDE" registry rm 0.1.0
  assert_rc "$rc" 1; assert_contains "$out" "deletes disabled"; assert_contains "$out" "cbde registry down && cbde registry up"
  run "$CBDE" registry rm
  assert_rc "$rc" 1; assert_contains "$out" "which tag"
  rm "$CFG"; : > "$STUB_LOG"
  run "$CBDE" registry rm 0.1.0
  assert_rc "$rc" 1; assert_contains "$out" "local registry only"
  assert_not_contains "$(cat "$STUB_LOG")" "DELETE"
}

test_registry_rm_never_stops_the_registry() {
  with_cfg; mkrepo p && cd p
  mkdir -p "$T/xdg/cbde"; printf 'registry=localhost:5000/cbde\n' > "$CFG"
  run "$CBDE" registry rm
  assert_rc "$rc" 1; assert_contains "$out" "which tag"
  STUB_DIGESTS="--purge=none" run "$CBDE" registry rm --purge
  assert_rc "$rc" 1
  assert_not_contains "$(cat "$STUB_LOG")" "docker rm -f cbde-registry"
  assert_file "$CFG"
}

# ---- matrix list from local images and the registry ------------------------
test_matrix_list_merges_local_images_and_registry_tags() {
  with_cfg; mkrepo p && cd p
  mkdir -p "$T/xdg/cbde"; printf 'registry=localhost:5000/cbde\n' > "$CFG"
  STUB_TAGS="0.1.0 0.2.0 latest base" STUB_IMAGES="cbde:latest cbde:0.1.0 cbde:0.2.0" STUB_GHC_0_1_0=9.6.6 \
    STUB_TAGS_JSON='{"tags":["0.2.0","0.3.0","latest"]}' run "$CBDE" matrix list
  assert_rc "$rc" 0 "$out"
  assert_match "$out" '^    0\.1\.0 +GHC 9\.6\.6 +cabal 3\.10\.3\.0 +Lean v4\.24\.0 +local$'
  assert_match "$out" '^  \* 0\.2\.0 +GHC 9\.6\.7 .* local, registry, latest   <- this project$'
  assert_match "$out" '^    0\.3\.0 +\(in registry, not pulled\) +cbde matrix 0\.3\.0  to use it$'
  assert_not_contains "$out" "base"
  assert_contains "$out" "registry: localhost:5000/cbde"
  assert_not_contains "$(cat "$STUB_LOG")" "docker run" "the list never starts a container"
}

test_matrix_list_stars_the_project_pin_and_survives_no_registry() {
  with_cfg; mkrepo p && cd p
  printf 'matrix=0.1.0\n' > .cbde
  STUB_TAGS="0.1.0 0.2.0 latest" STUB_IMAGES="cbde:latest cbde:0.1.0 cbde:0.2.0" STUB_TAGS_JSON='{}' run "$CBDE" matrix list
  assert_rc "$rc" 0 "$out"
  assert_match "$out" '^  \* 0\.1\.0 .*<- this project$'
  assert_match "$out" '^    0\.2\.0 .* local, latest$'
  assert_contains "$out" "(not reachable, or empty)"
}

test_matrix_list_with_nothing_anywhere() {
  with_cfg; mkrepo p && cd p
  STUB_TAGS="" STUB_IMAGES="" STUB_TAGS_JSON='{}' run "$CBDE" matrix list
  assert_rc "$rc" 0 "$out"
  assert_contains "$out" "no matrices"
  assert_contains "$out" "cbde build"
}

run_tests
