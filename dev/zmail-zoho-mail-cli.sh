#!/usr/bin/env bash
#
# Instalador idempotente de Zoho Mail CLI (zmail).
# Soporta: Termux (no-root) y Debian/Ubuntu (root o sudo).
#
# Uso:      ./install-zmail.sh
# Reinstalar forzado: FORCE_REINSTALL=1 ./install-zmail.sh
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Configuración general
# ---------------------------------------------------------------------------

readonly APP_NAME="zmail"
readonly MIN_JAVA_VERSION=17
readonly FORCE_REINSTALL="${FORCE_REINSTALL:-0}"

# URL oficial del JAR publicada por Zoho Mail.
# Fuente: https://www.zoho.com/mail/help/cli/getting-started-with-cli.html
readonly DOWNLOAD_URL="https://www.zoho.com/mail/3938191/ZMAIL_CLI/zmail-cli.jar"

# Colores (se desactivan si no hay TTY, ej. redirección a archivo/log)
if [[ -t 1 ]]; then
    readonly C_RESET=$'\033[0m'
    readonly C_BOLD=$'\033[1m'
    readonly C_GREEN=$'\033[32m'
    readonly C_YELLOW=$'\033[33m'
    readonly C_RED=$'\033[31m'
    readonly C_BLUE=$'\033[34m'
    readonly C_DIM=$'\033[2m'
else
    readonly C_RESET="" C_BOLD="" C_GREEN="" C_YELLOW="" C_RED="" C_BLUE="" C_DIM=""
fi

# ---------------------------------------------------------------------------
# Utilidades de salida
# ---------------------------------------------------------------------------

log()   { printf '%s[+]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
skip()  { printf '%s[=]%s %s\n' "$C_DIM" "$C_RESET" "$*"; }
step()  { printf '\n%s%s%s\n' "$C_BOLD$C_BLUE" "$*" "$C_RESET"; }
die()   { printf '%s[✗]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

on_error() {
    local exit_code=$? line_no=$1
    printf '\n%s[✗] Fallo inesperado en la línea %s (código %s).%s\n' \
        "$C_RED" "$line_no" "$exit_code" "$C_RESET" >&2
    exit "$exit_code"
}
trap 'on_error $LINENO' ERR

# ---------------------------------------------------------------------------
# Detección de plataforma
# ---------------------------------------------------------------------------
#
# PLATFORM:        "termux" | "debian"
# INSTALL_PREFIX:  raíz de instalación (equivalente a $PREFIX en Termux,
#                   /usr/local en Debian)
# PKG_INSTALL:     comando completo para instalar paquetes, ya resuelto
#                   con o sin sudo según corresponda
# SHEBANG:         shebang correcto para los scripts que este instalador genera

detect_platform() {
    if [[ -n "${PREFIX:-}" && "$PREFIX" == *com.termux* ]]; then
        PLATFORM="termux"
        INSTALL_PREFIX="$PREFIX"
        SHEBANG="#!${PREFIX}/bin/bash"
    elif [[ -f /etc/debian_version ]]; then
        PLATFORM="debian"
        INSTALL_PREFIX="/usr/local"
        SHEBANG="#!/usr/bin/env bash"
    else
        die "Plataforma no soportada. Este instalador solo funciona en Termux o Debian/Ubuntu."
    fi

    readonly PLATFORM INSTALL_PREFIX SHEBANG
    log "Plataforma detectada: $PLATFORM"
}

# Resuelve cómo ejecutar comandos privilegiados según la plataforma.
# Termux: nunca hay ni se necesita sudo/root real.
# Debian: usa root directo si ya lo es (ej. contenedores), si no exige sudo.
resolve_privilege_escalation() {
    if [[ "$PLATFORM" == "termux" ]]; then
        AS_ROOT=()
        return
    fi

    # Debian/Ubuntu
    if [[ "${EUID}" -eq 0 ]]; then
        AS_ROOT=()
    elif command -v sudo >/dev/null 2>&1; then
        AS_ROOT=(sudo)
    else
        die "Se requieren privilegios de administrador para instalar paquetes en Debian, y 'sudo' no está disponible. Ejecuta este script como root."
    fi

    readonly AS_ROOT
}

# ---------------------------------------------------------------------------
# Rutas derivadas (dependen de PLATFORM, se resuelven tras detectarla)
# ---------------------------------------------------------------------------

set_derived_paths() {
    readonly INSTALL_DIR="${INSTALL_PREFIX}/opt/${APP_NAME}"
    readonly BIN_DIR="${INSTALL_PREFIX}/bin"
    readonly JAR_PATH="${INSTALL_DIR}/zmail-cli.jar"
    readonly LAUNCHER_PATH="${BIN_DIR}/zmail"
}

# ---------------------------------------------------------------------------
# Verificaciones previas
# ---------------------------------------------------------------------------

require_environment() {
    if [[ "$PLATFORM" == "termux" ]]; then
        [[ -d "$PREFIX" ]] || die "No se encontró el entorno PREFIX de Termux: $PREFIX"
        [[ -w "$PREFIX" ]] || die "Sin permisos de escritura en \$PREFIX: $PREFIX"
    else
        [[ -d "$INSTALL_PREFIX" ]] || die "No se encontró: $INSTALL_PREFIX"
    fi
}

require_commands() {
    local missing=() cmd
    for cmd in awk mktemp chmod mv mkdir head; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    ((${#missing[@]} == 0)) || die "Faltan comandos base del sistema: ${missing[*]}"
}

# ---------------------------------------------------------------------------
# Dependencias (Java, curl) — instalación condicional e idempotente
# ---------------------------------------------------------------------------

java_major_version_installed() {
    command -v java >/dev/null 2>&1 || return 1
    local out ver major
    out="$(java -version 2>&1)" || return 1
    ver="$(awk -F '"' '/version/ {print $2; exit}' <<< "$out")"
    [[ -n "$ver" ]] || return 1
    major="$(parse_java_major_version "$ver")" || return 1
    printf '%s' "$major"
}

install_dependencies() {
    step "Verificando dependencias del sistema"

    local need_java=1 need_curl=1

    if major="$(java_major_version_installed)" && (( major >= MIN_JAVA_VERSION )); then
        skip "Java $major ya cumple el mínimo requerido ($MIN_JAVA_VERSION). Se omite instalación."
        need_java=0
    fi

    command -v curl >/dev/null 2>&1 && { skip "curl ya está instalado."; need_curl=0; }

    if (( need_java == 0 && need_curl == 0 )); then
        return
    fi

    case "$PLATFORM" in
        termux)
            log "Actualizando índice de paquetes (pkg)..."
            pkg update -y || die "No se pudo actualizar el índice de paquetes."
            local pkgs=()
            (( need_java )) && pkgs+=(openjdk-17)
            (( need_curl )) && pkgs+=(curl)
            log "Instalando: ${pkgs[*]}"
            pkg install -y "${pkgs[@]}" || die "No se pudieron instalar: ${pkgs[*]}"
            ;;
        debian)
            log "Actualizando índice de paquetes (apt)..."
            "${AS_ROOT[@]}" apt-get update -y || die "No se pudo actualizar el índice de paquetes (apt)."
            local pkgs=()
            (( need_java )) && pkgs+=(openjdk-17-jre-headless)
            (( need_curl )) && pkgs+=(curl)
            log "Instalando: ${pkgs[*]}"
            "${AS_ROOT[@]}" apt-get install -y "${pkgs[@]}" || die "No se pudieron instalar: ${pkgs[*]}"
            ;;
    esac
}

parse_java_major_version() {
    local raw="$1" major="${1%%.*}"
    if [[ "$major" == "1" ]]; then
        major="${raw#1.}"
        major="${major%%.*}"
    fi
    major="${major%%[-+]*}"
    [[ "$major" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$major"
}

verify_java() {
    step "Verificando Java"
    local major
    major="$(java_major_version_installed)" || die "Java no está disponible o no se pudo determinar su versión tras la instalación."
    (( major >= MIN_JAVA_VERSION )) || die "Se requiere Java $MIN_JAVA_VERSION o superior. Encontrado: $major."
    log "Java $major detectado (OK, >= $MIN_JAVA_VERSION)."
}

# ---------------------------------------------------------------------------
# Descarga e instalación del JAR — idempotente
# ---------------------------------------------------------------------------

download_zmail() {
    step "Zoho Mail CLI (JAR)"

    if [[ -f "$JAR_PATH" && "$FORCE_REINSTALL" != "1" ]]; then
        skip "Ya existe en $JAR_PATH. Usa FORCE_REINSTALL=1 para forzar la redescarga."
        return
    fi

    if [[ "$PLATFORM" == "termux" ]]; then
        mkdir -p "$INSTALL_DIR" || die "No se pudo crear: $INSTALL_DIR"
    else
        "${AS_ROOT[@]}" mkdir -p "$INSTALL_DIR" || die "No se pudo crear: $INSTALL_DIR"
        "${AS_ROOT[@]}" chown "$(id -u):$(id -g)" "$INSTALL_DIR" || die "No se pudo tomar propiedad de: $INSTALL_DIR"
    fi

    local tmp
    tmp="$(mktemp "${INSTALL_DIR}/.zmail-cli.XXXXXX.jar")" || die "No se pudo crear archivo temporal en $INSTALL_DIR."
    trap 'rm -f "$tmp"; trap - RETURN' RETURN

    log "Descargando desde: $DOWNLOAD_URL"
    curl --fail --show-error --location --retry 3 --retry-delay 2 \
         --connect-timeout 15 --output "$tmp" "$DOWNLOAD_URL" \
        || die "No se pudo descargar Zoho Mail CLI. Verifica tu conexión o si la URL sigue vigente en la documentación oficial de Zoho."

    [[ -s "$tmp" ]] || die "La descarga produjo un archivo vacío."

    # Un JAR es un ZIP: debe empezar con la firma 'PK'.
    if [[ "$(head -c 2 "$tmp")" != "PK" ]]; then
        die "El archivo descargado no parece un JAR válido (firma inesperada)."
    fi

    mv "$tmp" "$JAR_PATH" || die "No se pudo mover el JAR a: $JAR_PATH"
    chmod 0644 "$JAR_PATH"
    log "JAR guardado en: $JAR_PATH"
}

create_launcher() {
    step "Comando '$APP_NAME'"

    if [[ -f "$LAUNCHER_PATH" && "$FORCE_REINSTALL" != "1" ]] \
        && grep -qF "$JAR_PATH" "$LAUNCHER_PATH" 2>/dev/null; then
        skip "Ya existe y apunta al JAR correcto. Se omite."
        return
    fi

    if [[ -e "$LAUNCHER_PATH" ]]; then
        warn "Se sobrescribirá '$LAUNCHER_PATH' existente."
    fi

    local tmp_launcher
    tmp_launcher="$(mktemp)"
    cat > "$tmp_launcher" <<EOF
${SHEBANG}
exec java -jar "$JAR_PATH" "\$@"
EOF
    chmod 0755 "$tmp_launcher"

    if [[ "$PLATFORM" == "termux" ]]; then
        mv "$tmp_launcher" "$LAUNCHER_PATH" || die "No se pudo instalar el launcher en: $LAUNCHER_PATH"
    else
        "${AS_ROOT[@]}" mv "$tmp_launcher" "$LAUNCHER_PATH" || die "No se pudo instalar el launcher en: $LAUNCHER_PATH"
        "${AS_ROOT[@]}" chmod 0755 "$LAUNCHER_PATH"
    fi

    log "Comando instalado en: $LAUNCHER_PATH"
}

verify_installation() {
    step "Verificación final"
    command -v "$APP_NAME" >/dev/null 2>&1 || \
        die "'$APP_NAME' no está en PATH. Verifica que $BIN_DIR esté en tu \$PATH."
    [[ -f "$JAR_PATH" ]] || die "No se encontró el JAR en: $JAR_PATH"
    log "Instalación verificada correctamente."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

print_summary() {
    printf '\n%s%s ha sido instalado correctamente (%s).%s\n' \
        "$C_BOLD$C_GREEN" "ZMail CLI" "$PLATFORM" "$C_RESET"
    printf '\nEjecuta:\n  %s%s%s\n' "$C_BOLD" "zmail" "$C_RESET"
    printf '\nLa primera ejecución te pedirá una contraseña de cifrado.\n'
    printf 'Después podrás iniciar sesión con:\n  %s%s%s\n\n' "$C_BOLD" "login" "$C_RESET"
}

main() {
    detect_platform
    resolve_privilege_escalation
    set_derived_paths
    require_environment
    require_commands
    install_dependencies
    verify_java
    download_zmail
    create_launcher
    verify_installation
    print_summary
}

main "$@"
