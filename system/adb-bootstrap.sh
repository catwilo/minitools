#!/usr/bin/env bash
# adb-bootstrap.sh
# ----------------------------------------------------------------------------
# Set up privileged ADB access on Termux via Shizuku, then audit and harden
# the device interactively.
#
# Phases:
#   0. install android-tools, extract rish from the Shizuku APK
#   1. verify the privileged channel actually answers
#   2. snapshot current state (silent, enables --rollback)
#   3. build the untouchable whitelist (auto-detected + user additions)
#   4. read-only audit + impact report
#   5. interactive hardening (nothing runs without an explicit yes)
#
# Nothing destructive happens without a confirmation and a printed warning.
#
# Usage:
#   bash adb-bootstrap.sh [--dry-run] [--skip-log] [--audit-only] [--rollback]
#
# Exit codes:
#   0 = success
#   1 = fatal error
# ----------------------------------------------------------------------------

set -euo pipefail

# ----------------------------------------------------------------------------
# CONFIGURATION
# ----------------------------------------------------------------------------

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "$0")"

readonly SHIZUKU_PKG="moe.shizuku.privileged.api"
readonly TERMUX_PKG="com.termux"
readonly BIN_DIR="${PREFIX:-/data/data/com.termux/files/usr}/bin"
readonly RISH="$BIN_DIR/rish"
readonly RISH_DEX="$BIN_DIR/rish_shizuku.dex"

readonly LOG_DIR="${HOME}/.local/var/log"
readonly LOG_FILE="${LOG_DIR}/adb-bootstrap-$(date +%Y%m%d-%H%M%S).log"
readonly SNAP_DIR="${HOME}/.local/var/adb-snapshots"

SKIP_LOG=0
DRY_RUN=0
AUDIT_ONLY=0
DO_ROLLBACK=0
ASSUME_YES=0
EXIT_CODE=0
declare -a _CLEANUP_TMPFILES=()

# Packages that must never be touched: breaking these costs you the phone,
# the terminal, or the privileged channel this script depends on.
declare -a WHITELIST=(
    "$TERMUX_PKG"
    "$SHIZUKU_PKG"
    "com.termux.api"
    "com.termux.boot"
    "com.termux.x11"
    "com.termux.widget"
    "com.termux.styling"
    "com.termux.gui"
    "com.termux.tasker"
    # User apps that must survive any hardening pass.
    "com.x8bit.bitwarden"
    "org.fdroid.fdroid"
    "in.krosbits.musicolet"
    "org.woheller69.browser"
    "com.arslan.shizuwall"
    "com.miui.calculator"
    "com.miui.home"
    "android"
    "com.android.systemui"
    "com.android.settings"
    "com.android.shell"
)

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

_log_plain() {
    [[ $SKIP_LOG -eq 0 ]] && echo "$*" >> "$LOG_FILE" 2>/dev/null
}

ok()   { printf '%s[OK]%s   %s\n'   "$G" "$Z" "$*" >&2; _log_plain "[OK]   $*"; }
warn() { printf '%s[WARN]%s %s\n'  "$Y" "$Z" "$*" >&2; _log_plain "[WARN] $*"; }
err()  { printf '%s[ERR]%s  %s\n'  "$R" "$Z" "$*" >&2; _log_plain "[ERR]  $*"; }
info() { printf '%s[INFO]%s %s\n'  "$C" "$Z" "$*" >&2; _log_plain "[INFO] $*"; }
step() { printf '\n%s== %s ==%s\n' "$B" "$*" "$Z" >&2; _log_plain ""; _log_plain "== $* =="; }
die()  { err "$*"; exit 1; }

# risk <text> — a loud, unmissable warning before anything irreversible.
risk() {
    printf '\n%s!! RISK: %s%s\n' "$R$B" "$*" "$Z" >&2
    _log_plain "!! RISK: $*"
}

# ----------------------------------------------------------------------------
# CLEANUP
# ----------------------------------------------------------------------------

_cleanup() {
    local f
    for f in "${_CLEANUP_TMPFILES[@]:-}"; do
        [[ -n "$f" && -e "$f" ]] || continue
        # Some entries are scratch dirs (mktemp -d), not plain files.
        if [[ -d "$f" ]]; then rm -rf "$f"; else rm -f "$f"; fi
    done
}
trap _cleanup EXIT

# ----------------------------------------------------------------------------
# UTILITIES
# ----------------------------------------------------------------------------

_run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] $*"
        return 0
    fi
    "$@" >/dev/null 2>&1
}

_install_atomic() {
    local src="$1" dst="$2"
    local dstdir; dstdir="$(dirname "$dst")"

    [[ -f "$src" ]] || { err "source not found: $src"; return 1; }
    mkdir -p "$dstdir"

    local tmp
    tmp="$(mktemp "${dstdir}/install.XXXXXX")" || { err "mktemp failed in $dstdir"; return 1; }
    _CLEANUP_TMPFILES+=("$tmp")

    cp -f "$src" "$tmp" || { err "cp failed: $src"; return 1; }
    chmod +x "$tmp"     || { err "chmod failed: $tmp"; return 1; }
    mv -f "$tmp" "$dst" || { err "mv failed: $dst"; return 1; }
    ok "installed: $dst"
}

# sh_exec <command...> — run a command through the privileged Shizuku channel.
# Every privileged action in this script goes through here, so dry-run and
# logging are enforced in exactly one place.
sh_exec() {
    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] rish: $*"
        return 0
    fi
    RISH_APPLICATION_ID="$TERMUX_PKG" "$RISH" -c "$*" 2>/dev/null
}

# ----------------------------------------------------------------------------
# Reliable transport over the Shizuku channel
# ----------------------------------------------------------------------------
# rish truncates long output at random: the same command returns 356, 212, 144
# or 0 lines with exit 0 every time, so a successful exit proves nothing. The
# command itself always runs correctly -- only the transport back to Termux is
# lossy. (Redirecting to a file INSIDE the channel is worse: `pm ... > file`
# fails outright with "Failed transaction".)
#
# Two rules follow, and every read in this script obeys them:
#   1. Do the work on the privileged side; carry back as little as possible.
#   2. Never trust a payload that crossed the channel until its line count
#      matches a count computed on the far side.

# sh_count <command> — line count computed INSIDE the channel. One number
# crosses the wire, so this is reliable; it is the yardstick for sh_capture.
sh_count() {
    local n
    n="$(sh_exec "$1 | wc -l" | tr -d '[:space:]')"
    [[ "$n" =~ ^[0-9]+$ ]] || { printf '0'; return 1; }
    printf '%s' "$n"
}

# sh_capture <command> <outfile> — fetch a full listing, verified.
# Retries until the delivered line count matches the count taken on the far
# side. Returns 1 if it never lines up.
sh_capture() {
    local cmd="$1" out="$2"
    local expected got try

    expected="$(sh_count "$cmd")"
    if [[ "${expected:-0}" -eq 0 ]]; then
        : > "$out"
        return 0   # genuinely empty result, not a truncation
    fi

    for try in 1 2 3 4 5; do
        sh_exec "$cmd" > "$out" 2>/dev/null || true
        got="$(wc -l < "$out" 2>/dev/null | tr -d '[:space:]')"
        [[ "${got:-0}" -eq "$expected" ]] && return 0
        sleep 0.4
    done

    warn "truncated after 5 tries: '$cmd' (${got:-0}/${expected} lines)"
    return 1
}

# is_whitelisted <pkg>
is_whitelisted() {
    local pkg="$1" w
    for w in "${WHITELIST[@]}"; do
        [[ "$pkg" == "$w" ]] && return 0
    done
    return 1
}

# confirm <prompt> — yes/no, defaults to NO. Anything but an explicit y is no.
confirm() {
    if [[ $ASSUME_YES -eq 1 ]]; then
        printf '%s%s [y/N]: %sy (--yes)\n' "$B" "$*" "$Z" >&2
        _log_plain "$* -> yes (--yes)"
        return 0
    fi
    local reply=""
    printf '%s%s [y/N]: %s' "$B" "$*" "$Z" >&2
    read -r reply || true
    [[ "$reply" == "y" || "$reply" == "Y" ]]
}

# ----------------------------------------------------------------------------
# PHASE 0: TOOLING
# ----------------------------------------------------------------------------
# rish is not a pkg package: it ships inside the Shizuku APK. Rather than make
# the user export it by hand through Shizuku's UI, we pull the APK path from
# the package manager and unzip the two files we need straight out of it.
# ----------------------------------------------------------------------------

phase_0_tooling() {
    step "PHASE 0: tooling"

    info "installing android-tools (adb)"
    if ! _run pkg install -y android-tools; then
        die "package install failed -- cannot continue without adb"
    fi

    # rish must come from the Shizuku app itself: the app writes a copy of the
    # loader and its dex whose versions match the installed service. Extracting
    # them from the APK works too, but drifts the moment Shizuku updates.
    #
    # MANUAL STEP (once per Shizuku update):
    #   Shizuku app > Use Shizuku in terminal apps > Export files
    #   > save both files into the phone's Documents folder
    #
    # This phase then picks them up from there, patches the package id, and
    # installs them into $PREFIX/bin.
    local doc_dir="$HOME/storage/shared/Documents"
    local src_rish="$doc_dir/rish"
    local src_dex="$doc_dir/rish_shizuku.dex"

    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would install rish from $doc_dir"
        ok "tooling ready"
        return 0
    fi

    if [[ ! -f "$src_rish" ]] || [[ ! -f "$src_dex" ]]; then
        err "rish files not found in $doc_dir"
        err "export them first:"
        err "  Shizuku app > Use Shizuku in terminal apps > Export files"
        err "  save 'rish' and 'rish_shizuku.dex' into Documents"
        return 1
    fi

    # The exported loader ships RISH_APPLICATION_ID="PKG" as a placeholder;
    # without the real package id Shizuku refuses the binder call.
    info "installing rish from $doc_dir"
    local work
    work="$(mktemp -d "${TMPDIR:-/tmp}/rish-install.XXXXXX")"
    _CLEANUP_TMPFILES+=("$work")

    sed "s/RISH_APPLICATION_ID=\"PKG\"/RISH_APPLICATION_ID=\"$TERMUX_PKG\"/" \
        "$src_rish" > "$work/rish" || { err "could not patch rish"; return 1; }

    if ! grep -q "RISH_APPLICATION_ID=\"$TERMUX_PKG\"" "$work/rish"; then
        warn "package id placeholder not found -- the exported rish may already be patched"
    fi

    cp -f "$src_dex" "$work/rish_shizuku.dex" || { err "could not stage the dex"; return 1; }

    _install_atomic "$work/rish" "$RISH" || return 1

    # Android 14+ refuses to let app_process load a writable dex, so the dex
    # is installed read-only. _install_atomic chmods +x, which is wrong here.
    cp -f "$work/rish_shizuku.dex" "$RISH_DEX" || { err "could not install the dex"; return 1; }
    chmod 400 "$RISH_DEX"
    ok "installed: $RISH_DEX (read-only, required on Android 14+)"

    ok "tooling ready"
}

# ----------------------------------------------------------------------------
# PHASE 1: PRIVILEGED CHANNEL
# ----------------------------------------------------------------------------
# Shizuku's service must already be running: it cannot be started from here,
# only from the app (wireless debugging / adb pairing), and it stops on every
# reboot. A real command is the only honest test -- ps/dumpsys are blocked to
# an unprivileged Termux, so absence of evidence there proves nothing.
# ----------------------------------------------------------------------------

phase_1_channel() {
    step "PHASE 1: privileged channel"

    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would verify rish channel with: id"
        ok "channel assumed OK (dry-run)"
        return 0
    fi

    info "testing the channel (rish -c id)"
    # rish's own stderr carries the actionable diagnosis (service down vs
    # battery optimisation blocking the binder call), so it is shown as-is
    # rather than swallowed behind a generic message.
    local whoami_out rish_err
    rish_err="$(mktemp "${TMPDIR:-/tmp}/rish-err.XXXXXX")"
    _CLEANUP_TMPFILES+=("$rish_err")

    if ! whoami_out="$(RISH_APPLICATION_ID="$TERMUX_PKG" "$RISH" -c id 2>"$rish_err")"; then
        err "rish could not reach Shizuku"
        [[ -s "$rish_err" ]] && err "rish says: $(tr '\n' ' ' < "$rish_err")"
        warn "checklist:"
        warn "  1. the Shizuku app is open and its service is started"
        warn "  2. battery optimisation is DISABLED for both Termux and Shizuku"
        warn "     (Settings > Apps > <app> > Battery > Unrestricted)"
        warn "  3. Shizuku stops on every reboot -- restart it after booting"
        return 1
    fi

    case "$whoami_out" in
        *"uid=2000"*) ok "channel live as shell (uid=2000) -- full ADB rights" ;;
        *"uid=0"*)    ok "channel live as root (uid=0)" ;;
        *)            warn "channel answered but the identity is unexpected: $whoami_out" ;;
    esac
}

# ----------------------------------------------------------------------------
# PHASE 2: SNAPSHOT
# ----------------------------------------------------------------------------
# Written before anything is touched, silently. Dozens of packages and
# permissions change in one session; this file is the only way to know what
# was altered -- and the only way back.
# ----------------------------------------------------------------------------

phase_2_snapshot() {
    step "PHASE 2: snapshot"

    mkdir -p "$SNAP_DIR"
    local stamp snap
    stamp="$(date +%Y%m%d-%H%M%S)"
    snap="$SNAP_DIR/snapshot-$stamp"

    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would snapshot package + permission state to $snap"
        return 0
    fi

    mkdir -p "$snap"

    info "recording installed packages"
    sh_capture "pm list packages -f" "$snap/packages-all.txt"      || true
    sh_capture "pm list packages -3" "$snap/packages-user.txt"     || true
    sh_capture "pm list packages -s" "$snap/packages-system.txt"   || true
    sh_capture "pm list packages -d" "$snap/packages-disabled.txt" || true

    info "recording permission and appops state"
    sh_capture "appops get --all" "$snap/appops.txt" || true

    # dumpsys package is ~80k lines: far too big to survive the channel intact.
    # The awk runs on the privileged side and only the finished package list
    # (~120 lines) crosses the wire, where sh_capture can verify it.
    info "recording boot receivers"
    sh_capture "dumpsys package | awk '/android.intent.action.BOOT_COMPLETED:/{f=1;next} /^      [a-z]/{f=0} f && /\//{print \$2}' | cut -d/ -f1 | sort -u" \
        "$snap/boot-receivers.txt" || true

    info "recording settings"
    for ns in global secure system; do
        sh_capture "settings list $ns" "$snap/settings-$ns.txt" || true
    done

    printf '%s\n' "$stamp" > "$SNAP_DIR/latest"

    local size
    size="$(du -sh "$snap" 2>/dev/null | cut -f1)"
    ok "snapshot saved: $snap (${size:-?})"
}

# ----------------------------------------------------------------------------
# PHASE 3: WHITELIST
# ----------------------------------------------------------------------------
# The static list covers this toolchain. What varies per device -- launcher,
# dialer, SMS app, keyboard -- is asked of the system itself: hardcoding those
# would lock someone out of their own phone on the first run.
# ----------------------------------------------------------------------------

_detect_default_app() {
    # Resolves the package currently handling a role, via cmd/dumpsys output.
    local role="$1" out=""
    case "$role" in
        launcher)
            out="$(sh_exec "cmd shortcut get-default-launcher" 2>/dev/null \
                  | grep -o '[a-zA-Z0-9_.]*/[a-zA-Z0-9_.]*' | head -1 | cut -d/ -f1)"
            ;;
        ime)
            out="$(sh_exec "settings get secure default_input_method" 2>/dev/null \
                  | cut -d/ -f1)"
            ;;
        dialer)
            out="$(sh_exec "cmd role get-role-holders android.app.role.DIALER" 2>/dev/null \
                  | tr -d '[]' | cut -d, -f1)"
            ;;
        sms)
            out="$(sh_exec "cmd role get-role-holders android.app.role.SMS" 2>/dev/null \
                  | tr -d '[]' | cut -d, -f1)"
            ;;
    esac
    printf '%s' "${out//[[:space:]]/}"
}

phase_3_whitelist() {
    step "PHASE 3: whitelist"

    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would detect launcher/ime/dialer/sms and prompt for extras"
        return 0
    fi

    info "detecting the apps this device cannot lose"
    local role pkg
    for role in launcher ime dialer sms; do
        pkg="$(_detect_default_app "$role")"
        if [[ -n "$pkg" ]] && ! is_whitelisted "$pkg"; then
            WHITELIST+=("$pkg")
            ok "$role: $pkg"
        elif [[ -z "$pkg" ]]; then
            warn "$role: could not detect -- add it by hand below if it matters"
        fi
    done

    printf '\n%sProtected packages (never touched):%s\n' "$B" "$Z" >&2
    printf '  %s\n' "${WHITELIST[@]}" >&2
    printf '\n' >&2

    if [[ $ASSUME_YES -eq 0 ]] && confirm "Add more packages to this list?"; then
        printf 'Enter package names, one per line. Empty line to finish.\n' >&2
        local extra=""
        while :; do
            printf '  + ' >&2
            read -r extra || break
            [[ -z "$extra" ]] && break
            WHITELIST+=("$extra")
            ok "protected: $extra"
        done
    fi

    ok "${#WHITELIST[@]} package(s) protected"
}

# ----------------------------------------------------------------------------
# PHASE 4: AUDIT (read-only)
# ----------------------------------------------------------------------------
# Reads only. Nothing here changes the device; it exists so the hardening
# decisions in phase 5 are made against real data instead of guesses.
# ----------------------------------------------------------------------------

# Bloatware patterns, grouped by what they actually cost you when disabled.
# Kept as patterns, not fixed package names, because OEM naming varies.
declare -a BLOAT_TELEMETRY=(
    "com.google.android.gms.analytics"
    "com.google.android.feedback"
    "com.android.providers.partnerbookmarks"
)
declare -a BLOAT_CONTENT=(
    "com.google.android.apps.wellbeing"
    "com.google.android.googlequicksearchbox"
    "com.google.android.apps.magazines"
    "com.google.android.videos"
    "com.google.android.music"
    "com.google.android.apps.podcasts"
)
declare -a BLOAT_WALLPAPER=(
    "com.google.android.apps.wallpaper"
    "com.android.wallpaper.livepicker"
    "com.google.android.wallpaper.effects"
    "com.miui.android.fashiongallery"
    "com.miui.miwallpaper"
)

# --- Xiaomi/MIUI -----------------------------------------------------------
# MIUI ships its own ad network, analytics stack and media apps on top of
# AOSP. These lists only contain packages whose removal costs a feature, not
# the system: com.miui.core, com.miui.system, com.miui.rom, com.miui.notification,
# com.miui.securitycore, com.miui.powerkeeper and every *.overlay package are
# deliberately absent -- disabling those breaks the ROM.
declare -a BLOAT_MIUI_ADS=(
    "com.miui.msa.global"
    "com.xiaomi.mipicks"
    "com.xiaomi.discover"
    "com.xiaomi.glgm"
    "com.miui.yellowpage"
)
declare -a BLOAT_MIUI_TELEMETRY=(
    "com.miui.analytics"
    "com.miui.misightservice"
    "com.miui.daemon"
    "com.miui.bugreport"
    "com.miui.audiomonitor"
)
declare -a BLOAT_MIUI_MEDIA=(
    "com.miui.player"
    "com.miui.videoplayer"
    "com.miui.fm"
    "com.miui.fmservice"
    "com.miui.gallery"
    "com.miui.mediaviewer"
    "com.xiaomi.barrage"
)
declare -a BLOAT_MIUI_CLOUD=(
    "com.miui.cloudservice"
    "com.miui.cloudbackup"
    "com.miui.micloudsync"
    "com.xiaomi.account"
    "com.xiaomi.micloud.sdk"
)

_audit_count() { wc -l < "$1" 2>/dev/null | tr -d ' '; }

phase_4_audit() {
    step "PHASE 4: audit (read-only)"

    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would read package/permission/appops state and report"
        return 0
    fi

    local work
    work="$(mktemp -d "${TMPDIR:-/tmp}/adb-audit.XXXXXX")"
    _CLEANUP_TMPFILES+=("$work")

    # Reuse the snapshot taken in phase 2: every extra rish call spawns a new
    # app_process over binder, and a burst of them makes Shizuku return empty
    # output. One read, many uses.
    info "reading installed packages (from snapshot)"
    local snap="$SNAP_DIR/snapshot-$(cat "$SNAP_DIR/latest" 2>/dev/null)"
    if [[ -s "$snap/packages-user.txt" ]]; then
        sed 's/^package://' "$snap/packages-user.txt"     | sort > "$work/user.txt"
        sed 's/^package://' "$snap/packages-system.txt"   | sort > "$work/system.txt"
        sed 's/^package://' "$snap/packages-disabled.txt" | sort > "$work/disabled.txt"
    else
        warn "snapshot unusable -- querying the device directly"
        sh_exec "pm list packages -3" | sed 's/^package://' | sort > "$work/user.txt"
        sh_exec "pm list packages -s" | sed 's/^package://' | sort > "$work/system.txt"
        sh_exec "pm list packages -d" | sed 's/^package://' | sort > "$work/disabled.txt"
    fi

    local n_user n_system n_disabled
    n_user="$(_audit_count "$work/user.txt")"
    n_system="$(_audit_count "$work/system.txt")"
    n_disabled="$(_audit_count "$work/disabled.txt")"

    info "checking which apps start themselves at boot"
    # dumpsys lists the receivers UNDER the intent line, indented, as
    # "<hash> <pkg>/<class>". Anything matching before that line belongs to a
    # different intent entirely.
    if [[ -s "$snap/boot-receivers.txt" ]]; then
        # Already parsed on the privileged side at snapshot time.
        sort -u "$snap/boot-receivers.txt" > "$work/boot.txt" 2>/dev/null || true
    else
        : > "$work/boot.txt"
        warn "boot receivers unavailable in the snapshot"
    fi
    local n_boot; n_boot="$(_audit_count "$work/boot.txt")"

    printf '\n%s--- DEVICE AUDIT ---%s\n\n' "$B" "$Z" >&2
    printf '  user apps installed     %s\n' "${n_user:-0}" >&2
    printf '  system apps installed   %s\n' "${n_system:-0}" >&2
    printf '  already disabled        %s\n' "${n_disabled:-0}" >&2
    printf '  apps starting at boot   %s\n' "${n_boot:-0}" >&2

    # Bloat candidates present on this device, by category.
    local cat pkg present
    for cat in TELEMETRY CONTENT WALLPAPER MIUI_ADS MIUI_TELEMETRY MIUI_MEDIA MIUI_CLOUD; do
        local -n arr="BLOAT_$cat"
        present=0
        printf '\n%s  %s candidates:%s\n' "$B" "$cat" "$Z" >&2
        for pkg in "${arr[@]}"; do
            if grep -qx "$pkg" "$work/user.txt" "$work/system.txt" 2>/dev/null; then
                if grep -qx "$pkg" "$work/disabled.txt" 2>/dev/null; then
                    printf '    [already off] %s\n' "$pkg" >&2
                else
                    printf '    [active]      %s\n' "$pkg" >&2
                    present=$((present + 1))
                fi
            fi
        done
        [[ $present -eq 0 ]] && printf '    (none active)\n' >&2
    done

    printf '\n' >&2
    ok "audit complete -- nothing was changed"

    AUDIT_DIR="$work"
}

# ----------------------------------------------------------------------------
# PHASE 5: HARDENING (interactive)
# ----------------------------------------------------------------------------
# Bloat is offered per category (the choice is the same for every package in
# it); permissions are offered per app (the cost differs wildly app to app).
# Every group states its real cost before asking. Default is always no.
# ----------------------------------------------------------------------------

# _disable_category <name> <cost-description> <pkg...>
_disable_category() {
    local name="$1"; shift
    local cost="$1"; shift
    local -a pkgs=("$@")
    local -a active=()
    local pkg

    for pkg in "${pkgs[@]}"; do
        is_whitelisted "$pkg" && continue
        grep -qx "$pkg" "$AUDIT_DIR/disabled.txt" 2>/dev/null && continue
        if grep -qx "$pkg" "$AUDIT_DIR/user.txt" "$AUDIT_DIR/system.txt" 2>/dev/null; then
            active+=("$pkg")
        fi
    done

    [[ ${#active[@]} -eq 0 ]] && { info "$name: nothing active to disable"; return 0; }

    printf '\n%s%s -- %s package(s) active:%s\n' "$B" "$name" "${#active[@]}" "$Z" >&2
    printf '  %s\n' "${active[@]}" >&2
    risk "$cost"

    confirm "Disable all $name packages?" || { info "$name: skipped"; return 0; }

    for pkg in "${active[@]}"; do
        if sh_exec "pm disable-user --user 0 $pkg" >/dev/null 2>&1; then
            ok "disabled: $pkg"
        else
            warn "could not disable: $pkg"
        fi
    done
}

# _revoke_app_permissions <pkg> — offers each granted runtime permission.
_revoke_app_permissions() {
    local pkg="$1"
    local -a granted=()
    local line perm

    # The grep runs on the privileged side: a per-package dumpsys is still
    # thousands of lines, and anything that size gets truncated at random on
    # the way back. Only the matching lines cross the channel.
    local permfile
    permfile="$(mktemp "${TMPDIR:-/tmp}/perms.XXXXXX")"
    _CLEANUP_TMPFILES+=("$permfile")
    sh_capture "dumpsys package $pkg | grep 'granted=true'" "$permfile" || true

    while IFS= read -r line; do
        case "$line" in
            *": granted=true"*)
                perm="${line%%:*}"
                perm="${perm//[[:space:]]/}"
                [[ -n "$perm" ]] && granted+=("$perm")
                ;;
        esac
    done < "$permfile"

    [[ ${#granted[@]} -eq 0 ]] && return 0

    printf '\n%s%s -- %s permission(s) granted:%s\n' "$B" "$pkg" "${#granted[@]}" "$Z" >&2
    printf '  %s\n' "${granted[@]}" >&2

    confirm "Revoke ALL permissions from $pkg?" || { info "$pkg: kept"; return 0; }

    # Only runtime ("dangerous") permissions can be revoked. Normal-level ones
    # -- INTERNET, VIBRATE, WAKE_LOCK and friends -- are granted at install
    # time and Android refuses to touch them: pm answers with a SecurityException
    # ("not a changeable permission type"). That is a fact of the platform, not
    # a failure here, so it is reported as skipped rather than as an error.
    #
    # pm's exit status alone is not trustworthy through this channel, so the
    # result is confirmed by re-reading the permission afterwards.
    local revoked=0 skipped=0
    for perm in "${granted[@]}"; do
        sh_exec "pm revoke $pkg $perm" >/dev/null 2>&1 || true
        if [[ "$(sh_exec "dumpsys package $pkg | grep -c '$perm: granted=true'" | tr -d '[:space:]')" == "0" ]]; then
            ok "revoked: $pkg $perm"
            revoked=$((revoked + 1))
        else
            skipped=$((skipped + 1))
        fi
    done
    info "$pkg: $revoked revoked, $skipped not revocable (install-time permissions)"
}

phase_5_harden() {
    step "PHASE 5: hardening"

    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] would offer bloat categories and per-app permission revocation"
        return 0
    fi

    [[ -n "${AUDIT_DIR:-}" ]] || { err "no audit data -- phase 4 must run first"; return 1; }

    # --- bloat, by category -------------------------------------------------
    _disable_category "TELEMETRY" \
        "Analytics and crash reporting stop. No user-visible loss." \
        "${BLOAT_TELEMETRY[@]}"

    _disable_category "WALLPAPER" \
        "Live/dynamic wallpapers and wallpaper pickers stop working." \
        "${BLOAT_WALLPAPER[@]}"

    _disable_category "CONTENT" \
        "Google feed, search box, news, music and video apps stop. The home-screen search bar may disappear." \
        "${BLOAT_CONTENT[@]}"

    _disable_category "MIUI_ADS" \
        "MIUI's ad network (MSA), GetApps, recommendations and yellow pages stop. This is where most MIUI ads come from. No functional loss." \
        "${BLOAT_MIUI_ADS[@]}"

    _disable_category "MIUI_TELEMETRY" \
        "Xiaomi analytics, bug reporting and background monitoring stop. No user-visible loss." \
        "${BLOAT_MIUI_TELEMETRY[@]}"

    _disable_category "MIUI_MEDIA" \
        "MIUI Gallery, music/video player and FM radio stop. Photos remain on disk; you will need another gallery app to view them." \
        "${BLOAT_MIUI_MEDIA[@]}"

    _disable_category "MIUI_CLOUD" \
        "Xiaomi account, MiCloud sync and cloud backup stop. Anything not already synced stays local only, and Find My Device via Xiaomi may stop working." \
        "${BLOAT_MIUI_CLOUD[@]}"

    # --- Play Services: separate, because the blast radius is large ---------
    local gms="com.google.android.gms"
    local gstore="com.android.vending"
    if grep -qx "$gms" "$AUDIT_DIR/system.txt" 2>/dev/null \
       && ! grep -qx "$gms" "$AUDIT_DIR/disabled.txt" 2>/dev/null; then
        printf '\n%sGOOGLE PLAY SERVICES%s\n' "$B" "$Z" >&2
        printf '  %s\n  %s\n' "$gms" "$gstore" >&2
        risk "Push notifications die for EVERY app. Play Store stops. Apps that depend on Play Services (maps, auth, payments) may crash or refuse to start. This is the single most disruptive change in this script."
        if confirm "Disable Play Services and Play Store?"; then
            sh_exec "pm disable-user --user 0 $gms"    >/dev/null 2>&1 && ok "disabled: $gms"    || warn "could not disable: $gms"
            sh_exec "pm disable-user --user 0 $gstore" >/dev/null 2>&1 && ok "disabled: $gstore" || warn "could not disable: $gstore"
        else
            info "Play Services: kept"
        fi
    fi

    # --- background execution ----------------------------------------------
    printf '\n%sBACKGROUND EXECUTION%s\n' "$B" "$Z" >&2
    risk "Non-whitelisted user apps stop running in the background. They will not sync or notify until opened by hand."
    if confirm "Restrict background execution for all non-whitelisted user apps?"; then
        local pkg
        while IFS= read -r pkg <&3; do
            [[ -n "$pkg" ]] || continue
            is_whitelisted "$pkg" && continue
            sh_exec "appops set $pkg RUN_IN_BACKGROUND ignore"     >/dev/null 2>&1 || true
            sh_exec "appops set $pkg RUN_ANY_IN_BACKGROUND ignore" >/dev/null 2>&1 || true
            ok "background off: $pkg"
        done 3< "$AUDIT_DIR/user.txt"
    else
        info "background: skipped"
    fi

    # --- permissions, per app ----------------------------------------------
    printf '\n%sPERMISSIONS (app by app)%s\n' "$B" "$Z" >&2
    if confirm "Review permissions app by app?"; then
        local pkg
        while IFS= read -r pkg <&3; do
            [[ -n "$pkg" ]] || continue
            is_whitelisted "$pkg" && continue
            _revoke_app_permissions "$pkg"
        done 3< "$AUDIT_DIR/user.txt"
    else
        info "permissions: skipped"
    fi

    # --- Google telemetry settings -----------------------------------------
    printf '\n%sGOOGLE TELEMETRY SETTINGS%s\n' "$B" "$Z" >&2
    risk "Usage reporting, ad personalisation and crash upload are turned off. No functional loss."
    if confirm "Disable Google usage reporting and ad personalisation?"; then
        sh_exec "settings put global send_action_app_error 0"       >/dev/null 2>&1 && ok "app error reports off"
        sh_exec "settings put secure send_action_app_error 0"       >/dev/null 2>&1 || true
        sh_exec "settings put global device_provisioned 1"          >/dev/null 2>&1 || true
        sh_exec "settings put secure limit_ad_tracking 1"           >/dev/null 2>&1 && ok "ad tracking limited"
        sh_exec "settings put global wifi_scan_always_enabled 0"    >/dev/null 2>&1 && ok "passive wifi scanning off"
        sh_exec "settings put global ble_scan_always_enabled 0"     >/dev/null 2>&1 && ok "passive bluetooth scanning off"
    else
        info "telemetry settings: skipped"
    fi

    ok "hardening complete"
}

# ----------------------------------------------------------------------------
# ROLLBACK
# ----------------------------------------------------------------------------
# Re-enables every package that the snapshot shows as enabled but is disabled
# now. Permissions are reported, not auto-restored: re-granting in bulk would
# hand back rights the user may have removed on purpose, long before this run.
# ----------------------------------------------------------------------------

do_rollback() {
    step "ROLLBACK"

    [[ -f "$SNAP_DIR/latest" ]] || die "no snapshot found in $SNAP_DIR"
    local stamp snap
    stamp="$(cat "$SNAP_DIR/latest")"
    snap="$SNAP_DIR/snapshot-$stamp"
    [[ -d "$snap" ]] || die "snapshot directory missing: $snap"

    info "snapshot: $snap"

    local work
    work="$(mktemp -d "${TMPDIR:-/tmp}/adb-rollback.XXXXXX")"
    _CLEANUP_TMPFILES+=("$work")

    sed 's/^package://' "$snap/packages-disabled.txt" 2>/dev/null | sort > "$work/was-disabled.txt"
    sh_exec "pm list packages -d" | sed 's/^package://' | sort > "$work/now-disabled.txt"

    comm -13 "$work/was-disabled.txt" "$work/now-disabled.txt" > "$work/to-enable.txt"

    local n; n="$(wc -l < "$work/to-enable.txt" | tr -d ' ')"
    if [[ "${n:-0}" -eq 0 ]]; then
        ok "nothing to roll back -- no package disabled since the snapshot"
        return 0
    fi

    printf '\n%s%s package(s) disabled since the snapshot:%s\n' "$B" "$n" "$Z" >&2
    cat "$work/to-enable.txt" >&2
    printf '\n' >&2

    confirm "Re-enable all of them?" || { info "rollback cancelled"; return 0; }

    local pkg
    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] || continue
        if sh_exec "pm enable $pkg" >/dev/null 2>&1; then
            ok "enabled: $pkg"
        else
            warn "could not enable: $pkg"
        fi
    done < "$work/to-enable.txt"

    warn "permissions were NOT restored automatically -- compare against $snap/dumpsys-package.txt if needed"
    ok "rollback complete"
}

# ----------------------------------------------------------------------------
# MAIN
# ----------------------------------------------------------------------------

_usage() {
    cat << HELP
${B}$SCRIPT_NAME${Z} v$SCRIPT_VERSION
Privileged ADB setup via Shizuku, then an interactive device audit + hardening.

${B}Usage:${Z}  bash $SCRIPT_NAME [OPTIONS]

${B}Options:${Z}
  --dry-run      Print what would run, change nothing
  --skip-log     Do not write a log file
  --audit-only   Stop after the read-only audit (phases 0-4)
  --rollback     Re-enable packages disabled since the last snapshot
  -y, --yes      Answer yes to everything: disable every detected candidate
                 and revoke every revocable permission, unattended
  -h, --help     Show this help

${B}Phases:${Z}
  0. tooling            android-tools + rish extracted from the Shizuku APK
  1. privileged channel verify Shizuku answers
  2. snapshot           silent; enables --rollback
  3. whitelist          auto-detected + your additions
  4. audit              read-only report
  5. hardening          interactive, per category and per app

${B}Requires:${Z} the Shizuku app installed AND its service already started.
Shizuku stops on every reboot and cannot be started from a script.
HELP
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)    DRY_RUN=1;    shift ;;
            --skip-log)   SKIP_LOG=1;   shift ;;
            --audit-only) AUDIT_ONLY=1; shift ;;
            --rollback)   DO_ROLLBACK=1; shift ;;
            --yes|-y)     ASSUME_YES=1;  shift ;;
            -h|--help)    _usage; exit 0 ;;
            *)            die "unknown option: $1" ;;
        esac
    done

    if [[ $DO_ROLLBACK -eq 1 ]]; then
        phase_0_tooling || EXIT_CODE=1
        phase_1_channel || die "no privileged channel -- cannot roll back"
        do_rollback     || EXIT_CODE=1
        exit $EXIT_CODE
    fi

    phase_0_tooling || die "tooling failed"
    phase_1_channel || die "no privileged channel -- start Shizuku and re-run"
    phase_2_snapshot || warn "snapshot failed -- continuing without rollback safety"
    phase_3_whitelist || EXIT_CODE=1
    phase_4_audit     || EXIT_CODE=1

    if [[ $AUDIT_ONLY -eq 1 ]]; then
        ok "audit-only: stopping before any change"
        exit $EXIT_CODE
    fi

    phase_5_harden || EXIT_CODE=1

    step "DONE"
    printf '  Snapshot dir: %s\n' "$SNAP_DIR" >&2
    printf '  Log file:     %s\n' "$LOG_FILE" >&2
    printf '  Rollback:     bash %s --rollback\n\n' "$SCRIPT_NAME" >&2

    exit $EXIT_CODE
}

main "$@"
