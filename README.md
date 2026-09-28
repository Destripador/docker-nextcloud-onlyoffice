# Nextcloud + OnlyOffice con Docker Compose

Stack público para ejecutar Nextcloud FPM detrás de Nginx y `nginx-proxy`, con
MariaDB, Redis, OnlyOffice Document Server y certificados ACME opcionales. La
imagen de Nextcloud se construye localmente para añadir Samba, LibreOffice,
FFmpeg, ImageMagick, `bz2` y la extensión PHP `smbclient`.

> [!IMPORTANT]
> Este repositorio define infraestructura con estado. Revise el Compose y cree
> backups restaurables antes de cambiar una instalación existente. Nunca use
> `docker compose down -v` sobre datos que quiera conservar.

`compose.yaml` es la fuente canónica. `docker-compose.yml` es un enlace
simbólico temporal para flujos antiguos; consulte
[la guía de transición](docs/migration-compose.md).

## Componentes

| Servicio | Función | Exposición predeterminada |
| --- | --- | --- |
| `db` | MariaDB | Solo red interna `backend` |
| `redis` | Caché y locking con contraseña | Solo red interna `backend` |
| `app` | Nextcloud PHP-FPM y cron bajo Supervisor | Sin puerto de host |
| `web` | Nginx para estáticos, FastCGI y `/ds-vpath/` | A través de `proxy` |
| `proxy` | Entrada HTTP/HTTPS mediante nginx-proxy | Puertos 80 y 443 |
| `onlyoffice` | Document Server con JWT | Perfil Compose `onlyoffice`; a través de `/ds-vpath/` |
| `acme` | Certificados mediante acme-companion | Perfil Compose `acme` |
| `manager` | Panel web administrativo opcional | Perfil Compose `manager`; localhost:8090 por defecto |

El stack usa tres redes:

- `backend`, interna, para MariaDB, Redis y Nextcloud;
- `app-tier`, para Nextcloud, Nginx y OnlyOffice, con salida a Internet;
- `proxy-tier`, red externa compartida por Nginx, nginx-proxy y ACME.

Solo existe un mecanismo de cron: `/cron.sh` administrado por Supervisor dentro
de `app`. No añada otro servicio cron sin retirar primero ese programa.

## Versiones de referencia

`.env.example` fija un conjunto explícito revisado el 7 de septiembre de 2026:

| Componente | Referencia |
| --- | --- |
| Nextcloud base | `nextcloud:34.0.3-fpm-alpine` |
| MariaDB | `mariadb:11.8.9` |
| Redis | `redis:7.4.11-alpine` |
| Nginx | `nginx:1.30.4-alpine` |
| nginx-proxy | `nginxproxy/nginx-proxy:1.11.6` |
| acme-companion | `nginxproxy/acme-companion:2.8.2` |
| OnlyOffice | `onlyoffice/documentserver:9.4.0.1` |

Estas referencias tienen disponibilidad documental comprobada, pero el conjunto
completo no se construyó ni desplegó durante esta actualización. Antes de usarlo
en producción, compruebe los tags, revise las notas de versión y ejecute las
pruebas pendientes descritas en [limitaciones](docs/known-limitations.md).
Nextcloud 34 admite MariaDB 10.6, 10.11, 11.4 y 11.8 según sus
[requisitos oficiales](https://docs.nextcloud.com/server/stable/admin_manual/installation/system_requirements.html).

No cambie de versión mayor sustituyendo solo un tag. Siga la ruta de actualización
soportada de cada componente y conserve un rollback basado en restauración.

## Requisitos

- Linux de 64 bits con Docker Engine y Docker Compose V2; se recomienda Compose
  2.20 o posterior.
- Git, Bash 4+, OpenSSL y `jq` para los scripts auxiliares.
- DNS público, NAT/firewall TCP 80 y 443 y una dirección de correo válida si usa
  el desafío ACME HTTP-01.
- RAM y almacenamiento adecuados. OnlyOffice es el componente más pesado; mida
  el consumo con su carga real.
- Una ubicación definitiva para el checkout: todos los datos usan bind mounts
  relativos al directorio del proyecto.

Compruebe las herramientas sin iniciar servicios:

```sh
docker version
docker compose version
```

## Instalación rápida recomendada

Para una instalación nueva no necesita crear `.env`, generar secretos ni conocer
Docker Compose. Clone el repositorio y ejecute:

```sh
git clone https://github.com/Destripador/docker-nextcloud-onlyoffice.git
cd docker-nextcloud-onlyoffice
bash install.sh
```

El asistente ofrece cuatro modos:

```text
1) Desarrollo básico
   Nextcloud + MariaDB + Redis

2) Desarrollo completo
   Lo anterior + OnlyOffice

3) Servidor público
   Dominio + HTTPS automático + OnlyOffice opcional

4) Personalizado
```

El instalador genera los secretos, crea `.env`, prepara los directorios y
permisos, crea la red Docker, ejecuta el preflight, construye la imagen e inicia
el stack. No borra instalaciones existentes.

También puede ejecutarse sin menú:

```sh
bash install.sh --dev
bash install.sh --dev-full
bash install.sh --production --domain nube.example.com --email admin@example.com
```

Para preparar todo sin iniciar contenedores:

```sh
bash install.sh --dev --no-start
```

Consulte [la guía del instalador](docs/installer.md) para opciones adicionales.

## Instalación manual / avanzada

### 1. Clonar y crear la configuración privada

```sh
git clone https://github.com/Destripador/docker-nextcloud-onlyoffice.git
cd docker-nextcloud-onlyoffice
umask 077
cp .env.example .env
chmod 600 .env
umask 022
```

`umask 077` se usa únicamente para crear `.env`. Restáurelo antes de crear
directorios persistentes: Nginx se ejecuta con un usuario distinto al de
Nextcloud y necesita poder atravesar y leer los bind mounts que contienen el
core y los assets. Mantener un umask restrictivo durante el resto de la
instalación puede provocar errores `403 Permission denied` y respuestas 404
para archivos CSS/JS.

Edite `.env`, sustituya el dominio y el correo, y complete los secretos
obligatorios. `ONLYOFFICE_JWT_SECRET` solo es necesario cuando el perfil
`onlyoffice` está activo. Genere valores distintos para cada secreto, por ejemplo:

```sh
openssl rand -hex 32
```

No pegue secretos en el Compose, un issue, capturas o comandos que queden en el
historial del shell. Complete y revise el archivo `.env` **antes del primer
arranque de MariaDB**. Las variables `MYSQL_PASSWORD` y
`MYSQL_ROOT_PASSWORD` inicializan las cuentas cuando `db/` está vacío; cambiar
esas variables después no cambia automáticamente las credenciales almacenadas
en un datadir existente.

El mapa completo de variables está en
[docs/configuration.md](docs/configuration.md).

### 2. Preparar persistencia y red

Para el stack base:

```sh
mkdir -p \
  db data \
  nextcloud/page/web nextcloud/apps nextcloud/custom_apps nextcloud/config \
  config/proxy/conf.d config/proxy/vhost.d config/proxy/html config/proxy/certs \
  config/acme config/redis/data
```

Si habilita el perfil `onlyoffice`, cree además:

```sh
mkdir -p \
  config/onlyoffice/document_data config/onlyoffice/document_log \
  config/onlyoffice/document_cache config/onlyoffice/example_files \
  config/onlyoffice/fonts
```

El nombre de la red externa debe coincidir con `NGINX_PROXY_NETWORK`. Créela una
sola vez y únicamente si aún no existe:

```sh
docker network inspect nginx-proxy >/dev/null 2>&1 || docker network create nginx-proxy
```

Si cambia el nombre en `.env`, use ese mismo nombre en ambos comandos.

### 3. Ejecutar el preflight

Antes de construir imágenes o iniciar contenedores, ejecute el diagnóstico de
preinstalación. Es de solo lectura: no crea redes, directorios, contenedores ni
modifica `.env`.

```sh
bash scripts/preflight.sh
```

Comprueba sistema, Docker/Compose, herramientas auxiliares, RAM, espacio,
variables y perfiles, permisos de `.env`, persistencia previa, permisos de los
bind mounts, puertos, red externa y el Compose efectivo. El resultado termina en:

```text
[READY] ...
```

o:

```text
[BLOCKED] ...
```

No continúe con `docker compose up` mientras existan errores bloqueantes. Para
automatización están disponibles:

```sh
bash scripts/preflight.sh --quiet
bash scripts/preflight.sh --json
bash scripts/preflight.sh --verbose
```

### 4. Configurar DNS y HTTPS

Haga que el registro A y, si corresponde, AAAA de `NEXTCLOUD_DOMAIN` resuelva al
host. Permita tráfico entrante TCP 80/443 y confirme que ningún otro proceso usa
los puertos configurados. Si publica directamente un puerto HTTPS distinto de
443, ajústelo también en `NEXTCLOUD_TRUSTED_DOMAINS`,
`NEXTCLOUD_OVERWRITE_HOST` y `NEXTCLOUD_PUBLIC_URL`.

Los componentes opcionales se controlan con `COMPOSE_PROFILES`:

```ini
COMPOSE_PROFILES=                         # Nextcloud base
COMPOSE_PROFILES=onlyoffice               # Nextcloud + OnlyOffice
COMPOSE_PROFILES=acme                     # Nextcloud + ACME
COMPOSE_PROFILES=manager                  # panel administrativo local
COMPOSE_PROFILES=onlyoffice,manager       # OnlyOffice + panel
COMPOSE_PROFILES=acme,onlyoffice,manager  # todos los perfiles opcionales
```

Para terminar TLS en otro proxy, no active `acme`, ajuste
`NEXTCLOUD_OVERWRITE_PROTOCOL` y documente su propia cadena de proxies confiables. Detalles:
[docs/configuration.md](docs/configuration.md#dominio-proxy-y-tls).

### 5. Validar, construir e iniciar

Valide primero la base y después la combinación efectiva. El segundo comando
incluye automáticamente `compose.override.yaml` si existe:

```sh
docker compose -f compose.yaml config --quiet
docker compose config --quiet
docker compose config --services
```

Revise el resultado sin publicar la salida completa, porque la configuración
expandida contiene secretos. Luego construya la imagen derivada y arranque:

```sh
docker compose build app
docker compose up -d
docker compose ps
```

Esos dos últimos pasos modifican el runtime. Ejecútelos solo después de revisar
el plan y las copias de seguridad. Esta actualización del repositorio no los
ejecutó.

### 6. Acceso inicial y OnlyOffice

Abra la URL indicada por `NEXTCLOUD_PUBLIC_URL`. Las variables de `.env`
realizan la instalación inicial de Nextcloud cuando el volumen está vacío.

Con `install.sh`, si activó el perfil `onlyoffice`, el instalador también
instala o habilita automáticamente la app oficial **ONLYOFFICE** y configura las
URLs interna/pública, la cabecera JWT y el secreto del conector.

Si no activó `onlyoffice`, Document Server no se crea ni consume recursos.

En instalaciones manuales puede aplicar la integración después con:

```sh
bash set_config.sh --apply \
  --public-url https://cloud.example.com \
  --allow-local-remote-servers \
  --install-app
```

Para desarrollo local también se admite una URL `http://`. Pruebe después la
creación y edición de un documento; un healthcheck correcto no demuestra por sí
solo que la integración funcione extremo a extremo.

## Comprobaciones y administración

El diagnóstico es de solo lectura:

```sh
bash scripts/doctor.sh
```

También puede usar:

```sh
docker compose ps -a
docker compose logs --tail=200 SERVICIO
docker compose logs --tail=200 --follow SERVICIO
docker compose exec --user www-data app php occ status
```

También puede habilitar el panel administrativo local:

```sh
bash manage.sh manager-on
```

Por seguridad escucha en `127.0.0.1:8090` de forma predeterminada y solo
permite operaciones acotadas sobre los contenedores de este proyecto. Consulte
[la guía del panel administrativo](docs/manager.md).

Los logs pueden contener nombres, direcciones y URLs. Redáctelos antes de
compartirlos. Comandos habituales:

```sh
docker compose stop SERVICIO
docker compose start SERVICIO
docker compose restart SERVICIO
```

No use `down -v`: elimina volúmenes Docker y puede destruir estado. En este
repositorio la mayor parte de la persistencia son bind mounts, que tampoco se
restauran con un simple rollback de Git.

## Persistencia

| Ruta | Contenido principal |
| --- | --- |
| `db/` | Directorio de datos de MariaDB |
| `data/` | Archivos de usuarios de Nextcloud |
| `nextcloud/page/web/` | Árbol `/var/www/html` |
| `nextcloud/apps/` | Apps incluidas persistidas |
| `nextcloud/custom_apps/` | Apps instaladas o personalizadas |
| `nextcloud/config/` | Configuración viva de Nextcloud |
| `config/redis/data/` | Persistencia de Redis |
| `config/proxy/` | Configuración generada, desafíos y certificados |
| `config/acme/` | Cuenta y estado de acme.sh |
| `config/onlyoffice/` | Datos, logs, caché, archivos de ejemplo y fuentes |
| `.env` | Versiones, dominio y secretos de Compose |

Todos estos paths son locales e ignorados por Git. Mantenga el checkout y los
bind mounts en la misma ubicación o adapte un override antes de moverlos.

## Personalización con overrides

```sh
cp compose.override.example.yaml compose.override.yaml
```

`compose.override.yaml` está ignorado. Compose lo combina automáticamente al
ejecutar `docker compose` desde la raíz sin `-f`. Si usa `-f`, debe indicar todos
los archivos en orden:

```sh
docker compose -f compose.yaml -f compose.override.yaml config --quiet
```

Use overrides para puertos de mantenimiento, límites, mounts o una imagen local;
no cambie la base pública ni reutilice nombres de servicio de otro servidor.

## Dockge

Dockge debe administrar el mismo directorio que contiene `compose.yaml`, `.env`,
los overrides y los bind mounts. No copie solo el YAML ni cambie la ruta de una
instalación con datos. Para una instalación nueva, clone el repositorio dentro
del directorio de stacks configurado en Dockge y prepare `.env` antes de escanear.

La imagen `NEXTCLOUD_APP_IMAGE` es local y requiere una construcción deliberada.
No use **Update**, **Pull all** o **Rebuild with pull** como rutina. Consulte la
[guía de Dockge](docs/dockge.md).

## Actualización, backup y restauración

Antes de cambiar cualquier referencia de imagen:

1. guarde el Compose efectivo, `.env` por un canal cifrado y las referencias de
   imagen;
2. obtenga un dump consistente de MariaDB y una copia coordinada de los datos;
3. verifique hashes y restaure el backup en un entorno aislado;
4. revise las notas de Nextcloud, MariaDB, OnlyOffice y la imagen base;
5. valide Compose, construya y pruebe fuera de producción;
6. aplique un componente durante una ventana de mantenimiento.

Un downgrade de archivos no revierte una migración de base de datos. No habilite
actualizaciones automáticas de MariaDB ni salte versiones mayores. Procedimiento:
[docs/backup-restore.md](docs/backup-restore.md).

## Documentación

- [Instalador guiado](docs/installer.md)
- [Configuración y secretos](docs/configuration.md)
- [Preflight de instalación](docs/preflight.md)
- [Dockge](docs/dockge.md)
- [Transición desde docker-compose.yml](docs/migration-compose.md)
- [Backup y restauración](docs/backup-restore.md)
- [Diagnóstico y problemas frecuentes](docs/troubleshooting.md)
- [Panel administrativo web](docs/manager.md)
- [Limitaciones y pruebas pendientes](docs/known-limitations.md)

## Seguridad antes de publicar un fork

- No rastree `.env`, datos, dumps, claves privadas, certificados, logs ni
  overrides locales.
- Revise tanto el índice como el historial; `.gitignore` no borra commits
  anteriores.
- Rote cualquier contraseña o JWT que haya aparecido en un commit o captura.
- El socket Docker montado en proxy y ACME equivale a un privilegio elevado.
- Mantenga MariaDB y Redis sin puertos públicos.

El historial de este proyecto incluyó material que puede haber expuesto un JWT y
archivos de entorno. El candidato actual los retira, pero la rotación y una posible
limpieza de historial son decisiones administrativas separadas y aún pendientes.

## Licencia

Revise las licencias de este repositorio y de cada imagen antes de redistribuir
una instalación o imagen derivada.
