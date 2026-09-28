# Diagnóstico y problemas frecuentes

Empiece con comprobaciones de solo lectura:

```sh
docker compose config --quiet
docker compose config --services
docker compose config --images
docker compose ps -a
bash scripts/doctor.sh
```

No comparta `docker compose config` completo: contiene secretos interpolados.

## Compose no valida

- Confirme que `.env` existe, tiene modo `0600`, no tiene secretos vacíos y no
  conserva placeholders.
- Ejecute desde el directorio que contiene `compose.yaml`.
- Si usa `-f`, incluya explícitamente el override.
- Revise `COMPOSE_FILE`, `COMPOSE_PROFILES` y `COMPOSE_PROJECT_NAME` del entorno.
- Compruebe que `docker-compose.yml` sea un enlace a `compose.yaml`, no un archivo
  de texto creado por un checkout sin soporte de symlinks.

Valide solo la base para aislar un override defectuoso:

```sh
docker compose -f compose.yaml config --quiet
```

## Una imagen no existe o el build falla

Los pins se revisaron documentalmente, pero deben volver a verificarse antes de
desplegar. No sustituya un error por `latest`.

La imagen `NEXTCLOUD_APP_IMAGE` se construye localmente. El Dockerfile requiere
que `NEXTCLOUD_BASE_IMAGE` sea una variante FPM Alpine. Su contexto está limitado
por `.dockerignore` a Dockerfile y Supervisor.

Esta actualización no ejecutó el build. Si falla, conserve el log sin secretos y
revise cambios de PHP, Alpine, PECL `smbclient` y paquetes del repositorio base.
PHP IMAP no se añade en la imagen de referencia.

## MariaDB no queda healthy

```sh
docker compose ps db
docker compose logs --tail=200 db
```

Compruebe:

- credenciales coherentes y no vacías;
- permisos y propietario de `db/`;
- versión compatible con el datadir existente;
- espacio libre;
- ausencia de una actualización interrumpida.

No active una actualización automática ni haga downgrade para silenciar un
aviso. Obtenga un backup y siga la documentación de MariaDB.

## MariaDB responde pero Nextcloud muestra Access denied

Si Nextcloud muestra un error similar a:

```text
SQLSTATE[HY000] [1045] Access denied for user 'nextcloud'
```

compruebe primero las credenciales efectivas:

```sh
docker compose exec -T db sh -lc \
  'mariadb -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" -e "SELECT 1;"'
```

Si MariaDB está healthy pero esta prueba falla, el directorio `db/` probablemente
fue inicializado con un valor anterior de `MYSQL_PASSWORD`. Cambiar `.env`
después de la primera inicialización no cambia automáticamente la contraseña
almacenada en MariaDB.

En una instalación nueva y descartable, detenga el stack y reinicialice únicamente
`db/` después de confirmar que no contiene datos que deba conservar. En una
instalación con datos, cambie la contraseña dentro de MariaDB o restaure desde un
backup; no borre el datadir.

## Redis no responde

```sh
docker compose ps redis
docker compose logs --tail=200 redis
```

`REDIS_PASSWORD` se inyecta tanto en Redis como en Nextcloud. Si cambió solo un
lado mediante override, la autenticación falla. Redis no debe publicar 6379 y
solo debe pertenecer a `backend`.

## Error 403, assets 404 o MIME type text/html

Si el navegador muestra `403 Forbidden`, muchos `404` bajo `/apps/` o errores
de MIME porque un archivo CSS/JS devuelve HTML, compruebe los bind mounts:

```sh
ls -ld nextcloud nextcloud/page nextcloud/page/web \
  nextcloud/apps nextcloud/custom_apps
```

Los directorios que Nginx debe atravesar no deben quedar creados con modo
`0700`. Esto puede ocurrir si se ejecutó `umask 077` para proteger `.env` y no
se restauró antes de crear la persistencia.

Para una instalación afectada, revise primero el contenido y después aplique
permisos de lectura/traversal únicamente donde corresponda:

```sh
chmod 755 nextcloud nextcloud/page nextcloud/page/web
chmod 755 nextcloud/apps nextcloud/custom_apps
chmod -R a+rX nextcloud/page/web nextcloud/apps nextcloud/custom_apps
docker compose restart web
```

No use `chmod -R 777`.

Puede verificar desde el propio contenedor:

```sh
docker compose exec -T web sh -ec \
  'test -r /var/www/html/index.php &&
   test -r /var/www/html/status.php &&
   test -x /var/www/html/apps &&
   test -x /var/www/html/custom_apps'
```

## Error 502 o Nginx unhealthy

```sh
docker compose exec -T web nginx -t
docker compose logs --tail=200 web app
docker compose exec --user www-data app php occ status
```

Confirme que `app` y `web` comparten `app-tier`, que el upstream es `app:9000` y
que Nginx puede leer `/var/www/html` mediante `volumes_from`. Un override que
reemplace redes o volúmenes puede romper esa relación.

## Dominio o HTTPS no funciona

Verifique, en orden:

1. A/AAAA del dominio;
2. NAT y firewall TCP 80/443;
3. `NEXTCLOUD_DOMAIN`, `VIRTUAL_HOST` y `ACME_HOST` efectivos;
4. perfil `acme` presente en `docker compose config --services`;
5. red externa compartida por `web`, `proxy` y `acme`;
6. logs de proxy y ACME;
7. cadena y vigencia del certificado desde un cliente externo.

El desafío HTTP-01 falla si el dominio no llega al puerto 80 del proxy. Si usa
otro terminador TLS, desactive el perfil ACME y configure correctamente protocolo
y proxies confiables.

## OnlyOffice no abre documentos

```sh
docker compose ps onlyoffice web app
docker compose logs --tail=200 onlyoffice web app
```

Compruebe:

- healthcheck de Document Server;
- acceso público a `/ds-vpath/`;
- app ONLYOFFICE instalada y habilitada en Nextcloud;
- mismo JWT y cabecera `AuthorizationJwt`;
- URLs interna y pública configuradas por `set_config.sh`;
- resolución de `onlyoffice` y `web` en `app-tier`;
- callbacks sin bloqueo de proxy o firewall.

No desactive la verificación TLS ni elimine JWT como solución. Una página de
bienvenida o healthcheck correcto no valida la edición extremo a extremo.

## Subidas grandes fallan

El límite efectivo es el menor de:

- `PHP_UPLOAD_LIMIT`;
- `client_max_body_size` en el Nginx de Nextcloud;
- `client_max_body_size` de nginx-proxy;
- cualquier balanceador externo;
- timeouts y espacio temporal/disponible.

El ejemplo usa 10G en las tres capas internas. Si cambia el valor, ajuste las
copias Nginx mediante override y pruebe una subida real.

## Nextcloud está en mantenimiento o requiere upgrade

```sh
docker compose exec --user www-data app php occ status --output=json
```

No ejecute `occ upgrade`, migraciones ni reparaciones hasta identificar el cambio
de versión, revisar backups y leer las notas oficiales. Un flag de upgrade puede
proceder del core o de una app.

## Dockge muestra otro stack o paths vacíos

Confirme el directorio de trabajo, `COMPOSE_PROJECT_NAME`, archivos Compose y
mounts antes de Start. Dockge debe montar el mismo directorio padre con la misma
ruta. Consulte [dockge.md](dockge.md).

## Recopilar evidencia sin secretos

```sh
git status --short
git diff --stat
docker compose config --services
docker compose config --images
docker compose ps -a
docker compose logs --tail=100 SERVICIO
```

Redacte dominios internos, IP, nombres de usuario, tokens y datos de documentos
antes de publicar un reporte.
