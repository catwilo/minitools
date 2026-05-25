#!/bin/bash
# Inicia deadd si no está corriendo
pgrep -f deadd-notification-center >/dev/null && exit 0

# Espera X11 (max 20s)
for i in {1..20}; do
  [ -S /tmp/.X11-unix/X0 ] && break
  sleep 1
done

# Variables de entorno
export DISPLAY=${DISPLAY:-:0}
export XAUTHORITY=${XAUTHORITY:-$HOME/.Xauthority}
export DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$UID/bus}

# Matar cualquier daemon de notificaciones previo
pkill -f dunst 2>/dev/null
pkill -f notification-daemon 2>/dev/null

# Ejecuta deadd
/usr/bin/deadd-notification-center 2>&1 | grep -v "not a valid property" &

# Espera que se registre en D-Bus
sleep 2
