#!/usr/bin/env bash
# system/i3-bootstrap.sh
# ----------------------------------------------------------------------------
# Install i3wm + Termux:X11 companion + minimal desktop stack (xterm, dmenu,
# i3status) on top of an already-bootstrapped Termux node.
#
# Idempotent: safe to re-run; pkg install skips already-installed packages.
#
# Usage:
#   bash i3-bootstrap.sh [--dry-run]
#
# Exit codes:
#   0 = success
#   1 = fatal error
# ----------------------------------------------------------------------------

set -euo pipefail

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "$0")"

readonly PACKAGES=(x11-repo termux-x11-nightly i3wm xterm dmenu i3status)

DRY_RUN=0

if [[ -t 2 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    readonly G=$'\033[32m' Y=$'\033[33m' R=$'\033[31m'
    readonly C=$'\033[36m' B=$'\033[1m'  Z=$'\033[0m'
else
    readonly G='' Y='' R='' C='' B='' Z=''
fi

ok()   { printf '%s[OK]%s   %s\n'   "$G" "$Z" "$*" >&2; }
warn() { printf '%s[WARN]%s %s\n'  "$Y" "$Z" "$*" >&2; }
err()  { printf '%s[ERR]%s  %s\n'  "$R" "$Z" "$*" >&2; }
info() { printf '%s[INFO]%s %s\n'  "$C" "$Z" "$*" >&2; }
step() { printf '\n%s== %s ==%s\n' "$B" "$*" "$Z" >&2; }
die()  { err "$*"; exit 1; }

_run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] $*"
        return 0
    fi
    "$@" >/dev/null 2>&1
}

_verify_binary() {
    hash -r 2>/dev/null || true
    if command -v "$1" >/dev/null 2>&1; then
        ok "binary found: $1"; return 0
    fi
    err "binary not found: $1"; return 1
}

phase_1_packages() {
    step "PHASE 1: installing packages"
    info "packages: ${PACKAGES[*]}"
    if ! _run pkg install -y "${PACKAGES[@]}"; then
        die "package install failed"
    fi
    ok "packages installed"
}

phase_2_verify() {
    step "PHASE 2: verifying binaries"
    local rc=0
    for bin in termux-x11 i3 xterm dmenu i3status; do
        _verify_binary "$bin" || rc=1
    done
    [[ $rc -eq 0 ]] || warn "one or more binaries missing -- check pkg output above"
}

_usage() {
    cat << HELP
${B}$SCRIPT_NAME${Z} v$SCRIPT_VERSION
Install i3wm + Termux:X11 + minimal desktop stack on Termux.

${B}Usage:${Z}  bash $SCRIPT_NAME [OPTIONS]

${B}Options:${Z}
  --dry-run     Print what would run, do not execute
  -h, --help    Show this help

${B}Note:${Z} requires the Termux:X11 app (separate APK) installed on Android,
and "display over other apps" permission granted to it.
HELP
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)  DRY_RUN=1;  shift ;;
            -h|--help)  _usage; exit 0 ;;
            *)          die "unknown option: $1" ;;
        esac
    done

    phase_1_packages
    phase_2_verify

    echo ""
    ok "i3-bootstrap complete."
    echo "Next: bash system/start-i3.sh"
}

main "$@"
