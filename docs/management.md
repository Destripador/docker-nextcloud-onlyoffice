# Administración diaria

Después de instalar el stack, use `manage.sh` para tareas comunes:

```sh
bash manage.sh status
bash manage.sh start
bash manage.sh stop
bash manage.sh restart
bash manage.sh doctor
bash manage.sh rebuild
```

`stop` detiene los contenedores sin borrar los datos persistentes.

`rebuild` reconstruye la imagen de Nextcloud y recrea `app` y `web`, útil
cuando cambia el Dockerfile o la configuración PHP-FPM.

Los scripts de diagnóstico usan explícitamente `compose.yaml`, que es el archivo
canónico del proyecto.
