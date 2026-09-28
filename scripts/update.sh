#!/usr/bin/env bash

# Aplica las versiones ya definidas en .env con backup previo y validaciones.
# No cambia tags/versiones por sí solo.

if ((BASH_VERSINFO[0] < 4)); then
    printf '[ERROR] update.sh requiere Bash 4 o superior\n' >&2
    exit 2
fi

set -Eeuo pipefail
IFS=$'\n\t'

root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$root"
compose=(docker compose --project-directory "$root" -f "$root/compose.yaml")

apply=false
backup_output=

usage() {
    cat <<'EOF'
Uso:
  bash scripts/update.sh --apply
  bash scripts/update.sh --apply --backup-output /ruta/de/backups

Este script NO cambia versiones en .env. Aplica las referencias ya configuradas:
1. valida el stack;
2. crea un backup consistente;
3. activa mantenimiento;
4. descarga imágenes fijadas y reconstruye app;
5. recrea el stack;
6. ejecuta occ upgrade si es necesario;
7. desactiva mantenimiento;
8. ejecuta doctor.sh.
EOF
}

while (($# > 0)); do
    case $1 in
        --apply)
            apply=true
            ;;
        --backup-output)
            (($# >= 2)) || { printf '[ERROR] Falta valor para --backup-output\n' >&2; exit 2; }
            backup_output=$2
            shift
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

[[ $apply == true ]] || { usage >&2; exit 2; }
[[ -f .env ]] || { printf '[ERROR] Falta .env\n' >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { printf '[ERROR] Docker no está disponible\n' >&2; exit 1; }
"${compose[@]}" config --quiet >/dev/null

printf '[INFO] Ejecutando preflight...\n'
bash scripts/preflight.sh --quiet

for required_file in Dockerfile supervisord.conf config/php-fpm/zz-nextcloud.conf; do
    [[ -r $required_file ]] || {
        printf '[ERROR] Falta archivo requerido para construir app: %s\n' "$required_file" >&2
        exit 1
    }
done

printf '[INFO] Validando que el contexto Docker incluya la configuración PHP-FPM...\n'
if [[ -f .dockerignore ]] && ! grep -qx '!config/php-fpm/zz-nextcloud.conf' .dockerignore; then
    printf '[ERROR] .dockerignore excluye config/php-fpm/zz-nextcloud.conf del contexto de build\n' >&2
    exit 1
fi

printf '[INFO] Creando backup previo obligatorio...\n'
if [[ -n $backup_output ]]; then
    bash scripts/backup.sh --output "$backup_output"
else
    bash scripts/backup.sh
fi

maintenance_enabled=false
cleanup() {
    local code=$?
    trap - EXIT INT TERM
    if [[ $maintenance_enabled == true ]]; then
        printf '[INFO] Intentando desactivar modo mantenimiento...\n'
        for _ in {1..30}; do
            if "${compose[@]}" exec -T --user www-data app \
                php occ maintenance:mode --off >/dev/null 2>&1; then
                break
            fi
            sleep 2
        done
    fi
    if ((code != 0)); then
        printf '[ERROR] La actualización no terminó correctamente.\n' >&2
        printf '[ERROR] No se realizó rollback automático. Use el backup recién creado para recuperación.\n' >&2
    fi
    exit "$code"
}
trap cleanup EXIT INT TERM

printf '[INFO] Activando modo mantenimiento...\n'
"${compose[@]}" exec -T --user www-data app php occ maintenance:mode --on >/dev/null
maintenance_enabled=true

mapfile -t services < <("${compose[@]}" config --services)
pull_services=()
for service in "${services[@]}"; do
    [[ $service == app ]] && continue
    pull_services+=("$service")
done

if ((${#pull_services[@]} > 0)); then
    printf '[INFO] Descargando imágenes configuradas...\n'
    "${compose[@]}" pull "${pull_services[@]}"
fi

printf '[INFO] Reconstruyendo imagen Nextcloud con su base configurada...\n'
"${compose[@]}" build --pull app

printf '[INFO] Recreando stack...\n'
if "${compose[@]}" up --help 2>/dev/null | grep -q -- '--wait'; then
    "${compose[@]}" up -d --wait --wait-timeout 600
else
    "${compose[@]}" up -d
fi

printf '[INFO] Esperando a que Nextcloud responda por OCC...\n'
needs_upgrade=
occ_ready=false
for _ in {1..30}; do
    if needs_upgrade=$("${compose[@]}" exec -T --user www-data app \
        php occ status --output=json --no-ansi --no-interaction 2>/dev/null); then
        occ_ready=true
        break
    fi
    sleep 2
done

if [[ $occ_ready != true ]]; then
    printf '[ERROR] Nextcloud no respondió por OCC después de 60 segundos.\n' >&2
    exit 1
fi

if grep -Eq '"needsDbUpgrade"[[:space:]]*:[[:space:]]*true' <<< "$needs_upgrade"; then
    printf '[INFO] Nextcloud requiere actualización de base de datos; ejecutando occ upgrade...\n'
    "${compose[@]}" exec -T --user www-data app \
        php occ upgrade --no-ansi --no-interaction
fi

printf '[INFO] Desactivando modo mantenimiento...\n'
"${compose[@]}" exec -T --user www-data app php occ maintenance:mode --off >/dev/null
maintenance_enabled=false
trap - EXIT INT TERM

printf '[INFO] Ejecutando diagnóstico final...\n'
bash scripts/doctor.sh

printf '\n[OK] Actualización aplicada con las referencias actuales de .env\n'
printf '[INFO] Este flujo no modifica versiones por sí solo.\n'
