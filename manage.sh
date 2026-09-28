#!/usr/bin/env bash
set -Eeuo pipefail

root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
cd "$root"
compose=(docker compose --project-directory "$root" -f "$root/compose.yaml")

usage() {
  cat <<'EOF'
Uso: bash manage.sh <comando>

Comandos:
  status   Muestra el estado del stack
  start    Inicia el stack
  stop     Detiene el stack sin borrar datos
  restart  Reinicia el stack
  doctor          Ejecuta el diagnóstico
  ci               Ejecuta validaciones locales del repositorio
  backup           Crea un backup consistente
  logs [servicio]  Sigue logs; sin servicio muestra todos
  rebuild         Reconstruye la imagen de Nextcloud y recrea app/web
  onlyoffice-on   Activa OnlyOffice en una instalación existente
  onlyoffice-off  Detiene OnlyOffice y lo quita del perfil activo
  dev-on          Activa debug de Nextcloud y desactiva OPcache
  dev-off         Desactiva debug y restaura OPcache normal
  manager-on      Activa el panel web administrativo local
  manager-off     Detiene el panel y lo quita del perfil activo
  refresh         Reaplica las imágenes actuales sin cambiar versiones
  update          Actualización segura con backup obligatorio
EOF
}

case "${1:-}" in
  help|-h|--help|"")
    usage
    exit 0
    ;;
esac

[[ -f .env ]] || { echo "[ERROR] Falta .env. Ejecuta primero bash install.sh" >&2; exit 1; }
[[ -r .env ]] || {
  echo "[ERROR] .env existe pero el usuario actual no puede leerlo." >&2
  echo "[INFO] Revisa propietario y permisos con: ls -l .env" >&2
  echo "[INFO] Si el archivo pertenece a root por una versión anterior del manager, restaura el propietario del checkout y deja modo 600." >&2
  exit 1
}
command -v docker >/dev/null 2>&1 || { echo "[ERROR] Docker no está disponible" >&2; exit 1; }

env_value() {
  local key=$1 value
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
  ' .env > "$tmp"
  cat "$tmp" > .env
  rm -f "$tmp"
  chmod 600 .env
}

case "${1:-}" in
  status)
    public_url=$(env_value NEXTCLOUD_PUBLIC_URL)
    profiles=$(env_value COMPOSE_PROFILES)
    printf 'URL: %s\n' "${public_url:-no configurada}"
    printf 'Perfiles: %s\n\n' "${profiles:-base}"
    "${compose[@]}" ps
    ;;
  start)
    echo "[INFO] Iniciando stack..."
    "${compose[@]}" up -d
    echo "[OK] Stack iniciado."
    ;;
  stop)
    echo "[INFO] Deteniendo stack sin borrar datos..."
    "${compose[@]}" stop
    echo "[OK] Stack detenido."
    ;;
  restart)
    echo "[INFO] Reiniciando stack..."
    "${compose[@]}" restart
    echo "[OK] Stack reiniciado."
    ;;
  doctor)
    bash scripts/doctor.sh
    ;;
  ci)
    exec bash scripts/ci.sh
    ;;
  backup)
    exec bash scripts/backup.sh
    ;;
  logs)
    if [[ -n ${2:-} ]]; then
      exec "${compose[@]}" logs --tail=200 -f "$2"
    else
      exec "${compose[@]}" logs --tail=200 -f
    fi
    ;;
  rebuild)
    echo "[INFO] Reconstruyendo Nextcloud..."
    "${compose[@]}" build app
    "${compose[@]}" up -d --force-recreate app web
    echo "[OK] Reconstrucción completada."
    ;;
  onlyoffice-on)
    command -v openssl >/dev/null 2>&1 || { echo "[ERROR] OpenSSL no está disponible" >&2; exit 1; }
    profiles=$(env_value COMPOSE_PROFILES)
    case ",$profiles," in
      *,onlyoffice,*) ;;
      *)
        if [[ -z $profiles ]]; then
          set_env COMPOSE_PROFILES onlyoffice
        else
          set_env COMPOSE_PROFILES "$profiles,onlyoffice"
        fi
        ;;
    esac

    onlyoffice_secret=$(env_value ONLYOFFICE_JWT_SECRET)
    if [[ ${#onlyoffice_secret} -lt 64 ]]; then
      set_env ONLYOFFICE_JWT_SECRET "$(openssl rand -hex 32)"
    fi
    unset onlyoffice_secret

    echo "[INFO] Iniciando servicios requeridos y OnlyOffice..."
    "${compose[@]}" up -d db redis app web proxy onlyoffice

    public_url=$(env_value NEXTCLOUD_PUBLIC_URL)
    [[ -n $public_url ]] || { echo "[ERROR] NEXTCLOUD_PUBLIC_URL está vacío" >&2; exit 1; }

    echo "[INFO] Configurando conector OnlyOffice en Nextcloud..."
    bash set_config.sh --apply \
      --public-url "$public_url" \
      --allow-local-remote-servers \
      --install-app
    echo "[OK] OnlyOffice activado sin reconfigurar el modo de instalación."
    ;;
  onlyoffice-off)
    profiles=$(env_value COMPOSE_PROFILES)
    COMPOSE_PROFILES=onlyoffice "${compose[@]}" stop onlyoffice >/dev/null 2>&1 || true
    new_profiles=$(printf '%s' "$profiles" | awk -F, '
      {
        out=""
        for (i=1; i<=NF; i++) {
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
          if ($i == "" || $i == "onlyoffice") continue
          out = out (out == "" ? "" : ",") $i
        }
        print out
      }')
    backup=".env.bak.$(date +%Y%m%d-%H%M%S)"
    cp .env "$backup"
    chmod 600 "$backup"
    set_env COMPOSE_PROFILES "$new_profiles"
    echo "[OK] OnlyOffice desactivado. La app de Nextcloud permanece instalada."
    echo "[INFO] Copia de .env: $backup"
    ;;
  dev-on)
    backup=".env.bak.$(date +%Y%m%d-%H%M%S)"
    cp .env "$backup"
    chmod 600 "$backup"
    set_env NEXTCLOUD_DEV_MODE true
    echo "[INFO] Reconstruyendo app con soporte de desarrollo..."
    "${compose[@]}" build app
    "${compose[@]}" up -d --force-recreate app web
    echo "[OK] Modo desarrollo activado."
    echo "[INFO] Nextcloud debug=true; OPcache deshabilitado."
    echo "[INFO] Copia de .env: $backup"
    ;;
  dev-off)
    backup=".env.bak.$(date +%Y%m%d-%H%M%S)"
    cp .env "$backup"
    chmod 600 "$backup"
    set_env NEXTCLOUD_DEV_MODE false
    echo "[INFO] Aplicando modo normal..."
    "${compose[@]}" build app
    "${compose[@]}" up -d --force-recreate app web
    echo "[OK] Modo desarrollo desactivado."
    echo "[INFO] El fragmento debug se retirará y OPcache volverá a la configuración normal."
    echo "[INFO] Copia de .env: $backup"
    ;;
  manager-on)
    command -v openssl >/dev/null 2>&1 || { echo "[ERROR] OpenSSL no está disponible" >&2; exit 1; }
    profiles=$(env_value COMPOSE_PROFILES)
    case ",$profiles," in
      *,manager,*) ;;
      *)
        if [[ -z $profiles ]]; then
          set_env COMPOSE_PROFILES manager
        else
          set_env COMPOSE_PROFILES "$profiles,manager"
        fi
        ;;
    esac

    manager_password=$(env_value MANAGER_ADMIN_PASSWORD)
    generated_manager_password=false
    if [[ ${#manager_password} -lt 12 ]]; then
      manager_password=$(openssl rand -hex 16)
      set_env MANAGER_ADMIN_PASSWORD "$manager_password"
      generated_manager_password=true
    fi

    manager_secret=$(env_value MANAGER_SECRET_KEY)
    if [[ ${#manager_secret} -lt 32 ]]; then
      set_env MANAGER_SECRET_KEY "$(openssl rand -hex 32)"
    fi

    [[ -n $(env_value MANAGER_ADMIN_USER) ]] || set_env MANAGER_ADMIN_USER admin
    [[ -n $(env_value MANAGER_BIND_ADDRESS) ]] || set_env MANAGER_BIND_ADDRESS 127.0.0.1
    [[ -n $(env_value MANAGER_PORT) ]] || set_env MANAGER_PORT 8090
    [[ -n $(env_value MANAGER_COOKIE_SECURE) ]] || set_env MANAGER_COOKIE_SECURE false
    set_env MANAGER_PROJECT_HOST_PATH "$root"

    echo "[INFO] Construyendo e iniciando panel administrativo..."
    "${compose[@]}" up -d --build manager
    manager_bind=$(env_value MANAGER_BIND_ADDRESS)
    manager_port=$(env_value MANAGER_PORT)
    manager_user=$(env_value MANAGER_ADMIN_USER)
    echo "[OK] Panel administrativo iniciado."
    echo "[INFO] URL: http://${manager_bind:-127.0.0.1}:${manager_port:-8090}"
    echo "[INFO] Usuario: ${manager_user:-admin}"
    if [[ $generated_manager_password == true ]]; then
      echo "[INFO] Contraseña generada: $manager_password"
      echo "[INFO] Guárdala ahora; permanece en .env y no se vuelve a mostrar automáticamente."
    fi
    unset manager_password manager_secret
    ;;
  manager-off)
    profiles=$(env_value COMPOSE_PROFILES)
    "${compose[@]}" stop manager >/dev/null 2>&1 || true
    new_profiles=$(printf '%s' "$profiles" | awk -F, '
      {
        out=""
        for (i=1; i<=NF; i++) {
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
          if ($i == "" || $i == "manager") continue
          out = out (out == "" ? "" : ",") $i
        }
        print out
      }')
    backup=".env.bak.$(date +%Y%m%d-%H%M%S)"
    cp .env "$backup"
    chmod 600 "$backup"
    set_env COMPOSE_PROFILES "$new_profiles"
    echo "[OK] Panel administrativo detenido y perfil manager desactivado."
    echo "[INFO] Los secretos del panel permanecen en .env."
    echo "[INFO] Copia de .env: $backup"
    ;;
  refresh)
    echo "[INFO] Reaplicando referencias actuales de .env..."
    mapfile -t services < <("${compose[@]}" config --services)
    pull_services=()
    for service in "${services[@]}"; do
      case $service in
        app|manager) continue ;;
      esac
      pull_services+=("$service")
    done
    if ((${#pull_services[@]} > 0)); then
      "${compose[@]}" pull "${pull_services[@]}"
    fi
    "${compose[@]}" build --pull app
    "${compose[@]}" up -d
    echo "[OK] Stack reaplicado con las referencias actuales."
    ;;
  update)
    exec bash scripts/update.sh --apply
    ;;
  *)
    echo "[ERROR] Comando desconocido: $1" >&2
    usage >&2
    exit 2
    ;;
esac
