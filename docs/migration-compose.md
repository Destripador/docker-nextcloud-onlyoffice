# Transición a compose.yaml

`compose.yaml` es la fuente canónica. El repositorio conserva temporalmente
`docker-compose.yml` como enlace simbólico a ese archivo para no mantener dos
copias divergentes.

## Compatibilidad

- Docker Compose V2 descubre `compose.yaml` automáticamente.
- Un comando que indica `-f docker-compose.yml` funciona en clones que preservan
  enlaces simbólicos.
- Algunos ZIP, filesystems y checkouts Windows con `core.symlinks=false` pueden
  materializar el enlace como texto y no como YAML válido.
- El enlace no proporciona soporte para Docker Compose V1.

Automatizaciones nuevas deben usar `docker compose` y `compose.yaml`. El enlace
puede retirarse en una futura versión mayor cuando los consumidores hayan sido
migrados.

## Clon nuevo

No necesita ninguna conversión:

```sh
docker compose -f compose.yaml config --quiet
docker compose config --quiet
```

El primer comando valida solo la base. El segundo valida la combinación efectiva
y carga `compose.override.yaml` automáticamente si existe.

Compruebe el enlace sin modificarlo:

```sh
test -L docker-compose.yml
test "$(readlink docker-compose.yml)" = compose.yaml
```

En plataformas sin symlinks, use directamente `compose.yaml`; no copie ambos
archivos y los edite por separado.

## Instalación existente

Cambiar el nombre del archivo no debería cambiar el proyecto, pero cambiar el
directorio, `COMPOSE_PROJECT_NAME`, nombres de servicio o bind mounts sí puede
crear recursos nuevos. Antes de ejecutar `up`:

1. guarde el Compose anterior fuera del checkout;
2. respalde `.env` por un canal cifrado;
3. cree un dump consistente y una copia coordinada de los datos;
4. registre proyecto, working directory, servicios, imágenes, mounts, puertos y
   redes de los contenedores existentes;
5. construya un override local que preserve cualquier diferencia legítima;
6. valide la base y la combinación efectiva sin iniciar servicios;
7. compare un dry-run si su versión de Compose lo soporta.

Ejemplo de copia fuera del repositorio:

```sh
umask 077
mkdir -p ../nextcloud-compose-backup
cp -p docker-compose.yml ../nextcloud-compose-backup/docker-compose.yml
cp -p .env ../nextcloud-compose-backup/env
sha256sum ../nextcloud-compose-backup/* > ../nextcloud-compose-backup/SHA256SUMS
```

No publique ese directorio; contiene configuración privada. El ejemplo solo
protege archivos de configuración, no base de datos ni datos de usuarios.

Validación previa:

```sh
docker compose -f compose.yaml config --quiet
docker compose config --quiet
docker compose config --services
docker compose config --images
```

La lista de imágenes no contiene secretos. No comparta el Compose expandido.

Un dry-run es informativo, no una garantía:

```sh
docker compose --dry-run up -d
```

Aborte si anuncia pulls, builds, servicios, mounts, redes, puertos o volúmenes no
previstos. No añada `--remove-orphans` hasta identificar cada contenedor asociado
al proyecto.

## Overrides durante la transición

Copie el ejemplo y mantenga las diferencias locales fuera de Git:

```sh
cp compose.override.example.yaml compose.override.yaml
docker compose config --quiet
```

Si una herramienta exige archivos explícitos, indique ambos:

```sh
docker compose -f compose.yaml -f compose.override.yaml config --quiet
```

Pasar únicamente `-f compose.yaml` omite el override automático.

## Rollback

Restaurar el archivo Compose anterior solo revierte la definición. No revierte:

- migraciones de Nextcloud;
- cambios de esquema de MariaDB;
- archivos escritos por un entrypoint;
- certificados, apps o datos modificados.

El rollback real es restaurar un conjunto consistente de configuración, base de
datos y datos con las mismas imágenes. Consulte [backup-restore.md](backup-restore.md).

## Retirada futura del enlace

Antes de eliminar `docker-compose.yml`:

1. busque referencias en CI, scripts, systemd, cron y herramientas gráficas;
2. actualice Dockge y automatizaciones para `compose.yaml`;
3. publique la deprecación al menos durante una release;
4. valide un clon en Linux y en la plataforma Windows soportada.
