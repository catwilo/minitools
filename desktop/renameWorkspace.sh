#!/bin/sh

# Obtiene el nombre del workspace activo
param1=$(i3-msg -t get_workspaces | jq -r '.[] | select(.focused == true) | .name')

# Obtiene el nombre del workspace activo
pantalla=$(i3-msg -t get_workspaces | jq -r '.[] | select(.focused == true) | .output')

# Pide al usuario que ingrese un nuevo nombre para el workspace
read -p "Rename '$param1'  to  : " param2

# Renombra el workspace
i3-msg "rename workspace \"$param1\" to \"$param2\""

# devuelve la pantalla al monitor en el que estaba si no era el default
i3-msg "workspace \"$param2\"; move workspace to output $pantalla"
