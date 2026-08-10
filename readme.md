Proxy Manager

Kleine FastAPI-Webapp zur Verwaltung interner Reverse-Proxy-Einträge für nginx.

Was macht das Projekt?

Die Webapp verwaltet Reverse-Proxies über eine einfache Oberfläche unter /config.

Ein Eintrag besteht z. B. aus:

Name: Proxmox

Domain: proxmox.home.arpa

Ziel: 192.168.2.99

Port: 8006

Protokoll: https

Die App:

speichert die Einträge in config.json

erzeugt daraus automatisch eine nginx-Konfiguration (generated.conf)

kann optional passende DNS-Rewrites in AdGuard Home anlegen/löschen

nginx leitet anschließend z. B.http://proxmox.home.arpa → https://192.168.2.99:8006

Die eigentliche Verwaltungsseite läuft über FastAPI/Uvicorn und wird ebenfalls über nginx bereitgestellt.

Aufbau

Browser
   |
   v
nginx :80 / später :443
   |
   +--> nginx.home.arpa  --> FastAPI/Uvicorn :8000
   |
   +--> proxmox.home.arpa --> Proxmox :8006
   |
   +--> ha.home.arpa      --> Home Assistant :8123

Projektstruktur ungefähr:

/opt/proxy-manager/
├── main.py
├── config.json
├── settings.json
├── settings.example.json
├── requirements.txt
├── templates/
└── static/

Installation auf Debian/LXC

Repository klonen

cd /opt
git clone git@github.com:USERNAME/proxy-manager.git
cd proxy-manager

Python venv erstellen

apt update
apt install python3-venv
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

Falls noch keine config.json vorhanden ist:

echo '[]' > config.json

settings.json

settings.json sollte lokal bleiben und nicht in Git committed werden.

Beispiel:

{
    "nginx_config_path": "/etc/nginx/sites-available/generated.conf",
    "nginx_ip": "192.168.2.5",

    "adguard_enabled": true,
    "adguard_url": "http://adguard.home.arpa",
    "adguard_username": "admin",
    "adguard_password": "PASSWORT"
}

In .gitignore:

settings.json

Für GitHub stattdessen eine settings.example.json ohne echte Zugangsdaten verwenden.

FastAPI als systemd-Service

Datei:

nano /etc/systemd/system/proxy-manager.service

Inhalt:

[Unit]
Description=Proxy Manager FastAPI
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/proxy-manager
ExecStart=/opt/proxy-manager/.venv/bin/uvicorn main:app --host 127.0.0.1 --port 8000
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target

Aktivieren:

systemctl daemon-reload
systemctl enable --now proxy-manager

Status prüfen:

systemctl status proxy-manager

Logs:

journalctl -u proxy-manager -f

nginx Grundkonfiguration

Die Verwaltungsseite sollte in einer festen nginx-Datei bleiben, z. B.:

/etc/nginx/sites-available/main

Beispiel:

server {
    listen 80;
    server_name nginx.home.arpa;

    location / {
        proxy_pass http://127.0.0.1:8000;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

Aktivieren:

ln -s /etc/nginx/sites-available/main /etc/nginx/sites-enabled/main

Die automatisch erzeugten Proxy-Einträge landen getrennt in:

/etc/nginx/sites-available/generated.conf

Einmalig aktivieren:

ln -s /etc/nginx/sites-available/generated.conf /etc/nginx/sites-enabled/generated.conf

nginx prüfen:

nginx -t

und neu laden:

systemctl reload nginx

Generierte Proxy-Konfiguration

Ein Eintrag wird ungefähr so erzeugt:

server {
    listen 80;
    server_name ha.home.arpa;

    location / {
        proxy_pass http://192.168.2.20:8123;

        proxy_http_version 1.1;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

Die WebSocket-Header sind insbesondere für Anwendungen wie Home Assistant wichtig.

AdGuard Home

Wenn adguard_enabled auf true steht, kann die App beim Hinzufügen/Löschen eines Proxys automatisch einen DNS-Rewrite mitpflegen.

Beispiel:

proxmox.home.arpa -> 192.168.2.5
ha.home.arpa      -> 192.168.2.5

Wichtig: Die Domain zeigt auf die nginx-LXC, nicht direkt auf das Zielsystem.

nginx entscheidet danach anhand von server_name, wohin weitergeleitet wird.

Hinweis für Home Assistant

Home Assistant benötigt hinter einem Reverse Proxy zusätzlich eine passende Konfiguration in configuration.yaml.

Beispiel:

http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 192.168.2.5

Dabei ist 192.168.2.5 die IP der nginx-LXC.

Danach Home Assistant neu starten.

Ohne trusted_proxies kann die Login-Seite zwar erscheinen, danach aber z. B. die Meldung:

Unable to connect to Home Assistant

auftreten.

Update auf der LXC

cd /opt/proxy-manager
git pull
source .venv/bin/activate
pip install -r requirements.txt
systemctl restart proxy-manager

Danach bei Änderungen an der nginx-Konfiguration:

nginx -t
systemctl reload nginx

Nützliche Befehle

systemctl status proxy-manager
journalctl -u proxy-manager -f

nginx -t
systemctl reload nginx

cat /etc/nginx/sites-available/generated.conf