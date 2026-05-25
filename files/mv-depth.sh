#!/bin/bash

# Verificar parámetros
[[ $# -ne 3 ]] && { echo "Uso: $0 <ruta> <texto-antiguo> <texto-nuevo>"; exit 1; }

dir="$1"; old="$2"; new="$3"

# Función para renombrar un elemento (archivo o directorio)
rename() {
  mv -v "$1" "$2" || { echo "Error al renombrar '$1'"; exit 1; }
}

# Función para mostrar los cambios propuestos
show_changes() {
  find "$dir" -depth -name "*$old*" -print0 | while IFS= read -r -d '' file; do
    # Escapar los caracteres especiales en el texto de reemplazo
    escaped_old=$(printf '%s' "$old" | sed 's/[][\.*^$(){}?+|/\\]/\\&/g')
    escaped_new=$(printf '%s' "$new" | sed 's/[&/\]/\\&/g')
    
    # Realizar el reemplazo de manera segura con sed
    new_name=$(echo "$file" | sed "s/$escaped_old/$escaped_new/g")
    
    # Solo mostrar el cambio si es realmente diferente
    if [[ "$file" != "$new_name" ]]; then
      echo -e "OLD: $file\nNEW: $new_name"
    fi
  done
}


# Mostrar cambios (archivos y directorios) y solicitar confirmación
echo "Cambios propuestos:"
show_changes

read -p "¿Confirmar renombrado de archivos y directorios? Escribe 'Yes' para continuar: " confirm
[[ "$confirm" != "Yes" ]] && exit 0


# Ciclo de renombrado para archivos
for file in $(find "$dir" -depth -type f -name "*$old*"); do
  escaped_old=$(printf '%s' "$old" | sed 's/[][\.*^$(){}?+|/\\]/\\&/g')
  escaped_new=$(printf '%s' "$new" | sed 's/[&/\]/\\&/g')
  new_file=$(echo "$file" | sed "s/$escaped_old/$escaped_new/g")

  # Si el archivo va a cambiar de nombre
  if [[ "$file" != "$new_file" ]]; then
    # Verificar si el archivo de destino ya existe
    if [[ -e "$new_file" ]]; then
      # Preguntar al usuario si desea sobrescribir
      read -p "El archivo '$new_file' ya existe. ¿Sobrescribir? (Yes/No): " confirm
      if [[ "$confirm" != "Yes" ]]; then
        echo "Cancelado: no se sobrescribe '$new_file'."
        continue  # Continuar con el siguiente archivo
      fi
    fi
    # Si el archivo no existe o el usuario confirmó la sobrescritura, renombrar
    rename "$file" "$new_file"
  fi
done



# Renombrar directorios
for folder in $(find "$dir" -depth -type d -name "*$old*"); do
  escaped_old=$(printf '%s' "$old" | sed 's/[][\.*^$(){}?+|/\\]/\\&/g')
  escaped_new=$(printf '%s' "$new" | sed 's/[&/\]/\\&/g')
  new_folder=$(echo "$folder" | sed "s/$escaped_old/$escaped_new/g")

  if [[ "$folder" != "$new_folder" ]]; then
    if [[ -e "$new_folder" ]]; then
      read -p "El folder ya existe. ¿Moverlo dentro de '$new_folder' ? (Yes/No): " confirm
      if [[ "$confirm" != "Yes" ]]; then
        echo "Cancelado: no se sobrescribe '$new_folder'."
        continue
      fi
    fi
    rename "$folder" "$new_folder"
  fi
done

echo "Renombrado completado."

