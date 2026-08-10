from pathlib import Path
from textwrap import dedent

from fastapi import FastAPI, Request, Form
from fastapi.responses import RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

import json


BASE_DIR = Path(__file__).resolve().parent
CONFIG_FILE = BASE_DIR / "config.json"

app = FastAPI()

templates = Jinja2Templates(
    directory=BASE_DIR / "templates"
)

app.mount(
    "/static",
    StaticFiles(directory=BASE_DIR / "static"),
    name="static"
)

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
                    proxy_set_header Host $host;
                    proxy_set_header X-Real-IP $remote_addr;
                }}
            }}""").strip()
        config_lines.append(server_block)
        
    with open(BASE_DIR / "proxies.conf", "w", encoding="utf-8") as file:
        file.write("\n".join(config_lines))
        
def save_config(proxies):
    save_proxies(proxies)
    generate_nginx_config(proxies)

@app.get("/config")
def config(request: Request):

    proxies = load_proxies()

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
    port: int = Form(...),
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