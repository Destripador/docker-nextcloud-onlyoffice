#!/usr/bin/env bash

# Validaciones estáticas/locales usadas también por GitHub Actions.
# No inicia contenedores ni modifica la instalación.

if ((BASH_VERSINFO[0] < 4)); then
    printf '[ERROR] ci.sh requiere Bash 4 o superior\n' >&2
    exit 2
fi

set -Eeuo pipefail
IFS=$'\n\t'

root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$root"

ok() { printf '[OK] %s\n' "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

printf 'Validación CI local\n===================\n'

scripts=(
    install.sh
    manage.sh
    set_config.sh
    scripts/preflight.sh
    scripts/doctor.sh
    scripts/backup.sh
    scripts/restore.sh
    scripts/update.sh
    scripts/ci.sh
)

for script in "${scripts[@]}"; do
    [[ -f $script ]] || die "Falta script esperado: $script"
    bash -n "$script"
done
ok 'Sintaxis Bash'

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck --severity=error "${scripts[@]}"
    ok 'ShellCheck sin errores'
else
    printf '[WARN] shellcheck no está instalado; se omite esta comprobación local.\n'
fi

required_build_files=(
    Dockerfile
    supervisord.conf
    config/php-fpm/zz-nextcloud.conf
)
for file in "${required_build_files[@]}"; do
    [[ -r $file ]] || die "Falta archivo requerido por el build: $file"
done

grep -qx '!config/php-fpm/zz-nextcloud.conf' .dockerignore     || die '.dockerignore no incluye config/php-fpm/zz-nextcloud.conf'
ok 'Contexto de build requerido presente'

if [[ -e docker-compose.yml ]]; then
    if [[ -L docker-compose.yml ]]; then
        [[ $(readlink docker-compose.yml) == compose.yaml ]] || die 'docker-compose.yml debe apuntar a compose.yaml'
    else
        cmp -s compose.yaml docker-compose.yml || die 'docker-compose.yml diverge de compose.yaml'
    fi
    ok 'Compose legado no diverge de compose.yaml'
fi

bash manage.sh --help >/dev/null
ok 'Ayuda de manage.sh disponible sin runtime'

command -v docker >/dev/null 2>&1 || die 'Docker no está disponible'
docker compose version >/dev/null 2>&1 || die 'Docker Compose V2 no está disponible'

tmp_env=$(mktemp)
trap 'rm -f "$tmp_env"' EXIT
cp .env.example "$tmp_env"

set_env() {
    local key=$1 value=$2 tmp
    tmp=$(mktemp)
    awk -v key="$key" -v value="$value" '
        BEGIN { found=0 }
        $0 ~ "^[[:space:]]*" key "=" {
            print key "=" value
            found=1
            next
        }
        { print }
        END { if (!found) print key "=" value }
    ' "$tmp_env" > "$tmp"
    cat "$tmp" > "$tmp_env"
    rm -f "$tmp"
}

set_env MYSQL_PASSWORD 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
set_env MYSQL_ROOT_PASSWORD abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789
set_env NEXTCLOUD_ADMIN_PASSWORD ci-only-password
set_env REDIS_PASSWORD 1111111111111111111111111111111111111111111111111111111111111111
set_env ONLYOFFICE_JWT_SECRET 2222222222222222222222222222222222222222222222222222222222222222
set_env NEXTCLOUD_DOMAIN localhost
set_env NEXTCLOUD_TRUSTED_DOMAINS localhost
set_env NEXTCLOUD_OVERWRITE_PROTOCOL http
set_env NEXTCLOUD_OVERWRITE_HOST localhost
set_env NEXTCLOUD_PUBLIC_URL http://localhost
set_env ACME_EMAIL ci@example.invalid
set_env MANAGER_ADMIN_PASSWORD ci-manager-password
set_env MANAGER_SECRET_KEY 3333333333333333333333333333333333333333333333333333333333333333
set_env MANAGER_ADMIN_USER admin
set_env MANAGER_BIND_ADDRESS 127.0.0.1
set_env MANAGER_PORT 8090
set_env MANAGER_PROJECT_HOST_PATH /tmp/nextcloud-ci

python -m py_compile manager/app.py manager/backup_job.py manager/update_job.py
ok 'Sintaxis Python del manager'

for profiles in '' onlyoffice acme manager onlyoffice,manager acme,onlyoffice,manager; do
    COMPOSE_PROFILES="$profiles" docker compose         --project-directory "$root"         --env-file "$tmp_env"         -f "$root/compose.yaml"         config --quiet
done
ok 'Compose válido para perfiles base, OnlyOffice, ACME y manager'

if command -v jq >/dev/null 2>&1; then
    config_json=$(COMPOSE_PROFILES=onlyoffice docker compose         --project-directory "$root"         --env-file "$tmp_env"         -f "$root/compose.yaml"         config --format json)

    jq -e '
      (.networks.backend.internal == true)
      and ((.services.db.ports // []) | length == 0)
      and ((.services.redis.ports // []) | length == 0)
      and (.services | has("onlyoffice"))
    ' >/dev/null <<< "$config_json"         || die 'La estructura de redes/servicios no cumple las invariantes CI'
    ok 'Invariantes estructurales del Compose'
else
    printf '[WARN] jq no está instalado; se omiten invariantes estructurales locales.\n'
fi

ok 'Validación CI completada'
