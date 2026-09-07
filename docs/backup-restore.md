# Backup y restauración

Un backup útil debe poder restaurarse. Pruebe este procedimiento en un host o
proyecto aislado antes de depender de él. Los comandos son una guía y no se
ejecutaron durante la actualización del repositorio.

## Alcance mínimo

Conserve juntos:

- un dump consistente de MariaDB;
- `data/` y todo `nextcloud/`;
- `config/redis/data/` si necesita conservar caché/colas pendientes;
- `config/onlyoffice/`;
- `config/proxy/` y `config/acme/` si el stack administra TLS;
- `compose.yaml`, `docker-compose.yml`, Dockerfile, Supervisor y Nginx;
- `.env` y el override por un canal cifrado;
- referencias o digests de todas las imágenes;
- manifiestos SHA-256 y fecha UTC.

No copie `db/` mientras MariaDB escribe. Un tar del datadir activo no sustituye
un dump lógico ni un snapshot consistente del filesystem.

## Preparación

Elija un destino fuera del checkout y aplique permisos restrictivos:

```sh
umask 077
backup_dir=/ruta/backup/nextcloud-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$backup_dir"
```

Registre la forma del despliegue sin imprimir secretos:

```sh
docker compose config --services > "$backup_dir/services.txt"
docker compose config --images > "$backup_dir/images.txt"
docker compose ps -a > "$backup_dir/ps.txt"
cp -p compose.yaml Dockerfile supervisord.conf "$backup_dir/"
cp -p .env "$backup_dir/env"
test ! -e compose.override.yaml || cp -p compose.override.yaml "$backup_dir/"
tar -cpf "$backup_dir/public-source.tar" \
  .dockerignore .env.example .gitignore Dockerfile README.md \
  compose.yaml docker-compose.yml compose.override.example.yaml \
  supervisord.conf set_config.sh scripts docs config/nginx
```

Proteja y cifre el destino porque contiene `.env`.

## Ventana consistente de base y archivos

Todos los esquemas de aplicación deben usar InnoDB para que
`--single-transaction` sea consistente. Verifíquelo antes y no continúe si hay
DDL, una actualización o una migración en curso. El siguiente bloque detiene los
servicios que escriben, mantiene MariaDB activa para el dump y copia los bind
mounts dentro de la misma ventana:

```sh
set -Eeuo pipefail
docker compose exec --user www-data app php occ maintenance:mode --on
docker compose exec -T redis sh -ec \
  'export REDISCLI_AUTH="$REDIS_PASSWORD"; exec redis-cli SAVE'
docker compose stop web onlyoffice redis app

docker compose exec -T db sh -ec '
  export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
  exec mariadb-dump \
    --user=root \
    --single-transaction \
    --quick \
    --skip-lock-tables \
    --routines \
    --events \
    --triggers \
    --hex-blob \
    --default-character-set=utf8mb4 \
    --databases "$MYSQL_DATABASE"
' | gzip -1 > "$backup_dir/nextcloud.sql.gz.part"
gzip -t "$backup_dir/nextcloud.sql.gz.part"
mv "$backup_dir/nextcloud.sql.gz.part" "$backup_dir/nextcloud.sql.gz"

tar --xattrs --acls -cpf "$backup_dir/files.tar" \
  data nextcloud config/nginx config/redis config/onlyoffice config/proxy config/acme
docker compose start redis app web onlyoffice
docker compose exec --user www-data app php occ maintenance:mode --off
```

El modo mantenimiento y los `stop` son modificaciones reales y causan
indisponibilidad. Prepare un `trap` o procedimiento operativo para volver a
arrancar los cuatro servicios y desactivar mantenimiento si la copia falla. Redis
es caché y puede reconstruirse en muchos despliegues; decida si incluirlo según
las apps y colas usadas. `pipefail` hace fallar el pipeline si falla el dump o
gzip. No use `--force` ni publique la salida. En bases grandes, supervise espacio
libre y duración.

Genere el manifiesto al final:

```sh
(
  cd "$backup_dir"
  find . -maxdepth 1 -type f ! -name SHA256SUMS -print0 \
    | sort -z \
    | xargs -0 sha256sum > SHA256SUMS
  sha256sum --check --strict SHA256SUMS
)
```

Guarde el manifiesto en una ubicación separada o firmada para detectar una
alteración conjunta.

## Prueba de restauración aislada

No restaure primero sobre producción. Use otro nombre de proyecto, directorios
vacíos, puertos distintos y una red que no comparta tráfico con la instancia real.
No monte ningún datadir productivo como escritura.

1. Verifique todos los hashes y `gzip -t`.
2. Restaure el Compose, `.env`, override y referencias de imagen exactas.
3. Extraiga el archivo de datos conservando propietarios, ACL y xattrs.
4. Cree un directorio `db/` nuevo y arranque solo MariaDB.
5. Importe el dump.
6. Arranque Redis, app y web; después OnlyOffice, proxy y ACME si procede.
7. Ejecute `occ status`, `doctor.sh`, pruebas de login, subida, WebDAV y edición
   OnlyOffice.

Importación de ejemplo sobre una MariaDB vacía del clon aislado:

```sh
gzip -dc /ruta/backup/nextcloud.sql.gz | docker compose exec -T db sh -ec '
  export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
  exec mariadb --user=root
'
```

No importe encima de una base con datos sin un plan explícito. La versión de
MariaDB que restaura debe poder leer el dump y la versión de Nextcloud debe seguir
una ruta de actualización soportada.

## Validaciones posteriores

```sh
docker compose ps -a
docker compose exec --user www-data app php occ status --output=json
bash scripts/doctor.sh
(cd /ruta/backup && sha256sum --check --strict SHA256SUMS)
```

Además verifique:

- recuentos y permisos de archivos;
- jobs de fondo y modo cron;
- bloqueo/caché Redis;
- certificado, cadena TLS y renovación ACME;
- creación, edición y callback de un documento OnlyOffice;
- logs sin errores de upgrade, permisos o conexión.

No desactive la instancia original hasta que la restauración aislada sea
repetible y documentada.
