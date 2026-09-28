import hmac
import json
import os
import secrets
import time
from functools import wraps

import docker
from docker.errors import APIError, DockerException, NotFound
from flask import Flask, abort, flash, redirect, render_template, request, session, url_for

PROJECT = os.environ.get("COMPOSE_PROJECT_NAME", "nextcloud")
ADMIN_USER = os.environ.get("MANAGER_ADMIN_USER", "admin")
ADMIN_PASSWORD = os.environ.get("MANAGER_ADMIN_PASSWORD", "")
SECRET_KEY = os.environ.get("MANAGER_SECRET_KEY", "")
COOKIE_SECURE = os.environ.get("MANAGER_COOKIE_SECURE", "false").lower() == "true"

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


def nextcloud_status():
    try:
        container = service_container("app")
        if container.status != "running":
            return None
        result = container.exec_run(
            ["php", "occ", "status", "--output=json", "--no-ansi", "--no-interaction"],
            user="www-data",
            demux=False,
        )
        if result.exit_code != 0:
            return None
        return json.loads(result.output.decode("utf-8", errors="replace"))
    except (DockerException, ValueError, json.JSONDecodeError):
        return None


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


@app.post("/service/<service>/<action>")
@login_required
def service_action(service, action):
    require_csrf()
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
