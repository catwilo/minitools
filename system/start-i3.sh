#!/usr/bin/env bash
# system/start-i3.sh
# ----------------------------------------------------------------------------
# Launch Termux:X11 server + i3wm session.
#
# Prerequisite: run system/i3-bootstrap.sh first, and have the Termux:X11
# app open in the background with "display over other apps" permission
# granted.
#
# Usage:
#   bash start-i3.sh
#
# Exit codes:
#   0 = clean exit (i3 quit normally)
#   1 = fatal error (missing binaries)
# ----------------------------------------------------------------------------

set -euo pipefail

if [[ -t 2 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    readonly G=$'\033[32m' R=$'\033[31m' C=$'\033[36m' Z=$'\033[0m'
else
    readonly G='' R='' C='' Z=''
fi

ok()   { printf '%s[OK]%s   %s\n'  "$G" "$Z" "$*" >&2; }
err()  { printf '%s[ERR]%s  %s\n'  "$R" "$Z" "$*" >&2; }
info() { printf '%s[INFO]%s %s\n'  "$C" "$Z" "$*" >&2; }
die()  { err "$*"; exit 1; }

command -v termux-x11 >/dev/null 2>&1 || die "termux-x11 not found -- run i3-bootstrap.sh first"
command -v i3          >/dev/null 2>&1 || die "i3 not found -- run i3-bootstrap.sh first"

X11_PID=""
_cleanup() {
    if [[ -n "$X11_PID" ]] && kill -0 "$X11_PID" 2>/dev/null; then
        info "stopping termux-x11 (pid $X11_PID)"
        kill "$X11_PID" 2>/dev/null || true
    fi
}
trap _cleanup EXIT

info "starting termux-x11 on :0"
termux-x11 :0 &
X11_PID=$!

sleep 2
if ! kill -0 "$X11_PID" 2>/dev/null; then
    die "termux-x11 exited immediately -- is the Termux:X11 app open?"
fi
ok "termux-x11 running (pid $X11_PID)"

info "launching i3 (DISPLAY=:0)"
DISPLAY=:0 i3
ok "i3 session ended"
