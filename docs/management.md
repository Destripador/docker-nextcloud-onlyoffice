# Administración diaria

Después de instalar el stack, use `manage.sh` para tareas comunes:

```sh
bash manage.sh status
bash manage.sh start
bash manage.sh stop
bash manage.sh restart
bash manage.sh doctor
bash manage.sh logs
bash manage.sh logs app
bash manage.sh rebuild
bash manage.sh onlyoffice-on
bash manage.sh onlyoffice-off
bash manage.sh refresh
bash manage.sh update
```

`status` muestra la URL configurada, los perfiles activos y el estado de los
servicios.

`stop` detiene los contenedores sin borrar los datos persistentes.

`logs` sigue los logs del stack completo o de un servicio concreto.

`rebuild` reconstruye la imagen de Nextcloud y recrea `app` y `web`, útil
cuando cambia el Dockerfile o la configuración PHP-FPM.

`onlyoffice-on` reutiliza el flujo seguro del instalador para añadir OnlyOffice
a una instalación existente.

`onlyoffice-off` guarda una copia de `.env`, retira únicamente el perfil
`onlyoffice` y detiene Document Server. No desinstala la app de Nextcloud ni
borra sus datos, de modo que puede volver a activarse más tarde.

`refresh` no cambia versiones. Descarga las referencias ya fijadas en `.env`,
reconstruye la imagen app usando esas referencias y vuelve a aplicar el stack.

`update` ejecuta el flujo de actualización protegido: preflight, backup
obligatorio, mantenimiento, pull/build, recreación, `occ upgrade` cuando sea
necesario y `doctor.sh` al final. Tampoco modifica versiones por sí solo; primero
deben revisarse y cambiarse explícitamente en `.env`.

Para cambiar de versión de Nextcloud, MariaDB, Redis, Nginx u OnlyOffice siga
una ruta de actualización soportada y conserve el backup generado para recuperación.

Los scripts de gestión y diagnóstico usan explícitamente `compose.yaml`, que es
el archivo canónico del proyecto.
