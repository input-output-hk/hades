#!/usr/bin/env bash
# lib/matrix.sh: reading, validating and comparing compatibility matrices.
. "$(dirname "$0")/harness.sh"
. "$REPO/lib/matrix.sh"
export CBDE_MATRIX_DIR="$FIXTURES/matrices"
export PATH="$STUBS:$PATH"

test_list_is_version_sorted_oldest_first() {
  assert_eq "$(matrix_list | tr '\n' ' ')" "0.1.0 0.2.0 "
  mkdir m; for v in 0.10.0 0.9.0 0.2.0 1.0.0; do : > "m/$v.env"; done
  assert_eq "$(CBDE_MATRIX_DIR=m matrix_list | tr '\n' ' ')" "0.2.0 0.9.0 0.10.0 1.0.0 "
  assert_eq "$(CBDE_MATRIX_DIR=m matrix_newest)" "1.0.0"
  mkdir empty
  assert_eq "$(CBDE_MATRIX_DIR=empty matrix_list)" "" "empty dir lists nothing"
}

test_file_lookup() {
  run matrix_file 0.1.0
  assert_rc "$rc" 0; assert_eq "$out" "$FIXTURES/matrices/0.1.0.env"
  run matrix_file 9.9.9
  assert_rc "$rc" 1; assert_contains "$out" "no such matrix: 9.9.9"; assert_contains "$out" "known: 0.1.0 0.2.0"
  run matrix_file ../etc/passwd
  assert_rc "$rc" 2; assert_contains "$out" "invalid matrix name"
  run matrix_file ".hidden"
  assert_rc "$rc" 2
  run matrix_file ""
  assert_rc "$rc" 2
}

test_get_reads_values_without_sourcing() {
  local f="$FIXTURES/matrices/0.1.0.env"
  assert_eq "$(matrix_get "$f" CBDE_GHC)" "9.6.6"
  assert_eq "$(matrix_get "$f" CBDE_LEAN)" "leanprover/lean4:v4.22.0"
  assert_eq "$(matrix_get "$f" CBDE_HLS)" "" "empty value"
  assert_eq "$(matrix_get "$f" NOPE)" "" "absent key"
  # A key that is a prefix of another must not match it.
  printf 'CBDE_GHC_EXTRA=1\nCBDE_GHC=2\n' > p.env
  assert_eq "$(matrix_get p.env CBDE_GHC)" "2"
}

test_validate_accepts_fixtures_and_real_matrices() {
  local f
  for f in "$FIXTURES"/matrices/*.env "$REPO"/matrices/*.env; do
    run matrix_validate "$f"
    assert_rc "$rc" 0 "$f: $out"
  done
}

test_validate_rejects_malformed_files() {
  local b="$FIXTURES/bad-matrices"
  run matrix_validate "$b/bad-value.env";     assert_rc "$rc" 1; assert_contains "$out" "bad value"
  run matrix_validate "$b/missing-key.env";   assert_rc "$rc" 1; assert_contains "$out" "missing key: CBDE_HLS"; assert_contains "$out" "missing key: CBDE_LEAN"
  run matrix_validate "$b/name-mismatch.env"; assert_rc "$rc" 1; assert_contains "$out" "CBDE_IMAGE_VERSION=0.9.0 does not match the file name name-mismatch"
  run matrix_validate "$b/duplicate.env";     assert_rc "$rc" 1; assert_contains "$out" "duplicate key: CBDE_GHC"
  run matrix_validate "$b/not-kv.env";        assert_rc "$rc" 1; assert_contains "$out" "not KEY=VALUE: export FOO"; assert_contains "$out" "bad key: lower=1"
  run matrix_validate "$b/does-not-exist.env"; assert_rc "$rc" 1; assert_contains "$out" "not found"
}

test_build_args_one_per_pin_no_comments() {
  run matrix_build_args "$FIXTURES/matrices/0.1.0.env"
  assert_rc "$rc" 0
  assert_contains "$out" "--build-arg CBDE_GHC=9.6.6"
  assert_contains "$out" "--build-arg CBDE_HLS="
  assert_not_contains "$out" "#"
  assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "$(grep -c '^[A-Z]' "$FIXTURES/matrices/0.1.0.env")"
}

test_check_env_detects_drift() {
  local f="$FIXTURES/matrices/0.1.0.env"
  # Environment exactly as the file: passes.
  run env $(matrix_pairs "$f") bash -c ". '$REPO/lib/matrix.sh'; matrix_check_env '$f'"
  assert_rc "$rc" 0 "$out"
  # One pin differs, one is unset: both reported.
  run env $(matrix_pairs "$f" | grep -v '^CBDE_GHC=\|^BLST_TAG=') CBDE_GHC=9.8.1 \
      bash -c ". '$REPO/lib/matrix.sh'; matrix_check_env '$f'"
  assert_rc "$rc" 1
  assert_contains "$out" "CBDE_GHC: matrix says 9.6.6, build has 9.8.1"
  assert_contains "$out" "BLST_TAG: matrix says v0.3.14, build has (unset)"
}

test_status_verified_when_stubs_match() {
  run matrix_status "$FIXTURES/matrices/0.2.0.env"
  assert_rc "$rc" 0 "$out"
  assert_match "$out" $'^GHC\t9.6.7\t9.6.7\tok$'
  assert_match "$out" $'^cabal\t3.10.3.0\t3.10.3.0\tok$'
  assert_match "$out" $'^HLS\t\\(not pinned\\)\t\\(none\\)\toptional$'
  assert_match "$out" $'^Lean\tleanprover/lean4:v4.24.0\tleanprover/lean4:v4.24.0\tok$'
  assert_eq "$(matrix_verdict "$FIXTURES/matrices/0.2.0.env")" verified
}

test_status_custom_when_a_component_drifts() {
  run env STUB_GHC=9.6.6 bash -c ". '$REPO/lib/matrix.sh'; matrix_status '$FIXTURES/matrices/0.2.0.env'"
  assert_rc "$rc" 1
  assert_match "$out" $'^GHC\t9.6.7\t9.6.6\toff$'
  assert_eq "$(STUB_GHC=9.6.6 matrix_verdict "$FIXTURES/matrices/0.2.0.env")" custom
}

test_status_missing_when_nothing_installed() {
  run env STUB_GHC= STUB_LEAN= bash -c ". '$REPO/lib/matrix.sh'; matrix_status '$FIXTURES/matrices/0.2.0.env'"
  assert_rc "$rc" 1
  assert_match "$out" $'^GHC\t9.6.7\t\\(none\\)\tmissing$'
  assert_match "$out" $'^Lean\tleanprover/lean4:v4.24.0\t\\(none\\)\tmissing$'
}

test_installed_but_unpinned_hls_is_optional() {
  run env STUB_HLS=2.9.0.0 bash -c ". '$REPO/lib/matrix.sh'; matrix_status '$FIXTURES/matrices/0.2.0.env'"
  assert_rc "$rc" 0
  assert_match "$out" $'^HLS\t\\(not pinned\\)\t2.9.0.0\toptional$'
}

run_tests
