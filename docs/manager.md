# Panel administrativo web

El perfil opcional `manager` añade una interfaz web para consultar y administrar
los contenedores del proyecto Compose sin exponer una terminal.

## Alcance actual

La primera versión permite:

- iniciar, detener y reiniciar servicios del proyecto;
- consultar estado, health e imagen efectiva;
- mostrar CPU, RAM, disco libre, tamaños de data/DB/backups y consumo por contenedor;
- mostrar uptime, memoria y CPU instantánea de cada servicio;
- mostrar la versión de Nextcloud mediante `occ status`;
- ejecutar una vista de diagnóstico para MariaDB, Redis, Nginx, proxy, OCC y OnlyOffice;
- activar o desactivar el modo mantenimiento de Nextcloud;
- crear backups en segundo plano reutilizando `scripts/backup.sh`;
- listar backups existentes, tamaño y estructura esperada;
- verificar `SHA256SUMS` y la integridad gzip del dump SQL;
- consultar la salida del último backup;
- aplicar las referencias actuales de `.env` reutilizando `scripts/update.sh`;
- exigir confirmación textual antes de actualizar y bloquear acciones concurrentes;
- consultar la salida de la última actualización;
- editar de forma segura una allowlist de parámetros no sensibles de `.env`;
- consultar si los secretos esperados están configurados sin revelar su valor;
- listar usuarios de Nextcloud y consultar su detalle mediante OCC;
- habilitar/deshabilitar usuarios con confirmación textual, protegiendo la cuenta administrativa inicial;
- listar apps habilitadas/deshabilitadas y cambiar su estado mediante OCC;
- bloquear la desactivación desde el panel de apps consideradas esenciales;
- consultar las últimas 250 líneas de logs por servicio;
- administrar únicamente contenedores con la etiqueta
  `com.docker.compose.project` que coincide con este stack.

Restore permanece por CLI. La edición de `.env` se limita a una allowlist de
parámetros no sensibles; los secretos nunca se muestran. El panel no duplica
la lógica de backup ni actualización: ejecuta los mismos `scripts/backup.sh` y
`scripts/update.sh` usados por la CLI. Las operaciones se ejecutan en segundo
plano y usan bloqueos para impedir que backup/update se solapen.

## Activación recomendada

En una instalación existente:

```sh
bash manage.sh manager-on
```

El comando:

1. añade `manager` a `COMPOSE_PROFILES`;
2. genera `MANAGER_ADMIN_PASSWORD` si falta;
3. genera `MANAGER_SECRET_KEY` si falta;
4. conserva una configuración existente;
5. construye e inicia el servicio `manager`.

De forma predeterminada escucha exclusivamente en:

```text
http://127.0.0.1:8090
```

Por ello, desde otro equipo puede acceder temporalmente mediante un túnel SSH:

```sh
ssh -L 8090:127.0.0.1:8090 usuario@servidor
```

y abrir `http://127.0.0.1:8090` en el navegador local.

Para desactivarlo:

```sh
bash manage.sh manager-off
```

Los secretos permanecen en `.env` para que una reactivación no cambie las
credenciales automáticamente.

## Variables

```ini
MANAGER_IMAGE=nextcloud-stack-manager:0.1.0
MANAGER_BIND_ADDRESS=127.0.0.1
MANAGER_PORT=8090
MANAGER_PROJECT_HOST_PATH=/ruta/absoluta/al/checkout
MANAGER_ADMIN_USER=admin
MANAGER_ADMIN_PASSWORD=
MANAGER_SECRET_KEY=
MANAGER_COOKIE_SECURE=false
```

Use una contraseña larga y un secreto aleatorio. `manager-on` los genera cuando
están ausentes.

## Seguridad

El panel monta `/var/run/docker.sock` para ejecutar acciones Docker. El acceso
al socket Docker equivale, en la práctica, a un privilegio muy alto sobre el
host. Por esa razón:

- el puerto se enlaza a `127.0.0.1` de forma predeterminada;
- no existe terminal web ni endpoint para comandos arbitrarios;
- las acciones se limitan a una allowlist de servicios y a
  `start`, `stop` y `restart`;
- las operaciones mutables usan POST y token CSRF;
- la sesión usa cookies HttpOnly y SameSite=Lax;
- se añaden cabeceras de seguridad y CSP;
- no publique el puerto 8090 directamente a Internet.

Si en el futuro se publica detrás de HTTPS, cambie:

```ini
MANAGER_COOKIE_SECURE=true
```

y mantenga autenticación adicional en el reverse proxy cuando corresponda.

## Desarrollo

El código vive en:

```text
manager/
├── Dockerfile
├── requirements.txt
├── app.py
├── templates/
└── static/
```

La UI sigue el mismo patrón del administrador de instancias CFDI: login,
dashboard de tarjetas, acciones acotadas y vistas de detalle/logs.


## Backups desde el panel

La vista **Backups** muestra hasta 25 copias recientes bajo `backups/`. El
botón **Crear backup** arranca `scripts/backup.sh` en segundo plano; el
navegador puede cerrarse sin cancelar el proceso mientras el contenedor
`manager` continúe en ejecución.

El panel muestra la salida reciente del trabajo y permite **Verificar hashes**.
La verificación ejecuta `sha256sum --check --strict SHA256SUMS` y `gzip -t`
sobre el dump SQL.

`MANAGER_PROJECT_HOST_PATH` es necesario porque Docker interpreta rutas de bind
mount desde el host. `bash manage.sh manager-on` establece automáticamente la
ruta absoluta actual del repositorio para evitar que el proceso de backup monte
una ruta incorrecta.

No se ofrece restauración desde la web en esta versión. Una restauración puede
reemplazar estado completo y se mantendrá fuera del panel hasta contar con una
confirmación reforzada y una prueba aislada del flujo.


## Actualizaciones desde el panel

La vista **Actualizar** muestra únicamente referencias no sensibles de `.env`
(imágenes y perfiles). El panel **no edita versiones**.

Para aplicar las referencias actuales se debe escribir literalmente
`ACTUALIZAR`. Después se ejecuta el mismo flujo que:

```sh
bash scripts/update.sh --apply
```

Ese flujo realiza preflight, backup obligatorio, mantenimiento, pull de imágenes
configuradas, rebuild de la imagen Nextcloud, recreación del stack principal,
`occ upgrade` cuando corresponde y diagnóstico final.

El servicio `manager` se excluye deliberadamente del pull y de la recreación
durante ese flujo para que la interfaz y el proceso de actualización no se
destruyan a sí mismos. No existe rollback automático de migraciones de base de
datos; ante un fallo debe usarse el backup creado inmediatamente antes.

Mientras hay un backup o una actualización activa, el panel bloquea nuevas
operaciones de backup, update, mantenimiento y start/stop/restart de servicios
para evitar interferencias.


## Métricas del sistema

El dashboard muestra un resumen de recursos usando información de Docker y del
filesystem donde vive el checkout:

- CPU y memoria total visibles por Docker;
- espacio total/libre/usado del filesystem del proyecto;
- tamaño de `data/`, `db/` y `backups/`;
- tamaño lógico de la base Nextcloud consultado desde `information_schema`;
- CPU, memoria y uptime por contenedor.

Los tamaños de directorio se calculan con `du` y tienen timeout para evitar que
una ruta muy grande bloquee indefinidamente el panel. Las métricas son
informativas y no sustituyen una plataforma de monitoreo histórico.


## Configuración administrable

La vista **Configuración** permite modificar únicamente campos explícitamente
permitidos:

- dominio/host público;
- protocolo HTTP/HTTPS;
- zona horaria;
- `PHP_MEMORY_LIMIT`;
- `PHP_UPLOAD_LIMIT`;
- modo desarrollo (`NEXTCLOUD_DEV_MODE`);
- perfiles `onlyoffice` y `acme`;
- correo ACME.

Al cambiar dominio se sincronizan también
`NEXTCLOUD_TRUSTED_DOMAINS`, `NEXTCLOUD_OVERWRITE_HOST` y
`NEXTCLOUD_PUBLIC_URL`.

Antes de escribir se crea automáticamente una copia:

```text
.env.bak.manager.YYYYMMDD-HHMMSS
```

El guardado es atómico y mantiene `.env` con permisos 600. Los secretos de
MariaDB, Redis, OnlyOffice y el propio manager no son editables ni visibles;
solo se indica si están configurados.

Guardar configuración no recrea contenedores. Después de revisar los cambios,
use la vista **Actualizar** para aplicar las referencias y variables actuales al
runtime con el flujo seguro ya existente.

Al activar **Modo desarrollo**, el panel guarda `NEXTCLOUD_DEV_MODE=true`.
Cuando se aplica mediante Actualizar, `app` se reconstruye/recrea y arranca con
debug de Nextcloud, `loglevel=0`, errores PHP visibles y OPcache deshabilitado.
Al desactivarlo se vuelve al comportamiento normal.


## Usuarios y apps de Nextcloud

La vista **Usuarios** usa `occ user:list` y `occ user:info`. Las acciones
mutables disponibles son `user:enable` y `user:disable`; requieren escribir
exactamente el UID antes de ejecutar el cambio. La cuenta indicada por
`NEXTCLOUD_ADMIN_USER` no puede deshabilitarse desde el panel.

La vista **Apps** usa `occ app:list`, `app:enable` y `app:disable`. Cada
cambio requiere escribir exactamente el ID de la app. El panel mantiene una
lista conservadora de apps protegidas (por ejemplo `files`, `settings`,
`provisioning_api`, `oauth2`, `theming`) que no pueden deshabilitarse desde
la interfaz.

Estas acciones también quedan bloqueadas durante backup o update para evitar
cambios concurrentes sobre Nextcloud.


### Propiedad de .env

El manager preserva UID, GID y permisos del archivo `.env` al guardar cambios.
Las primeras versiones de la vista de configuración podían reemplazar el archivo
desde el contenedor y dejarlo propiedad de `root` en el host. Si una instalación
afectada muestra `Permission denied`, restaure el propietario al usuario que
administra el checkout y mantenga permisos `600`.
