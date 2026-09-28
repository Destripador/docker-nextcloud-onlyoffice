# Changelog

## [Unreleased]

### Added

- instalador interactivo y modos `--dev`, `--dev-full` y `--production`;
- preflight de solo lectura;
- diagnóstico `doctor.sh`;
- OnlyOffice opcional mediante perfiles Compose y configuración automática;
- `manage.sh` para operaciones comunes;
- backup consistente y restore guardado;
- actualización con backup obligatorio, mantenimiento y diagnóstico final;
- CI local y GitHub Actions;
- panel web opcional con autenticación, CSRF y bind local por defecto;
- métricas del host y contenedores;
- administración web de backups, actualizaciones y configuración no sensible;
- administración acotada de usuarios y apps de Nextcloud mediante OCC;
- modo de desarrollo explícito con debug de Nextcloud y OPcache deshabilitado.

### Changed

- `compose.yaml` es la definición canónica;
- Nginx ya no depende de que OnlyOffice esté activo para iniciar;
- configuración PHP-FPM pública incluida en la imagen;
- scripts internos usan explícitamente `compose.yaml`;
- actualización excluye al manager para no interrumpir su propio proceso;
- edición web de `.env` preserva UID, GID y permisos.

### Fixed

- permisos restrictivos causados por `umask 077` durante instalaciones manuales;
- diagnóstico de credenciales MariaDB;
- resolución y path stripping de OnlyOffice;
- falsos bloqueos/hangs de varias comprobaciones del doctor;
- archivado de bind mounts protegidos durante backup;
- contexto Docker que omitía la configuración PHP-FPM;
- activación/desactivación de OnlyOffice en instalaciones existentes;
- lectura de `.env` con mensaje claro cuando el archivo no es accesible.

## v1.0.0-rc1

Pendiente de publicación después de completar `docs/release-checklist.md`.
