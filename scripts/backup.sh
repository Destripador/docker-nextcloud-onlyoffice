#!/usr/bin/env bash
if ((BASH_VERSINFO[0] < 4)); then
    printf '[ERROR] backup.sh requiere Bash 4 o superior\n' >&2
    exit 2
fi

set -Eeuo pipefail
IFS=$'\n\t'

root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$root"
compose=(docker compose --project-directory "$root" -f "$root/compose.yaml")

output=
while (($# > 0)); do
    case $1 in
        --output)
            (($# >= 2)) || { printf '[ERROR] Falta valor para --output\n' >&2; exit 2; }
            output=$2
            shift
            ;;
        -h|--help)
            cat <<'EOF'
Uso:
  bash scripts/backup.sh
  bash scripts/backup.sh --output /ruta/de/backups
EOF
            exit 0
            ;;
        *)
            printf '[ERROR] Opción desconocida: %s\n' "$1" >&2
            exit 2
            ;;
    esac
    shift
done

[[ -f .env ]] || { printf '[ERROR] Falta .env\n' >&2; exit 1; }
for cmd in docker tar gzip sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || { printf '[ERROR] Falta %s\n' "$cmd" >&2; exit 1; }
done
"${compose[@]}" config --quiet >/dev/null

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
[[ -n $output ]] || output="$root/backups"
mkdir -p "$output"
backup_dir="$output/nextcloud-$timestamp"
mkdir -p "$backup_dir"
chmod 700 "$backup_dir"

maintenance_enabled=false
declare -a stopped_services=()

cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM
    if ((${#stopped_services[@]} > 0)); then
        printf '[INFO] Restaurando servicios detenidos...\n'
        "${compose[@]}" start "${stopped_services[@]}" >/dev/null 2>&1 || true
    fi
    if [[ $maintenance_enabled == true ]]; then
        for _ in {1..20}; do
            if "${compose[@]}" exec -T --user www-data app php occ maintenance:mode --off >/dev/null 2>&1; then
                break
            fi
            sleep 2
        done
    fi
    if ((exit_code != 0)); then
        rm -f "$backup_dir"/*.part 2>/dev/null || true
        printf '[ERROR] Backup incompleto: %s\n' "$backup_dir" >&2
    fi
    exit "$exit_code"
}
trap cleanup EXIT INT TERM

printf '[INFO] Verificando servicios...\n'
for required in db app; do
    [[ -n $("${compose[@]}" ps --status running --quiet "$required" 2>/dev/null) ]] || {
        printf '[ERROR] El servicio %s debe estar en ejecución\n' "$required" >&2
        exit 1
    }
done

app_container=$("${compose[@]}" ps --all --quiet app 2>/dev/null | head -n 1)
[[ -n $app_container ]] || {
    printf '[ERROR] No se pudo localizar el contenedor app para preparar el archivado\n' >&2
    exit 1
}
app_image_id=$(docker inspect --format '{{.Image}}' "$app_container" 2>/dev/null || true)
[[ -n $app_image_id ]] || {
    printf '[ERROR] No se pudo resolver la imagen local de app\n' >&2
    exit 1
}

printf '[INFO] Guardando metadatos...\n'
"${compose[@]}" config --services > "$backup_dir/services.txt"
"${compose[@]}" config --images > "$backup_dir/images.txt"
"${compose[@]}" ps -a > "$backup_dir/ps.txt"
cp -p .env "$backup_dir/env"
chmod 600 "$backup_dir/env"
cp -p compose.yaml Dockerfile supervisord.conf "$backup_dir/"
[[ ! -e compose.override.yaml ]] || cp -p compose.override.yaml "$backup_dir/"

printf '[INFO] Activando modo mantenimiento...\n'
"${compose[@]}" exec -T --user www-data app php occ maintenance:mode --on >/dev/null
maintenance_enabled=true

if [[ -n $("${compose[@]}" ps --status running --quiet redis 2>/dev/null) ]]; then
    "${compose[@]}" exec -T redis sh -ec \
        'export REDISCLI_AUTH="$REDIS_PASSWORD"; exec redis-cli SAVE' >/dev/null 2>&1 || true
fi

for service in web onlyoffice redis app; do
    if [[ -n $("${compose[@]}" ps --status running --quiet "$service" 2>/dev/null) ]]; then
        stopped_services+=("$service")
    fi
done

if ((${#stopped_services[@]} > 0)); then
    printf '[INFO] Pausando servicios que escriben datos...\n'
    "${compose[@]}" stop "${stopped_services[@]}" >/dev/null
fi

printf '[INFO] Exportando MariaDB...\n'
"${compose[@]}" exec -T db sh -ec '
    export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
    exec mariadb-dump \
      --user=root \
      --single-transaction \
      --quick \
      --skip-lock-tables \
      --routines \
      --events \
      --triggers \
      --hex-blob \
      --default-character-set=utf8mb4 \
      --databases "$MYSQL_DATABASE"
' | gzip -1 > "$backup_dir/nextcloud.sql.gz.part"

gzip -t "$backup_dir/nextcloud.sql.gz.part"
mv "$backup_dir/nextcloud.sql.gz.part" "$backup_dir/nextcloud.sql.gz"

printf '[INFO] Archivando archivos persistentes...\n'
paths=()
for path in data nextcloud config/redis config/onlyoffice config/proxy config/acme; do
    [[ -e $path ]] && paths+=("$path")
done
((${#paths[@]} > 0)) || { printf '[ERROR] No hay rutas persistentes\n' >&2; exit 1; }

# Algunos bind mounts contienen archivos que el usuario del host no puede leer.
# Se archivan desde un contenedor efímero como root, sin cambiar permisos.
docker run --rm --user 0 \
    --entrypoint sh \
    -v "$root:/source:ro" \
    -v "$backup_dir:/backup" \
    -w /source \
    "$app_image_id" \
    -ec 'exec tar -cpf /backup/files.tar.part "$@"' sh "${paths[@]}"

[[ -s "$backup_dir/files.tar.part" ]] || {
    printf '[ERROR] El archivo de persistencia quedó vacío\n' >&2
    exit 1
}
mv "$backup_dir/files.tar.part" "$backup_dir/files.tar"

printf '[INFO] Generando manifiesto SHA-256...\n'
(
    cd "$backup_dir"
    find . -maxdepth 1 -type f ! -name SHA256SUMS -print0 \
      | sort -z \
      | xargs -0 sha256sum > SHA256SUMS
    sha256sum --check --strict SHA256SUMS >/dev/null
)

trap - EXIT INT TERM
if ((${#stopped_services[@]} > 0)); then
    "${compose[@]}" start "${stopped_services[@]}" >/dev/null
fi
if [[ $maintenance_enabled == true ]]; then
    for _ in {1..20}; do
        if "${compose[@]}" exec -T --user www-data app php occ maintenance:mode --off >/dev/null 2>&1; then
            maintenance_enabled=false
            break
        fi
        sleep 2
    done
fi

if [[ $maintenance_enabled == true ]]; then
    printf '[WARN] Backup creado, pero Nextcloud quedó en modo mantenimiento.\n' >&2
    exit 1
fi

printf '\n[OK] Backup completado\n'
printf 'Ruta: %s\n' "$backup_dir"
