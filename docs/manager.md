# Panel administrativo web

El perfil opcional `manager` añade una interfaz web para consultar y administrar
los contenedores del proyecto Compose sin exponer una terminal.

## Alcance actual

La primera versión permite:

- iniciar, detener y reiniciar servicios del proyecto;
- consultar estado, health e imagen efectiva;
- mostrar la versión de Nextcloud mediante `occ status`;
- consultar las últimas 250 líneas de logs por servicio;
- administrar únicamente contenedores con la etiqueta
  `com.docker.compose.project` que coincide con este stack.

Backup, restore, update y edición de `.env` permanecen por CLI por ahora. No se
duplicó esa lógica dentro del panel.

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
