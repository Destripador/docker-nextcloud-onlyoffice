#!/usr/bin/env bash

# Diagnóstico de solo lectura para el Compose público efectivo.
# No crea, inicia, detiene, reinicia, actualiza ni modifica contenedores.

if ((BASH_VERSINFO[0] < 4)); then
    printf '[ERROR] doctor.sh requiere Bash 4 o superior\n' >&2
    exit 2
fi

set -uo pipefail
IFS=$'\n\t'

ok_count=0
warn_count=0
error_count=0

ok() { printf '[OK] %s\n' "$*"; ((ok_count += 1)); }
warn() { printf '[WARN] %s\n' "$*"; ((warn_count += 1)); }
error() { printf '[ERROR] %s\n' "$*"; ((error_count += 1)); }

run_timeout() {
    local seconds=$1
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$seconds" "$@"
    else
        "$@"
    fi
}

env_value() {
    local key=$1 value
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

has_service() {
    local wanted=$1 service
    for service in "${services[@]}"; do
        [[ $service == "$wanted" ]] && return 0
    done
    return 1
}

is_running() {
    [[ ${service_state[$1]:-missing} == running ]]
}

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
env_file="$project_dir/.env"

if ! cd -- "$project_dir"; then
    printf '[ERROR] No se pudo acceder al directorio del proyecto: %s\n' "$project_dir" >&2
    exit 2
fi

docker_ready=false
compose_ready=false
config_valid=false
services=()
declare -A service_state=()
compose=(docker compose --project-directory "$project_dir")

if [[ -n ${COMPOSE_FILE:-} ]]; then
    warn 'COMPOSE_FILE está definido; se validará esa combinación efectiva. Confirme que todos sus archivos pertenecen a este despliegue.'
fi

if [[ -f $env_file ]]; then
    ok '.env presente'
    if command -v stat >/dev/null 2>&1; then
        env_mode=$(stat -c '%a' "$env_file" 2>/dev/null || true)
        if [[ $env_mode =~ ^[0-7]+$ ]] && (( (8#$env_mode & 077) != 0 )); then
            warn ".env tiene permisos $env_mode; se recomienda 600"
        else
            ok '.env con permisos restrictivos'
        fi
    fi

    required_env_vars=(
        NEXTCLOUD_BASE_IMAGE NEXTCLOUD_APP_IMAGE MARIADB_IMAGE REDIS_IMAGE
        NGINX_IMAGE NGINX_PROXY_IMAGE ACME_COMPANION_IMAGE
        NEXTCLOUD_DOMAIN NEXTCLOUD_TRUSTED_DOMAINS NEXTCLOUD_OVERWRITE_HOST
        NEXTCLOUD_PUBLIC_URL MYSQL_DATABASE MYSQL_USER MYSQL_PASSWORD
        MYSQL_ROOT_PASSWORD NEXTCLOUD_ADMIN_USER NEXTCLOUD_ADMIN_PASSWORD
        REDIS_PASSWORD
    )
    invalid_env=0
    for env_name in "${required_env_vars[@]}"; do
        value=$(env_value "$env_name")
        if [[ -z $value || $value == CHANGE_ME* ]]; then
            ((invalid_env += 1))
        fi
        unset value
    done
    if ((invalid_env == 0)); then
        ok 'Variables obligatorias sin placeholders'
    else
        error "$invalid_env variables obligatorias están vacías o conservan CHANGE_ME"
    fi

    compose_profiles=$(env_value COMPOSE_PROFILES)
    onlyoffice_profile=false
    if [[ ,$compose_profiles, == *,onlyoffice,* ]]; then
        onlyoffice_profile=true
        onlyoffice_image=$(env_value ONLYOFFICE_IMAGE)
        onlyoffice_jwt=$(env_value ONLYOFFICE_JWT_SECRET)
        if [[ -z $onlyoffice_image || $onlyoffice_image == CHANGE_ME* ]]; then
            error 'OnlyOffice está activo, pero ONLYOFFICE_IMAGE está vacío o conserva un placeholder'
        fi
        if [[ ! $onlyoffice_jwt =~ ^[0-9A-Fa-f]{64,}$ ]]; then
            error 'OnlyOffice está activo, pero ONLYOFFICE_JWT_SECRET debe contener al menos 64 caracteres hexadecimales'
        else
            ok 'OnlyOffice activo con JWT no trivial'
        fi
        unset onlyoffice_image onlyoffice_jwt
    else
        ok 'OnlyOffice deshabilitado por perfil'
    fi

    if [[ ,$compose_profiles, == *,acme,* ]]; then
        acme_email=$(env_value ACME_EMAIL)
        if [[ -z $acme_email || $acme_email == *@example.com ]]; then
            error 'ACME está activo, pero ACME_EMAIL está vacío o conserva el dominio de ejemplo'
        else
            ok 'Correo ACME configurado'
        fi
        unset acme_email
    fi
    unset compose_profiles
else
    error '.env no existe; copie .env.example, complete los valores y aplique chmod 600'
fi

if command -v git >/dev/null 2>&1; then
    tracked_sensitive=$(git -c safe.directory="$project_dir" -C "$project_dir" ls-files 2>/dev/null |
        awk '
            /(^|\/)\.env($|\.)/ && $0 !~ /\.env\.example$/ { count++ }
            /(^|\/)(secrets?|certs?)(\/|$)/ { count++ }
            /\.(swp|swo|key|pem|p12|pfx|sql|sql\.gz|dump)$/ { count++ }
            END { print count + 0 }
        ')
    if ((tracked_sensitive > 0)); then
        warn "$tracked_sensitive rutas potencialmente sensibles siguen rastreadas; revíselas antes de publicar"
    else
        ok 'Git no rastrea patrones sensibles conocidos'
    fi
fi

# Los bind mounts que Nginx sirve deben ser atravesables/legibles por un UID
# distinto al de Nextcloud. Esto detecta el fallo típico causado por dejar
# umask 077 activo al crear la persistencia.
permission_paths=(
    nextcloud/page/web
    nextcloud/apps
    nextcloud/custom_apps
)
permission_errors=0
for permission_path in "${permission_paths[@]}"; do
    if [[ ! -e $permission_path ]]; then
        continue
    fi
    if [[ ! -d $permission_path ]]; then
        error "Permisos: $permission_path existe pero no es un directorio"
        ((permission_errors += 1))
        continue
    fi
    if command -v stat >/dev/null 2>&1; then
        path_mode=$(stat -c '%a' "$permission_path" 2>/dev/null || true)
        if [[ $path_mode =~ ^[0-7]+$ ]] && (( (8#$path_mode & 005) != 005 )); then
            error "Permisos: $permission_path tiene modo $path_mode; Nginx necesita lectura/traversal"
            ((permission_errors += 1))
        fi
    fi
done
if ((permission_errors == 0)); then
    ok 'Bind mounts web con permisos de directorio compatibles'
fi

if ! command -v docker >/dev/null 2>&1; then
    error 'Docker: comando no disponible'
elif run_timeout 15 docker info >/dev/null 2>&1; then
    ok 'Docker daemon accesible'
    docker_ready=true
else
    error 'Docker: daemon no disponible o acceso denegado'
fi

if command -v docker >/dev/null 2>&1 && run_timeout 15 docker compose version >/dev/null 2>&1; then
    ok 'Docker Compose V2 disponible'
    compose_ready=true
else
    error 'Docker Compose: plugin docker compose no disponible'
fi

if [[ $compose_ready == true ]]; then
    if run_timeout 30 "${compose[@]}" config --quiet >/dev/null 2>&1 \
        && services_output=$(run_timeout 30 "${compose[@]}" config --services 2>/dev/null) \
        && [[ -n $services_output ]]; then
        mapfile -t services <<< "$services_output"
        config_valid=true
        ok 'Docker Compose efectivo válido'
    else
        error 'Docker Compose: la configuración efectiva no es válida'
    fi
fi

if [[ $config_valid == true ]]; then
    missing_services=0
    for required_service in db redis app web proxy; do
        if ! has_service "$required_service"; then
            error "Compose: falta el servicio público requerido $required_service"
            ((missing_services += 1))
        fi
    done
    ((missing_services == 0)) && ok 'Servicios base requeridos presentes'
    if has_service onlyoffice; then
        ok 'Perfil OnlyOffice activo'
    else
        ok 'Perfil OnlyOffice no activo'
    fi

    if has_service cron; then
        error 'Compose define un servicio cron adicional; el mecanismo público único es Supervisor en app'
    elif [[ $(grep -Ec '^[[:space:]]*command=/cron\.sh[[:space:]]*$' supervisord.conf 2>/dev/null || true) == 1 ]] \
        && grep -Eq '^CMD \["/usr/bin/supervisord", "-c", "/supervisord.conf"\]$' Dockerfile 2>/dev/null; then
        ok 'Cron único mediante Supervisor'
    else
        error 'Cron: Dockerfile y supervisord.conf no describen un único /cron.sh'
    fi

    if images_output=$(run_timeout 30 "${compose[@]}" config --images 2>/dev/null); then
        floating_images=0
        while IFS= read -r image_ref; do
            [[ -n $image_ref ]] || continue
            image_tail=${image_ref##*/}
            if [[ $image_ref != *@sha256:* && $image_tail != *:* ]] \
                || [[ $image_ref == *:latest || $image_ref == *:stable || $image_ref == *:production || $image_ref == *:alpine ]]; then
                ((floating_images += 1))
            fi
        done <<< "$images_output"
        if ((floating_images == 0)); then
            ok 'Imágenes efectivas con tags o digests explícitos'
        else
            error "$floating_images imágenes efectivas usan referencias flotantes o sin tag"
        fi
    else
        error 'Compose: no se pudieron resolver las imágenes efectivas'
    fi

    if command -v jq >/dev/null 2>&1 \
        && config_json=$(run_timeout 30 "${compose[@]}" config --format json 2>/dev/null); then
        if jq -e '
            (.networks.backend.internal == true)
            and ((.services.db.networks | keys) == ["backend"])
            and ((.services.redis.networks | keys) == ["backend"])
            and (.services.app.networks | has("backend") and has("app-tier"))
            and (.services.web.networks | has("app-tier") and has("proxy-tier"))
            and ((.services.proxy.networks | keys) == ["proxy-tier"])
            and ((.services | has("onlyoffice") | not) or ((.services.onlyoffice.networks | keys) == ["app-tier"]))
        ' >/dev/null <<< "$config_json"; then
            ok 'Redes públicas segmentadas'
        else
            error 'Compose: la segmentación backend/app-tier/proxy-tier no coincide con la base pública'
        fi

        if jq -e '((.services.db.ports // []) | length == 0) and ((.services.redis.ports // []) | length == 0)' \
            >/dev/null <<< "$config_json"; then
            ok 'MariaDB y Redis sin puertos publicados'
        else
            warn 'El Compose efectivo publica MariaDB o Redis; restrinja el bind y justifique el override'
        fi

        if jq -e '
            .services.redis.environment.REDIS_PASSWORD
            | type == "string" and test("^[0-9A-Fa-f]{64,}$")
        ' >/dev/null <<< "$config_json"; then
            ok 'Redis tiene un secreto no trivial'
        else
            error 'Redis tiene un secreto ausente, corto o inválido'
        fi

        if jq -e '.services | has("onlyoffice")' >/dev/null <<< "$config_json"; then
            if jq -e '
                .services.onlyoffice.environment.JWT_SECRET
                | type == "string" and test("^[0-9A-Fa-f]{64,}$")
            ' >/dev/null <<< "$config_json"; then
                ok 'JWT de OnlyOffice válido en el Compose efectivo'
            else
                error 'Perfil OnlyOffice activo con JWT ausente, corto o inválido'
            fi
        fi

        mapfile -t external_networks < <(jq -r '.networks[] | select(.external == true) | .name' <<< "$config_json")
        unset config_json
    else
        warn 'jq no está disponible; se omiten comprobaciones estructurales avanzadas'
        external_networks=()
    fi
fi

if [[ $config_valid == true && $docker_ready == true ]]; then
    if ((${#external_networks[@]} == 0)); then
        ok 'Compose no requiere redes externas'
    else
        for network_name in "${external_networks[@]}"; do
            if run_timeout 10 docker network inspect -- "$network_name" >/dev/null 2>&1; then
                ok "Red externa $network_name"
            else
                error "Red externa $network_name: no existe"
            fi
        done
    fi

    for service in "${services[@]}"; do
        if ! container_ids=$(run_timeout 15 "${compose[@]}" ps --all --quiet "$service" 2>/dev/null); then
            service_state["$service"]=unknown
            error "Contenedor $service: no se pudo consultar"
            continue
        fi
        mapfile -t ids <<< "$container_ids"
        if [[ -z ${container_ids:-} ]]; then
            service_state["$service"]=missing
            error "Contenedor $service: no creado para este proyecto"
            continue
        elif ((${#ids[@]} != 1)); then
            service_state["$service"]=ambiguous
            error "Contenedor $service: se encontraron ${#ids[@]} instancias; se esperaba una"
            continue
        fi

        if ! metadata=$(run_timeout 10 docker inspect \
            --format '{{.State.Status}}|{{.State.ExitCode}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
            -- "${ids[0]}" 2>/dev/null); then
            service_state["$service"]=unknown
            error "Contenedor $service: docker inspect falló"
            continue
        fi
        IFS='|' read -r state exit_code health <<< "$metadata"
        service_state["$service"]=${state:-unknown}
        if [[ $state != running ]]; then
            error "Contenedor $service: ${state:-desconocido} (exit ${exit_code:-?})"
        elif [[ $health == unhealthy ]]; then
            error "Contenedor $service: running, health=unhealthy"
        elif [[ $health == starting ]]; then
            warn "Contenedor $service: running, health=starting"
        elif [[ $health == healthy ]]; then
            ok "Contenedor $service: running, health=healthy"
        else
            ok "Contenedor $service: running (sin healthcheck)"
        fi
    done
fi

if [[ $config_valid == true && $docker_ready == true ]]; then
    if is_running db && run_timeout 15 "${compose[@]}" exec -T db \
        healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1; then
        ok 'MariaDB responde'
    else
        error 'MariaDB: servicio detenido o sonda fallida'
    fi

    if is_running db; then
        if run_timeout 15 "${compose[@]}" exec -T db sh -ec \
            'mariadb -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" -e "SELECT 1" >/dev/null' \
            >/dev/null 2>&1; then
            ok 'MariaDB acepta MYSQL_USER/MYSQL_PASSWORD actuales'
        else
            error 'MariaDB rechaza las credenciales actuales; el datadir puede haber sido inicializado con otro .env'
        fi
    fi

    if is_running app; then
        if occ_status=$(run_timeout 20 "${compose[@]}" exec -T --user www-data app \
            php occ status --output=json --no-ansi --no-interaction 2>/dev/null); then
            if grep -Eq '"installed"[[:space:]]*:[[:space:]]*true' <<< "$occ_status"; then
                ok 'occ status'
            else
                warn 'occ status responde, pero Nextcloud no figura como instalado'
            fi
            grep -Eq '"maintenance"[[:space:]]*:[[:space:]]*true' <<< "$occ_status" \
                && warn 'Nextcloud está en modo mantenimiento'
            grep -Eq '"needsDbUpgrade"[[:space:]]*:[[:space:]]*true' <<< "$occ_status" \
                && warn 'Nextcloud informa una actualización de base pendiente'
        else
            error 'occ status: no se pudo ejecutar'
        fi
    else
        error 'Nextcloud: servicio app no está en ejecución'
    fi

    if is_running web && run_timeout 15 "${compose[@]}" exec -T web nginx -t >/dev/null 2>&1; then
        ok 'Nginx de Nextcloud'
    else
        error 'Nginx de Nextcloud: detenido o configuración inválida'
    fi

    if is_running web; then
        if run_timeout 15 "${compose[@]}" exec -T web sh -ec \
            'test -r /var/www/html/index.php && test -r /var/www/html/status.php && test -x /var/www/html/apps && test -x /var/www/html/custom_apps' \
            >/dev/null 2>&1; then
            ok 'Nginx puede leer core y atravesar directorios de apps'
        else
            error 'Nginx no puede leer core/apps; revise permisos de nextcloud/page/web, nextcloud/apps y nextcloud/custom_apps'
        fi
    fi

    if is_running proxy && run_timeout 15 "${compose[@]}" exec -T proxy nginx -t >/dev/null 2>&1; then
        ok 'nginx-proxy'
    else
        error 'nginx-proxy: detenido o configuración inválida'
    fi

    if is_running app && is_running web && nextcloud_status=$(run_timeout 15 "${compose[@]}" exec -T app php -r '
        $context = stream_context_create(["http" => ["timeout" => 5, "ignore_errors" => true]]);
        $body = @file_get_contents("http://web/status.php", false, $context);
        $status = $http_response_header[0] ?? "";
        $data = json_decode((string)$body, true);
        if ($body === false || !preg_match("~^HTTP/\\S+\\s+200(?:\\s|$)~", $status)
            || !is_array($data) || !array_key_exists("installed", $data)) { exit(1); }
        echo json_encode(["installed" => (bool)$data["installed"]]);
    ' 2>/dev/null) && grep -Eq '"installed"[[:space:]]*:[[:space:]]*true' <<< "$nextcloud_status"; then
        ok 'Nextcloud status.php interno'
    else
        error 'Nextcloud: web/status.php interno no responde correctamente'
    fi

    if is_running redis; then
        redis_result=$(run_timeout 10 "${compose[@]}" exec -T redis sh -ec \
            'export REDISCLI_AUTH="$REDIS_PASSWORD"; exec redis-cli ping' 2>/dev/null || true)
        redis_result=${redis_result//$'\r'/}
        redis_result=${redis_result//$'\n'/}
        [[ $redis_result == PONG ]] && ok 'Redis' || error 'Redis: no responde PONG'
    else
        error 'Redis: servicio detenido'
    fi

    if is_running onlyoffice && run_timeout 20 "${compose[@]}" exec -T onlyoffice \
        curl -fsS --max-time 8 http://127.0.0.1:8000/info/info.json >/dev/null 2>&1; then
        ok 'OnlyOffice'
    else
        error 'OnlyOffice: servicio detenido o healthcheck fallido'
    fi
fi

if disk_line=$(df -Pk "$project_dir" 2>/dev/null | awk 'NR == 2 { print $4 "|" $5 }'); then
    available_kb=${disk_line%%|*}
    used_percent=${disk_line##*|}
    used_percent=${used_percent%%%}
    available_human=$(df -hP "$project_dir" 2>/dev/null | awk 'NR == 2 { print $4 }')
    if [[ $used_percent =~ ^[0-9]+$ ]] && ((used_percent >= 90)); then
        error "Filesystem: ${available_human:-?} libres, $used_percent% usado"
    elif [[ $used_percent =~ ^[0-9]+$ ]] && ((used_percent >= 80)); then
        warn "Filesystem: ${available_human:-?} libres, $used_percent% usado"
    elif [[ $available_kb =~ ^[0-9]+$ ]]; then
        ok "Filesystem: ${available_human:-?} libres, ${used_percent:-?}% usado"
    else
        warn 'Filesystem: no se pudo interpretar el espacio disponible'
    fi
else
    error 'Filesystem: no se pudo consultar el espacio disponible'
fi

if ((error_count > 0)); then
    printf '[ERROR] Resumen: %d OK, %d WARN, %d ERROR\n' \
        "$ok_count" "$warn_count" "$error_count"
    exit 1
fi

printf '[OK] Resumen: %d OK, %d WARN, 0 ERROR\n' "$ok_count" "$warn_count"
