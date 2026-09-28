# Checklist de release

Esta lista define el cierre mínimo antes de crear `v1.0.0-rc1`.

## Validación automática

- [ ] `bash manage.sh ci` termina sin errores.
- [ ] GitHub Actions está verde en el commit candidato.
- [ ] `compose.yaml` y el alias legado `docker-compose.yml` no divergen.
- [ ] `bash manage.sh --help` funciona incluso antes de una instalación.

## Instalación nueva

En una VM o host desechable:

- [ ] clonar el repositorio desde cero;
- [ ] ejecutar `bash install.sh --dev`;
- [ ] validar `bash scripts/doctor.sh`;
- [ ] habilitar manager con `bash manage.sh manager-on`;
- [ ] iniciar sesión en el panel;
- [ ] repetir la prueba con `--dev-full` y abrir un documento con OnlyOffice.

## Instalación existente

Sobre una instalación respaldada:

- [ ] ejecutar `bash manage.sh update`;
- [ ] confirmar que se crea el backup obligatorio;
- [ ] confirmar que Nextcloud sale de mantenimiento;
- [ ] ejecutar `bash scripts/doctor.sh`;
- [ ] comprobar navegación, subida/descarga y OnlyOffice si está habilitado;
- [ ] confirmar que `.env` conserva propietario y modo 600 tras guardar Configuración.

## Backup y recuperación

- [ ] crear un backup desde CLI;
- [ ] crear un backup desde el panel;
- [ ] verificar SHA-256 y gzip;
- [ ] copiar un backup a una VM desechable;
- [ ] restaurarlo sobre rutas persistentes vacías con `scripts/restore.sh --apply`;
- [ ] ejecutar `doctor.sh` después de restaurar;
- [ ] abrir sesión y comprobar al menos un archivo restaurado.

La prueba de restore debe hacerse en un entorno aislado. No use una instalación
de producción como primera prueba de restauración.

## Panel web

- [ ] dashboard y métricas;
- [ ] diagnóstico;
- [ ] logs;
- [ ] mantenimiento on/off;
- [ ] backup y verificación;
- [ ] actualización;
- [ ] configuración segura;
- [ ] usuarios;
- [ ] apps;
- [ ] confirmar que las operaciones mutables quedan bloqueadas durante backup/update.

## Revisión de seguridad

- [ ] manager sigue ligado a `127.0.0.1` salvo decisión explícita;
- [ ] no hay secretos en commits, logs compartidos o documentación;
- [ ] `.env` tiene modo 600;
- [ ] no se expone MariaDB ni Redis al host;
- [ ] no existe endpoint de terminal/comando arbitrario;
- [ ] no se usa `docker compose down -v` en ningún flujo de mantenimiento.

## Publicación

Cuando todos los puntos anteriores estén completados:

1. congelar nuevas funciones;
2. actualizar `CHANGELOG.md`;
3. crear el PR hacia la rama estable;
4. repetir CI sobre el merge candidate;
5. crear tag `v1.0.0-rc1`;
6. probar el artefacto/tag, no solo la rama;
7. tras las pruebas del RC, publicar `v1.0.0`.
