# Configuración

La configuración privada vive en `.env`, que Docker Compose carga para
interpolar `compose.yaml`. No existen contraseñas predeterminadas ni archivos env
adicionales por servicio. `.env` está ignorado por Git y debe tener modo `0600`.

```sh
umask 077
cp .env.example .env
chmod 600 .env
```

No use `docker compose config` sin `--quiet` en una terminal compartida: la
salida expandida contiene secretos.

## Variables

### Proyecto e imágenes

| Variable | Obligatoria | Uso |
| --- | --- | --- |
| `COMPOSE_PROJECT_NAME` | Sí | Identidad estable del proyecto |
| `COMPOSE_PROFILES` | No | `acme` activa el companion; vacío lo omite |
| `NEXTCLOUD_BASE_IMAGE` | Sí | Imagen oficial FPM Alpine usada por el build |
| `NEXTCLOUD_APP_IMAGE` | Sí | Nombre distinto para la imagen derivada local |
| `MARIADB_IMAGE` | Sí | Referencia completa de MariaDB |
| `REDIS_IMAGE` | Sí | Referencia completa de Redis oficial |
| `NGINX_IMAGE` | Sí | Referencia completa de Nginx |
| `NGINX_PROXY_IMAGE` | Sí | Referencia completa de nginx-proxy |
| `ACME_COMPANION_IMAGE` | Sí | Referencia completa de acme-companion |
| `ONLYOFFICE_IMAGE` | Sí | Referencia completa de Document Server |

Use tags exactos o digests. No use `latest`, `stable`, `production`, `alpine` sin
versión ni una referencia sin tag. Actualizar un pin sigue siendo una operación
deliberada: revise compatibilidad y pruebe restauración antes.

### Dominio, proxy y TLS

| Variable | Obligatoria | Uso |
| --- | --- | --- |
| `NEXTCLOUD_DOMAIN` | Sí | Host sin esquema ni ruta |
| `NEXTCLOUD_TRUSTED_DOMAINS` | Sí | Hosts aceptados por Nextcloud; puede incluir puerto |
| `NEXTCLOUD_OVERWRITE_PROTOCOL` | Sí | Normalmente `https`; `http` solo en redes confiables |
| `NEXTCLOUD_OVERWRITE_HOST` | Sí | Host público que Nextcloud anuncia, incluido puerto no estándar |
| `NEXTCLOUD_PUBLIC_URL` | Sí | URL pública completa usada por CLI y jobs |
| `NGINX_PROXY_NETWORK` | Sí | Red Docker externa compartida |
| `PROXY_BIND_ADDRESS` | Sí | Dirección de escucha del host; por defecto todas |
| `HTTP_PORT` / `HTTPS_PORT` | Sí | Puertos publicados por `proxy` |
| `ACME_EMAIL` | Con perfil ACME | Avisos y recuperación de la cuenta ACME |

`NEXTCLOUD_DOMAIN` alimenta `VIRTUAL_HOST` y `ACME_HOST`, por lo que nunca debe
contener esquema, ruta ni puerto. Para publicar directamente un puerto HTTPS no
estándar, inclúyalo en `NEXTCLOUD_TRUSTED_DOMAINS`,
`NEXTCLOUD_OVERWRITE_HOST` y `NEXTCLOUD_PUBLIC_URL`. Debe existir un registro A
y, si publica IPv6, AAAA que apunte al host. El desafío HTTP-01 requiere acceso
externo al puerto 80 además de 443.

Si otro balanceador termina TLS, deje `COMPOSE_PROFILES` vacío, no publique el
perfil ACME y configure los proxies confiables de Nextcloud para las direcciones
reales de su entorno. No acepte cabeceras reenviadas desde redes no confiables.

La red externa no se crea automáticamente:

```sh
docker network inspect nginx-proxy >/dev/null 2>&1 || docker network create nginx-proxy
```

Sustituya el nombre si cambió `NGINX_PROXY_NETWORK`.

### Base de datos e instalación inicial

| Variable | Obligatoria | Uso |
| --- | --- | --- |
| `MYSQL_DATABASE` | Sí | Base de datos de Nextcloud |
| `MYSQL_USER` | Sí | Usuario de aplicación |
| `MYSQL_PASSWORD` | Sí | Contraseña del usuario de aplicación |
| `MYSQL_ROOT_PASSWORD` | Sí | Contraseña administrativa, solo inyectada en `db` |
| `NEXTCLOUD_ADMIN_USER` | Sí en instalación nueva | Usuario administrador inicial |
| `NEXTCLOUD_ADMIN_PASSWORD` | Sí en instalación nueva | Contraseña inicial |

El servicio `app` recibe únicamente la credencial de aplicación, no la de root.
Las variables de administrador solo afectan una instalación inicial; cambiarlas
después no cambia automáticamente la contraseña de una cuenta existente.

Para migraciones existentes, preserve los valores y el nombre del proyecto. No
copie `.env.example` sobre `.env` ni apunte el stack a un directorio de base de
datos incompatible.

### Redis y OnlyOffice

| Variable | Obligatoria | Uso |
| --- | --- | --- |
| `REDIS_PASSWORD` | Sí | Contraseña compartida por Redis y Nextcloud |
| `ONLYOFFICE_JWT_SECRET` | Sí | JWT compartido por Document Server y el conector |

Genere valores independientes de al menos 32 bytes:

```sh
openssl rand -hex 32
```

`REDIS_PASSWORD` debe conservar el formato hexadecimal de esa orden (64 o más
caracteres). El entrypoint lo valida antes de crear dentro del contenedor un
archivo de configuración temporal con modo restrictivo; el secreto no forma
parte del argv de `redis-server`.

Redis no publica puerto y solo se conecta a `backend`, marcada como interna.
Aunque el secreto aparece en el entorno de sus contenedores, no se expone por
línea de comandos ni por una red compartida. Restrinja el acceso al daemon Docker,
que permite inspeccionar esos entornos.

## Integración de OnlyOffice

Nginx publica Document Server en `https://DOMINIO/ds-vpath/`; las conexiones
internas usan `http://onlyoffice/` y `http://web/`. El JWT usa la cabecera
`AuthorizationJwt` en ambos extremos.

Después de instalar y habilitar la app oficial ONLYOFFICE en Nextcloud:

```sh
bash set_config.sh --apply \
  --public-url https://cloud.example.com \
  --allow-local-remote-servers
```

El último flag es deliberado. Nextcloud bloquea por defecto destinos locales para
reducir SSRF; esta topología necesita permitir los nombres internos confinados a
las redes Docker. No habilite esa opción si permite a usuarios no confiables
configurar destinos arbitrarios. Como alternativa, diseñe una ruta pública de
callback y mantenga la protección.

El script:

- valida el Compose efectivo y los servicios lógicos;
- exige que la app ya esté habilitada;
- no instala ni actualiza aplicaciones;
- añade el hostname interno `web` a `trusted_domains` si falta;
- toma el JWT del Compose sin mostrarlo;
- configura URLs, cabecera y secreto marcado como sensible;
- requiere dos confirmaciones explícitas en su línea de comandos.

Pruebe un documento real después. El healthcheck solo comprueba el motor de
Document Server.

## Límites PHP y Nginx

El conjunto de referencia usa `PHP_UPLOAD_LIMIT=10G` y dos directivas Nginx de
10G: `config/nginx/nginx.conf` y `config/nginx/uploadsize.conf`. El límite
efectivo es el menor de toda la cadena, incluido cualquier proxy externo.

Si cambia `PHP_UPLOAD_LIMIT`, cree copias locales de ambos archivos Nginx, ajuste
sus directivas y móntelas mediante `compose.override.yaml`. No edite solo una
capa. `PHP_MEMORY_LIMIT` no debe confundirse con el límite total de memoria del
contenedor ni con memoria por todos los workers FPM.

## Zona horaria y correo

`TZ` se comparte con los servicios. Use un nombre válido de la base tz, por
ejemplo `UTC`.

El Compose base no inventa SMTP. Configure correo después de la instalación con
la interfaz administrativa, `occ` o variables adicionales en un override. No
guarde la contraseña SMTP en un archivo rastreado.

## Overrides

`compose.override.yaml` se carga automáticamente solo al ejecutar `docker compose`
desde el directorio del proyecto sin `-f`. Con archivos explícitos:

```sh
docker compose -f compose.yaml -f compose.override.yaml config --quiet
```

Un override puede publicar MariaDB temporalmente en `127.0.0.1`, añadir un ini
local o elegir otro Dockerfile. Valide siempre la combinación efectiva. Cambiar
nombres de servicios, proyecto, mounts o redes puede crear contenedores nuevos y
dejar datos aparentemente vacíos.
