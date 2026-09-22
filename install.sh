#!/bin/sh
# install.sh — put the cbde launcher on this machine, or in one shell only.
#
#   curl -fsSL https://raw.githubusercontent.com/input-output-hk/hades/main/install.sh | sh
#       installs bin/cbde into ~/.local/bin (override: --dir, $CBDE_INSTALL_DIR)
#
#   curl -fsSL https://raw.githubusercontent.com/input-output-hk/hades/main/install.sh | sh -s -- --try
#       opens your $SHELL with a `cbde` function; nothing lands on disk and
#       the function dies with the shell. For trying cbde before installing.
#
# Both modes fetch exactly one file, bin/cbde, from GitHub. Where from:
#   --repo OWNER/NAME   ($CBDE_REPO)   default input-output-hk/hades
#   --ref  REF          ($CBDE_REF)    branch or tag, default main
#   $CBDE_SOURCE                       full URL of bin/cbde; overrides both
#                                      (file:///path/to/checkout/bin/cbde works)
#
# POSIX sh on purpose: `curl | sh` runs under whatever /bin/sh is. The launcher
# itself needs bash (3.2 is enough, macOS has it); we only check it is there.
set -eu

REPO="${CBDE_REPO:-input-output-hk/hades}"
REF="${CBDE_REF:-main}"
DIR="${CBDE_INSTALL_DIR:-$HOME/.local/bin}"
MODE=install

die()  { printf 'cbde install: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }

usage() {
  cat <<EOU
Usage: install.sh [--try] [--dir DIR] [--ref REF] [--repo OWNER/NAME]

  (no flag)   install the cbde launcher into DIR (default ~/.local/bin)
  --try       open a shell with cbde available, install nothing
  --dir DIR   where to put the launcher                 [\$CBDE_INSTALL_DIR]
  --ref REF   git branch or tag to fetch it from        [\$CBDE_REF, main]
  --repo R    GitHub repository OWNER/NAME              [\$CBDE_REPO]
EOU
}

while [ $# -gt 0 ]; do
  case "$1" in
    --try)       MODE=try ;;
    --dir)       [ $# -ge 2 ] || die "--dir needs a value"; DIR="$2"; shift ;;
    --ref)       [ $# -ge 2 ] || die "--ref needs a value"; REF="$2"; shift ;;
    --repo)      [ $# -ge 2 ] || die "--repo needs a value"; REPO="$2"; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

SOURCE="${CBDE_SOURCE:-https://raw.githubusercontent.com/$REPO/$REF/bin/cbde}"

fetch() { # print bin/cbde on stdout
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$SOURCE"
  elif command -v wget >/dev/null 2>&1; then wget -qO- "$SOURCE"
  else die "need curl or wget"
  fi
}

# A 404 page or an empty body must never end up executable on someone's PATH.
looks_like_launcher() { case "$1" in '#!/usr/bin/env bash'*) return 0 ;; esac; return 1; }

check_host() {
  command -v bash   >/dev/null 2>&1 || die "cbde needs bash on the host (any version, 3.2 is fine)"
  command -v docker >/dev/null 2>&1 || note "warning: docker is not on PATH; install Docker before running cbde"
}

# ---------------------------------------------------------------- install ----

do_install() {
  check_host
  script="$(fetch)" || die "could not fetch $SOURCE"
  looks_like_launcher "$script" || die "what $SOURCE served does not look like the cbde launcher"
  mkdir -p "$DIR" || die "cannot create $DIR"
  tmp="$DIR/.cbde.$$"
  printf '%s\n' "$script" > "$tmp" && chmod 0755 "$tmp" && mv -f "$tmp" "$DIR/cbde" \
    || { rm -f "$tmp"; die "cannot write $DIR/cbde"; }
  note "installed $DIR/cbde  (from $REPO@$REF)"
  case ":$PATH:" in
    *":$DIR:"*) note "next:  cbde doctor" ;;
    *) note "note:  $DIR is not on your PATH; add it to your shell profile, e.g."
       note "         export PATH=\"$DIR:\$PATH\""
       note "next:  cbde doctor" ;;
  esac
}

# -------------------------------------------------------------------- try ----
#
# The launcher's text travels in $CBDE_TRY_SCRIPT and a shell function runs it
# with `bash -c`, so it works from bash, zsh or fish alike and there is no file
# to clean up. The user's own rc files are still sourced (prompt, aliases,
# PATH), then the function and a "[cbde try]" prompt marker are added on top.

RC=
cleanup() { [ -n "$RC" ] && rm -rf "$RC"; }

do_try() {
  check_host
  script="$(fetch)" || die "could not fetch $SOURCE"
  looks_like_launcher "$script" || die "what $SOURCE served does not look like the cbde launcher"
  CBDE_TRY_SCRIPT="$script"; export CBDE_TRY_SCRIPT

  shell="${SHELL:-/bin/bash}"
  [ -x "$shell" ] || shell="$(command -v bash)"
  RC="$(mktemp -d "${TMPDIR:-/tmp}/cbde-try.XXXXXX")" || die "cannot create a temp dir"
  trap cleanup EXIT INT TERM

  note "cbde $REF is available in this shell only; nothing was installed."
  note "try:   cbde doctor        leave:  exit"

  case "$(basename "$shell")" in
    zsh)
      cat > "$RC/.zshenv" <<'EOF'
[ -f "$HOME/.zshenv" ] && . "$HOME/.zshenv"
EOF
      cat > "$RC/.zshrc" <<'EOF'
ZDOTDIR="$HOME"
[ -f "$HOME/.zshrc" ] && . "$HOME/.zshrc"
cbde() { bash -c "$CBDE_TRY_SCRIPT" cbde "$@"; }
PROMPT="[cbde try] ${PROMPT-%# }"
EOF
      run_shell env ZDOTDIR="$RC" "$shell" -i ;;
    fish)
      run_shell "$shell" -i -C '
function cbde; bash -c "$CBDE_TRY_SCRIPT" cbde $argv; end
functions -q fish_prompt; and functions -c fish_prompt __cbde_prompt
function fish_prompt; echo -n "[cbde try] "; functions -q __cbde_prompt; and __cbde_prompt; end' ;;
    bash|*)
      case "$(basename "$shell")" in bash) ;; *) note "note:  $shell is not bash, zsh or fish; using bash" ;; esac
      shell="$(command -v bash)"
      cat > "$RC/bashrc" <<'EOF'
[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"
cbde() { bash -c "$CBDE_TRY_SCRIPT" cbde "$@"; }
PS1="[cbde try] ${PS1-\$ }"
EOF
      run_shell "$shell" --rcfile "$RC/bashrc" -i ;;
  esac
  note "left the cbde try shell; nothing was installed."
  note "to install: curl -fsSL https://raw.githubusercontent.com/$REPO/$REF/install.sh | sh"
}

# Under `curl | sh` stdin is the pipe, not the terminal; an interactive shell
# reading from it would exit at once. Reattach to the tty when there is one.
run_shell() {
  if [ -t 0 ]; then "$@" || true
  elif (exec </dev/tty) 2>/dev/null; then "$@" </dev/tty || true
  else "$@" || true
  fi
}

case "$MODE" in
  install) do_install ;;
  try)     do_try ;;
esac
