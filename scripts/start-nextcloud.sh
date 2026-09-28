#!/bin/sh
set -eu

dev_mode=${NEXTCLOUD_DEV_MODE:-false}
php_dev_ini=/usr/local/etc/php/conf.d/zz-nextcloud-development.ini
nextcloud_dev_config=/var/www/html/config/zz-development.config.php

case "${dev_mode}" in
  1|true|TRUE|yes|YES|on|ON)
    cat > "${php_dev_ini}" <<'EOF'
; Generado por docker-nextcloud-onlyoffice para desarrollo.
; No usar en producción.
opcache.enable=0
opcache.enable_cli=0
opcache.validate_timestamps=1
display_errors=On
display_startup_errors=On
error_reporting=E_ALL
EOF

    mkdir -p /var/www/html/config
    cat > "${nextcloud_dev_config}" <<'EOF'
<?php
// Generado por docker-nextcloud-onlyoffice. Se elimina al desactivar NEXTCLOUD_DEV_MODE.
$CONFIG = [
    'debug' => true,
    'loglevel' => 0,
];
EOF
    chown www-data:www-data "${nextcloud_dev_config}" 2>/dev/null || true
    chmod 640 "${nextcloud_dev_config}" 2>/dev/null || true
    echo "[INFO] NEXTCLOUD_DEV_MODE activo: debug de Nextcloud habilitado y OPcache deshabilitado."
    ;;
  0|false|FALSE|no|NO|off|OFF|"")
    rm -f "${php_dev_ini}"
    if [ -f "${nextcloud_dev_config}" ] && grep -q 'Generado por docker-nextcloud-onlyoffice' "${nextcloud_dev_config}"; then
      rm -f "${nextcloud_dev_config}"
    fi
    ;;
  *)
    echo "[ERROR] NEXTCLOUD_DEV_MODE debe ser true o false." >&2
    exit 1
    ;;
esac

exec /usr/bin/supervisord -c /supervisord.conf
