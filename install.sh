#!/usr/bin/env bash
# minitools/install.sh — idempotent installer
#
# usage:
#   bash install.sh          install
#   bash install.sh verify   verify only (no changes)
#
# PHILOSOPHY (mandatory, repo-deletable rule): COPY, never symlink. After
# install, the repo must be deletable without breaking anything installed.
# This installer's correctness IS the deploy mechanism -- if a tool's
# behavior needs to change, fix the SOURCE here in the repo and re-run
# install.sh (or `ut deploy minitools`). Never hand-patch the copy living
# in ~/.local/bin -- that copy is overwritten on every install and any
# direct edit to it is silently lost on the next deploy.
#
# Add new tools to the TOOLS array below -- one line per tool.

set -Eeuo pipefail

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[0;31m' YELLOW='\033[1;33m' GREEN='\033[0;32m' CYAN='\033[0;36m' RESET='\033[0m'
else
    RED='' YELLOW='' GREEN='' CYAN='' RESET=''
fi
ok()   { printf "${GREEN}[OK]${RESET}    %s\n" "$*" >&2; }
warn() { printf "${YELLOW}[WARN]${RESET}  %s\n" "$*" >&2; }
die()  { printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2; exit 1; }

_self="$0"
case "$_self" in */*) ;; *) _self="$(command -v "$_self")" ;; esac
if _real="$(readlink -f "$_self" 2>/dev/null)" && [ -n "$_real" ]; then
    _self="$_real"
else
    while [ -L "$_self" ]; do
        _link="$(readlink "$_self")"
        case "$_link" in /*) _self="$_link" ;; *) _self="$(dirname "$_self")/$_link" ;; esac
    done
fi
SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd -P)"

# name:relative-path-from-repo-root  -- add one line per standalone tool to install
TOOLS=(
    "pty-run:system/pty-run"
)

if [ -n "${PREFIX:-}" ] && [ -d "${PREFIX}/bin" ]; then
    BINDIR="${PREFIX}/bin"
elif [ -d "$HOME/.local/bin" ] || mkdir -p "$HOME/.local/bin" 2>/dev/null; then
    BINDIR="$HOME/.local/bin"
else
    die "no writable bin dir found"
fi

_do_verify() {
    local rc=0
    for entry in "${TOOLS[@]}"; do
        local name="${entry%%:*}"
        local found
        found="$(command -v "$name" 2>/dev/null || true)"
        if [ -z "$found" ]; then warn "$name not in PATH"; rc=1; continue; fi
        [ -L "$found" ] && { warn "$name is a symlink (expected a copy) -> $found"; rc=1; continue; }
        [ -x "$found" ] || { warn "$name not executable -> $found"; rc=1; continue; }
        ok "$name -> $found"
    done
    return $rc
}

if [ "${1:-}" = verify ]; then _do_verify; exit $?; fi

for entry in "${TOOLS[@]}"; do
    name="${entry%%:*}" rel="${entry#*:}"
    src="$SCRIPT_DIR/$rel"
    [ -f "$src" ] || die "$name not found at $src"

    tmp="$(mktemp "${BINDIR}/.${name}.XXXXXX")"
    cp -fL "$src" "$tmp"
    chmod +x "$tmp"
    mv -f "$tmp" "$BINDIR/$name"
    ok "copied $name -> $BINDIR/$name"

    if [ "$BINDIR" != "$HOME/.local/bin" ] && [ -d "$HOME/.local/bin" ]; then
        tmp2="$(mktemp "$HOME/.local/bin/.${name}.XXXXXX")"
        cp -fL "$src" "$tmp2"
        chmod +x "$tmp2"
        mv -f "$tmp2" "$HOME/.local/bin/$name"
        ok "copied $name -> $HOME/.local/bin/$name (stale guard)"
    fi
done

ok "done"
