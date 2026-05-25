#!/bin/bash
# ----------------------------------------------
# Propósito: Crear una pantalla extendida virtual
#             a la derecha (1366x768) y compartirla por VNC.
# ----------------------------------------------

# Configuración
VIRTUAL_OUTPUT="VIRTUAL1"
MAIN_OUTPUT=$(xrandr | grep " connected" | awk '{print $1}' | head -n1)
VNC_PORT=5901
RESOLUTION="1366x768"

echo "🖥️  Configurando salida virtual en $VIRTUAL_OUTPUT (resolución $RESOLUTION)..."

# Anadir modo virtual (si no existe)
if ! xrandr | grep -q "$VIRTUAL_OUTPUT"; then
    echo "→ Intentando agregar salida virtual $VIRTUAL_OUTPUT..."
    xrandr --addmode $VIRTUAL_OUTPUT $RESOLUTION 2>/dev/null || true
fi

# Crear modo si el driver lo permite
xrandr --output $VIRTUAL_OUTPUT --mode $RESOLUTION --right-of $MAIN_OUTPUT || {
    echo "⚠️ No se pudo activar $VIRTUAL_OUTPUT. Intentando método alternativo (clip)..."
}

# Obtener ancho del monitor principal
WIDTH=$(xrandr | grep -A1 "$MAIN_OUTPUT connected" | grep -oP "\d+x\d+" | head -n1 | cut -d'x' -f1)

echo "🧭 Monitor principal: $MAIN_OUTPUT ($WIDTH px ancho)"
echo "📐 Región para VNC: $RESOLUTION ubicada en +${WIDTH}+0"

# Ejecutar servidor VNC en esa región (solo la pantalla extendida)
echo "🚀 Iniciando x11vnc en puerto $VNC_PORT..."
x11vnc -clip ${RESOLUTION}+${WIDTH}+0 -rfbport $VNC_PORT -noxdamage -forever -shared -bg

echo "✅ Servidor listo. Conéctate desde el cliente con:"
echo "   vncviewer <IP_DEL_SERVIDOR>:$VNC_PORT"
