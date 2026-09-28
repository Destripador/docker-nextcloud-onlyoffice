#!/usr/bin/env bash

# Instala/habilita y configura el conector OnlyOffice para este stack.
# Modifica la configuración de Nextcloud mediante occ. No imprime el JWT.

set -Eeuo pipefail
IFS=$'\n\t'

apply=false
allow_local=false
install_app=false
public_url=

usage() {
    cat <<'EOF'
Uso:
  bash set_config.sh --apply --public-url https://cloud.example.com \
    --allow-local-remote-servers [--install-app]

Opciones obligatorias:
  --apply
  --public-url URL
  --allow-local-remote-servers

Opcional:
  --install-app   Instala la app ONLYOFFICE desde la App Store si falta y la
                  habilita antes de configurar el conector.

La URL puede ser HTTP para desarrollo local o HTTPS para despliegues públicos.
El perfil Compose "onlyoffice" debe estar activo y sus contenedores en ejecución.
EOF
}

while (($# > 0)); do
    case $1 in
        --apply) apply=true ;;
        --public-url)
            (($# >= 2)) || { printf 'Falta el valor de --public-url\n' >&2; exit 2; }
            public_url=$2
            shift
            ;;
        --allow-local-remote-servers) allow_local=true ;;
        --install-app) install_app=true ;;
        -h|--help) usage; exit 0 ;;
        *)
            printf 'Opción desconocida: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

if [[ $apply != true || $allow_local != true || -z $public_url ]]; then
    usage >&2
    exit 2
fi

if [[ ! $public_url =~ ^https?://[^/?#[:space:]]+/?$ ]]; then
    printf 'La URL pública debe ser HTTP/HTTPS, contener solo el host y no incluir ruta, query ni fragmento.\n' >&2
    exit 2
fi
public_url=${public_url%/}

command -v docker >/dev/null 2>&1 || {
    printf 'Docker no está disponible.\n' >&2
    exit 2
}

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
cd -- "$script_dir"
compose=(docker compose --project-directory "$script_dir" -f "$script_dir/compose.yaml")

"${compose[@]}" version >/dev/null
"${compose[@]}" config --quiet

services=$("${compose[@]}" config --services)
for service in app web onlyoffice; do
    if ! grep -qx "$service" <<< "$services"; then
        if [[ $service == onlyoffice ]]; then
            printf '%s\n' 'OnlyOffice está deshabilitado. Active el perfil "onlyoffice" en COMPOSE_PROFILES y vuelva a levantar el stack.' >&2
        else
            printf 'El Compose efectivo no define el servicio requerido: %s\n' "$service" >&2
        fi
        exit 2
    fi
done
unset services

for service in app web onlyoffice; do
    if [[ -z $("${compose[@]}" ps --status running --quiet "$service" 2>/dev/null) ]]; then
        printf 'El servicio requerido no está en ejecución: %s\n' "$service" >&2
        exit 1
    fi
done

jwt_secret=$("${compose[@]}" exec -T onlyoffice sh -ec 'printf %s "$JWT_SECRET"' 2>/dev/null || true)
if [[ ! $jwt_secret =~ ^[0-9A-Fa-f]{64,}$ ]]; then
    printf 'JWT de OnlyOffice ausente, corto o inválido dentro de Document Server.\n' >&2
    exit 1
fi
trap 'unset jwt_secret' EXIT

occ=("${compose[@]}" exec -T --user www-data app php occ --no-ansi --no-interaction)

if ! apps_json=$("${occ[@]}" app:list --output=json 2>/dev/null); then
    printf 'No se pudo consultar la lista de apps de Nextcloud.\n' >&2
    exit 1
fi

if grep -Eq '"onlyoffice"[[:space:]]*:' <<< "$apps_json"; then
    "${occ[@]}" app:enable onlyoffice >/dev/null
elif [[ $install_app == true ]]; then
    printf '%s\n' 'Instalando la app ONLYOFFICE en Nextcloud...'
    "${occ[@]}" app:install onlyoffice >/dev/null
else
    printf '%s\n' 'La app ONLYOFFICE no está instalada. Ejecute de nuevo con --install-app.' >&2
    exit 1
fi
unset apps_json

if ! enabled_apps=$("${occ[@]}" app:list --enabled --output=json 2>/dev/null) \
    || ! grep -Eq '"onlyoffice"[[:space:]]*:' <<< "$enabled_apps"; then
    printf 'La app ONLYOFFICE no quedó habilitada.\n' >&2
    exit 1
fi
unset enabled_apps

if ! trusted_output=$("${occ[@]}" config:system:get trusted_domains 2>/dev/null); then
    printf 'No se pudo consultar trusted_domains.\n' >&2
    exit 1
fi
trusted_domains=()
[[ -z $trusted_output ]] || mapfile -t trusted_domains <<< "$trusted_output"
trusted_web=false
for trusted_domain in "${trusted_domains[@]}"; do
    [[ $trusted_domain == web ]] && trusted_web=true
done
if [[ $trusted_web != true ]]; then
    "${occ[@]}" config:system:set trusted_domains "${#trusted_domains[@]}" --value=web >/dev/null
fi
unset trusted_output trusted_domains trusted_domain

"${occ[@]}" config:app:set onlyoffice DocumentServerUrl \
    --value="${public_url}/ds-vpath/" >/dev/null
"${occ[@]}" config:app:set onlyoffice DocumentServerInternalUrl \
    --value="http://onlyoffice/" >/dev/null
"${occ[@]}" config:app:set onlyoffice StorageUrl \
    --value="http://web/" >/dev/null
"${occ[@]}" config:app:set onlyoffice jwt_header \
    --value="AuthorizationJwt" >/dev/null

ONLYOFFICE_CONFIG_JWT=$jwt_secret "${compose[@]}" exec -T --user www-data \
    -e ONLYOFFICE_CONFIG_JWT app sh -ec \
    'exec php occ --no-ansi --no-interaction config:app:set onlyoffice jwt_secret --sensitive --value="$ONLYOFFICE_CONFIG_JWT" >/dev/null'
unset jwt_secret
trap - EXIT

"${occ[@]}" config:system:set allow_local_remote_servers \
    --type=boolean --value=true >/dev/null

printf '%s\n' 'OnlyOffice quedó instalado, habilitado y configurado.'
