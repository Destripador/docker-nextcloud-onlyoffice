import hmac
import json
import os
import secrets
import subprocess
import sys
import time
from functools import wraps
from pathlib import Path

import docker
from docker.errors import APIError, DockerException, NotFound
from flask import Flask, abort, flash, redirect, render_template, request, session, url_for

PROJECT = os.environ.get("COMPOSE_PROJECT_NAME", "nextcloud")
ADMIN_USER = os.environ.get("MANAGER_ADMIN_USER", "admin")
ADMIN_PASSWORD = os.environ.get("MANAGER_ADMIN_PASSWORD", "")
SECRET_KEY = os.environ.get("MANAGER_SECRET_KEY", "")
COOKIE_SECURE = os.environ.get("MANAGER_COOKIE_SECURE", "false").lower() == "true"
PROJECT_ROOT = Path(os.environ.get("MANAGER_PROJECT_ROOT", "/project")).resolve()

if len(SECRET_KEY) < 32:
    raise RuntimeError("MANAGER_SECRET_KEY debe tener al menos 32 caracteres")
if len(ADMIN_PASSWORD) < 12:
    raise RuntimeError("MANAGER_ADMIN_PASSWORD debe tener al menos 12 caracteres")

app = Flask(__name__)
app.secret_key = SECRET_KEY
app.config.update(
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
    SESSION_COOKIE_SECURE=COOKIE_SECURE,
    PERMANENT_SESSION_LIFETIME=60 * 60 * 12,
)

docker_client = docker.from_env()

SERVICES = {
    "db": "MariaDB",
    "redis": "Redis",
    "app": "Nextcloud",
    "web": "Nginx",
    "proxy": "Proxy",
    "onlyoffice": "OnlyOffice",
    "acme": "ACME",
}
ACTIONS = {"start", "stop", "restart"}


def login_required(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        if not session.get("authenticated"):
            return redirect(url_for("login", next=request.path))
        return view(*args, **kwargs)

    return wrapped


def csrf_token():
    token = session.get("csrf_token")
    if not token:
        token = secrets.token_urlsafe(32)
        session["csrf_token"] = token
    return token


app.jinja_env.globals["csrf_token"] = csrf_token


def require_csrf():
    supplied = request.form.get("csrf_token", "")
    expected = session.get("csrf_token", "")
    if not expected or not hmac.compare_digest(supplied, expected):
        abort(400)


def project_containers(all_containers=True):
    return docker_client.containers.list(
        all=all_containers,
        filters={"label": f"com.docker.compose.project={PROJECT}"},
    )


def service_container(service):
    if service not in SERVICES:
        abort(404)
    matches = [
        container
        for container in project_containers()
        if container.labels.get("com.docker.compose.service") == service
    ]
    if not matches:
        raise NotFound(f"No existe contenedor para {service}")
    if len(matches) != 1:
        raise DockerException(f"Se encontraron {len(matches)} contenedores para {service}")
    return matches[0]


def health_of(container):
    container.reload()
    state = container.attrs.get("State", {})
    health = state.get("Health", {}).get("Status")
    return health or "none"


def exec_check(service, command, user=None):
    try:
        container = service_container(service)
        container.reload()
        if container.status != "running":
            return False, "servicio detenido"
        result = container.exec_run(command, user=user, demux=False)
        output = result.output.decode("utf-8", errors="replace").strip()
        return result.exit_code == 0, output
    except (APIError, DockerException, NotFound) as exc:
        return False, str(exc)


def nextcloud_status():
    ok, output = exec_check(
        "app",
        ["php", "occ", "status", "--output=json", "--no-ansi", "--no-interaction"],
        user="www-data",
    )
    if not ok:
        return None
    try:
        return json.loads(output)
    except (ValueError, json.JSONDecodeError):
        return None


def human_size(total):
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    value = float(total)
    for unit in units:
        if value < 1024 or unit == units[-1]:
            return f"{value:.1f} {unit}" if unit != "B" else f"{int(value)} B"
        value /= 1024
    return f"{total} B"


def operation_state(kind):
    state_dir = PROJECT_ROOT / ".manager"
    status_path = state_dir / f"{kind}.status.json"
    lock_path = state_dir / f"{kind}.lock"
    payload = {"state": "running" if lock_path.exists() else "idle"}
    if status_path.is_file():
        try:
            stored = json.loads(status_path.read_text(encoding="utf-8"))
            if not lock_path.exists():
                payload = stored
            else:
                payload.update(stored)
                payload["state"] = "running"
        except (OSError, ValueError, json.JSONDecodeError):
            pass
    return payload


def backup_state():
    return operation_state("backup")


def active_operation():
    state_dir = PROJECT_ROOT / ".manager"
    for kind in ("update", "backup"):
        if (state_dir / f"{kind}.lock").exists():
            return kind
    return None


def env_public_values():
    wanted = [
        "NEXTCLOUD_BASE_IMAGE",
        "NEXTCLOUD_APP_IMAGE",
        "MARIADB_IMAGE",
        "REDIS_IMAGE",
        "NGINX_IMAGE",
        "NGINX_PROXY_IMAGE",
        "ACME_COMPANION_IMAGE",
        "ONLYOFFICE_IMAGE",
        "COMPOSE_PROFILES",
    ]
    values = {}
    env_path = PROJECT_ROOT / ".env"
    if not env_path.is_file():
        return values
    try:
        for raw in env_path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            if key in wanted:
                values[key] = value.strip().strip('"').strip("'")
    except OSError:
        pass
    return values


def backup_inventory():
    root = PROJECT_ROOT / "backups"
    items = []
    if not root.is_dir():
        return items
    for path in sorted(root.glob("nextcloud-*"), reverse=True):
        if not path.is_dir():
            continue
        size = 0
        try:
            size = sum(p.stat().st_size for p in path.rglob("*") if p.is_file())
        except OSError:
            pass
        complete = all(
            (path / name).is_file()
            for name in ("SHA256SUMS", "nextcloud.sql.gz", "files.tar")
        )
        items.append(
            {
                "name": path.name,
                "size": human_size(size),
                "complete": complete,
            }
        )
    return items[:25]


def safe_backup_dir(name):
    if not name.startswith("nextcloud-") or "/" in name or "\\" in name:
        abort(404)
    root = (PROJECT_ROOT / "backups").resolve()
    path = (root / name).resolve()
    if path.parent != root or not path.is_dir():
        abort(404)
    return path


def diagnostics():
    checks = []

    def add(name, ok, detail):
        checks.append({"name": name, "ok": bool(ok), "detail": detail})

    ok, output = exec_check(
        "db",
        ["sh", "-ec", 'mariadb -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" -Nse "SELECT 1"'],
    )
    add("MariaDB", ok and output.splitlines()[-1:] == ["1"], output or "sin respuesta")

    ok, output = exec_check(
        "redis",
        ["sh", "-ec", 'export REDISCLI_AUTH="$REDIS_PASSWORD"; redis-cli ping'],
    )
    add("Redis", ok and output == "PONG", output or "sin respuesta")

    ok, output = exec_check("web", ["nginx", "-t"])
    add("Nginx Nextcloud", ok, output or ("configuración válida" if ok else "sin respuesta"))

    ok, output = exec_check("proxy", ["nginx", "-t"])
    add("nginx-proxy", ok, output or ("configuración válida" if ok else "sin respuesta"))

    nc = nextcloud_status()
    add(
        "Nextcloud OCC",
        bool(nc and nc.get("installed")),
        f"versión {nc.get('versionstring') or nc.get('version')}" if nc else "occ status no respondió correctamente",
    )

    try:
        service_container("onlyoffice")
    except NotFound:
        add("OnlyOffice", True, "perfil no creado")
    else:
        ok, output = exec_check(
            "onlyoffice",
            ["curl", "-fsS", "--max-time", "6", "http://127.0.0.1:8000/info/info.json"],
        )
        add("OnlyOffice", ok, "Document Server responde" if ok else (output or "sin respuesta"))

    return checks


@app.after_request
def security_headers(response):
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Referrer-Policy"] = "same-origin"
    response.headers["Cache-Control"] = "no-store"
    response.headers["Content-Security-Policy"] = (
        "default-src 'self'; style-src 'self'; img-src 'self'; "
        "form-action 'self'; frame-ancestors 'none'"
    )
    return response


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        supplied_user = request.form.get("username", "")
        supplied_password = request.form.get("password", "")
        user_ok = hmac.compare_digest(supplied_user, ADMIN_USER)
        password_ok = hmac.compare_digest(supplied_password, ADMIN_PASSWORD)
        if user_ok and password_ok:
            session.clear()
            session.permanent = True
            session["authenticated"] = True
            session["csrf_token"] = secrets.token_urlsafe(32)
            return redirect(url_for("dashboard"))
        time.sleep(0.8)
        flash("Credenciales inválidas.", "error")
    return render_template("login.html")


@app.post("/logout")
@login_required
def logout():
    require_csrf()
    session.clear()
    return redirect(url_for("login"))


@app.get("/")
@login_required
def dashboard():
    by_service = {}
    try:
        for container in project_containers():
            service = container.labels.get("com.docker.compose.service")
            if service in SERVICES:
                by_service[service] = {
                    "name": SERVICES[service],
                    "service": service,
                    "status": container.status,
                    "health": health_of(container),
                    "image": ", ".join(container.image.tags) or container.image.short_id,
                }
    except DockerException as exc:
        flash(f"No se pudo consultar Docker: {exc}", "error")

    cards = []
    for service, name in SERVICES.items():
        cards.append(
            by_service.get(
                service,
                {
                    "name": name,
                    "service": service,
                    "status": "not-created",
                    "health": "none",
                    "image": "—",
                },
            )
        )

    return render_template(
        "dashboard.html",
        cards=cards,
        nc=nextcloud_status(),
        project=PROJECT,
    )


@app.get("/backups")
@login_required
def backups_view():
    log_path = PROJECT_ROOT / ".manager" / "backup.log"
    log_tail = ""
    if log_path.is_file():
        try:
            lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
            log_tail = "\n".join(lines[-80:])
        except OSError:
            pass
    return render_template(
        "backups.html",
        backups=backup_inventory(),
        backup_state=backup_state(),
        log_tail=log_tail,
        project=PROJECT,
    )


@app.post("/backups/create")
@login_required
def backup_create():
    require_csrf()
    running = active_operation()
    if running:
        flash(f"No se puede iniciar backup mientras {running} está en ejecución.", "error")
        return redirect(url_for("backups_view"))
    state_dir = PROJECT_ROOT / ".manager"
    state_dir.mkdir(mode=0o700, exist_ok=True)
    lock_path = state_dir / "backup.lock"

    try:
        fd = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(fd)
    except FileExistsError:
        flash("Ya hay un backup en ejecución.", "error")
        return redirect(url_for("backups_view"))

    try:
        subprocess.Popen(
            [sys.executable, "/app/backup_job.py", str(PROJECT_ROOT)],
            cwd=PROJECT_ROOT,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError as exc:
        try:
            lock_path.unlink()
        except FileNotFoundError:
            pass
        flash(f"No se pudo iniciar el backup: {exc}", "error")
        return redirect(url_for("backups_view"))

    flash("Backup iniciado en segundo plano.", "success")
    return redirect(url_for("backups_view"))


@app.post("/backups/<name>/verify")
@login_required
def backup_verify(name):
    require_csrf()
    path = safe_backup_dir(name)
    manifest = path / "SHA256SUMS"
    sql = path / "nextcloud.sql.gz"
    if not manifest.is_file() or not sql.is_file():
        flash("El backup no contiene manifiesto o dump SQL completo.", "error")
        return redirect(url_for("backups_view"))

    manifest_check = subprocess.run(
        ["sha256sum", "--check", "--strict", "SHA256SUMS"],
        cwd=path,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=120,
        check=False,
    )
    gzip_check = subprocess.run(
        ["gzip", "-t", "nextcloud.sql.gz"],
        cwd=path,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=120,
        check=False,
    )
    if manifest_check.returncode == 0 and gzip_check.returncode == 0:
        flash(f"{name}: hashes y dump SQL verificados correctamente.", "success")
    else:
        flash(f"{name}: la verificación falló. Revise el backup antes de restaurar.", "error")
    return redirect(url_for("backups_view"))


@app.get("/updates")
@login_required
def updates_view():
    log_path = PROJECT_ROOT / ".manager" / "update.log"
    log_tail = ""
    if log_path.is_file():
        try:
            lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
            log_tail = "\n".join(lines[-120:])
        except OSError:
            pass
    return render_template(
        "updates.html",
        update_state=operation_state("update"),
        active_operation=active_operation(),
        refs=env_public_values(),
        log_tail=log_tail,
        project=PROJECT,
    )


@app.post("/updates/apply")
@login_required
def update_apply():
    require_csrf()
    confirmation = request.form.get("confirmation", "")
    if confirmation != "ACTUALIZAR":
        flash("Escriba ACTUALIZAR exactamente para confirmar.", "error")
        return redirect(url_for("updates_view"))

    running = active_operation()
    if running:
        flash(f"No se puede actualizar mientras {running} está en ejecución.", "error")
        return redirect(url_for("updates_view"))

    state_dir = PROJECT_ROOT / ".manager"
    state_dir.mkdir(mode=0o700, exist_ok=True)
    lock_path = state_dir / "update.lock"
    try:
        fd = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(fd)
    except FileExistsError:
        flash("Ya hay una actualización en ejecución.", "error")
        return redirect(url_for("updates_view"))

    try:
        subprocess.Popen(
            [sys.executable, "/app/update_job.py", str(PROJECT_ROOT)],
            cwd=PROJECT_ROOT,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError as exc:
        try:
            lock_path.unlink()
        except FileNotFoundError:
            pass
        flash(f"No se pudo iniciar la actualización: {exc}", "error")
        return redirect(url_for("updates_view"))

    flash("Actualización iniciada. Se creará un backup obligatorio antes de aplicar cambios.", "success")
    return redirect(url_for("updates_view"))


@app.get("/diagnostics")
@login_required
def diagnostics_view():
    checks = diagnostics()
    passed = sum(1 for check in checks if check["ok"])
    return render_template(
        "diagnostics.html",
        checks=checks,
        passed=passed,
        total=len(checks),
        project=PROJECT,
    )


@app.post("/nextcloud/maintenance/<state>")
@login_required
def maintenance_action(state):
    require_csrf()
    running = active_operation()
    if running:
        flash(f"No se puede cambiar mantenimiento mientras {running} está en ejecución.", "error")
        return redirect(url_for("dashboard"))
    if state not in {"on", "off"}:
        abort(404)
    ok, output = exec_check(
        "app",
        ["php", "occ", "maintenance:mode", f"--{state}", "--no-ansi", "--no-interaction"],
        user="www-data",
    )
    if ok:
        flash(f"Modo mantenimiento {state}.", "success")
    else:
        flash(f"No se pudo cambiar modo mantenimiento: {output}", "error")
    return redirect(url_for("dashboard"))


@app.post("/service/<service>/<action>")
@login_required
def service_action(service, action):
    require_csrf()
    running = active_operation()
    if running:
        flash(f"No se pueden administrar servicios mientras {running} está en ejecución.", "error")
        return redirect(url_for("dashboard"))
    if service not in SERVICES or action not in ACTIONS:
        abort(404)
    try:
        container = service_container(service)
        if action == "start":
            container.start()
        elif action == "stop":
            container.stop(timeout=30)
        else:
            container.restart(timeout=30)
        flash(f"{SERVICES[service]}: acción {action} enviada.", "success")
    except NotFound:
        flash(f"{SERVICES[service]} no está creado.", "error")
    except (APIError, DockerException) as exc:
        flash(f"No se pudo administrar {SERVICES[service]}: {exc}", "error")
    return redirect(url_for("dashboard"))


@app.get("/logs/<service>")
@login_required
def logs(service):
    if service not in SERVICES:
        abort(404)
    try:
        container = service_container(service)
        content = container.logs(tail=250, timestamps=True).decode("utf-8", errors="replace")
    except NotFound:
        content = "El servicio no tiene un contenedor creado."
    except (APIError, DockerException) as exc:
        content = f"No se pudieron obtener los logs: {exc}"
    return render_template("logs.html", service=service, name=SERVICES[service], content=content)


@app.get("/healthz")
def healthz():
    try:
        docker_client.ping()
        return {"status": "ok"}, 200
    except DockerException:
        return {"status": "error"}, 503
