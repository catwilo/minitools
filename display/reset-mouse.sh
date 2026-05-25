#!/usr/bin/env bash
#
# reset-touchpad.sh — Reinicio inteligente del touchpad (PS/2 o I2C)
# Optimizado para ThinkPad (SynPS/2) como caso por defecto
#

set -euo pipefail

COLOR_RESET="\e[0m"
COLOR_OK="\e[32m"
COLOR_ERR="\e[31m"
COLOR_INFO="\e[36m"
COLOR_WARN="\e[33m"

log()  { echo -e "${COLOR_INFO}[INFO]${COLOR_RESET} $*"; }
ok()   { echo -e "${COLOR_OK}[OK]${COLOR_RESET} $*"; }
warn() { echo -e "${COLOR_WARN}[WARN]${COLOR_RESET} $*"; }
err()  { echo -e "${COLOR_ERR}[ERROR]${COLOR_RESET} $*" >&2; }

if [[ $EUID -ne 0 ]]; then
  err "Debes ejecutar este script con sudo."
  exit 1
fi

log "🔍 Detectando tipo de touchpad..."

TP_INFO=$(grep -iE "TouchPad|Synaptics|ELAN|SYNA|ALPS" /proc/bus/input/devices -A3 || true)

if echo "$TP_INFO" | grep -qi "SynPS/2"; then
  TYPE="PS2"
  MODEL="Synaptics (PS/2)"
elif echo "$TP_INFO" | grep -qi "i2c"; then
  TYPE="I2C"
  MODEL="ELAN/SYNA (I2C)"
else
  TYPE="UNKNOWN"
  MODEL="Desconocido"
fi

log "Touchpad detectado: ${MODEL}"

if [[ "$TYPE" == "PS2" ]]; then
  log "🧠 Modo PS/2: reconectando dispositivo Synaptics (perfil predeterminado)."

  # Intento directo de reconexión estándar
  if [[ -w /sys/bus/serio/devices/serio1/drvctl ]]; then
    echo -n "reconnect" > /sys/bus/serio/devices/serio1/drvctl 2>/dev/null || true
    ok "Reconexión enviada en serio1 (perfil ThinkPad)."
  else
    warn "No se encontró /sys/bus/serio/devices/serio1/drvctl. Buscando alternativa..."
    FOUND=0
    for d in /sys/bus/serio/devices/serio*/drvctl; do
      echo -n "reconnect" > "$d" 2>/dev/null && FOUND=1
    done
    if [[ $FOUND -eq 1 ]]; then
      ok "Reconexión genérica enviada correctamente."
    else
      err "No se pudo realizar reconexión PS/2. Verifica el módulo psmouse."
    fi
  fi

  sleep 1

  if xinput list | grep -q "SynPS/2"; then
    ok "✅ TouchPad PS/2 Synaptics activo tras reconexión."
  else
    warn "El TouchPad PS/2 no aparece en xinput. Intentando recarga de módulo..."
    modprobe -r psmouse 2>/dev/null || true
    sleep 1
    modprobe psmouse 2>/dev/null || true
    if xinput list | grep -q "SynPS/2"; then
      ok "✅ TouchPad reactivado tras recarga del módulo."
    else
      err "El TouchPad PS/2 sigue sin responder. Podría requerir reinicio del servicio gráfico."
    fi
  fi

elif [[ "$TYPE" == "I2C" ]]; then
  log "🧠 Modo I²C: reiniciando módulos i2c_hid e hid_multitouch."

  MODULES=(i2c_hid_acpi i2c_hid_core hid_multitouch)
  for m in "${MODULES[@]}"; do
    if lsmod | grep -q "^${m}"; then
      modprobe -r "$m" 2>/dev/null || true
    fi
  done

  sleep 1
  for m in "${MODULES[@]}"; do
    modprobe "$m" 2>/dev/null || true
  done

  sleep 1
  if xinput list | grep -qi "ELAN\|SYNA\|TouchPad"; then
    ok "✅ TouchPad I²C operativo tras reinicio de módulos."
  else
    warn "El touchpad I²C no aparece. Podría requerir reinicio de sesión gráfica."
  fi

else
  warn "No se pudo determinar el tipo de touchpad. Puede ser USB o Bluetooth."
fi

ok "Proceso completado."
exit 0

