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
  refresh         Reaplica las imágenes actuales sin cambiar versiones
  update          Actualización segura con backup obligatorio
EOF
}

[[ -f .env ]] || { echo "[ERROR] Falta .env. Ejecuta primero bash install.sh" >&2; exit 1; }
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
    exec bash install.sh --dev-full
    ;;
  onlyoffice-off)
    profiles=$(env_value COMPOSE_PROFILES)
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
    "${compose[@]}" stop onlyoffice >/dev/null 2>&1 || true
    echo "[OK] OnlyOffice desactivado. La app de Nextcloud permanece instalada."
    echo "[INFO] Copia de .env: $backup"
    ;;
  refresh)
    echo "[INFO] Reaplicando referencias actuales de .env..."
    mapfile -t services < <("${compose[@]}" config --services)
    pull_services=()
    for service in "${services[@]}"; do
      [[ $service == app ]] && continue
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
  help|-h|--help|"")
    usage
    ;;
  *)
    echo "[ERROR] Comando desconocido: $1" >&2
    usage >&2
    exit 2
    ;;
esac
