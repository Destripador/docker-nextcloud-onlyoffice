# Administración con Dockge

Dockge es una interfaz para proyectos Docker Compose. No sustituye los backups,
las notas de actualización ni la revisión del Compose renderizado. Su acceso al
socket Docker concede control administrativo del host; publíquelo solo en una
red de gestión confiable.

## Principio de rutas

Dockge debe ver el directorio del stack con la misma ruta que usa el host. El
directorio administrado debe contener como mínimo:

```text
nextcloud/
├── compose.yaml
├── docker-compose.yml -> compose.yaml
├── Dockerfile
├── supervisord.conf
├── .dockerignore
├── .env
├── compose.override.yaml       # opcional y local
├── config/
├── data/
├── db/
└── nextcloud/
```

Los bind mounts de `compose.yaml` son relativos. Copiar solo el YAML a otra
carpeta crea rutas distintas y puede parecer una instalación vacía. Para una
instalación existente, no mueva ni duplique el stack durante la adopción.

## Instalar Dockge por separado

Mantenga Dockge en su propio proyecto y monte el directorio padre de los stacks
con la misma ruta interna. Ejemplo conceptual:

```yaml
services:
  dockge:
    image: louislam/dockge:VERSION_EXPLICITA
    ports:
      - "127.0.0.1:5001:5001"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /ruta/stacks:/ruta/stacks
      - ./data:/app/data
    environment:
      DOCKGE_STACKS_DIR: /ruta/stacks
```

Seleccione una versión explícita de Dockge y siga su documentación oficial. El
ejemplo no fija una versión porque este repositorio no la valida ni la actualiza.
No exponga el puerto de administración directamente a Internet.

## Stack nuevo

1. Clone este repositorio como un subdirectorio del directorio configurado en
   `DOCKGE_STACKS_DIR`.
2. Copie `.env.example` a `.env`, aplique modo `0600` y sustituya todos los
   placeholders.
3. Prepare los directorios persistentes y la red externa descritos en el
   [README](../README.md#instalación-desde-un-clon-limpio).
4. Ejecute desde el host, antes de usar Start:

   ```sh
   docker compose -f compose.yaml config --quiet
   docker compose config --quiet
   docker compose config --services
   ```

5. Construya deliberadamente `app`. `NEXTCLOUD_APP_IMAGE` es una imagen local,
   distinta de la base oficial:

   ```sh
   docker compose build app
   ```

6. En Dockge, escanee el directorio de stacks, abra el proyecto correcto y
   confirme ruta, nombre del proyecto, servicios, mounts, redes e imágenes antes
   de pulsar **Start**.

El build y Start son operaciones reales. No se ejecutaron al preparar esta
documentación.

## Perfil ACME

Dockge debe cargar el `.env` del mismo directorio. El ejemplo establece
`COMPOSE_PROFILES=acme`, por lo que `acme` forma parte de la configuración
efectiva. Déjelo vacío si termina TLS fuera del stack. Valide con el mismo entorno
que utilizará Dockge:

```sh
docker compose config --services
```

No confunda un servicio oculto por perfil con un servicio eliminado del YAML.

## Overrides

Dockge y Compose cargan automáticamente `compose.override.yaml` cuando operan
desde el directorio y no reciben otra lista de archivos. Si su instalación de
Dockge permite seleccionar archivos Compose, confirme que incluye la base y el
override en el mismo orden que:

```sh
docker compose -f compose.yaml -f compose.override.yaml config --quiet
```

Guarde personalizaciones locales solo en el override ignorado y en `.env`. No
edite la base desde el editor de Dockge si espera seguir actualizando por Git.

## Adoptar una instalación existente

Antes de cualquier Start:

1. obtenga de los labels de los contenedores existentes el proyecto, directorio
   de trabajo y archivos Compose originales;
2. preserve `COMPOSE_PROJECT_NAME`, los nombres de servicios y todas las rutas;
3. cree un backup restaurable fuera del checkout;
4. compare configuración, mounts, puertos, redes e IDs de imagen;
5. use `docker compose --dry-run up -d --remove-orphans` si su versión lo admite;
6. aborte si aparecen servicios, volúmenes, redes, pulls o builds no previstos.

Un Start de Dockge suele ejecutar `docker compose up`; puede recrear contenedores
aunque el editor no muestre un cambio obvio. La semántica exacta depende de la
versión de Dockge y debe confirmarse antes de una adopción.

## Operación diaria

- Use **Logs** para inspección, con redacción antes de compartir.
- Reinicie un único servicio solo cuando conozca el impacto.
- No use **Update**, **Pull all** o **Rebuild with pull** como mantenimiento
  automático: los tags están fijados y `app` es una imagen construida localmente.
- No use **Delete** para corregir una configuración; podría retirar recursos del
  proyecto.
- Nunca añada `-v` a `down` si quiere conservar datos.

Después de un cambio controlado, compruebe:

```sh
docker compose ps -a
bash scripts/doctor.sh
docker compose exec --user www-data app php occ status
```

## Actualizar desde Git

1. Respaldar y probar restauración.
2. Revisar el diff de archivos públicos sin imprimir `.env`.
3. Comparar `.env.example` con el `.env` local manualmente.
4. Validar la combinación efectiva.
5. Revisar qué imágenes cambian y si `app` requiere build.
6. Aplicar durante una ventana de mantenimiento.

No ejecute `git diff` sobre rutas que contienen secretos en una terminal que se
registre. Prefiera:

```sh
git status --short
git diff --stat
git diff -- compose.yaml Dockerfile README.md docs scripts
```

## Compatibilidad de docker-compose.yml

El enlace simbólico temporal facilita algunas automatizaciones Linux, pero no es
portable a todos los checkouts Windows ni convierte Compose V1 en soportado.
Configure Dockge para usar `compose.yaml`. Consulte
[migration-compose.md](migration-compose.md) antes de retirar el nombre antiguo.
