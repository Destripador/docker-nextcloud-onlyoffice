# Preflight de instalación

`scripts/preflight.sh` valida el host y la configuración antes de construir o
iniciar el stack. Es deliberadamente de solo lectura: no crea directorios, redes,
contenedores ni modifica `.env`.

## Uso

```sh
bash scripts/preflight.sh
```

Modos adicionales:

```sh
bash scripts/preflight.sh --quiet
bash scripts/preflight.sh --verbose
bash scripts/preflight.sh --json
```

Los códigos de salida son:

- `0`: no hay errores bloqueantes;
- `1`: existe al menos un error que debe corregirse antes de iniciar;
- `2`: uso incorrecto o error interno del preflight.

Las advertencias no cambian el código de salida a error.

## Qué comprueba

El preflight revisa:

- Linux, arquitectura y versión de Bash;
- Git, OpenSSL y jq;
- Docker Engine, acceso al daemon y Docker Compose V2;
- RAM y espacio disponible en el filesystem del proyecto;
- existencia y permisos de `.env`;
- variables base y formato de `REDIS_PASSWORD`;
- requisitos condicionales de los perfiles `onlyoffice` y `acme`;
- estado de persistencia: `NEW`, `EXISTING` o `PARTIAL`;
- combinación peligrosa de un datadir MariaDB existente sin `config.php`;
- permisos de los bind mounts que debe leer Nginx;
- disponibilidad de los puertos HTTP/HTTPS cuando el proyecto no está corriendo;
- existencia de la red externa de nginx-proxy;
- `docker compose config --quiet` y los servicios efectivos.

## Estados de persistencia

`NEW` significa que no se detectaron datos previos de MariaDB, datos de usuario
ni `nextcloud/config/config.php`.

`EXISTING` significa que existe un datadir MariaDB y un `config.php`. El
preflight no asume que la instalación sea sana; use también
`scripts/doctor.sh` cuando los servicios estén levantados.

`PARTIAL` significa que solo existe una parte del estado esperado. Es una señal
para revisar una instalación interrumpida, una restauración incompleta o un
checkout apuntando a rutas equivocadas.

## Perfiles

Con:

```ini
COMPOSE_PROFILES=
```

no se exige configuración de OnlyOffice ni ACME.

Con:

```ini
COMPOSE_PROFILES=onlyoffice
```

también se valida `ONLYOFFICE_IMAGE`, un `ONLYOFFICE_JWT_SECRET` hexadecimal
de al menos 64 caracteres y se avisa si el host tiene menos de 4 GiB de RAM.

Con:

```ini
COMPOSE_PROFILES=acme
```

se valida correo ACME, dominio no local, protocolo HTTPS y URL pública HTTPS.

Los perfiles pueden combinarse:

```ini
COMPOSE_PROFILES=acme,onlyoffice
```

## Diferencia frente a doctor.sh

Use `preflight.sh` **antes** de `docker compose up`.

Use `doctor.sh` **después** de iniciar el stack para comprobar contenedores,
healthchecks, MariaDB, Redis, Nginx, Nextcloud y, si corresponde, OnlyOffice.

Una instalación nueva debería seguir esta secuencia:

```text
.env
  ↓
directorios + red externa
  ↓
preflight.sh
  ↓
docker compose build/up
  ↓
doctor.sh
```

## Salida JSON

`--json` está pensado para el futuro instalador y para CI. Ejemplo:

```json
{
  "status": "READY",
  "installation_state": "NEW",
  "onlyoffice": false,
  "acme": false,
  "ok": 18,
  "info": 8,
  "warnings": 0,
  "errors": 0
}
```

El JSON es un resumen. Para investigar un fallo ejecute el modo normal o
`--verbose`.
