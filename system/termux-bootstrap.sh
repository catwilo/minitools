#!/usr/bin/env bash
# termux-bootstrap.sh
# ----------------------------------------------------------------------------
# Bootstrap a fresh Termux node with base packages + 9 CORE applications.
#
# Order: [phase 0: termux base] -> ut -> clipso -> zsh-setup -> maid-chan
#        -> mkit -> miko-task -> noemap -> nvim-setup -> audit-privacy
#
# Idempotent: safe to re-run; skips already-installed phases.
# Modular:    each phase self-contained, testable independently.
#
# Usage:
#   bash termux-bootstrap.sh [--skip-log] [--dry-run]
#
# Exit codes:
#   0 = success
#   1 = fatal error
# ----------------------------------------------------------------------------

set -euo pipefail

# ----------------------------------------------------------------------------
# CONFIGURATION
# ----------------------------------------------------------------------------

readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_NAME="$(basename "$0")"

readonly UT_ROOT="${HOME}/unix-toolkit"
readonly TOOLS_DIR="${HOME}/unix-toolkit-tools"
readonly LOCAL_BIN="${HOME}/.local/bin"
readonly LOG_DIR="${HOME}/.local/var/log"
readonly LOG_FILE="${LOG_DIR}/termux-bootstrap-$(date +%Y%m%d-%H%M%S).log"

# Base packages Termux does NOT ship by default but every later phase needs.
readonly BASE_PACKAGES=(git openssh gh python nodejs neovim rsync termux-api zsh curl wget)

SKIP_LOG=0
DRY_RUN=0
EXIT_CODE=0
declare -a _CLEANUP_TMPFILES=()


# ----------------------------------------------------------------------------
# LOGGING
# ----------------------------------------------------------------------------

if [[ -t 2 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    readonly G=$'\033[32m' Y=$'\033[33m' R=$'\033[31m'
    readonly C=$'\033[36m' B=$'\033[1m'  Z=$'\033[0m'
else
    readonly G='' Y='' R='' C='' B='' Z=''
fi

mkdir -p "$LOG_DIR" 2>/dev/null || true

# Plain (no color codes) copy of a line, written to the log file only.
_log_plain() {
    [[ $SKIP_LOG -eq 0 ]] && echo "$*" >> "$LOG_FILE" 2>/dev/null
}

ok()   { printf '%s[OK]%s   %s\n'   "$G" "$Z" "$*" >&2; _log_plain "[OK]   $*"; }
warn() { printf '%s[WARN]%s %s\n'  "$Y" "$Z" "$*" >&2; _log_plain "[WARN] $*"; }
err()  { printf '%s[ERR]%s  %s\n'  "$R" "$Z" "$*" >&2; _log_plain "[ERR]  $*"; }
info() { printf '%s[INFO]%s %s\n'  "$C" "$Z" "$*" >&2; _log_plain "[INFO] $*"; }
step() { printf '\n%s== %s ==%s\n' "$B" "$*" "$Z" >&2; _log_plain ""; _log_plain "== $* =="; }
die()  { err "$*"; exit 1; }
# ----------------------------------------------------------------------------
# CLEANUP
# ----------------------------------------------------------------------------

_cleanup() {
    local f
    for f in "${_CLEANUP_TMPFILES[@]:-}"; do
        [[ -n "$f" && -e "$f" ]] && rm -f "$f"
    done
}
trap _cleanup EXIT

# ----------------------------------------------------------------------------
# UTILITIES
# ----------------------------------------------------------------------------

# Run a command with stdout/stderr silenced (e.g. apt/pkg
# noise). Dry-run prints and returns 0 without executing.
_run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] $*"
        return 0
    fi
    "$@" >/dev/null 2>&1
    local rc=$?
    return $rc
}

# Run a command, capturing stderr for diagnosis on
# failure instead of silently discarding it.
_run_capture() {
    local errfile; errfile="$(mktemp "${TMPDIR:-/tmp}/berr.XXXXXX")"
    _CLEANUP_TMPFILES+=("$errfile")
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] $*"
        return 0
    fi
    if "$@" >/dev/null 2>"$errfile"; then
        return 0
    fi
    local rc=$?
    if [[ -s "$errfile" ]]; then
        warn "stderr: $(tail -n 3 "$errfile" | tr '\n' ' ')"
    fi
    return $rc
}

_verify_binary() {
    hash -r 2>/dev/null || true
    if command -v "$1" >/dev/null 2>&1; then
        ok "binary found: $1"; return 0
    fi
    err "binary not found: $1"; return 1
}

_git_sync() {
    local name="$1" url="$2" path="${3:-$TOOLS_DIR/$1}"

    if [[ -d "$path/.git" ]]; then
        info "repo exists, updating: $name"
        if ! _run_capture git -C "$path" fetch origin; then
            warn "fetch failed for $name (network?), continuing with local state"
            return 0
        fi
        if ! _run_capture git -C "$path" pull --rebase origin main; then
            warn "pull failed for $name, continuing with local state"
            return 0
        fi
    else
        info "cloning: $name"
        if ! _run_capture git clone "$url" "$path"; then
            warn "clone failed for $name, retrying once after network blip"
            sleep 2
            if ! _run_capture git clone "$url" "$path"; then
                err "clone failed: $name (after retry)"
                return 1
            fi
        fi
    fi
    ok "repo synced: $name"
}

# Atomic install: verify src -> tmp copy -> chmod -> mv. Never symlink.
_install_atomic() {
    local src="$1" dst="$2"
    local dstdir; dstdir="$(dirname "$dst")"

    [[ -f "$src" ]] || { err "source not found: $src"; return 1; }
    mkdir -p "$dstdir"

    local tmp
    tmp="$(mktemp "${dstdir}/install.XXXXXX")" || { err "mktemp failed in $dstdir"; return 1; }
    _CLEANUP_TMPFILES+=("$tmp")

    if ! _run cp -f "$src" "$tmp"; then
        err "cp failed: $src -> $tmp"; return 1
    fi
    if ! _run chmod +x "$tmp"; then
        err "chmod failed: $tmp"; return 1
    fi
    if ! _run mv -f "$tmp" "$dst"; then
        err "mv failed: $tmp -> $dst"; return 1
    fi
    ok "installed: $dst"
}

# ----------------------------------------------------------------------------
# PHASE 0: TERMUX BASE (fresh device has none of this)
# ----------------------------------------------------------------------------

phase_0_termux_base() {
    step "PHASE 0: Termux base environment"

    if [[ -z "${TERMUX_BOOTSTRAP_REPO_DONE:-}" ]]; then
        warn "termux-change-repo is interactive (TUI menu) -- cannot be scripted with -y."
        warn "Run it once manually if you need a mirror change: termux-change-repo"
        info "skipping automated repo-change; using whatever repo is currently configured"
    fi

    info "updating package index"
    _run_capture pkg update -y || warn "pkg update reported issues, continuing"

    info "upgrading installed packages"
    _run_capture pkg upgrade -y || warn "pkg upgrade reported issues, continuing"

    info "installing base packages: ${BASE_PACKAGES[*]}"
    if ! _run pkg install -y "${BASE_PACKAGES[@]}"; then
        die "base package install failed -- cannot continue without git/gh/etc"
    fi

    for bin in git gh python node nvim rsync zsh curl wget; do
        _verify_binary "$bin" || warn "$bin missing after install -- later phases may fail"
    done

    if command -v termux-setup-storage >/dev/null 2>&1; then
        if [[ -d "$HOME/storage" ]]; then
            info "storage already configured ($HOME/storage exists)"
        else
            info "requesting storage access (Android will prompt -- tap Allow)"
            _run termux-setup-storage || warn "storage setup skipped/denied"
        fi
    fi
    ok "Termux base environment ready"
}

# ----------------------------------------------------------------------------
# PHASES 1-9: TOOL REPOS
# ----------------------------------------------------------------------------

_phase_repo_install() {
    local label="$1" name="$2" url="$3" installer="$4" verify_bin="$5"
    step "$label"
    _git_sync "$name" "$url" || return 1
    if [[ -n "$installer" ]]; then
        ( cd "$TOOLS_DIR/$name" && bash "$installer" ) \
            || warn "$name installer had issues, continuing"
    fi
    _verify_binary "$verify_bin" \
        || warn "$verify_bin not in PATH yet (may require shell reload)"
    ok "$name installed"
}

phase_1_ut() {
    step "PHASE 1: ut (unix-toolkit)"
    _git_sync "unix-toolkit" "https://github.com/catwilo/unix-toolkit.git" "$UT_ROOT" || return 1
    # ut ships its binary at repo root; install it atomically once cloned.
    if [[ -f "$UT_ROOT/ut" ]]; then
        _install_atomic "$UT_ROOT/ut" "$LOCAL_BIN/ut" || return 1
    else
        err "ut binary not found at $UT_ROOT/ut after clone"
        return 1
    fi
    # ut-collect.sh is a companion script ut itself needs at runtime (used
    # by 'ut machines diff'). It must sit next to the installed binary, not
    # just live in the source repo.
    if [[ -f "$UT_ROOT/ut-collect.sh" ]]; then
        _install_atomic "$UT_ROOT/ut-collect.sh" "$LOCAL_BIN/ut-collect.sh" || return 1
    fi
    _verify_binary ut || return 1
    _run git config --global init.templateDir "$UT_ROOT/git-templates" 2>/dev/null || true
    _run git config --global push.followTags   true
    _run git config --global pull.rebase       true
    ok "ut installed"
}

phase_2_clipso()     { _phase_repo_install "PHASE 2: clipso"     clipso     "https://github.com/catwilo/clipso.git"     install.sh clipso; }
phase_3_zsh_setup()  { _phase_repo_install "PHASE 3: zsh-setup"  zsh-setup  "https://github.com/catwilo/zsh-setup.git"  install.sh zsh; }
phase_4_maid_chan()  { _phase_repo_install "PHASE 4: maid-chan"  maid-chan  "https://github.com/catwilo/maid-chan.git"  install.sh maid; }
phase_5_mkit()       { _phase_repo_install "PHASE 5: mkit"       mkit       "https://github.com/catwilo/mkit.git"       install.sh mkit; }
phase_6_miko_task()  { _phase_repo_install "PHASE 6: miko-task"  miko-task  "https://github.com/catwilo/miko-task.git"  install.sh miko; }
phase_7_noemap()     { _phase_repo_install "PHASE 7: noemap"     noemap     "https://github.com/catwilo/noemap.git"     install.sh ndevs; }
phase_8_nvim_setup() { _phase_repo_install "PHASE 8: nvim-setup" nvim-setup "https://github.com/catwilo/nvim-setup.git" install.sh nvim; }

phase_9_audit_privacy() {
    step "PHASE 9: audit-privacy"
    _git_sync "audit-privacy" "https://github.com/catwilo/audit-privacy.git" || return 1
    local src="$TOOLS_DIR/audit-privacy/audit-privacy.sh"
    if [[ -f "$src" ]]; then
        _install_atomic "$src" "$LOCAL_BIN/audit-privacy" || return 1
        ok "audit-privacy installed"
    else
        warn "audit-privacy.sh not found in repo; skipping bin install"
    fi
    _verify_binary audit-privacy \
        || warn "audit-privacy not in PATH yet (may require shell reload)"
}

# ----------------------------------------------------------------------------
# PHASE 10: TERMUX COMPANION TOOLS
# ----------------------------------------------------------------------------
# Installs the Termux-side counterparts of companion apps the user already
# has installed from F-Droid (Termux:API, Termux:Boot, Termux:X11). These
# apps are Android APKs and cannot be installed by this script -- only their
# Termux package/binary counterparts can. If an app's Termux side responds,
# we assume the APK is present and working; if not, we tell the user what
# manual step (usually: open the app once) is still needed.

phase_10_termux_companions() {
    step "PHASE 10: Termux companion tools"

    # --- termux-gui-package: lets scripts show images/dialogs from the CLI ---
    info "installing termux-gui-package (console image viewer, dialogs)"
    if _run pkg install -y termux-gui-package; then
        _verify_binary termux-gui-view || warn "termux-gui-view not found after install"
    else
        warn "termux-gui-package install failed, continuing"
    fi

    # --- Termux:X11 companion package ---
    # termux-x11-nightly lives in a separate repo (x11-repo) that Termux does
    # NOT enable by default -- installing it directly without enabling the
    # repo first fails with "unable to locate package".
    info "enabling x11-repo and installing termux-x11-nightly"
    if _run pkg install -y x11-repo && _run pkg install -y termux-x11-nightly; then
        _verify_binary termux-x11 || warn "termux-x11 not found after install"
    else
        warn "termux-x11-nightly install failed, continuing"
    fi

    # --- Termux:API verification (package already in BASE_PACKAGES) ---
    # Termux:API is a two-part system: the termux-api PACKAGE (already
    # installed in Phase 0) and the Termux:API APP (a separate APK). The
    # package alone does nothing if the app isn't installed and running, so
    # we verify with a real call instead of just checking the binary exists.
    info "verifying Termux:API app responds"
    if _run_capture termux-battery-status; then
        ok "Termux:API app responding"
    else
        warn "Termux:API app not responding -- confirm the Termux:API app (APK) is installed"
    fi

    # --- Termux:Boot: create ~/.termux/boot/start-sshd (idempotent) ---
    # Termux:Boot is a separate APK that must be opened by the user at least
    # once to register as a boot receiver with Android -- this script cannot
    # do that tap for you. What it CAN do is prepare the boot script so that,
    # once the app is registered, sshd starts automatically on every reboot.
    local boot_dir="$HOME/.termux/boot"
    local boot_script="$boot_dir/start-sshd"
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would create/verify $boot_script"
    else
        mkdir -p "$boot_dir"
        if [[ -f "$boot_script" ]] && grep -q "^sshd$" "$boot_script" 2>/dev/null; then
            info "boot script already present: $boot_script"
        else
            local tmp_boot
            tmp_boot="$(mktemp "${TMPDIR:-/tmp}/start-sshd.XXXXXX")"
            cat > "$tmp_boot" << 'BOOTSCRIPT'
#!/data/data/com.termux/files/usr/bin/sh
# ~/.termux/boot/start-sshd
# Runs automatically when Termux:Boot detects Android finished booting.
# termux-wake-lock first, so Android doesn't kill sshd by sleeping the device.
termux-wake-lock
sshd
BOOTSCRIPT
            if command -v mkit >/dev/null 2>&1; then
                mkit write "$boot_script" "$tmp_boot" >/dev/null 2>&1
            else
                cp -f "$tmp_boot" "$boot_script"
            fi
            chmod +x "$boot_script"
            rm -f "$tmp_boot"
            ok "boot script created: $boot_script"
        fi
    fi
    warn "Termux:Boot must be opened manually once for Android to register it -- if you haven't, open the Termux:Boot app icon now"


    ok "Termux companion tools ready"
}

# ----------------------------------------------------------------------------
# FINAL STATE
# ----------------------------------------------------------------------------

phase_final_state() {
    step "FINAL STATE"
    hash -r 2>/dev/null || true
    echo ""
    echo "${B}Base packages:${Z}"
    for bin in git gh python node nvim rsync zsh curl wget; do
        if command -v "$bin" >/dev/null 2>&1; then echo "  [OK] $bin"; else echo "  [--] $bin"; fi
    done
    echo ""
    echo "${B}Installed tool binaries:${Z}"
    for bin in ut clipso zsh maid mkit miko ndevs nvim audit-privacy; do
        if command -v "$bin" >/dev/null 2>&1; then
            echo "  [OK] $bin"
        else
            echo "  [--] $bin (may need shell reload)"
        fi
    done
    echo ""
    echo "${B}Paths:${Z}"
    echo "  Local bin: $LOCAL_BIN"
    echo "  Tools dir: $TOOLS_DIR"
    echo "  Log file:  $LOG_FILE"
    echo ""
    echo "${G}${B}Bootstrap complete.${Z}"
    echo "Next: exec zsh && miko status && miko pending && miko next"
    echo ""
}

# ----------------------------------------------------------------------------
# MAIN
# ----------------------------------------------------------------------------

_usage() {
    cat << HELP
${B}$SCRIPT_NAME${Z} v$SCRIPT_VERSION
Bootstrap a fresh Termux node: base packages + 9 CORE applications.

${B}Usage:${Z}  bash $SCRIPT_NAME [OPTIONS]

${B}Options:${Z}
  --skip-log    Do not write to log file (stdout/stderr only)
  --dry-run     Print what would run, do not execute
  -h, --help    Show this help

${B}Phases:${Z}
  0. termux base (pkg update/upgrade + git,gh,python,node,nvim,rsync,zsh,curl,wget)
  1. ut          6. miko-task
  2. clipso      7. noemap
  3. zsh-setup   8. nvim-setup
  4. maid-chan   9. audit-privacy
  5. mkit

${B}Note:${Z} termux-change-repo is interactive and not run automatically.
Run it manually first if you need a faster/alternate mirror.
HELP
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-log) SKIP_LOG=1; shift ;;
            --dry-run)  DRY_RUN=1;  shift ;;
            -h|--help)  _usage; exit 0 ;;
            *)          die "unknown option: $1" ;;
        esac
    done

    phase_0_termux_base   || EXIT_CODE=1
    [[ $EXIT_CODE -eq 1 ]] && die "phase 0 failed -- cannot continue without base tools"

    mkdir -p "$LOCAL_BIN" "$TOOLS_DIR"
    export PATH="$LOCAL_BIN:$PATH"

    phase_1_ut            || EXIT_CODE=1
    phase_2_clipso        || EXIT_CODE=1
    phase_3_zsh_setup     || EXIT_CODE=1
    phase_4_maid_chan     || EXIT_CODE=1
    phase_5_mkit          || EXIT_CODE=1
    phase_6_miko_task     || EXIT_CODE=1
    phase_7_noemap        || EXIT_CODE=1
    phase_8_nvim_setup    || EXIT_CODE=1
    phase_9_audit_privacy      || EXIT_CODE=1
    phase_10_termux_companions || EXIT_CODE=1
    phase_final_state

    exit $EXIT_CODE
}

main "$@"
