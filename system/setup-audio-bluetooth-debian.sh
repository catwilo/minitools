#!/usr/bin/env bash
#
# setup-audio-bluetooth-debian.sh
#
# Idempotent setup for audio (PipeWire) and Bluetooth (BlueZ) on Debian.
# Installs only what is missing, enables and starts required services,
# and prints a status report.
#
# Usage: sudo ./setup-audio-bluetooth-debian.sh

set -euo pipefail

section() { printf "\n== %s ==\n" "$1"; }
ok()      { printf "  [OK]      %s\n" "$1"; }
skip()    { printf "  [SKIP]    %s\n" "$1"; }
info()    { printf "  [INFO]    %s\n" "$1"; }
fail()    { printf "  [FAIL]    %s\n" "$1"; }

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (sudo)." >&2
    exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"

PACKAGES_TO_CHECK=(pipewire pipewire-pulse pipewire-alsa alsa-utils wireplumber pulseaudio-utils libspa-0.2-bluetooth bluez)
PACKAGES_TO_INSTALL=()

section "Package check"

for pkg in "${PACKAGES_TO_CHECK[@]}"; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        ok "$pkg already installed"
    else
        skip "$pkg not installed -- queued"
        PACKAGES_TO_INSTALL+=("$pkg")
    fi
done

if [[ ${#PACKAGES_TO_INSTALL[@]} -gt 0 ]]; then
    section "Installing missing packages"
    info "apt install: ${PACKAGES_TO_INSTALL[*]}"
    apt-get update -qq
    apt-get install -y "${PACKAGES_TO_INSTALL[@]}"
    for pkg in "${PACKAGES_TO_INSTALL[@]}"; do
        ok "$pkg installed"
    done
else
    section "Package installation"
    ok "all required packages already present -- nothing to install"
fi

section "User audio services"

USER_SERVICES=(pipewire pipewire-pulse wireplumber)

for svc in "${USER_SERVICES[@]}"; do
    is_active=$(sudo -u "$REAL_USER" systemctl --user is-active "$svc" 2>/dev/null || true)
    if [[ "$is_active" == "active" ]]; then
        ok "$svc.service already active"
    else
        info "$svc.service not active -- starting"
        sudo -u "$REAL_USER" systemctl --user enable --now "$svc" >/dev/null 2>&1 || true
        is_active_after=$(sudo -u "$REAL_USER" systemctl --user is-active "$svc" 2>/dev/null || true)
        if [[ "$is_active_after" == "active" ]]; then
            ok "$svc.service started"
        else
            fail "$svc.service failed to start -- check manually"
        fi
    fi
done

section "System Bluetooth service"

if systemctl is-active --quiet bluetooth; then
    ok "bluetooth.service already active"
else
    info "bluetooth.service not active -- enabling and starting"
    systemctl enable --now bluetooth >/dev/null 2>&1
    if systemctl is-active --quiet bluetooth; then
        ok "bluetooth.service started"
    else
        fail "bluetooth.service failed to start -- check manually"
    fi
fi

section "Status report"

printf "  %-28s %s\n" "Component" "Status"
printf "  %-28s %s\n" "----------------------------" "------"

for svc in "${USER_SERVICES[@]}"; do
    state=$(sudo -u "$REAL_USER" systemctl --user is-active "$svc" 2>/dev/null || echo unknown)
    printf "  %-28s %s\n" "$svc (user)" "$state"
done

bt_state=$(systemctl is-active bluetooth 2>/dev/null || echo unknown)
printf "  %-28s %s\n" "bluetooth (system)" "$bt_state"

if command -v pactl >/dev/null 2>&1; then
    default_sink=$(sudo -u "$REAL_USER" pactl info 2>/dev/null | grep "Default Sink" | cut -d: -f2- | sed "s/^ //")
    printf "  %-28s %s\n" "default sink" "${default_sink:-none detected}"
fi

if command -v bluetoothctl >/dev/null 2>&1; then
    adapter_power=$(bluetoothctl show 2>/dev/null | grep -oP "PowerState: \K\S+")
    printf "  %-28s %s\n" "bluetooth adapter power" "${adapter_power:-unknown}"
fi

printf "\nSetup complete.\n\n"
