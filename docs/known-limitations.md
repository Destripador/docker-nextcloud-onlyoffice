# Limitaciones y pruebas pendientes

## Estado de validación

El candidato público recibió validación estática de Compose, Bash, referencias,
redes, mounts y documentación con valores ficticios. Durante este cierre no se
ejecutaron:

- pulls de imágenes;
- build del Dockerfile;
- instalación desde un clon vacío;
- `docker compose up`;
- emisión o renovación real de certificados;
- instalación/configuración funcional del conector OnlyOffice;
- backup y restauración extremo a extremo;
- actualización o rollback de versiones.

Por tanto, esas pruebas siguen siendo obligatorias en un laboratorio aislado
antes de anunciar el stack como validado para producción.

## Compatibilidad de imágenes

Las referencias de `.env.example` estaban publicadas y la pareja Nextcloud 34 /
MariaDB 11.8 figura en los requisitos oficiales al revisarlas el 7 de septiembre
de 2026. Un tag puede ser retirado o su manifiesto puede cambiar. Para máxima
reproducibilidad, registre el digest multi-arquitectura después de verificar la
plataforma.

El Dockerfile es Alpine y no sirve con una base Debian. Añade `smbclient` PECL
1.1.2, pero su compilación con la versión exacta de PHP/Alpine aún debe probarse.
PHP IMAP dejó de formar parte del core de PHP desde 8.4 y no se instala aquí. Si
una app lo requiere, extienda la imagen en un Dockerfile local y valide la versión
PECL apropiada.

## OnlyOffice

Document Server está definido, tiene healthcheck, JWT, persistencia y proxy de
ruta virtual. Aun así:

- la app de integración de Nextcloud se instala por separado;
- `set_config.sh` habilita `allow_local_remote_servers` solo con consentimiento
  explícito, lo cual amplía el alcance de conexiones servidor-a-servidor;
- hace falta una prueba de creación, apertura, guardado y callback de documentos;
- los requisitos de CPU/RAM y compatibilidad de formatos dependen de la carga.

No se debe desactivar TLS o JWT para diagnosticarlo.

## Persistencia y backups

El proyecto usa bind mounts relativos, no volúmenes Docker administrados para los
datos principales. Mover el Compose cambia las rutas. No incluye scheduler de
backups, cifrado, almacenamiento remoto ni política de retención.

La guía de restauración es un procedimiento de referencia todavía no ensayado con
este conjunto exacto de imágenes. Valídelo antes de depender de él.

## Proxy y seguridad

`nginx-proxy` y `acme` montan el socket Docker en modo lectura. La API expuesta por
ese socket conserva privilegios significativos aunque el mount sea `ro`; proteja
los contenedores y el host.

La base no configura automáticamente `trusted_proxies` ni normaliza la IP real de
una cadena adicional de proxies. Revise ambas cosas si coloca otro balanceador
delante del stack; aceptar cabeceras reenviadas desde cualquier origen permite
suplantar direcciones de cliente.

El proxy publica 80/443 en todas las interfaces por defecto. Cambie
`PROXY_BIND_ADDRESS` si existe otro terminador o una política de red distinta.
MariaDB y Redis no publican puertos en la base.

Redis usa autenticación, pero el secreto forma parte del entorno del contenedor y
es visible para administradores del daemon. No comparta `docker inspect` sin
redacción.

## Límites y recursos

El ejemplo permite subidas de 10G. No define límites CPU/memoria/PID ni ajusta el
pool FPM para una carga concreta. Dimensione los servicios y el almacenamiento
temporal mediante un override probado.

## Cron

Supervisor ejecuta PHP-FPM y `/cron.sh` en `app`. Este diseño impide escalar
horizontalmente `app` sin duplicar cron. Para alta disponibilidad, sustituya ese
mecanismo completo mediante una variante de imagen/override probada; no añada
simplemente otro servicio cron.

## Docker Compose y Dockge

`docker-compose.yml` es un symlink de transición. Algunos checkouts Windows no lo
preservan. Use `compose.yaml` como archivo canónico.

El comportamiento exacto de botones como Start, Update o Rebuild depende de la
versión de Dockge. Confirme los comandos que ejecuta antes de adoptar una
instalación existente.

## Historial y rotación de secretos

El árbol publicable actual elimina archivos env previamente rastreados y una
captura que mostraba un JWT. Eso no elimina versiones anteriores de Git. Sin
reproducir los valores, antes de publicar se debe:

1. tratar como comprometido cualquier secreto que se haya usado realmente;
2. rotarlo en los sistemas afectados;
3. auditar el historial completo con una herramienta de detección de secretos;
4. decidir por separado si se reescribe historia, coordinándolo con todos los
   clones y remotos.

Esta actualización no rota secretos ni reescribe historial.
