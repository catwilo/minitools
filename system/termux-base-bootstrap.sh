#!/data/data/com.termux/files/usr/bin/bash
#==============================================================================
# termux-base-bootstrap.sh
# Bootstrap idempotente del entorno base de Termux (sin root): paquetes
# esenciales, estructura de directorios de automation, acceso a storage
# y rclone listo para configurar.
#
# Uso: ./termux-base-bootstrap.sh [--skip-upgrade] [--no-storage] [-h]
#==============================================================================

set -euo pipefail
IFS=$'\n\t'

#------------------------------------------------------------------------------
# Entorno Termux (sin root: todo bajo $PREFIX o $HOME, nunca /tmp)
#------------------------------------------------------------------------------
readonly TERMUX_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
readonly TERMUX_HOME="${HOME:-/data/data/com.termux/files/home}"

resolve_tmp_root() {
    local candidate
    for candidate in "${TMPDIR:-}" "$TERMUX_PREFIX/tmp" "$TERMUX_HOME/.cache/tmp"; do
        [[ -n "$candidate" ]] || continue
        mkdir -p "$candidate" 2>/dev/null || continue
        [[ -w "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
    done
    return 1
}

#------------------------------------------------------------------------------
# Configuración (editable)
#------------------------------------------------------------------------------
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="2.2.0"

if ! TMP_ROOT="$(resolve_tmp_root)"; then
    printf 'ERROR: no hay directorio temporal escribible\n' >&2
    exit 1
fi
readonly TMP_ROOT
export TMPDIR="$TMP_ROOT"            # herramientas hijas (pkg, pip, mktemp) lo respetan

readonly BASE_DIR="${AUTOMATION_HOME:-$TERMUX_HOME/automation}"
readonly LOG_DIR="$BASE_DIR/logs"
readonly SCRIPTS_DIR="$BASE_DIR/scripts"
readonly LOG_FILE="$LOG_DIR/bootstrap-$(date +%Y%m%d-%H%M%S).log"
readonly LOCK_FILE="$TMP_ROOT/${SCRIPT_NAME}.lock"

readonly PACKAGES=(git curl wget unzip python nodejs-lts rclone)
readonly DIRS=("$SCRIPTS_DIR")

WORK_DIR=""          # se crea en main con mktemp
SKIP_UPGRADE=0
SKIP_STORAGE=0

#------------------------------------------------------------------------------
# Logging
#------------------------------------------------------------------------------
_c() { [[ -t 1 ]] && printf '\033[%sm' "$1" || true; }
_log() {
    local level="$1" color="$2"; shift 2
    local msg; msg="$(date '+%F %T') [$level] $*"
    printf '%s%s%s\n' "$(_c "$color")" "$msg" "$(_c 0)"
    [[ -d "$LOG_DIR" ]] && printf '%s\n' "$msg" >> "$LOG_FILE" || true
}
log_info()  { _log INFO  '0;36' "$@"; }
log_ok()    { _log OK    '0;32' "$@"; }
log_warn()  { _log WARN  '0;33' "$@"; }
log_error() { _log ERROR '0;31' "$@" >&2; }

#------------------------------------------------------------------------------
# Manejo de errores y limpieza
#------------------------------------------------------------------------------
cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" && "$WORK_DIR" == "$TMP_ROOT"/* ]]; then
        rm -rf "$WORK_DIR"
    fi
    if [[ -f "$LOCK_FILE" && "$(cat "$LOCK_FILE" 2>/dev/null)" == "$$" ]]; then
        rm -f "$LOCK_FILE"
    fi
    return 0
}
trap cleanup EXIT
trap 'log_warn "Interrumpido por el usuario"; exit 130' INT TERM

#------------------------------------------------------------------------------
# Utilidades
#------------------------------------------------------------------------------
command_exists() { command -v "$1" >/dev/null 2>&1; }

# retry <intentos> <espera_seg> <comando...>
#
# Solo apto para comandos externos. No usar con funciones que corran bajo
# `set -e`: si la función falla internamente, aborta antes de que `until`
# pueda inspeccionar su código de salida.
retry() {
    local attempts="$1" delay="$2" n=1; shift 2
    until "$@"; do
        if (( n >= attempts )); then
            log_error "Comando falló tras $attempts intentos: $*"
            return 1
        fi
        log_warn "Intento $n/$attempts falló, reintentando en ${delay}s: $*"
        sleep "$delay"; n=$((n + 1))
    done
}

usage() {
    cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION
Uso: $SCRIPT_NAME [opciones]

  --skip-upgrade   Omite 'pkg upgrade'
  --no-storage     Omite termux-setup-storage
  -h, --help       Muestra esta ayuda
EOF
}

parse_args() {
    while (( $# )); do
        case "$1" in
            --skip-upgrade) SKIP_UPGRADE=1 ;;
            --no-storage)   SKIP_STORAGE=1 ;;
            -h|--help)      usage; exit 0 ;;
            *) log_error "Opción desconocida: $1"; usage; exit 64 ;;
        esac
        shift
    done
}

#------------------------------------------------------------------------------
# Pre-checks
#------------------------------------------------------------------------------
check_environment() {
    [[ "$TERMUX_PREFIX" == /data/data/com.termux/* ]] \
        || { log_error "Este script debe ejecutarse dentro de Termux"; exit 1; }
    command_exists pkg || { log_error "'pkg' no disponible"; exit 1; }
    [[ -w "$TMP_ROOT" ]] || { log_error "Directorio temporal no escribible: $TMP_ROOT"; exit 1; }
}

acquire_lock() {
    if ! ( set -o noclobber; echo $$ > "$LOCK_FILE" ) 2>/dev/null; then
        local pid; pid="$(cat "$LOCK_FILE" 2>/dev/null || true)"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            log_error "Ya hay otra instancia en ejecución (PID $pid)"
            exit 1
        fi
        log_warn "Lock obsoleto detectado, recuperando..."
        rm -f "$LOCK_FILE"
        ( set -o noclobber; echo $$ > "$LOCK_FILE" ) \
            || { log_error "Otra instancia tomó el lock durante la recuperación"; exit 1; }
    fi
}

setup_workdir() {
    WORK_DIR="$(mktemp -d "$TMP_ROOT/${SCRIPT_NAME}.XXXXXX")"
    log_info "Directorio de trabajo temporal: $WORK_DIR"
}

check_network() {
    log_info "Verificando conectividad..."
    retry 2 2 curl -fsS --max-time 5 -o /dev/null https://packages.termux.dev \
        || { log_error "Sin conexión a los repositorios de Termux"; exit 1; }
}

#------------------------------------------------------------------------------
# Tareas
#------------------------------------------------------------------------------
setup_dirs() {
    log_info "Creando estructura de directorios..."
    mkdir -p "${DIRS[@]}"
}

update_system() {
    log_info "Actualizando índices de paquetes..."
    retry 3 5 pkg update -y
    if (( SKIP_UPGRADE )); then
        log_warn "Upgrade omitido (--skip-upgrade)"
    else
        log_info "Actualizando paquetes instalados..."
        retry 2 5 pkg upgrade -y
    fi
}

setup_storage() {
    (( SKIP_STORAGE )) && { log_warn "Storage omitido (--no-storage)"; return 0; }
    if [[ -d "$TERMUX_HOME/storage/shared" ]]; then
        log_ok "Acceso a almacenamiento ya configurado"
        return 0
    fi
    log_info "Solicitando acceso al almacenamiento (acepta el permiso en pantalla)..."
    termux-setup-storage || log_warn "No se pudo configurar el almacenamiento"
}

install_packages() {
    log_info "Verificando paquetes: ${PACKAGES[*]}"
    local missing=() p
    for p in "${PACKAGES[@]}"; do
        dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
    done
    if (( ${#missing[@]} == 0 )); then
        log_ok "Todos los paquetes ya están instalados"
        return 0
    fi
    log_info "Instalando faltantes: ${missing[*]}"
    retry 3 5 pkg install -y "${missing[@]}"
}

update_pip() {
    log_info "Actualizando pip..."
    python3 -m pip install --upgrade --no-input --cache-dir "$WORK_DIR/pip-cache" pip \
        || log_warn "No se pudo actualizar pip (no crítico)"
}

verify_installation() {
    log_info "Verificando instalaciones..."
    local failed=0 cmd
    for cmd in git curl wget unzip python3 node npm rclone; do
        if command_exists "$cmd"; then
            log_ok "$(printf '%-8s' "$cmd") $("$cmd" --version 2>&1 | head -n1)"
        else
            log_error "$cmd no encontrado"; failed=1
        fi
    done
    return "$failed"
}

print_next_steps() {
    cat <<EOF

────────────────────────────────────────────
 Instalación completada · Log: $LOG_FILE
────────────────────────────────────────────
 1) Configurar Google Drive:   rclone config
 2) Probar acceso:             rclone lsd drive:
 3) Subir archivo:             rclone copy archivo.zip drive:Backups
 4) Sincronizar carpeta:       rclone sync ~/storage/shared/Documents drive:Documentos
    (usa --dry-run primero; sync puede BORRAR archivos en destino)
────────────────────────────────────────────
EOF
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------
main() {
    parse_args "$@"
    check_environment
    mkdir -p "$LOG_DIR"
    acquire_lock
    setup_workdir
    log_info "Iniciando $SCRIPT_NAME v$SCRIPT_VERSION (tmp: $TMP_ROOT)"

    check_network
    update_system
    setup_storage
    install_packages
    update_pip
    setup_dirs
    verify_installation
    print_next_steps
    log_ok "Bootstrap finalizado"
}

main "$@"
