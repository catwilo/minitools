#!/data/data/com.termux/files/usr/bin/bash
#==============================================================================
# rclone-gdrive-setup.sh
# Configuracion idempotente de Google Drive via rclone en Termux.
#
# Hace todo lo automatizable:
#   - verifica/instala rclone
#   - verifica si el remote 'drive:' ya existe
#   - si no existe, guia el wizard 'rclone config' con los valores exactos
#     para Google Drive y ofrece lanzarlo
#   - verifica el remote con 'rclone lsd drive:'
#   - crea carpetas base opcionales (Backups/, Documentos/) de forma
#     idempotente con 'rclone mkdir'
#
# Lo que NO puede automatizar (por diseno de Google):
#   - el paso OAuth en el navegador: el usuario debe aprobar el acceso
#     y pegar el codigo de vuelta en rclone. Por eso el wizard se
#     muestra con los valores exactos, no se inventa un flujo headless.
#
# Uso: ./rclone-gdrive-setup.sh [--dry-run] [-h]
#==============================================================================

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="1.0.0"
readonly REMOTE_NAME="drive"
readonly CARPETAS_BASE=("Backups" "Documentos")

DRY_RUN=0

if [[ -t 2 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    readonly G=$'\033[32m' Y=$'\033[33m' R=$'\033[31m'
    readonly C=$'\033[36m' B=$'\033[1m'  Z=$'\033[0m'
else
    readonly G='' Y='' R='' C='' B='' Z=''
fi

ok()   { printf '%s[OK]%s   %s\n'   "$G" "$Z" "$*" >&2; }
warn() { printf '%s[WARN]%s %s\n'  "$Y" "$Z" "$*" >&2; }
err()  { printf '%s[ERR]%s  %s\n'  "$R" "$Z" "$*" >&2; }
info() { printf '%s[INFO]%s %s\n'  "$C" "$Z" "$*" >&2; }
step() { printf '\n%s== %s ==%s\n' "$B" "$*" "$Z" >&2; }
die()  { err "$*"; exit 1; }

_run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        local _cmd
        _cmd="$(printf '%s ' "$@")"
        info "[DRY-RUN] ${_cmd% }"
        return 0
    fi
    "$@"
}

usage() {
    cat <<HELP
${B}$SCRIPT_NAME${Z} v$SCRIPT_VERSION
Configura Google Drive en Termux via rclone (guiado, idempotente).

${B}Uso:${Z}  bash $SCRIPT_NAME [opciones]

${B}Opciones:${Z}
  --dry-run     Muestra lo que se haria, sin ejecutar cambios
  -h, --help    Muestra esta ayuda

${B}Notas:${Z}
  - rclone debe estar instalado (lo trae termux-base-bootstrap.sh).
  - La parte OAuth de Google Drive es interactiva en el navegador:
    el script la guia pero no la puede automatizar.
HELP
}

parse_args() {
    while (( $# )); do
        case "$1" in
            --dry-run)  DRY_RUN=1 ;;
            -h|--help)  usage; exit 0 ;;
            *) die "Opcion desconocida: $1" ;;
        esac
        shift
    done
}

# ----------------------------------------------------------------------------
# Verificacion / instalacion de rclone
# ----------------------------------------------------------------------------

asegurar_rclone() {
    step "rclone"

    hash -r 2>/dev/null || true
    if command -v rclone >/dev/null 2>&1; then
        ok "rclone instalado: $(rclone version 2>/dev/null | head -n1)"
        return 0
    fi

    warn "rclone no esta en PATH"
    if ! command -v pkg >/dev/null 2>&1; then
        die "pkg no disponible -- este script es para Termux"
    fi

    info "instalando rclone via pkg"
    _run pkg install -y rclone || die "pkg install rclone fallo"

    if [[ $DRY_RUN -eq 1 ]]; then
        ok "[DRY-RUN] rclone quedaria instalado (se asume exito)"
        return 0
    fi

    hash -r 2>/dev/null || true
    command -v rclone >/dev/null 2>&1 \
        || die "rclone sigue sin estar en PATH tras la instalacion"
    ok "rclone instalado: $(rclone version 2>/dev/null | head -n1)"
}

# ----------------------------------------------------------------------------
# Verificacion del remote
# ----------------------------------------------------------------------------

remote_existe() {
    rclone listremotes 2>/dev/null | grep -qx "${REMOTE_NAME}:"
}

mostrar_guia_wizard() {
    cat <<HELP

${B}Valores para el wizard 'rclone config':${Z}
  1. n                                  -> nuevo remote
  2. name> ${REMOTE_NAME}                      -> nombre del remote
  3. Storage> drive                     -> Google Drive
  4. client_id> (dejar en blanco)       -> usa el client_id de rclone
  5. client_secret> (dejar en blanco)   -> usa el client_secret de rclone
  6. scope> 1                           -> acceso completo a Drive
  7. root_folder_id> (dejar en blanco)
  8. service_account_file> (dejar en blanco)
  9. Edit advanced config? n
 10. Use auto config? y                 -> abre el navegador
 11. En el navegador: iniciar sesion y aprobar acceso a Drive
 12. Pegar el codigo de vuelta en la terminal
 13. Configure this as a Shared Drive? n
 14. y (confirmar)  /  q (salir)

${B}Alternativa mas rapida si ya tienes credenciales propias:${Z}
  create client_id y client_secret en Google Cloud Console, luego
  export GDRIVE_CLIENT_ID=... GDRIVE_CLIENT_SECRET=...
  (opcional, no soportado por este script v${SCRIPT_VERSION})

HELP
}

configurar_remote() {
    step "remote '${REMOTE_NAME}:'"

    if remote_existe; then
        ok "remote '${REMOTE_NAME}:' ya configurado"
        return 0
    fi

    warn "remote '${REMOTE_NAME}:' no existe"
    mostrar_guia_wizard

    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] se lanzaria 'rclone config' para crear el remote"
        return 0
    fi

    printf '%sLanzar ' "$B" >&2
    printf "'rclone config'"
    printf ' ahora? [y/N]: %s' "$Z" >&2
    local respuesta=""
    read -r respuesta || true
    case "$respuesta" in
        y|Y) : ;;
        *) warn "configuracion del remote omitida -- corre 'rclone config' cuando quieras"; return 0 ;;
    esac

    rclone config || die "rclone config termino con error"

    if remote_existe; then
        ok "remote '${REMOTE_NAME}:' creado"
    else
        warn "remote '${REMOTE_NAME}:' aun no aparece -- revisa rclone config"
    fi
}

# ----------------------------------------------------------------------------
# Verificacion funcional
# ----------------------------------------------------------------------------

verificar_acceso() {
    step "verificacion de acceso"

    if ! remote_existe; then
        warn "sin remote '${REMOTE_NAME}:' -- se omite la verificacion"
        return 0
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        info "[DRY-RUN] se ejecutaria: rclone lsd ${REMOTE_NAME}:"
        return 0
    fi

    info "probando 'rclone lsd ${REMOTE_NAME}:'"
    if rclone lsd "${REMOTE_NAME}:" >/dev/null 2>&1; then
        ok "acceso a Google Drive confirmado"
    else
        warn "rclone lsd fallo -- puede requerir re-autorizacion OAuth"
    fi
}

# ----------------------------------------------------------------------------
# Carpetas base
# ----------------------------------------------------------------------------

crear_carpetas_base() {
    step "carpetas base"

    if ! remote_existe; then
        warn "sin remote '${REMOTE_NAME}:' -- se omiten las carpetas base"
        return 0
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        local c
        for c in "${CARPETAS_BASE[@]}"; do
            info "[DRY-RUN] rclone mkdir ${REMOTE_NAME}:${c}"
        done
        return 0
    fi

    local c
    for c in "${CARPETAS_BASE[@]}"; do
        if rclone mkdir "${REMOTE_NAME}:${c}" >/dev/null 2>&1; then
            ok "carpeta asegurada: ${REMOTE_NAME}:${c}"
        else
            warn "no se pudo asegurar: ${REMOTE_NAME}:${c}"
        fi
    done
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

main() {
    parse_args "$@"

    step "iniciando $SCRIPT_NAME v$SCRIPT_VERSION"
    [[ $DRY_RUN -eq 1 ]] && warn "modo --dry-run: no se aplicaran cambios"

    asegurar_rclone
    configurar_remote
    verificar_acceso
    crear_carpetas_base

    step "listo"
    printf '  Probar:      rclone lsd %s:\n' "$REMOTE_NAME" >&2
    printf '  Subir:       rclone copy archivo.zip %s:Backups\n' "$REMOTE_NAME" >&2
    printf '  Sincronizar: rclone sync ~/storage/shared/Documents %s:Documentos\n' "$REMOTE_NAME" >&2
    printf '  (usa --dry-run primero; sync puede BORRAR archivos en destino)\n' >&2
}

main "$@"
