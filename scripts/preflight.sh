#!/usr/bin/env bash

# Preflight de solo lectura para instalaciones nuevas o existentes.
# No crea directorios, redes, contenedores ni modifica .env.

if ((BASH_VERSINFO[0] < 4)); then
    printf '[ERROR] preflight.sh requiere Bash 4 o superior\n' >&2
    exit 2
fi

set -uo pipefail
IFS=$'\n\t'

quiet=false
verbose=false
json=false

usage() {
    cat <<'EOF'
Uso:
  bash scripts/preflight.sh [--quiet] [--verbose] [--json]

Opciones:
  --quiet    Oculta mensajes OK e INFO; conserva WARN, ERROR y resumen.
  --verbose  Muestra detalles adicionales.
  --json     Emite solo un resumen JSON.

Códigos:
  0  Puede continuar.
  1  Hay errores bloqueantes.
  2  Uso incorrecto o error interno.
EOF
}

while (($# > 0)); do
    case $1 in
        --quiet) quiet=true ;;
        --verbose) verbose=true ;;
        --json) json=true; quiet=true ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Opción desconocida: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

ok_count=0
info_count=0
warn_count=0
error_count=0

emit() {
    local level=$1
    shift
    [[ $json == true ]] && return
    [[ $quiet == true && ($level == OK || $level == INFO) ]] && return
    printf '[%s] %s\n' "$level" "$*"
}
ok() { ((ok_count += 1)); emit OK "$@"; }
info() { ((info_count += 1)); emit INFO "$@"; }
warn() { ((warn_count += 1)); emit WARN "$@"; }
error() { ((error_count += 1)); emit ERROR "$@"; }
section() { [[ $quiet == true || $json == true ]] || printf '\n%s\n' "$1"; }

env_value() {
    local key=$1 value
    [[ -f $env_file ]] || return 0
    value=$(awk -F= -v wanted="$key" '
        $0 !~ /^[[:space:]]*#/ && $1 ~ "^[[:space:]]*" wanted "[[:space:]]*$" {
            sub(/^[^=]*=/, "")
            print
            exit
        }
    ' "$env_file" 2>/dev/null || true)
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    if [[ ${#value} -ge 2 && $value == \"*\" ]]; then
        value=${value:1:${#value}-2}
    elif [[ ${#value} -ge 2 && $value == \'*\' ]]; then
        value=${value:1:${#value}-2}
    fi
    printf '%s' "$value"
}

profile_enabled() {
    local wanted=$1 profiles
    profiles=$(env_value COMPOSE_PROFILES)
    [[ ,$profiles, == *,$wanted,* ]]
}

dir_nonempty() {
    local path=$1
    [[ -d $path ]] && find "$path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .
}

port_in_use() {
    local port=$1
    if command -v ss >/dev/null 2>&1; then
        ss -ltnH "sport = :$port" 2>/dev/null | grep -q .
        return
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk -v p=":$port" 'NR > 2 && $4 ~ p "$" { found=1 } END { exit !found }'
        return
    fi
    return 2
}

human_gib() {
    awk -v kb="$1" 'BEGIN { printf "%.1f", kb / 1024 / 1024 }'
}

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
env_file="$project_dir/.env"

cd -- "$project_dir" || { printf '[ERROR] No se pudo acceder a %s\n' "$project_dir" >&2; exit 2; }

[[ $json == true ]] || printf 'Nextcloud Docker Preflight\n==========================\n'

section 'Sistema'

os_name=$(uname -s 2>/dev/null || true)
arch=$(uname -m 2>/dev/null || true)
if [[ $os_name == Linux ]]; then ok "Linux $arch"; else error "Sistema no soportado: ${os_name:-desconocido}"; fi
ok "Bash $BASH_VERSION"

case $arch in
    x86_64|amd64) ok 'Arquitectura amd64 compatible con las imágenes de referencia' ;;
    aarch64|arm64) warn 'Arquitectura arm64: verifique soporte de todos los tags, especialmente OnlyOffice' ;;
    *) warn "Arquitectura $arch no validada por este repositorio" ;;
esac

for required_command in git openssl; do
    if command -v "$required_command" >/dev/null 2>&1; then
        version=$("$required_command" --version 2>/dev/null | head -n 1 || true)
        ok "$required_command disponible${version:+: $version}"
    else
        error "Falta comando requerido: $required_command"
    fi
done

if command -v jq >/dev/null 2>&1; then
    version=$(jq --version 2>/dev/null | head -n 1 || true)
    ok "jq disponible${version:+: $version}"
else
    warn 'jq no está disponible; doctor.sh omitirá algunas comprobaciones estructurales avanzadas'
fi

docker_ready=false
compose_ready=false
if ! command -v docker >/dev/null 2>&1; then
    error 'Docker CLI no está instalado'
else
    docker_version=$(docker --version 2>/dev/null || true)
    ok "Docker CLI disponible${docker_version:+: $docker_version}"
    if docker info >/dev/null 2>&1; then
        docker_ready=true
        ok 'Docker daemon accesible'
    else
        error 'Docker daemon no disponible o el usuario no tiene permiso'
    fi
    if docker compose version >/dev/null 2>&1; then
        compose_ready=true
        compose_version=$(docker compose version 2>/dev/null | head -n 1 || true)
        ok "Docker Compose V2 disponible${compose_version:+: $compose_version}"
    else
        error 'Docker Compose V2 no está disponible'
    fi
fi

section 'Recursos'

mem_total_kb=0
if [[ -r /proc/meminfo ]]; then
    mem_total_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    mem_available_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    if [[ $mem_total_kb =~ ^[0-9]+$ ]]; then
        ok "RAM: $(human_gib "$mem_total_kb") GiB total, $(human_gib "${mem_available_kb:-0}") GiB disponible"
    else
        warn 'No se pudo interpretar la memoria del host'
    fi
else
    warn 'No se pudo consultar /proc/meminfo'
fi

if disk_line=$(df -Pk "$project_dir" 2>/dev/null | awk 'NR == 2 { print $4 "|" $5 "|" $1 }'); then
    disk_available_kb=${disk_line%%|*}
    disk_rest=${disk_line#*|}
    disk_used_percent=${disk_rest%%|*}
    disk_fs=${disk_rest#*|}
    disk_used_percent=${disk_used_percent%%%}
    disk_available_human=$(df -hP "$project_dir" 2>/dev/null | awk 'NR == 2 { print $4 }')
    if [[ $disk_available_kb =~ ^[0-9]+$ && $disk_used_percent =~ ^[0-9]+$ ]]; then
        if ((disk_used_percent >= 90)); then
            error "Disco: ${disk_available_human:-?} libres, $disk_used_percent% usado en $disk_fs"
        elif ((disk_used_percent >= 80)); then
            warn "Disco: ${disk_available_human:-?} libres, $disk_used_percent% usado en $disk_fs"
        else
            ok "Disco: ${disk_available_human:-?} libres, $disk_used_percent% usado en $disk_fs"
        fi
    fi
else
    error 'No se pudo consultar el filesystem del proyecto'
fi

section 'Configuración'

env_ready=false
onlyoffice_enabled=false
acme_enabled=false

if [[ ! -f $env_file ]]; then
    error '.env no existe; copie .env.example antes de instalar'
else
    env_ready=true
    ok '.env presente'
    if command -v stat >/dev/null 2>&1; then
        env_mode=$(stat -c '%a' "$env_file" 2>/dev/null || true)
        if [[ $env_mode == 600 ]]; then
            ok '.env con permisos 600'
        elif [[ $env_mode =~ ^[0-7]+$ ]] && (( (8#$env_mode & 077) == 0 )); then
            warn ".env tiene permisos $env_mode; se recomienda exactamente 600"
        else
            error ".env tiene permisos ${env_mode:-desconocidos}; otros usuarios podrían leer secretos"
        fi
    fi

    required_env_vars=(
        NEXTCLOUD_BASE_IMAGE NEXTCLOUD_APP_IMAGE MARIADB_IMAGE REDIS_IMAGE
        NGINX_IMAGE NGINX_PROXY_IMAGE ACME_COMPANION_IMAGE
        NEXTCLOUD_DOMAIN NEXTCLOUD_TRUSTED_DOMAINS
        NEXTCLOUD_OVERWRITE_PROTOCOL NEXTCLOUD_OVERWRITE_HOST
        NEXTCLOUD_PUBLIC_URL NGINX_PROXY_NETWORK
        MYSQL_DATABASE MYSQL_USER MYSQL_PASSWORD MYSQL_ROOT_PASSWORD
        NEXTCLOUD_ADMIN_USER NEXTCLOUD_ADMIN_PASSWORD REDIS_PASSWORD
    )
    invalid_env=0
    for env_name in "${required_env_vars[@]}"; do
        value=$(env_value "$env_name")
        if [[ -z $value || $value == CHANGE_ME* ]]; then
            error "Variable obligatoria vacía o de ejemplo: $env_name"
            ((invalid_env += 1))
        elif [[ $verbose == true ]]; then
            info "Variable presente: $env_name"
        fi
    done
    ((invalid_env == 0)) && ok 'Variables base obligatorias completas'

    redis_secret=$(env_value REDIS_PASSWORD)
    [[ $redis_secret =~ ^[0-9A-Fa-f]{64,}$ ]] \
        && ok 'REDIS_PASSWORD tiene formato hexadecimal y longitud válida' \
        || error 'REDIS_PASSWORD debe contener al menos 64 caracteres hexadecimales'

    if profile_enabled onlyoffice; then
        onlyoffice_enabled=true
        info 'Perfil OnlyOffice activo'
        onlyoffice_image=$(env_value ONLYOFFICE_IMAGE)
        onlyoffice_jwt=$(env_value ONLYOFFICE_JWT_SECRET)
        [[ -n $onlyoffice_image && $onlyoffice_image != CHANGE_ME* ]] \
            && ok 'ONLYOFFICE_IMAGE configurada' \
            || error 'ONLYOFFICE_IMAGE es obligatorio cuando onlyoffice está activo'
        [[ $onlyoffice_jwt =~ ^[0-9A-Fa-f]{64,}$ ]] \
            && ok 'ONLYOFFICE_JWT_SECRET tiene formato y longitud válidos' \
            || error 'ONLYOFFICE_JWT_SECRET debe contener al menos 64 caracteres hexadecimales'
        if [[ $mem_total_kb =~ ^[0-9]+$ ]] && ((mem_total_kb > 0 && mem_total_kb < 4194304)); then
            warn 'OnlyOffice está activo con menos de 4 GiB de RAM total; mida el consumo antes de carga real'
        fi
    else
        info 'Perfil OnlyOffice deshabilitado'
    fi

    if profile_enabled acme; then
        acme_enabled=true
        info 'Perfil ACME activo'
        acme_email=$(env_value ACME_EMAIL)
        domain=$(env_value NEXTCLOUD_DOMAIN)
        protocol=$(env_value NEXTCLOUD_OVERWRITE_PROTOCOL)
        public_url=$(env_value NEXTCLOUD_PUBLIC_URL)
        [[ -n $acme_email && $acme_email != *@example.com ]] \
            && ok 'ACME_EMAIL configurado' \
            || error 'ACME_EMAIL es obligatorio y no debe conservar el dominio de ejemplo'
        case $domain in
            localhost|127.0.0.1|::1|'') error 'ACME no debe usarse con localhost o loopback' ;;
            *) ok "Dominio ACME: $domain" ;;
        esac
        [[ $protocol == https ]] || error 'NEXTCLOUD_OVERWRITE_PROTOCOL debe ser https cuando ACME está activo'
        [[ $public_url == https://* ]] || error 'NEXTCLOUD_PUBLIC_URL debe usar https cuando ACME está activo'
    else
        info 'Perfil ACME deshabilitado'
    fi
fi

section 'Persistencia'

db_has_data=false
data_has_data=false
config_exists=false
dir_nonempty db && db_has_data=true
dir_nonempty data && data_has_data=true
[[ -f nextcloud/config/config.php ]] && config_exists=true

install_state=NEW
if [[ $db_has_data == true && $config_exists == true ]]; then
    install_state=EXISTING
    info 'Estado detectado: instalación existente'
elif [[ $db_has_data == true || $data_has_data == true || $config_exists == true ]]; then
    install_state=PARTIAL
    warn 'Estado detectado: instalación parcial o persistencia preexistente'
else
    info 'Estado detectado: instalación nueva'
fi

[[ $db_has_data == true ]] && warn 'db/ contiene datos: cambiar MYSQL_PASSWORD en .env no actualiza automáticamente MariaDB'
[[ $db_has_data == true && $config_exists == false ]] \
    && error 'MariaDB contiene datos pero nextcloud/config/config.php no existe; revise una inicialización interrumpida'
[[ $config_exists == true && $db_has_data == false ]] \
    && error 'Existe config.php pero db/ está vacío; confirme la base de datos antes de continuar'

permission_paths=(nextcloud nextcloud/page nextcloud/page/web nextcloud/apps nextcloud/custom_apps)
permission_errors=0
for permission_path in "${permission_paths[@]}"; do
    [[ -e $permission_path ]] || continue
    if [[ ! -d $permission_path ]]; then
        error "$permission_path existe pero no es directorio"
        ((permission_errors += 1))
        continue
    fi
    if command -v stat >/dev/null 2>&1; then
        path_mode=$(stat -c '%a' "$permission_path" 2>/dev/null || true)
        if [[ $path_mode =~ ^[0-7]+$ ]] && (( (8#$path_mode & 005) != 005 )); then
            error "$permission_path tiene modo $path_mode; Nginx necesita lectura/traversal"
            ((permission_errors += 1))
        elif [[ $verbose == true ]]; then
            info "$permission_path permisos $path_mode"
        fi
    fi
done
((permission_errors == 0)) && ok 'Permisos de directorios web compatibles'

section 'Red y puertos'

compose=(docker compose --project-directory "$project_dir")
compose_running=false
if [[ $docker_ready == true && $compose_ready == true && -f compose.yaml && -f $env_file ]]; then
    running_services=$("${compose[@]}" ps --status running --services 2>/dev/null || true)
    if [[ -n $running_services ]]; then
        compose_running=true
        info 'Ya hay servicios de este proyecto en ejecución; se omite la exigencia de puertos libres'
    fi
fi

if [[ $compose_running == false && $env_ready == true ]]; then
    http_port=$(env_value HTTP_PORT); http_port=${http_port:-80}
    https_port=$(env_value HTTPS_PORT); https_port=${https_port:-443}
    for port in "$http_port" "$https_port"; do
        if [[ ! $port =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
            error "Puerto inválido: $port"
            continue
        fi
        if port_in_use "$port"; then
            error "Puerto TCP $port ya está en escucha; libérelo o cambie la configuración"
        else
            port_status=$?
            ((port_status == 2)) && warn "No hay ss ni netstat; no se pudo comprobar TCP $port" || ok "Puerto TCP $port disponible"
        fi
    done
fi

if [[ $env_ready == true && $docker_ready == true ]]; then
    proxy_network=$(env_value NGINX_PROXY_NETWORK); proxy_network=${proxy_network:-nginx-proxy}
    if docker network inspect -- "$proxy_network" >/dev/null 2>&1; then
        ok "Red Docker externa presente: $proxy_network"
    else
        error "Red Docker externa ausente: $proxy_network"
        [[ $json == true ]] || printf '       Cree la red antes de iniciar: docker network create %q\n' "$proxy_network"
    fi
fi

section 'Docker Compose'

services=()
if [[ $compose_ready == true && -f compose.yaml && $env_ready == true ]]; then
    if "${compose[@]}" config --quiet >/dev/null 2>&1; then
        ok 'Compose efectivo válido'
        services_output=$("${compose[@]}" config --services 2>/dev/null || true)
        if [[ -n $services_output ]]; then
            mapfile -t services <<< "$services_output"
            for service in "${services[@]}"; do info "Servicio efectivo: $service"; done
            for required_service in db redis app web proxy; do
                printf '%s\n' "${services[@]}" | grep -qx "$required_service" \
                    || error "Falta servicio base: $required_service"
            done
            if [[ $onlyoffice_enabled == true ]]; then
                printf '%s\n' "${services[@]}" | grep -qx onlyoffice \
                    && ok 'Perfil onlyoffice incluido' || error 'Perfil onlyoffice activo pero servicio ausente'
            elif printf '%s\n' "${services[@]}" | grep -qx onlyoffice; then
                warn 'OnlyOffice aparece aunque el perfil no figura activo'
            else
                info 'Servicio onlyoffice omitido'
            fi
            if [[ $acme_enabled == true ]]; then
                printf '%s\n' "${services[@]}" | grep -qx acme \
                    && ok 'Perfil acme incluido' || error 'Perfil acme activo pero servicio ausente'
            elif printf '%s\n' "${services[@]}" | grep -qx acme; then
                warn 'ACME aparece aunque el perfil no figura activo'
            else
                info 'Servicio acme omitido'
            fi
        else
            error 'Compose no devolvió servicios efectivos'
        fi
    else
        error 'docker compose config --quiet falló; revise .env y compose.yaml'
        [[ $verbose == true ]] && "${compose[@]}" config --quiet || true
    fi
else
    [[ -f compose.yaml ]] || error 'compose.yaml no existe en la raíz'
fi

section 'Resultado'

status=READY
((error_count > 0)) && status=BLOCKED
if [[ $json == true ]]; then
    printf '{"status":"%s","installation_state":"%s","onlyoffice":%s,"acme":%s,"ok":%d,"info":%d,"warnings":%d,"errors":%d}\n' \
        "$status" "$install_state" "$onlyoffice_enabled" "$acme_enabled" \
        "$ok_count" "$info_count" "$warn_count" "$error_count"
else
    printf '\n[%s] %d OK, %d INFO, %d WARN, %d ERROR\n' \
        "$status" "$ok_count" "$info_count" "$warn_count" "$error_count"
    if [[ $status == READY ]]; then
        printf 'El host y la configuración superaron el preflight.\n'
    else
        printf 'Corrija los errores bloqueantes antes de ejecutar docker compose up.\n'
    fi
fi

((error_count == 0)) && exit 0
exit 1
