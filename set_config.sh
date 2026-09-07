#!/usr/bin/env bash

# Configura el conector OnlyOffice ya instalado. Este script modifica la
# configuración de Nextcloud; no instala aplicaciones ni despliega servicios.

set -Eeuo pipefail
IFS=$'\n\t'

usage() {
    cat <<'EOF'
Uso:
  bash set_config.sh --apply --public-url https://cloud.example.com \
    --allow-local-remote-servers

Opciones obligatorias:
  --apply                         Confirma que se aplicarán cambios vía occ.
  --public-url URL                URL HTTPS pública de Nextcloud, sin ruta.
  --allow-local-remote-servers    Acepta habilitar conexiones servidor-a-servidor
                                  a los nombres internos web y onlyoffice.

El conector OnlyOffice debe estar instalado y habilitado previamente. El JWT se
obtiene del Compose efectivo y nunca se imprime.
EOF
}

apply=false
allow_local=false
public_url=

while (($# > 0)); do
    case $1 in
        --apply)
            apply=true
            shift
            ;;
        --public-url)
            (($# >= 2)) || { printf 'Falta el valor de --public-url\n' >&2; exit 2; }
            public_url=$2
            shift 2
            ;;
        --allow-local-remote-servers)
            allow_local=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Opción desconocida: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ $apply != true || $allow_local != true || -z $public_url ]]; then
    usage >&2
    exit 2
fi

if [[ ! $public_url =~ ^https://[^/?#[:space:]]+/?$ ]]; then
    printf 'La URL pública debe ser HTTPS, contener solo el host y no incluir ruta, query ni fragmento.\n' >&2
    exit 2
fi
public_url=${public_url%/}

for command_name in docker jq; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'Comando requerido no disponible: %s\n' "$command_name" >&2
        exit 2
    }
done

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
cd -- "$script_dir"
compose=(docker compose --project-directory "$script_dir")

"${compose[@]}" version >/dev/null
"${compose[@]}" config --quiet

config_json=$("${compose[@]}" config --format json)
for service in app web onlyoffice; do
    if ! jq -e --arg service "$service" '.services | has($service)' \
        >/dev/null <<< "$config_json"; then
        printf 'El Compose efectivo no define el servicio requerido: %s\n' "$service" >&2
        exit 2
    fi
done

jwt_secret=$(jq -er '
    .services.onlyoffice.environment.JWT_SECRET
    | select(type == "string" and length >= 32)
    | select(startswith("CHANGE_ME") | not)
' <<< "$config_json") || {
    printf 'JWT de OnlyOffice ausente, de ejemplo o demasiado corto en el Compose efectivo.\n' >&2
    exit 2
}
trap 'unset jwt_secret' EXIT
unset config_json

occ=("${compose[@]}" exec -T --user www-data app php occ --no-ansi --no-interaction)
if ! enabled_apps=$("${occ[@]}" app:list --enabled --output=json 2>/dev/null) \
    || ! grep -Eq '"onlyoffice"[[:space:]]*:' <<< "$enabled_apps"; then
    printf 'La app onlyoffice no está instalada y habilitada; instálela y revísela antes de ejecutar este script.\n' >&2
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
    "${occ[@]}" config:system:set trusted_domains "${#trusted_domains[@]}" --value=web
fi
unset trusted_output trusted_domains trusted_domain

"${occ[@]}" config:app:set onlyoffice DocumentServerUrl \
    --value="${public_url}/ds-vpath/"
"${occ[@]}" config:app:set onlyoffice DocumentServerInternalUrl \
    --value="http://onlyoffice/"
"${occ[@]}" config:app:set onlyoffice StorageUrl \
    --value="http://web/"
"${occ[@]}" config:app:set onlyoffice jwt_header \
    --value="AuthorizationJwt"

# El valor vive en el entorno del cliente y se reenvía indicando solo su nombre:
# no forma parte del argv local ni se muestra en stdout.
ONLYOFFICE_CONFIG_JWT=$jwt_secret "${compose[@]}" exec -T --user www-data \
    -e ONLYOFFICE_CONFIG_JWT app sh -ec \
    'exec php occ --no-ansi --no-interaction config:app:set onlyoffice jwt_secret --sensitive --value="$ONLYOFFICE_CONFIG_JWT"'
unset jwt_secret
trap - EXIT

"${occ[@]}" config:system:set allow_local_remote_servers \
    --type=boolean --value=true

printf '%s\n' 'Configuración de OnlyOffice aplicada. Compruebe el editor extremo a extremo y revise los logs.'
