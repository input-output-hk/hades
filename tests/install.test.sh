#!/usr/bin/env bash
# install.sh: the curl-style installer, both modes. curl is stubbed and serves
# a small fake launcher (STUB_CURL_FILE); the try mode's shell is the zsh stub.
. "$(dirname "$0")/harness.sh"
INSTALL="$REPO/install.sh"
export PATH="$STUBS:$PATH"

fake_launcher() { # a file that passes the shebang check and identifies itself
  printf '#!/usr/bin/env bash\necho "fake cbde $*"\n' > "$T/launcher"
  export STUB_CURL_FILE="$T/launcher"
}

# ------------------------------------------------------------- install ----

test_install_writes_executable_launcher() {
  fake_launcher
  run env HOME="$T/home" sh "$INSTALL" --dir "$T/bin"
  assert_rc "$rc" 0
  assert_file "$T/bin/cbde"
  [ -x "$T/bin/cbde" ] || fail "not executable"
  assert_eq "$("$T/bin/cbde" doctor)" "fake cbde doctor"
  assert_contains "$out" "installed $T/bin/cbde"
  assert_contains "$out" "next:  cbde doctor"
}

test_install_defaults_to_local_bin_and_main() {
  fake_launcher
  run env HOME="$T/home" sh "$INSTALL"
  assert_rc "$rc" 0
  assert_file "$T/home/.local/bin/cbde"
  assert_contains "$(cat "$STUB_LOG")" "https://raw.githubusercontent.com/input-output-hk/hades/main/bin/cbde"
  assert_contains "$out" "(from input-output-hk/hades@main)"
}

test_install_ref_and_repo_shape_the_url() {
  fake_launcher
  run env HOME="$T/home" sh "$INSTALL" --dir "$T/bin" --ref feat/x --repo acme/cbde
  assert_rc "$rc" 0
  assert_contains "$(cat "$STUB_LOG")" "https://raw.githubusercontent.com/acme/cbde/feat/x/bin/cbde"
  : > "$STUB_LOG"
  run env HOME="$T/home" CBDE_REF=v1 CBDE_REPO=org/tool sh "$INSTALL" --dir "$T/bin"
  assert_contains "$(cat "$STUB_LOG")" "https://raw.githubusercontent.com/org/tool/v1/bin/cbde"
}

test_install_source_overrides_url() {
  fake_launcher
  run env HOME="$T/home" CBDE_SOURCE="file://$T/launcher" sh "$INSTALL" --dir "$T/bin"
  assert_rc "$rc" 0
  assert_contains "$(cat "$STUB_LOG")" "file://$T/launcher"
}

test_install_hints_when_dir_not_on_path() {
  fake_launcher
  run env HOME="$T/home" PATH="$STUBS:/usr/bin:/bin" sh "$INSTALL" --dir "$T/elsewhere"
  assert_rc "$rc" 0
  assert_contains "$out" "$T/elsewhere is not on your PATH"
  assert_contains "$out" "export PATH=\"$T/elsewhere:\$PATH\""
}

test_install_refuses_body_that_is_not_the_launcher() {
  printf '<html>404</html>\n' > "$T/launcher"; export STUB_CURL_FILE="$T/launcher"
  run env HOME="$T/home" sh "$INSTALL" --dir "$T/bin"
  assert_rc "$rc" 1
  assert_contains "$out" "does not look like the cbde launcher"
  assert_no_file "$T/bin/cbde"
}

test_install_fails_cleanly_when_fetch_fails() {
  fake_launcher; export STUB_CURL_FAIL=1
  run env HOME="$T/home" sh "$INSTALL" --dir "$T/bin"
  assert_rc "$rc" 1
  assert_contains "$out" "could not fetch"
  assert_no_file "$T/bin/cbde"
  [ -z "$(ls -A "$T/bin" 2>/dev/null)" ] || fail "left files behind in $T/bin: $(ls -A "$T/bin")"
}

test_install_replaces_existing_launcher() {
  fake_launcher; mkdir -p "$T/bin"; printf 'old\n' > "$T/bin/cbde"
  run env HOME="$T/home" sh "$INSTALL" --dir "$T/bin"
  assert_rc "$rc" 0
  assert_eq "$("$T/bin/cbde" x)" "fake cbde x"
}

test_install_dies_without_bash_on_host() {
  fake_launcher
  mkdir -p "$T/nobash"; ln -s "$(command -v sh)" "$T/nobash/sh"
  run env HOME="$T/home" PATH="$T/nobash" "$T/nobash/sh" "$INSTALL" --dir "$T/bin"
  assert_rc "$rc" 1
  assert_contains "$out" "needs bash"
  assert_no_file "$T/bin/cbde"
}

test_install_usage_and_bad_option() {
  run sh "$INSTALL" --help
  assert_rc "$rc" 0; assert_contains "$out" "--try"
  run sh "$INSTALL" --bogus
  assert_rc "$rc" 1; assert_contains "$out" "unknown option: --bogus"
  run sh "$INSTALL" --ref
  assert_rc "$rc" 1; assert_contains "$out" "--ref needs a value"
}

# ----------------------------------------------------------------- try ----

test_try_opens_shell_with_function_and_installs_nothing() {
  fake_launcher
  run env HOME="$T/home" SHELL="$STUBS/zsh" sh "$INSTALL" --try
  assert_rc "$rc" 0
  assert_contains "$out" "available in this shell only; nothing was installed"
  assert_contains "$out" "try:   cbde doctor"
  assert_contains "$out" "CBDE_TRY_SCRIPT first line: #!/usr/bin/env bash"
  assert_contains "$out" 'cbde() { bash -c "$CBDE_TRY_SCRIPT" cbde "$@"; }'
  assert_contains "$out" 'PROMPT="[cbde try] '
  assert_contains "$out" 'ZDOTDIR="$HOME"'          # user's own zshrc still sourced
  assert_contains "$out" "left the cbde try shell"
  assert_no_file "$T/home/.local/bin/cbde"
  assert_match "$(cat "$STUB_LOG")" '^zsh -i$'
}

test_try_function_runs_the_fetched_launcher() {
  fake_launcher
  run env HOME="$T/home" SHELL="$STUBS/zsh" STUB_ZSH_RUN_CBDE="matrix list" sh "$INSTALL" --try
  assert_rc "$rc" 0
  assert_contains "$out" "fake cbde matrix list"
}

test_try_removes_its_temp_dir_on_exit() {
  fake_launcher
  run env HOME="$T/home" SHELL="$STUBS/zsh" TMPDIR="$T/tmp" sh -c 'mkdir -p "$TMPDIR"; sh "$0" --try' "$INSTALL"
  assert_rc "$rc" 0
  rcdir="$(printf '%s\n' "$out" | sed -n 's/^ZDOTDIR=//p')"
  [ -n "$rcdir" ] || fail "no ZDOTDIR reported"
  assert_contains "$rcdir" "$T/tmp/cbde-try."
  assert_no_file "$rcdir"
}

test_try_falls_back_to_bash_for_unknown_shell() {
  fake_launcher
  # a real, non-interactive-capable bash reading /dev/null sources the rcfile
  # and exits at EOF; that is enough to see the function defined.
  printf '#!/bin/sh\n' > "$T/oddsh"; chmod +x "$T/oddsh"
  run env HOME="$T/home" SHELL="$T/oddsh" sh "$INSTALL" --try
  assert_rc "$rc" 0
  assert_contains "$out" "$T/oddsh is not bash, zsh or fish; using bash"
  assert_contains "$out" "left the cbde try shell"
}

test_try_does_not_touch_disk_when_fetch_fails() {
  fake_launcher; export STUB_CURL_FAIL=1
  run env HOME="$T/home" SHELL="$STUBS/zsh" TMPDIR="$T/tmp" sh -c 'mkdir -p "$TMPDIR"; sh "$0" --try' "$INSTALL"
  assert_rc "$rc" 1
  assert_contains "$out" "could not fetch"
  [ -z "$(ls -A "$T/tmp")" ] || fail "temp dir created before fetch succeeded"
}

run_tests
