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
  doctor   Ejecuta el diagnóstico
  rebuild  Reconstruye la imagen de Nextcloud y recrea app/web
EOF
}

[[ -f .env ]] || { echo "[ERROR] Falta .env. Ejecuta primero bash install.sh" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "[ERROR] Docker no está disponible" >&2; exit 1; }

case "${1:-}" in
  status)
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
  rebuild)
    echo "[INFO] Reconstruyendo Nextcloud..."
    "${compose[@]}" build app
    "${compose[@]}" up -d --force-recreate app web
    echo "[OK] Reconstrucción completada."
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
