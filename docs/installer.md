# Instalador guiado

`install.sh` es la ruta recomendada para instalaciones nuevas. Su objetivo es
que el usuario no tenga que editar `.env`, generar secretos ni memorizar comandos
de Docker Compose.

## Uso recomendado

```sh
bash install.sh
```

El asistente permite elegir desarrollo básico, desarrollo con OnlyOffice,
producción con HTTPS o una configuración personalizada.

También se puede usar directamente:

```sh
bash install.sh --dev
bash install.sh --dev-full
bash install.sh --production --domain nube.example.com --email admin@example.com
```

## Qué hace automáticamente

El instalador:

- valida Docker y Docker Compose;
- detecta la zona horaria cuando es posible;
- genera contraseñas independientes para MariaDB y Redis;
- genera JWT para OnlyOffice solo cuando el perfil está activo;
- crea `.env` con permisos `0600`;
- restaura un umask seguro antes de crear persistencia;
- crea los bind mounts necesarios;
- aplica permisos compatibles con Nginx;
- crea la red externa de nginx-proxy si falta;
- ejecuta `scripts/preflight.sh`;
- construye la imagen de Nextcloud;
- inicia los servicios;
- espera healthchecks cuando Compose soporta `--wait`;
- si OnlyOffice está activo, instala y habilita automáticamente la app conectora y aplica su configuración;
- ejecuta `scripts/doctor.sh` de forma silenciosa cuando todo está bien;
- muestra un resumen simple por componente;
- solo imprime el diagnóstico técnico completo cuando algo falla;
- muestra la URL y el usuario administrador.

Si la contraseña del administrador se deja vacía, genera una automáticamente y
la muestra al final.

## Presets

### Desarrollo básico

```sh
bash install.sh --dev
```

Configura:

```text
HTTP
localhost
sin ACME
sin OnlyOffice
```

Es el modo recomendado para desarrollar apps o trabajar sobre Nextcloud sin
consumir recursos en Document Server.

### Desarrollo completo

```sh
bash install.sh --dev-full
```

Configura:

```text
HTTP
localhost
sin ACME
con OnlyOffice
```

### Producción

```sh
bash install.sh --production
```

Solicita dominio y correo ACME, habilita HTTPS automático y pregunta si desea
OnlyOffice.

También acepta:

```sh
bash install.sh --production \
  --domain nube.example.com \
  --email admin@example.com
```

### Personalizado

```sh
bash install.sh --custom
```

Permite decidir protocolo, ACME y OnlyOffice.

## Preparar sin arrancar

Para validar una instalación sin construir ni iniciar contenedores:

```sh
bash install.sh --dev --no-start
```

Esto crea la configuración, directorios y red, y ejecuta el preflight.

## Instalaciones existentes

El instalador detecta primero si ya existe persistencia y evita reemplazar
`.env`, contraseñas, MariaDB o archivos de usuario.

Una instalación básica existente puede ampliarse con OnlyOffice usando:

```sh
bash install.sh --dev-full
```

En ese caso el instalador conserva toda la configuración existente, añade el
perfil `onlyoffice`, genera el JWT solo si hace falta, guarda una copia de
`.env`, crea únicamente los directorios de Document Server, inicia OnlyOffice y
configura la app conectora dentro de Nextcloud.

La reconfiguración automática de dominio, HTTPS o credenciales de una instalación
existente sigue bloqueada deliberadamente porque puede afectar un despliegue en
producción.

En instalaciones nuevas, si existe únicamente un `.env` pero no hay datos, el
instalador pide confirmación antes de sustituirlo y guarda una copia con modo
`0600`.

## Opciones

```text
--dev
--dev-full
--production
--custom
--domain HOST
--email EMAIL
--admin-user USER
--admin-password PASS
--timezone TZ
--with-onlyoffice
--without-onlyoffice
--no-start
--force-config
```

Evite pasar `--admin-password` en equipos compartidos porque puede quedar en el
historial del shell o ser visible temporalmente en la lista de procesos. En modo
interactivo la contraseña se solicita sin eco.

## Preflight y doctor

El instalador usa ambas herramientas automáticamente:

```text
install.sh
   │
   ├── crea configuración
   ├── prepara persistencia y red
   │
   ├── preflight.sh
   │      └── valida antes de iniciar
   │
   ├── docker compose build/up
   │
   └── doctor.sh
          └── valida el runtime
```

Para diagnóstico manual siguen disponibles:

```sh
bash scripts/preflight.sh
bash scripts/doctor.sh
```

## OnlyOffice automático

Cuando el perfil `onlyoffice` está activo, el instalador también instala o
habilita la app ONLYOFFICE en Nextcloud y aplica automáticamente la configuración
necesaria para enlazarla con Document Server.

Si la descarga de la app desde Nextcloud App Store falla, Nextcloud permanece
funcionando y el instalador muestra el error para reintentar únicamente esa
integración más tarde con `set_config.sh`.

Para desarrollo local, `set_config.sh` admite una URL pública HTTP; en
producción se mantiene HTTPS.



## Modo desarrollo

Los presets `--dev` y `--dev-full` activan automáticamente:

```ini
NEXTCLOUD_DEV_MODE=true
```

Al arrancar `app`, esto habilita `debug => true` y `loglevel => 0` en
Nextcloud, desactiva OPcache para PHP-FPM/CLI y activa la visualización de
errores PHP. No use este modo en servidores públicos.

En una instalación existente puede alternarlo con:

```sh
bash manage.sh dev-on
bash manage.sh dev-off
```

Ambos comandos guardan una copia de `.env`, reconstruyen la imagen `app` y
recrean `app/web` para aplicar el cambio.
