#!/usr/bin/env bash

if ((BASH_VERSINFO[0] < 4)); then
    printf '[ERROR] restore.sh requiere Bash 4 o superior\n' >&2
    exit 2
fi

set -Eeuo pipefail
IFS=$'\n\t'

root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$root"

backup_dir=
apply=false

usage() {
    cat <<'EOF'
Uso:
  bash scripts/restore.sh --from /ruta/nextcloud-AAAAMMDDTHHMMSSZ --apply

La restauración solo se ejecuta sobre rutas persistentes vacías.
Nunca borra datos existentes.
EOF
}

while (($# > 0)); do
    case $1 in
        --from)
            (($# >= 2)) || { printf '[ERROR] Falta valor para --from\n' >&2; exit 2; }
            backup_dir=$2
            shift
            ;;
        --apply)
            apply=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf '[ERROR] Opción desconocida: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

[[ $apply == true && -n $backup_dir ]] || { usage >&2; exit 2; }
backup_dir=$(CDPATH= cd -- "$backup_dir" 2>/dev/null && pwd -P) || {
    printf '[ERROR] No existe el directorio de backup\n' >&2
    exit 1
}

for file in env files.tar nextcloud.sql.gz SHA256SUMS; do
    [[ -f "$backup_dir/$file" ]] || {
        printf '[ERROR] Falta %s en el backup\n' "$file" >&2
        exit 1
    }
done

for cmd in docker tar gzip sha256sum awk; do
    command -v "$cmd" >/dev/null 2>&1 || { printf '[ERROR] Falta %s\n' "$cmd" >&2; exit 1; }
done

printf '[INFO] Verificando integridad del backup...\n'
(
    cd "$backup_dir"
    sha256sum --check --strict SHA256SUMS
)
gzip -t "$backup_dir/nextcloud.sql.gz"

if tar -tf "$backup_dir/files.tar" | awk '
    /^\// { bad=1 }
    /(^|\/)\.\.(\/|$)/ { bad=1 }
    END { exit bad ? 0 : 1 }
'; then
    printf '[ERROR] files.tar contiene rutas inseguras\n' >&2
    exit 1
fi

persistent_paths=(db data nextcloud config/redis config/onlyoffice config/proxy config/acme)
for path in "${persistent_paths[@]}"; do
    if [[ -d $path ]] && find "$path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
        printf '[ERROR] La ruta %s no está vacía. No se sobrescribirá nada.\n' "$path" >&2
        exit 1
    elif [[ -e $path && ! -d $path ]]; then
        printf '[ERROR] La ruta %s existe y no es directorio\n' "$path" >&2
        exit 1
    fi
done

if [[ -f .env ]]; then
    env_backup=".env.before-restore.$(date +%Y%m%d-%H%M%S)"
    cp -p .env "$env_backup"
    chmod 600 "$env_backup"
    printf '[INFO] Configuración actual guardada en %s\n' "$env_backup"
fi

umask 077
cp "$backup_dir/env" .env
chmod 600 .env
umask 022

compose=(docker compose --project-directory "$root" -f "$root/compose.yaml")
"${compose[@]}" config --quiet >/dev/null

if [[ -n $("${compose[@]}" ps --status running --quiet 2>/dev/null || true) ]]; then
    printf '[ERROR] Hay contenedores de este proyecto en ejecución. Deténgalos antes de restaurar.\n' >&2
    exit 1
fi

proxy_network=$(awk -F= '$1=="NGINX_PROXY_NETWORK" {print $2; exit}' .env)
proxy_network=${proxy_network:-nginx-proxy}
if ! docker network inspect "$proxy_network" >/dev/null 2>&1; then
    docker network create "$proxy_network" >/dev/null
fi

printf '[INFO] Restaurando archivos persistentes...\n'
tar --xattrs --acls -xpf "$backup_dir/files.tar" -C "$root"
mkdir -p db

printf '[INFO] Iniciando MariaDB vacía...\n'
"${compose[@]}" up -d db

db_ready=false
for _ in {1..60}; do
    if "${compose[@]}" exec -T db healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1; then
        db_ready=true
        break
    fi
    sleep 2
done
[[ $db_ready == true ]] || {
    printf '[ERROR] MariaDB no quedó lista para importar el dump\n' >&2
    exit 1
}

printf '[INFO] Importando MariaDB...\n'
gzip -dc "$backup_dir/nextcloud.sql.gz" | "${compose[@]}" exec -T db sh -ec '
    export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
    exec mariadb --user=root
'

printf '[INFO] Iniciando el stack restaurado...\n'
if "${compose[@]}" up --help 2>/dev/null | grep -q -- '--wait'; then
    "${compose[@]}" up -d --wait --wait-timeout 300
else
    "${compose[@]}" up -d
fi

printf '[INFO] Desactivando modo mantenimiento...\n'
for _ in {1..30}; do
    if "${compose[@]}" exec -T --user www-data app \
        php occ maintenance:mode --off >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

if ! "${compose[@]}" exec -T --user www-data app php occ status >/dev/null 2>&1; then
    printf '[WARN] Los datos fueron restaurados, pero occ status todavía no responde correctamente.\n' >&2
    printf '[WARN] Ejecute: bash scripts/doctor.sh\n' >&2
    exit 1
fi

printf '\n[OK] Restauración completada\n'
printf 'Ejecute ahora: bash scripts/doctor.sh\n'
