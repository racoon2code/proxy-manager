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

def generate_nginx_config(proxies):
    config_lines = []

    for proxy in proxies:
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

    settings = load_settings()
    nginx_config_path = Path(settings["nginx_config_path"])

    with open(nginx_config_path, "w", encoding="utf-8") as file:
        file.write("\n\n".join(config_lines))
        


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
    generate_nginx_config(proxies)
    
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

    return templates.TemplateResponse(
        request=request,
        name="config.html",
        context={
            "proxies": proxies
        }
    )


@app.get("/config/add")
def config_add(request: Request):

    return templates.TemplateResponse(
        request=request,
        name="config_add.html"
    )


@app.post("/config/add")
def config_add_save(
    name: str = Form(...),
    domain: str = Form(...),
    target: str = Form(...),
    port: int | None = Form(None),
    protocol: str = Form(...)
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
        "protocol": protocol
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

    generate_nginx_config(proxies)

    success, message = check_nginx_config()

    if not success:
        print(message)

        return RedirectResponse(
            url="/config?status=error",
            status_code=303
        )

    success, message = reload_nginx()

    if not success:
        print(message)

        return RedirectResponse(
            url="/config?status=reload_error",
            status_code=303
        )

    return RedirectResponse(
        url="/config?status=success",
        status_code=303
    )