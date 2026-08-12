from pathlib import Path
from textwrap import dedent

from fastapi import FastAPI, Request, Form, Response
from fastapi.responses import RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from ipaddress import ip_address

from bs4 import BeautifulSoup
from urllib.parse import urljoin, urlsplit

import json
import subprocess
import requests


BASE_DIR = Path(__file__).resolve().parent
CONFIG_FILE = BASE_DIR / "config.json"
SETTINGS_FILE = BASE_DIR / "settings.json"
VERSION_FILE = BASE_DIR / "VERSION"

app = FastAPI()

templates = Jinja2Templates(
    directory=BASE_DIR / "templates"
)

app.mount(
    "/static",
    StaticFiles(directory=BASE_DIR / "static"),
    name="static"
)


def load_settings():
    with open(SETTINGS_FILE, "r", encoding="utf-8") as file:
        return json.load(file)


def proxy_ip_sort_key(proxy):
    try:
        address = ip_address(proxy["target"])
        return (0, address.version, int(address))
    except ValueError:
        # Falls irgendwann statt einer IP ein Hostname eingetragen wird
        return (1, 0, proxy["target"].casefold())


def check_nginx_config():
    result = subprocess.run(
        ["nginx", "-t"],
        capture_output=True,
        text=True
    )

    return result.returncode == 0, result.stderr


def reload_nginx():
    result = subprocess.run(
        ["systemctl", "reload", "nginx"],
        capture_output=True,
        text=True
    )

    return result.returncode == 0, result.stderr


def load_proxies():
    if not CONFIG_FILE.exists():
        return []

    with open(CONFIG_FILE, "r", encoding="utf-8") as file:
        return json.load(file)


def save_proxies(proxies):
    with open(CONFIG_FILE, "w", encoding="utf-8") as file:
        json.dump(
            proxies,
            file,
            indent=4,
            ensure_ascii=False
        )


def build_nginx_config(proxies):
    config_lines = []

    for proxy in proxies:

        if proxy.get("tls_passthrough", False):

            server_block = dedent(f"""
                server {{
                    listen 80;
                    server_name {proxy['domain']};

                    return 301 https://$host$request_uri;
                }}
            """).strip()

        else:

            server_block = dedent(f"""
                server {{
                    listen 80;
                    server_name {proxy['domain']};

                    location / {{
                        proxy_pass {proxy['protocol']}://{proxy['target']}:{proxy['port']};

                        proxy_http_version 1.1;

                        proxy_set_header Upgrade $http_upgrade;
                        proxy_set_header Connection "upgrade";

                        proxy_set_header Host $host;
                        proxy_set_header X-Real-IP $remote_addr;
                        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                        proxy_set_header X-Forwarded-Proto $scheme;
                    }}
                }}
            """).strip()

        config_lines.append(server_block)

    return "\n\n".join(config_lines)

def build_nginx_stream_config(proxies):

    passthrough_proxies = [
        proxy
        for proxy in proxies
        if proxy.get("tls_passthrough", False)
    ]

    if not passthrough_proxies:
        return ""

    config_lines = [
        "map $ssl_preread_server_name $proxy_manager_tls_backend {",
        "    default 127.0.0.1:9;"
    ]

    for proxy in passthrough_proxies:
        config_lines.append(
            f"    {proxy['domain']} {proxy['target']}:{proxy['port']};"
        )

    config_lines.extend([
        "}",
        "",
        "server {",
        "    listen 443;",
        "",
        "    ssl_preread on;",
        "",
        "    proxy_connect_timeout 10s;",
        "    proxy_timeout 3600s;",
        "",
        "    proxy_pass $proxy_manager_tls_backend;",
        "}"
    ])

    return "\n".join(config_lines)


def generate_nginx_config(proxies):

    settings = load_settings()

    nginx_config_path = Path(
        settings["nginx_config_path"]
    )

    nginx_stream_config_path = Path(
        settings["nginx_stream_config_path"]
    )

    nginx_config = build_nginx_config(proxies)
    nginx_stream_config = build_nginx_stream_config(proxies)

    with open(
        nginx_config_path,
        "w",
        encoding="utf-8"
    ) as file:
        file.write(nginx_config)

    with open(
        nginx_stream_config_path,
        "w",
        encoding="utf-8"
    ) as file:
        file.write(nginx_stream_config)


def nginx_config_pending():

    proxies = load_proxies()
    settings = load_settings()

    nginx_config_path = Path(
        settings["nginx_config_path"]
    )

    nginx_stream_config_path = Path(
        settings["nginx_stream_config_path"]
    )

    expected_config = build_nginx_config(proxies)
    expected_stream_config = build_nginx_stream_config(proxies)

    if not nginx_config_path.exists():
        return True

    if not nginx_stream_config_path.exists():
        return True

    with open(
        nginx_config_path,
        "r",
        encoding="utf-8"
    ) as file:
        current_config = file.read()

    with open(
        nginx_stream_config_path,
        "r",
        encoding="utf-8"
    ) as file:
        current_stream_config = file.read()

    return (
        expected_config != current_config
        or
        expected_stream_config != current_stream_config
    )


def get_local_version():
    if not VERSION_FILE.exists():
        return "unknown"

    return VERSION_FILE.read_text(
        encoding="utf-8"
    ).strip()


def get_remote_version():
    settings = load_settings()

    if not settings.get("update_enabled", False):
        return None

    try:
        response = requests.get(
            settings["update_version_url"],
            timeout=5
        )

        response.raise_for_status()

        return response.text.strip()

    except requests.RequestException:
        return None


def get_update_status():
    settings = load_settings()

    local_version = get_local_version()

    if not settings.get("update_enabled", False):
        return {
            "enabled": False,
            "local_version": local_version,
            "remote_version": None,
            "available": False,
            "check_failed": False
        }

    remote_version = get_remote_version()

    if remote_version is None:
        return {
            "enabled": True,
            "local_version": local_version,
            "remote_version": None,
            "available": False,
            "check_failed": True
        }

    return {
        "enabled": True,
        "local_version": local_version,
        "remote_version": remote_version,
        "available": local_version != remote_version,
        "check_failed": False
    }


def add_adguard_rewrite(domain, settings):
    url = settings["adguard_url"].rstrip("/")

    response = requests.post(
        f"{url}/control/rewrite/add",
        json={
            "domain": domain,
            "answer": settings["nginx_ip"]
        },
        auth=(
            settings["adguard_username"],
            settings["adguard_password"]
        ),
        timeout=5
    )

    response.raise_for_status()


def delete_adguard_rewrite(domain, settings):
    url = settings["adguard_url"].rstrip("/")

    response = requests.post(
        f"{url}/control/rewrite/delete",
        json={
            "domain": domain,
            "answer": settings["nginx_ip"]
        },
        auth=(
            settings["adguard_username"],
            settings["adguard_password"]
        ),
        timeout=5
    )

    response.raise_for_status()


def sync_adguard_rewrites(old_proxies, new_proxies, settings):

    old_domains = {
        proxy["domain"].strip().lower()
        for proxy in old_proxies
    }

    new_domains = {
        proxy["domain"].strip().lower()
        for proxy in new_proxies
    }

    added_domains = new_domains - old_domains
    removed_domains = old_domains - new_domains

    for domain in added_domains:
        add_adguard_rewrite(domain, settings)

    for domain in removed_domains:
        delete_adguard_rewrite(domain, settings)


def save_config(proxies):

    old_proxies = load_proxies()
    settings = load_settings()

    save_proxies(proxies)

    settings = load_settings()

    if settings.get("adguard_enabled", False):
        sync_adguard_rewrites(
            old_proxies,
            proxies,
            settings
        )


@app.get("/favicon/{proxy_id}")
def favicon(proxy_id: int):

    proxies = load_proxies()

    proxy = next(
        (
            proxy
            for proxy in proxies
            if proxy["id"] == proxy_id
        ),
        None
    )

    if proxy is None:
        return RedirectResponse(
            url="/static/default-icon.svg"
        )

    base_url = (
        f"{proxy['protocol']}://"
        f"{proxy['target']}:{proxy['port']}/"
    )

    try:
        page_response = requests.get(
            base_url,
            headers={
                "Host": proxy["domain"]
            },
            timeout=5,
            verify=False
        )

        page_response.raise_for_status()

        soup = BeautifulSoup(
            page_response.text,
            "html.parser"
        )

        icon_url = None

        for link in soup.find_all("link", href=True):

            rel = [
                value.lower()
                for value in link.get("rel", [])
            ]

            if "icon" in rel:
                icon_url = urljoin(
                    page_response.url,
                    link["href"]
                )
                break

        # Falls kein <link rel="icon"> vorhanden ist
        if icon_url is None:
            icon_url = urljoin(
                page_response.url,
                "/favicon.ico"
            )

        icon_headers = {}

        # Bei relativen Icons, die weiterhin vom Backend
        # geladen werden, den ursprünglichen Host mitsenden.
        if (
            urlsplit(icon_url).hostname
            == urlsplit(base_url).hostname
        ):
            icon_headers["Host"] = proxy["domain"]

        icon_response = requests.get(
            icon_url,
            headers=icon_headers,
            timeout=5,
            verify=False
        )

        icon_response.raise_for_status()

        content_type = icon_response.headers.get(
            "Content-Type",
            "image/x-icon"
        )

        return Response(
            content=icon_response.content,
            media_type=content_type,
            headers={
                "Cache-Control": "no-store"
            }
        )

    except requests.RequestException:
        return RedirectResponse(
            url="/static/default-icon.svg"
        )


@app.get("/")
def home(request: Request):

    proxies = load_proxies()

    proxies.sort(
        key=lambda proxy: proxy["name"].casefold()
    )

    return templates.TemplateResponse(
        request=request,
        name="home.html",
        context={
            "proxies": proxies
        }
    )


@app.get("/config")
def config(request: Request):

    proxies = load_proxies()

    proxies.sort(key=proxy_ip_sort_key)

    update_status = get_update_status()

    return templates.TemplateResponse(
        request=request,
        name="config.html",
        context={
            "proxies": proxies,
            "config_pending": nginx_config_pending(),
            "update_status": update_status
        }
    )


@app.get("/config/add")
def config_add(request: Request):

    return templates.TemplateResponse(
        request=request,
        name="config_add.html",
        context={
            "proxy": None,
            "edit_mode": False
        }
    )


@app.post("/config/add")
def config_add_save(
    name: str = Form(...),
    domain: str = Form(...),
    target: str = Form(...),
    port: int | None = Form(None),
    protocol: str = Form(...),
    tls_passthrough: bool = Form(False)
):

    proxies = load_proxies()

    new_id = max(
        [proxy["id"] for proxy in proxies],
        default=0
    ) + 1

    new_proxy = {
        "id": new_id,
        "name": name,
        "domain": domain,
        "target": target,
        "port": port,
        "protocol": protocol,
        "tls_passthrough": tls_passthrough
    }

    if port is None:
        if protocol == "http":
            new_proxy["port"] = 80

        if protocol == "https":
            new_proxy["port"] = 443

    proxies.append(new_proxy)

    save_config(proxies)

    return RedirectResponse(
        url="/config",
        status_code=303
    )


@app.post("/config/delete/{proxy_id}")
def config_delete(proxy_id: int):

    proxies = load_proxies()

    proxies = [
        proxy
        for proxy in proxies
        if proxy["id"] != proxy_id
    ]

    save_config(proxies)

    return RedirectResponse(
        url="/config",
        status_code=303
    )


@app.post("/config/apply")
def config_apply():

    proxies = load_proxies()

    settings = load_settings()

    nginx_config_path = Path(
        settings["nginx_config_path"]
    )

    nginx_stream_config_path = Path(
        settings["nginx_stream_config_path"]
    )

    old_config = ""

    if nginx_config_path.exists():
        with open(
            nginx_config_path,
            "r",
            encoding="utf-8"
        ) as file:
            old_config = file.read()

    old_stream_config = ""

    if nginx_stream_config_path.exists():
        with open(
            nginx_stream_config_path,
            "r",
            encoding="utf-8"
        ) as file:
            old_stream_config = file.read()

    generate_nginx_config(proxies)

    result = subprocess.run(
        [
            "sudo",
            "/usr/local/sbin/proxy-manager-apply"
        ],
        capture_output=True,
        text=True
    )

    if result.returncode != 0:

        print(result.stdout)
        print(result.stderr)

        with open(
            nginx_config_path,
            "w",
            encoding="utf-8"
        ) as file:
            file.write(old_config)

        with open(
            nginx_stream_config_path,
            "w",
            encoding="utf-8"
        ) as file:
            file.write(old_stream_config)

        return RedirectResponse(
            url="/config?status=error",
            status_code=303
        )

    return RedirectResponse(
        url="/config?status=success",
        status_code=303
    )


@app.post("/config/update")
def config_update():

    settings = load_settings()

    if not settings.get("update_enabled", False):
        return RedirectResponse(
            url="/config?update=disabled",
            status_code=303
        )

    result = subprocess.run(
        [
            "sudo",
            "systemctl",
            "start",
            "--no-block",
            "proxy-manager-update.service"
        ],
        capture_output=True,
        text=True
    )

    if result.returncode != 0:
        print(result.stderr)

        return RedirectResponse(
            url="/config?update=error",
            status_code=303
        )

    return RedirectResponse(
        url="/config?update=started",
        status_code=303
    )

@app.get("/config/edit/{proxy_id}")
def config_edit(request: Request, proxy_id: int):

    proxies = load_proxies()

    proxy = next(
        (
            proxy
            for proxy in proxies
            if proxy["id"] == proxy_id
        ),
        None
    )

    if proxy is None:
        return RedirectResponse(
            url="/config",
            status_code=303
        )

    return templates.TemplateResponse(
        request=request,
        name="config_add.html",
        context={
            "proxy": proxy,
            "edit_mode": True
        }
    )

@app.post("/config/edit/{proxy_id}")
def config_edit_save(
    proxy_id: int,
    name: str = Form(...),
    domain: str = Form(...),
    target: str = Form(...),
    port: int | None = Form(None),
    protocol: str = Form(...),
    tls_passthrough: bool = Form(False)
):

    proxies = load_proxies()

    if port is None:
        if protocol == "http":
            port = 80

        if protocol == "https":
            port = 443

    for proxy in proxies:

        if proxy["id"] == proxy_id:

            proxy["name"] = name
            proxy["domain"] = domain
            proxy["target"] = target
            proxy["port"] = port
            proxy["protocol"] = protocol
            proxy["tls_passthrough"] = tls_passthrough

            break

    save_config(proxies)

    return RedirectResponse(
        url="/config",
        status_code=303
    )