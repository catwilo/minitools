#!/bin/bash
################################################################################
# fixsuffix.sh
################################################################################
# Descripción:
#   Script para renombrar archivos que tienen un sufijo específico,
#   removiendo ese sufijo de manera interactiva.
#
# Uso:
#   ./fixsuffix.sh -d <directorio> -s <sufijo>
#
# Opciones:
#   -d, --dir <directorio>  Directorio donde buscar archivos
#   -s, --sub <sufijo>      Sufijo a remover (ej: .~1~, .bak, .old)
#
# Ejemplo:
#   ./fixsuffix.sh -d ~/scripts -s .~1~
#   ./fixsuffix.sh -d /tmp -s .backup
#
# Comportamiento:
#   - Busca recursivamente todos los archivos con el sufijo especificado
#   - Para cada archivo encontrado, pregunta si deseas renombrarlo
#   - Si el archivo destino ya existe, pregunta si deseas sobrescribirlo
#   - Requiere confirmación explícita (tecla 's') para cada operación
#
# Notas:
#   - Es interactivo: pregunta antes de cada operación
#   - Usa 'find -depth' para procesar directorios desde lo más profundo
#   - Si el destino existe, lo elimina completamente (rm -rf) antes de renombrar
#
################################################################################

while [[ $# -gt 0 ]]; do
  case $1 in 
    -d|--dir) d="$2"; shift 2;;
    -s|--sub) s="$2"; shift 2;;
    *) echo "uso: $0 -d <dir> -s <sub>"; echo "ej: $0 -d ~/scripts -s .~1~"; exit 1;;
  esac
done

[[ -z $d || -z $s ]] && { 
  echo "uso: $0 -d <dir> -s <sub>"
  echo "ej: $0 -d ~/scripts -s .~1~"
  exit 1
}

find "$d" -depth -name "*$s" | while read -r f; do
  b="${f%$s}"
  echo -n "procesar: $f → $b ? (s/N): "
  read -r r < /dev/tty
  [[ $r != "s" ]] && { echo "omitido"; continue; }
  
  if [[ -e $b ]]; then
    echo -n "existe $b, borrar y renombrar $f? (s/N): "
    read -r r2 < /dev/tty
    [[ $r2 != "s" ]] && { echo "omitido"; continue; }
    rm -rf "$b"
  fi
  
  mv "$f" "$b"
  echo "hecho: $b"
done
