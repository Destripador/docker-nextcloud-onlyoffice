#!/usr/bin/env bash

# Instalador guiado para Nextcloud + componentes opcionales.
# Diseñado para instalaciones nuevas. No borra datos existentes.

if ((BASH_VERSINFO[0] < 4)); then
    printf '[ERROR] install.sh requiere Bash 4 o superior\n' >&2
    exit 2
fi

set -Eeuo pipefail
IFS=$'\n\t'

mode=
domain=
email=
admin_user=admin
admin_password=
timezone=
onlyoffice_choice=
dev_mode=false
no_start=false
force_config=false
generated_admin_password=false

usage() {
    cat <<'EOF'
Uso:
  bash install.sh
  bash install.sh --dev
  bash install.sh --dev-full
  bash install.sh --production --domain nube.example.com --email admin@example.com

Opciones:
  --dev                 Desarrollo local, HTTP, sin OnlyOffice.
  --dev-full            Desarrollo local, HTTP, con OnlyOffice.
  --production          Servidor público con HTTPS/ACME.
  --custom              Asistente personalizado.
  --domain HOST         Dominio o IP que usará Nextcloud.
  --email EMAIL         Correo para ACME.
  --admin-user USER     Usuario administrador inicial (default: admin).
  --admin-password PASS Contraseña inicial; si se omite se pregunta/genera.
  --timezone TZ         Zona horaria (default: detectada o UTC).
  --with-onlyoffice     Activa OnlyOffice.
  --without-onlyoffice  Desactiva OnlyOffice.
  --no-start            Prepara y valida, pero no construye/inicia contenedores.
  --force-config        Reemplaza .env existente guardando una copia .bak.
  -h, --help            Muestra esta ayuda.

El instalador no elimina db/, data/ ni otros datos persistentes.
EOF
}

while (($# > 0)); do
    case $1 in
        --dev) mode=dev ;;
        --dev-full) mode=dev-full ;;
        --production) mode=production ;;
        --custom) mode=custom ;;
        --domain)
            (($# >= 2)) || { printf '[ERROR] Falta valor para --domain\n' >&2; exit 2; }
            domain=$2; shift
            ;;
        --email)
            (($# >= 2)) || { printf '[ERROR] Falta valor para --email\n' >&2; exit 2; }
            email=$2; shift
            ;;
        --admin-user)
            (($# >= 2)) || { printf '[ERROR] Falta valor para --admin-user\n' >&2; exit 2; }
            admin_user=$2; shift
            ;;
        --admin-password)
            (($# >= 2)) || { printf '[ERROR] Falta valor para --admin-password\n' >&2; exit 2; }
            admin_password=$2; shift
            ;;
        --timezone)
            (($# >= 2)) || { printf '[ERROR] Falta valor para --timezone\n' >&2; exit 2; }
            timezone=$2; shift
            ;;
        --with-onlyoffice) onlyoffice_choice=yes ;;
        --without-onlyoffice) onlyoffice_choice=no ;;
        --no-start) no_start=true ;;
        --force-config) force_config=true ;;
        -h|--help) usage; exit 0 ;;
        *)
            printf '[ERROR] Opción desconocida: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
cd -- "$script_dir"
compose=(docker compose --project-directory "$script_dir" -f "$script_dir/compose.yaml")

say() { printf '%s\n' "$*"; }
ok() { printf '[OK] %s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

have_tty=false
[[ -t 0 && -t 1 ]] && have_tty=true

ask_yes_no() {
    local prompt=$1 default=$2 answer
    if [[ $have_tty != true ]]; then
        [[ $default == yes ]]
        return
    fi
    while true; do
        if [[ $default == yes ]]; then
            read -r -p "$prompt [S/n]: " answer
            answer=${answer:-s}
        else
            read -r -p "$prompt [s/N]: " answer
            answer=${answer:-n}
        fi
        case ${answer,,} in
            s|si|sí|y|yes) return 0 ;;
            n|no) return 1 ;;
        esac
    done
}

ask_value() {
    local prompt=$1 default=$2 value
    if [[ $have_tty != true ]]; then
        printf '%s' "$default"
        return
    fi
    if [[ -n $default ]]; then
        read -r -p "$prompt [$default]: " value
        printf '%s' "${value:-$default}"
    else
        read -r -p "$prompt: " value
        printf '%s' "$value"
    fi
}

set_env() {
    local key=$1 value=$2 file=.env tmp
    tmp=$(mktemp)
    awk -v key="$key" -v value="$value" '
        BEGIN { found=0 }
        $0 ~ "^[[:space:]]*" key "=" {
            print key "=" value
            found=1
            next
        }
        { print }
        END {
            if (!found) print key "=" value
        }
    ' "$file" > "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

env_value() {
    local key=$1 value
    [[ -f .env ]] || return 0
    value=$(awk -F= -v wanted="$key" '
        $0 !~ /^[[:space:]]*#/ && $1 ~ "^[[:space:]]*" wanted "[[:space:]]*$" {
            sub(/^[^=]*=/, "")
            print
            exit
        }
    ' .env 2>/dev/null || true)
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    printf '%s' "$value"
}

nonempty_dir() {
    local path=$1
    [[ -d $path ]] && find "$path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .
}

say 'Nextcloud Easy Installer'
say '========================'
say

for command_name in docker openssl awk mktemp; do
    command -v "$command_name" >/dev/null 2>&1 || die "Falta el comando requerido: $command_name"
done
docker info >/dev/null 2>&1 || die 'Docker está instalado, pero el daemon no está accesible.'
"${compose[@]}" version >/dev/null 2>&1 || die 'Se requiere Docker Compose V2.'

if [[ -z $mode ]]; then
    [[ $have_tty == true ]] || die 'En modo no interactivo use --dev, --dev-full, --production o --custom.'
    cat <<'EOF'
¿Cómo quieres usar Nextcloud?

  1) Desarrollo básico
     Nextcloud + MariaDB + Redis. Menor consumo.

  2) Desarrollo completo
     Igual que desarrollo básico + OnlyOffice.

  3) Servidor público
     Dominio + HTTPS automático. OnlyOffice opcional.

  4) Personalizado

EOF
    while true; do
        read -r -p 'Selecciona [1-4]: ' selection
        case $selection in
            1) mode=dev; break ;;
            2) mode=dev-full; break ;;
            3) mode=production; break ;;
            4) mode=custom; break ;;
        esac
    done
fi

case $mode in
    dev)
        domain=${domain:-localhost}
        protocol=http
        acme=false
        onlyoffice=false
        dev_mode=true
        ;;
    dev-full)
        domain=${domain:-localhost}
        protocol=http
        acme=false
        onlyoffice=true
        dev_mode=true
        ;;
    production)
        protocol=https
        acme=true
        dev_mode=false
        if [[ -z $domain ]]; then
            domain=$(ask_value 'Dominio público (ej. nube.example.com)' '')
        fi
        [[ -n $domain ]] || die 'El dominio es obligatorio para producción.'
        case $domain in
            localhost|127.0.0.1|::1) die 'Producción con ACME requiere un dominio público, no localhost.' ;;
        esac
        if [[ -z $email ]]; then
            email=$(ask_value 'Correo para certificados HTTPS' '')
        fi
        [[ -n $email ]] || die 'El correo ACME es obligatorio para producción.'
        if [[ -n $onlyoffice_choice ]]; then
            [[ $onlyoffice_choice == yes ]] && onlyoffice=true || onlyoffice=false
        elif ask_yes_no '¿Instalar OnlyOffice?' yes; then
            onlyoffice=true
        else
            onlyoffice=false
        fi
        ;;
    custom)
        [[ -n $domain ]] || domain=$(ask_value 'Dominio, IP o localhost' 'localhost')
        if ask_yes_no '¿Activar modo desarrollo (debug de Nextcloud y OPcache deshabilitado)?' no; then
            dev_mode=true
        else
            dev_mode=false
        fi
        if ask_yes_no '¿Usar HTTPS automático con ACME?' no; then
            acme=true
            protocol=https
            [[ -n $email ]] || email=$(ask_value 'Correo para certificados HTTPS' '')
            [[ -n $email ]] || die 'ACME requiere correo.'
        else
            acme=false
            protocol=$(ask_value 'Protocolo público (http/https)' 'http')
            [[ $protocol == http || $protocol == https ]] || die 'El protocolo debe ser http o https.'
        fi
        if [[ -n $onlyoffice_choice ]]; then
            [[ $onlyoffice_choice == yes ]] && onlyoffice=true || onlyoffice=false
        elif ask_yes_no '¿Instalar OnlyOffice?' no; then
            onlyoffice=true
        else
            onlyoffice=false
        fi
        ;;
    *) die "Modo desconocido: $mode" ;;
esac

existing_install=false
if nonempty_dir db || [[ -f nextcloud/config/config.php ]]; then
    existing_install=true
fi

if [[ $existing_install == true ]]; then
    [[ -f .env ]] || die 'Se detectó una instalación existente pero falta .env. No se modificará nada.'

    info 'Se detectó una instalación existente; no se tocarán MariaDB, datos ni credenciales.'

    if [[ $onlyoffice != true ]]; then
        if [[ $mode == production || $mode == custom ]]; then
            die 'La reconfiguración de dominio/HTTPS de una instalación existente no se automatiza todavía.'
        fi
        info 'No hay componentes nuevos que agregar para este modo.'
        if [[ -f scripts/doctor.sh ]]; then
            bash scripts/doctor.sh --quiet 2>/dev/null || true
        fi
        exit 0
    fi

    current_profiles=$(env_value COMPOSE_PROFILES)
    if [[ ,$current_profiles, == *,onlyoffice,* ]]; then
        info 'OnlyOffice ya está habilitado en COMPOSE_PROFILES.'
    else
        backup=".env.bak.$(date +%Y%m%d-%H%M%S)"
        cp .env "$backup"
        chmod 600 "$backup"
        warn "Se guardó la configuración actual en $backup"

        if [[ -z $current_profiles ]]; then
            set_env COMPOSE_PROFILES onlyoffice
        else
            set_env COMPOSE_PROFILES "$current_profiles,onlyoffice"
        fi

        current_jwt=$(env_value ONLYOFFICE_JWT_SECRET)
        if [[ ! $current_jwt =~ ^[0-9A-Fa-f]{64,}$ ]]; then
            set_env ONLYOFFICE_JWT_SECRET "$(openssl rand -hex 32)"
        fi
        unset current_jwt
    fi
    unset current_profiles

    mkdir -p \
        config/onlyoffice/document_data \
        config/onlyoffice/document_log \
        config/onlyoffice/document_cache \
        config/onlyoffice/example_files \
        config/onlyoffice/fonts

    info 'Validando la instalación existente con el nuevo perfil...'
    preflight_log=$(mktemp)
    if bash scripts/preflight.sh --quiet >"$preflight_log" 2>&1; then
        ok 'Preflight superado.'
        rm -f "$preflight_log"
    else
        printf '\n'
        cat "$preflight_log"
        rm -f "$preflight_log"
        die 'El preflight encontró errores. No se modificaron los datos persistentes.'
    fi

    if [[ $no_start == true ]]; then
        ok 'OnlyOffice quedó preparado en la configuración (--no-start).'
        exit 0
    fi

    info 'Asegurando el stack base y OnlyOffice en ejecución...'
    if "${compose[@]}" up --help 2>/dev/null | grep -q -- '--wait'; then
        "${compose[@]}" up -d --wait --wait-timeout 300 db redis app web proxy onlyoffice
    else
        "${compose[@]}" up -d db redis app web proxy onlyoffice
    fi

    public_url=$(env_value NEXTCLOUD_PUBLIC_URL)
    [[ -n $public_url ]] || die 'NEXTCLOUD_PUBLIC_URL no está definido en .env.'

    info 'Configurando el conector OnlyOffice...'
    onlyoffice_log=$(mktemp)
    if bash set_config.sh --apply \
        --public-url "$public_url" \
        --allow-local-remote-servers \
        --install-app >"$onlyoffice_log" 2>&1; then
        rm -f "$onlyoffice_log"
        ok 'OnlyOffice agregado y configurado en la instalación existente.'
    else
        printf '\n'
        cat "$onlyoffice_log"
        rm -f "$onlyoffice_log"
        die 'OnlyOffice arrancó, pero el conector de Nextcloud requiere atención.'
    fi

    say
    say 'Actualización completada'
    say '======================'
    say "URL: $public_url"
    say 'OnlyOffice: activado'
    exit 0
fi

if [[ -z $timezone ]]; then
    if [[ -r /etc/timezone ]]; then
        timezone=$(head -n 1 /etc/timezone | tr -d '\r\n')
    elif [[ -L /etc/localtime ]]; then
        timezone=$(readlink /etc/localtime 2>/dev/null | sed 's#^.*/zoneinfo/##' || true)
    fi
    timezone=${timezone:-UTC}
fi

if [[ -z $admin_password ]]; then
    if [[ $have_tty == true ]]; then
        read -r -s -p 'Contraseña del administrador [Enter = generar automáticamente]: ' admin_password
        printf '\n'
    fi
    if [[ -z $admin_password ]]; then
        admin_password=$(openssl rand -hex 16)
        generated_admin_password=true
    fi
fi

[[ -f .env.example ]] || die '.env.example no existe.'
[[ -f compose.yaml ]] || die 'compose.yaml no existe.'
[[ -f scripts/preflight.sh ]] || die 'scripts/preflight.sh no existe.'

if [[ -f .env ]]; then
    if [[ $force_config == true ]]; then
        backup=".env.bak.$(date +%Y%m%d-%H%M%S)"
        cp .env "$backup"
        chmod 600 "$backup"
        warn "Se guardó la configuración anterior en $backup"
    elif [[ $have_tty == true ]]; then
        if ask_yes_no '.env ya existe. ¿Reemplazarlo? Se guardará una copia' no; then
            backup=".env.bak.$(date +%Y%m%d-%H%M%S)"
            cp .env "$backup"
            chmod 600 "$backup"
            warn "Se guardó la configuración anterior en $backup"
        else
            die 'Instalación cancelada para no modificar la configuración existente.'
        fi
    else
        die '.env ya existe. Use --force-config solo si realmente desea reemplazarlo.'
    fi
fi

info 'Generando configuración segura...'
old_umask=$(umask)
umask 077
cp .env.example .env
chmod 600 .env

mysql_password=$(openssl rand -hex 32)
mysql_root_password=$(openssl rand -hex 32)
redis_password=$(openssl rand -hex 32)
onlyoffice_jwt=
[[ $onlyoffice == true ]] && onlyoffice_jwt=$(openssl rand -hex 32)

profiles=
if [[ $acme == true && $onlyoffice == true ]]; then
    profiles=acme,onlyoffice
elif [[ $acme == true ]]; then
    profiles=acme
elif [[ $onlyoffice == true ]]; then
    profiles=onlyoffice
fi

set_env COMPOSE_PROFILES "$profiles"
set_env NEXTCLOUD_DOMAIN "$domain"
set_env NEXTCLOUD_TRUSTED_DOMAINS "$domain"
set_env NEXTCLOUD_OVERWRITE_PROTOCOL "$protocol"
set_env NEXTCLOUD_OVERWRITE_HOST "$domain"
set_env NEXTCLOUD_PUBLIC_URL "$protocol://$domain"
set_env ACME_EMAIL "$email"
set_env MYSQL_PASSWORD "$mysql_password"
set_env MYSQL_ROOT_PASSWORD "$mysql_root_password"
set_env NEXTCLOUD_ADMIN_USER "$admin_user"
set_env NEXTCLOUD_ADMIN_PASSWORD "$admin_password"
set_env REDIS_PASSWORD "$redis_password"
set_env ONLYOFFICE_JWT_SECRET "$onlyoffice_jwt"
set_env TZ "$timezone"
set_env NEXTCLOUD_DEV_MODE "$dev_mode"

unset mysql_password mysql_root_password redis_password onlyoffice_jwt
umask 022

info 'Preparando directorios persistentes...'
mkdir -p \
    db data \
    nextcloud/page/web nextcloud/apps nextcloud/custom_apps nextcloud/config \
    config/proxy/conf.d config/proxy/vhost.d config/proxy/html config/proxy/certs \
    config/acme config/redis/data

if [[ $onlyoffice == true ]]; then
    mkdir -p \
        config/onlyoffice/document_data \
        config/onlyoffice/document_log \
        config/onlyoffice/document_cache \
        config/onlyoffice/example_files \
        config/onlyoffice/fonts
fi

chmod 755 nextcloud nextcloud/page nextcloud/page/web nextcloud/apps nextcloud/custom_apps
chmod 600 .env
umask "$old_umask"

proxy_network=$(awk -F= '$1=="NGINX_PROXY_NETWORK" {print $2; exit}' .env)
proxy_network=${proxy_network:-nginx-proxy}
if ! docker network inspect -- "$proxy_network" >/dev/null 2>&1; then
    info "Creando red Docker $proxy_network..."
    docker network create "$proxy_network" >/dev/null
fi
ok "Red Docker preparada: $proxy_network"

info 'Validando host y configuración...'
preflight_log=$(mktemp)
if bash scripts/preflight.sh --quiet >"$preflight_log" 2>&1; then
    ok 'Preflight superado.'
    rm -f "$preflight_log"
else
    printf '\n'
    cat "$preflight_log"
    rm -f "$preflight_log"
    die 'El preflight encontró errores. No se inició ningún contenedor.'
fi

if [[ $no_start == true ]]; then
    ok 'Configuración preparada y validada (--no-start).'
    exit 0
fi

info 'Construyendo la imagen de Nextcloud...'
"${compose[@]}" build app

info 'Iniciando servicios...'
if "${compose[@]}" up --help 2>/dev/null | grep -q -- '--wait'; then
    "${compose[@]}" up -d --wait --wait-timeout 300
else
    "${compose[@]}" up -d
fi

ok 'Contenedores iniciados.'

onlyoffice_config_status=0
if [[ $onlyoffice == true ]]; then
    info 'Configurando OnlyOffice dentro de Nextcloud...'
    onlyoffice_log=$(mktemp)
    if bash set_config.sh --apply \
        --public-url "$protocol://$domain" \
        --allow-local-remote-servers \
        --install-app >"$onlyoffice_log" 2>&1; then
        ok 'Conector OnlyOffice instalado y configurado.'
        rm -f "$onlyoffice_log"
    else
        onlyoffice_config_status=$?
        warn 'Document Server arrancó, pero el conector de Nextcloud no pudo configurarse.'
        printf '\nDetalle de OnlyOffice:\n\n'
        cat "$onlyoffice_log"
        rm -f "$onlyoffice_log"
    fi
fi

doctor_status=0
if [[ -f scripts/doctor.sh ]]; then
    info 'Verificando la instalación...'
    doctor_log=$(mktemp)
    if bash scripts/doctor.sh >"$doctor_log" 2>&1; then
        ok 'MariaDB'
        ok 'Redis'
        ok 'Nextcloud'
        ok 'Nginx'
        ok 'Proxy'
        if [[ $onlyoffice == true ]]; then
            ok 'OnlyOffice'
        else
            info 'OnlyOffice deshabilitado'
        fi
        rm -f "$doctor_log"
    else
        doctor_status=$?
        warn 'La comprobación final encontró un problema.'
        printf '\nDiagnóstico detallado:\n\n'
        cat "$doctor_log"
        rm -f "$doctor_log"
    fi
fi

say
say 'Instalación finalizada'
say '====================='
say "URL: $protocol://$domain"
say "Usuario administrador: $admin_user"
if [[ $generated_admin_password == true ]]; then
    say "Contraseña generada: $admin_password"
    say 'Guárdala en un gestor de contraseñas; no se volverá a mostrar automáticamente.'
else
    say 'Contraseña: la que ingresaste durante la instalación.'
fi
say "OnlyOffice: $([[ $onlyoffice == true ]] && printf 'activado' || printf 'desactivado')"
say "HTTPS automático: $([[ $acme == true ]] && printf 'activado' || printf 'desactivado')"
say "Modo desarrollo: $([[ $dev_mode == true ]] && printf 'activado' || printf 'desactivado')"

if ((onlyoffice_config_status != 0)); then
    warn 'Nextcloud está funcionando, pero OnlyOffice requiere atención.'
    say 'Puede reintentar con:'
    say "bash set_config.sh --apply --public-url $protocol://$domain --allow-local-remote-servers --install-app"
    exit 1
fi

if ((doctor_status != 0)); then
    warn 'Los contenedores arrancaron, pero la comprobación final requiere atención.'
    say 'Puede repetir el diagnóstico con: bash scripts/doctor.sh'
    exit 1
fi

ok 'Nextcloud está listo para la comprobación final en el navegador.'
