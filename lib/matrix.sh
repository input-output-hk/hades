#!/usr/bin/env bash
# lib/matrix.sh — the compatibility matrix, as data.
#
# A matrix is one file, matrices/<version>.env: the verified set of pins that
# ships as the image cbde:<version>. Its keys are the Dockerfile ARG names, so a
# file turns straight into --build-arg flags, and they are the ENV names the
# image carries, so a running container can compare itself against the file it
# was built from. Anything that differs is a "custom" toolchain: allowed, but
# doctor says so.
#
# The file is data, never sourced: values are read with sed and validated
# against a whitelist, so a matrix cannot run code.
#
# Sourced by the in-container cbde, by the host launcher (from a checkout, for
# `cbde build`) and by the tests. Runs under bash 3.2: no associative arrays,
# no ${var,,}, no mapfile.

CBDE_MATRIX_DIR="${CBDE_MATRIX_DIR:-/opt/cbde/matrices}"

# Keys every matrix must define, whether or not the value is empty.
MATRIX_REQUIRED_KEYS="CBDE_IMAGE_VERSION CBDE_GHC CBDE_CABAL CBDE_HLS CBDE_LEAN"

# Components that live in the volume and can drift at run time: displayed by
# `cbde matrix` and compared by matrix_status. Everything else in a matrix is
# baked into the image and can only change by changing image.
MATRIX_SWITCHABLE="GHC:CBDE_GHC cabal:CBDE_CABAL HLS:CBDE_HLS Lean:CBDE_LEAN"

matrix_name_ok() { case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; *) return 0 ;; esac; }

# Version-ordered, oldest first. `sort -V` is GNU and recent BSD; fall back to a
# numeric sort on the first three dotted fields.
version_sort() {
  local input; input="$(cat)"
  [ -n "$input" ] || return 0
  printf '%s\n' "$input" | sort -V 2>/dev/null \
    || printf '%s\n' "$input" | sort -t. -k1,1n -k2,2n -k3,3n
}

matrix_list() {
  local f
  for f in "$CBDE_MATRIX_DIR"/*.env; do
    [ -f "$f" ] || continue
    f="${f##*/}"; printf '%s\n' "${f%.env}"
  done | version_sort
}

matrix_newest() { matrix_list | tail -n 1; }

# NAME -> path, or an error on stderr. Exit 2 for a malformed name, 1 for a
# well-formed one that does not exist.
matrix_file() {
  local name="$1" f
  matrix_name_ok "$name" || { printf 'cbde: invalid matrix name: %s\n' "$name" >&2; return 2; }
  f="$CBDE_MATRIX_DIR/$name.env"
  if [ ! -f "$f" ]; then
    printf 'cbde: no such matrix: %s (known: %s)\n' "$name" "$(matrix_list | tr '\n' ' ' | sed 's/ $//')" >&2
    return 1
  fi
  printf '%s\n' "$f"
}

# FILE KEY -> value; empty when the key is absent or set empty.
matrix_get() { sed -n "s/^$2=//p" "$1" | head -n 1; }

# FILE -> every KEY=VALUE line, comments and blanks stripped.
matrix_pairs() { grep -E '^[A-Z_][A-Z0-9_]*=' "$1"; }

# FILE -> one `--build-arg KEY=VALUE` per line, for docker build.
matrix_build_args() { matrix_pairs "$1" | sed 's/^/--build-arg /'; }

# FILE -> 0 when well-formed, else prints every problem and returns 1.
# Well-formed: only comments, blank lines and KEY=VALUE; keys upper-case
# identifiers, values from a whitelist of plain characters (no quotes, spaces
# or shell syntax), no duplicate keys, every required key present, and
# CBDE_IMAGE_VERSION equal to the file's own name.
matrix_validate() {
  local f="$1" bad=0 line key val name dupes
  [ -f "$f" ] || { printf 'matrix file not found: %s\n' "$f"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) ;;
      *=*)
        key="${line%%=*}"; val="${line#*=}"
        case "$key" in
          ''|[!A-Z_]*|*[!A-Z0-9_]*) printf 'bad key: %s\n' "$line"; bad=1 ;;
        esac
        case "$val" in
          *[!A-Za-z0-9._:/+~@-]*) printf 'bad value (only letters, digits and ._:/+~@- allowed): %s\n' "$line"; bad=1 ;;
        esac
        ;;
      *) printf 'not KEY=VALUE: %s\n' "$line"; bad=1 ;;
    esac
  done < "$f"
  dupes="$(matrix_pairs "$f" | cut -d= -f1 | sort | uniq -d)"
  [ -z "$dupes" ] || { printf 'duplicate key: %s\n' $dupes; bad=1; }
  for key in $MATRIX_REQUIRED_KEYS; do
    grep -q "^$key=" "$f" || { printf 'missing key: %s\n' "$key"; bad=1; }
  done
  name="${f##*/}"; name="${name%.env}"
  val="$(matrix_get "$f" CBDE_IMAGE_VERSION)"
  [ "$val" = "$name" ] || { printf 'CBDE_IMAGE_VERSION=%s does not match the file name %s\n' "$val" "$name"; bad=1; }
  return "$bad"
}

# FILE -> 0 when every key in the file equals the same-named variable in the
# environment. Used at image build time, where the Dockerfile ARGs are the
# environment, to refuse an image whose pins drifted from its matrix.
matrix_check_env() {
  local f="$1" bad=0 line key want have
  for line in $(matrix_pairs "$f"); do
    key="${line%%=*}"; want="${line#*=}"
    eval "have=\${$key-}"
    [ "$have" = "$want" ] || { printf '%s: matrix says %s, build has %s\n' "$key" "${want:-(empty)}" "${have:-(unset)}"; bad=1; }
  done
  return "$bad"
}

# What is actually active in this container. Each is a single external command
# so the tests can stand in a stub on PATH.
active_ghc()   { ghc --numeric-version 2>/dev/null; }
active_cabal() { cabal --numeric-version 2>/dev/null; }
active_hls()   { haskell-language-server-wrapper --numeric-version 2>/dev/null | tr -d '\n'; }
# `elan toolchain list` prints bare names; only `elan show` marks the default
# (first line: "<toolchain> (default)"). Both are local, no network.
active_lean()  { elan show 2>/dev/null | sed -n 's/ (default)$//p' | head -n 1; }

active_of() {
  case "$1" in
    GHC)   active_ghc ;;
    cabal) active_cabal ;;
    HLS)   active_hls ;;
    Lean)  active_lean ;;
  esac
}

# FILE -> one tab-separated line per switchable component:
#   component <TAB> pinned <TAB> active <TAB> ok|off|missing|optional
# Returns 0 when everything pinned is active (verified), 1 otherwise (custom).
# A component the matrix leaves empty (HLS, usually) is optional: whatever is
# installed is fine.
matrix_status() {
  local f="$1" rc=0 pair comp key want have state
  for pair in $MATRIX_SWITCHABLE; do
    comp="${pair%%:*}"; key="${pair#*:}"
    want="$(matrix_get "$f" "$key")"
    have="$(active_of "$comp")"
    if   [ -z "$want" ];         then state=optional
    elif [ -z "$have" ];         then state=missing
    elif [ "$want" = "$have" ];  then state=ok
    else                              state=off
    fi
    printf '%s\t%s\t%s\t%s\n' "$comp" "${want:-(not pinned)}" "${have:-(none)}" "$state"
    case "$state" in ok|optional) ;; *) rc=1 ;; esac
  done
  return "$rc"
}

# FILE -> "verified" or "custom".
matrix_verdict() { matrix_status "$1" >/dev/null && printf 'verified' || printf 'custom'; }

# ---------------------------------------------------------------------------
# Installing the matrix's toolchain: from the image when possible
# ---------------------------------------------------------------------------
# The image carries the compressed ghcup bindists of its matrix (about 210 MB
# for GHC and cabal, already xz) under $CBDE_SEED_DIR, fetched at build time
# with `ghcup prefetch` so their names are exactly what ghcup looks for. To
# install offline they are copied into ghcup's cache, ghcup is run with
# --offline --cache, and the copies are removed again (the seed stays in the
# image for the next fresh volume). Anything the seed does not have, another
# GHC the user asked for, say, goes the online way as before.
CBDE_SEED_DIR="${CBDE_SEED_DIR:-/opt/cbde/seed}"

seed_prefix() {
  case "$1" in
    ghc)   printf 'ghc-' ;;
    cabal) printf 'cabal-install-' ;;
    hls)   printf 'haskell-language-server-' ;;
    *)     printf '%s-' "$1" ;;
  esac
}

# TOOL VERSION -> the seed files for that exact version, if any.
seed_files() {
  local f
  for f in "$CBDE_SEED_DIR/$(seed_prefix "$1")$2"-*; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
  return 0
}

# ghcup_install TOOL VERSION [ghcup install flags...]
# Offline from the seed when it has this version, else online. With
# CBDE_SEED_STRICT=1 (the image build) a seeded install must succeed offline,
# so a broken seed fails the build instead of quietly downloading.
ghcup_install() {
  local tool="$1" version="$2"; shift 2
  local cache="${GHCUP_INSTALL_BASE_PREFIX:-/nix/cbde}/.ghcup/cache" f copied= rc=0
  local seeds; seeds="$(seed_files "$tool" "$version")"
  if [ -n "$seeds" ]; then
    printf 'cbde: installing %s %s from the image (no download)\n' "$tool" "$version" >&2
    mkdir -p "$cache"
    for f in $seeds; do
      if [ ! -e "$cache/${f##*/}" ]; then cp "$f" "$cache/" && copied="$copied $cache/${f##*/}"; fi
    done
    ghcup --offline --cache install "$tool" "$version" "$@" || rc=$?
    [ -z "$copied" ] || rm -f $copied
    [ "$rc" = 0 ] && return 0
    if [ "${CBDE_SEED_STRICT:-}" = 1 ]; then
      printf 'cbde: offline install from the seed failed (CBDE_SEED_STRICT=1, not falling back)\n' >&2
      return "$rc"
    fi
    printf 'cbde: WARNING: offline install from the seed failed, downloading instead\n' >&2
  fi
  ghcup install "$tool" "$version" "$@"
}

# ---------------------------------------------------------------------------
# The Lean toolchain: from the image when possible
# ---------------------------------------------------------------------------
# elan has no download cache, but its toolchain directory is just the unpacked
# release under ~/.elan/toolchains/<name with / -> -- and : -> --->. The image
# build packs that directory (xz, ~390 MB) into the seed; installing from it is
# untar into the volume plus `elan default`. Verified: elan lists and uses a
# toolchain that appeared this way, and the prebuilt Blaster checkout runs.
CBDE_ELAN_DIR="${CBDE_ELAN_DIR:-/nix/cbde/elan}"

# leanprover/lean4:v4.24.0 -> leanprover--lean4---v4.24.0
elan_toolchain_dir() { printf '%s' "$1" | sed 's|/|--|g; s|:|---|g'; }

lean_seed_file() {
  local f="$CBDE_SEED_DIR/lean-$(elan_toolchain_dir "$1").tar.xz"
  [ -f "$f" ] && printf '%s\n' "$f"
  return 0
}

# lean_install TOOLCHAIN: unpack from the seed when the image has it, else
# `elan toolchain install` (network). Either way it becomes the default.
# CBDE_SEED_STRICT=1 refuses to fall back to the network.
lean_install() {
  local tc="$1" seed dir tmp rc=0
  seed="$(lean_seed_file "$tc")"
  if [ -n "$seed" ]; then
    dir="$CBDE_ELAN_DIR/toolchains/$(elan_toolchain_dir "$tc")"
    printf 'cbde: installing Lean %s from the image (no download)\n' "$tc" >&2
    mkdir -p "$CBDE_ELAN_DIR/toolchains"
    # Unpack beside the target and rename, so an interrupted unpack never
    # leaves a half toolchain that elan would happily list as installed.
    tmp="$(mktemp -d "$CBDE_ELAN_DIR/toolchains/.unpack.XXXXXX")" || return 1
    if xz -dc -T0 "$seed" | tar -x -C "$tmp" && [ -d "$tmp/$(elan_toolchain_dir "$tc")" ]; then
      rm -rf "$dir" && mv "$tmp/$(elan_toolchain_dir "$tc")" "$dir" && rmdir "$tmp"
      elan default "$tc" >/dev/null 2>&1 || rc=$?
    else
      rc=1; rm -rf "$tmp"
    fi
    [ "$rc" = 0 ] && return 0
    if [ "${CBDE_SEED_STRICT:-}" = 1 ]; then
      printf 'cbde: Lean install from the seed failed (CBDE_SEED_STRICT=1, not falling back)\n' >&2
      return "$rc"
    fi
    printf 'cbde: WARNING: Lean install from the seed failed, downloading instead\n' >&2
  fi
  elan toolchain install "$tc" && elan default "$tc" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# The package indices: from the image when possible
# ---------------------------------------------------------------------------
# cabal's ~/.cabal/packages/<repo>/ holds the index tar, its cache and the
# hackage-security metadata; the image build packs the two directories at the
# matrix's pinned index-states. Installing is untar into the volume. Online,
# `cabal update <repo>,<state>` fetches the very same snapshot, run from a
# throwaway copy of the warm-index project (cabal writes a dist-newstyle next
# to it, and the image copy is root-owned).
CBDE_CABAL_DIR="${CBDE_CABAL_DIR:-/nix/cbde/cabal}"
CBDE_WARM_INDEX="${CBDE_WARM_INDEX:-/opt/cbde/warm-index}"

cabal_index_seed_file() {
  [ -f "$CBDE_SEED_DIR/cabal-packages.tar.xz" ] && printf '%s\n' "$CBDE_SEED_DIR/cabal-packages.tar.xz"
  return 0
}

cabal_index_install() {
  local pkgs="$CBDE_CABAL_DIR/packages" seed tmp d rc=0
  seed="$(cabal_index_seed_file)"
  if [ -n "$seed" ]; then
    printf 'cbde: installing the package indices from the image (no download)\n' >&2
    mkdir -p "$pkgs"
    tmp="$(mktemp -d "$pkgs/.unpack.XXXXXX")" || return 1
    if xz -dc -T0 "$seed" | tar -x -C "$tmp"; then
      for d in "$tmp"/*/; do
        d="${d%/}"; rm -rf "$pkgs/${d##*/}" && mv "$d" "$pkgs/${d##*/}"
      done
      rmdir "$tmp" 2>/dev/null || rm -rf "$tmp"
      return 0
    fi
    rm -rf "$tmp"; rc=1
    if [ "${CBDE_SEED_STRICT:-}" = 1 ]; then
      printf 'cbde: index install from the seed failed (CBDE_SEED_STRICT=1, not falling back)\n' >&2
      return "$rc"
    fi
    printf 'cbde: WARNING: index install from the seed failed, downloading instead\n' >&2
  fi
  rc=0
  local states=() warm
  [ -z "${CBDE_INDEX_STATE:-}" ]      || states+=("hackage.haskell.org,$CBDE_INDEX_STATE")
  [ -z "${CBDE_CHAP_INDEX_STATE:-}" ] || states+=("cardano-haskell-packages,$CBDE_CHAP_INDEX_STATE")
  warm="$(mktemp -d)" || return 1
  cp "$CBDE_WARM_INDEX/cabal.project" "$warm/" || { rm -rf "$warm"; return 1; }
  (cd "$warm" && cabal update ${states[@]+"${states[@]}"}) || rc=$?
  rm -rf "$warm"
  return "$rc"
}
