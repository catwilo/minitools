#!/usr/bin/env bash
# Reinicio atómico e idempotente del servicio iwd (Intel Wireless Daemon)
# Script minimalista, profesional y sin logs residuales.

set -euo pipefail

# === Funciones auxiliares ===
info()  { echo -e "\033[1;36m[INFO]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
fail()  { echo -e "\033[1;31m[FAIL]\033[0m $*"; exit 1; }

# === Comprobaciones previas ===
[[ $EUID -eq 0 ]] || fail "Ejecuta este script como root."

command -v systemctl &>/dev/null || fail "systemctl no está disponible."
command -v journalctl &>/dev/null || fail "journalctl no está disponible."

# === Lógica principal ===
SERVICE="iwd"

info "Verificando estado actual de $SERVICE..."
if systemctl is-active --quiet "$SERVICE"; then
    info "$SERVICE está activo. Mostrando últimas 7 líneas del registro:"
    echo -e "\033[0;90m──────────────────────────────────────────────\033[0m"
    journalctl -u "$SERVICE" -n 7 --no-pager | sed 's/^/  /'
    echo -e "\033[0;90m──────────────────────────────────────────────\033[0m"
    info "Reiniciando servicio..."
    systemctl try-restart "$SERVICE" || fail "No se pudo reiniciar $SERVICE."
else
    warn "$SERVICE está inactivo. Iniciando servicio..."
    systemctl start "$SERVICE" || fail "No se pudo iniciar $SERVICE."
fi

# === Verificación post-operación ===
if systemctl is-active --quiet "$SERVICE"; then
    ok "$SERVICE se encuentra operativo y estable."
else
    fail "$SERVICE no se pudo poner en marcha correctamente."
fi

exit 0

