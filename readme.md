# Proxy Manager

Ein einfacher webbasierter Reverse-Proxy-Manager für kleine Heimnetzwerke und Homelabs.

Der Proxy Manager verwendet **nginx** als Reverse Proxy und stellt eine kleine **FastAPI-Weboberfläche** zur Verfügung, über die interne Dienste verwaltet werden können.

Ziel des Projekts ist eine möglichst einfache Verwaltung interner Dienste ohne manuelles Bearbeiten von nginx-Konfigurationsdateien.

---

## Funktionen

- Weboberfläche zur Verwaltung von Reverse-Proxy-Einträgen
- Dienste hinzufügen und löschen
- Automatische nginx-Konfiguration
- Prüfung der nginx-Konfiguration vor dem Reload
- Anzeige noch nicht angewendeter Konfigurationsänderungen
- Übersicht aller Dienste auf der Startseite
- Alphabetische Sortierung der Dienste
- Automatisches Laden der Favicons der Zielsysteme
- Sortierung der Konfiguration nach Ziel-IP
- HTTP- und HTTPS-Backends
- Unterstützung von WebSockets
- Optionaler AdGuard-Home-Support
- Wildcard-DNS-Unterstützung
- Integrierte Versionsprüfung
- Updates direkt aus der Weboberfläche
- Installation über ein einzelnes Shell-Script

---

# Architektur

Der Proxy Manager besteht im Wesentlichen aus zwei Komponenten:

```text
Browser
   │
   ▼
 nginx :80
   │
   ├── bekannte Domain
   │       │
   │       ▼
   │   Zielsystem
   │
   └── unbekannte Domain / Startseite
           │
           ▼
     FastAPI :8000
```

nginx übernimmt den eigentlichen Reverse Proxy.

FastAPI stellt die Verwaltungsoberfläche sowie die Startseite bereit.

---

# Voraussetzungen

Empfohlen wird eine kleine Debian-Installation oder ein Debian-LXC, beispielsweise unter Proxmox.

Getestete bzw. vorgesehene Umgebung:

```text
Debian
Python 3
nginx
systemd
Git
```

Die Installation lädt die benötigten Pakete automatisch nach.

---

# Installation

Das Repository muss für die einfache Installation öffentlich erreichbar sein.

Installation als `root`:

```bash
curl -fsSL https://raw.githubusercontent.com/DEIN-GITHUB-USER/proxy-manager/main/installation.sh | bash
```

Alternativ mit `sudo`:

```bash
curl -fsSL https://raw.githubusercontent.com/DEIN-GITHUB-USER/proxy-manager/main/installation.sh | sudo bash
```

Während der Installation werden unter anderem folgende Informationen abgefragt:

```text
Interne Domain [home.arpa]:
IP der nginx-LXC [automatisch erkannt]:
```

Beispiel:

```text
Interne Domain [home.arpa]: home.arpa
IP der nginx-LXC [192.168.178.20]:
```

Anschließend wird automatisch:

```text
nginx installiert
Git installiert
Python installiert
Python venv erstellt
Repository nach /opt/proxy-manager geklont
Python-Abhängigkeiten installiert
FastAPI-Systemdienst erstellt
nginx konfiguriert
Update-System eingerichtet
Proxy Manager gestartet
```

---

# DNS

Damit die internen Domains funktionieren, sollte im lokalen DNS ein Wildcard-Eintrag auf die IP des Proxy Managers zeigen.

Beispiel:

```text
*.home.arpa → 192.168.178.20
```

Dadurch können später beliebige Dienste verwendet werden:

```text
homeassistant.home.arpa
proxmox.home.arpa
adguard.home.arpa
nas.home.arpa
```

ohne für jeden Reverse Proxy einen eigenen DNS-Eintrag erstellen zu müssen.

## AdGuard Home

Bei Verwendung von AdGuard Home kann beispielsweise eine DNS-Umschreibung eingerichtet werden:

```text
*.home.arpa
```

auf:

```text
192.168.178.20
```

Die integrierte AdGuard-API-Unterstützung kann zusätzlich über `settings.json` aktiviert werden. Bei Verwendung eines Wildcard-DNS-Eintrags wird sie normalerweise nicht benötigt.

---

# Weboberfläche

Nach erfolgreicher Installation ist die Oberfläche beispielsweise erreichbar über:

```text
http://nginx.home.arpa
```

oder direkt über die IP:

```text
http://192.168.178.20
```

## Startseite

Die Startseite zeigt alle konfigurierten Dienste als Kacheln an.

Jede Kachel enthält:

```text
Favicon

Name des Dienstes
```

Das Favicon wird automatisch vom jeweiligen Zielsystem geladen.

Die Einträge werden alphabetisch nach ihrem Namen sortiert.

Ein Klick auf eine Kachel öffnet direkt den entsprechenden Reverse Proxy.

---

# Konfiguration

Die Verwaltung befindet sich unter:

```text
/config
```

Dort können Reverse-Proxy-Einträge hinzugefügt oder gelöscht werden.

Ein Eintrag besteht aus:

```text
Name
Domain
Ziel-IP / Hostname
Port
Protokoll
```

Beispiel:

```text
Name:       Proxmox
Domain:     proxmox.home.arpa
Ziel:       192.168.178.10
Port:       8006
Protokoll:  https
```

Für HTTP und HTTPS können die Standardports automatisch verwendet werden:

```text
HTTP  → 80
HTTPS → 443
```

Wird kein Port angegeben, verwendet der Proxy Manager den passenden Standardport.

---

# Konfiguration anwenden

Änderungen werden zunächst nur in:

```text
config.json
```

gespeichert.

Die aktuell von nginx verwendete Konfiguration befindet sich in:

```text
/etc/nginx/sites-available/generated.conf
```

Der Proxy Manager vergleicht beide Zustände automatisch.

Wenn Änderungen noch nicht angewendet wurden, erscheint auf der Konfigurationsseite:

```text
⚠ Konfiguration geändert

Die Änderungen wurden noch nicht auf nginx angewendet.

[ Konfiguration anwenden ]
```

Beim Anwenden wird aus `config.json` die neue nginx-Konfiguration erzeugt.

Vor dem Reload wird die nginx-Konfiguration geprüft.

```text
config.json
     │
     ▼
generated.conf
     │
     ▼
 nginx -t
     │
     ├── Fehler → alte Konfiguration wiederherstellen
     │
     └── OK
          │
          ▼
     nginx reload
```

Dadurch soll verhindert werden, dass eine fehlerhafte Konfiguration nginx unbrauchbar macht.

---

# Generierte nginx-Konfiguration

Für jeden Proxy wird automatisch ein eigener nginx-Serverblock erzeugt.

Beispiel:

```nginx
server {
    listen 80;
    server_name homeassistant.home.arpa;

    location / {
        proxy_pass http://192.168.178.30:8123;

        proxy_http_version 1.1;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

WebSocket-Header werden automatisch gesetzt.

Damit funktionieren auch Anwendungen, die WebSockets benötigen.

---

# Home Assistant

Bei Home Assistant muss der Reverse Proxy zusätzlich als vertrauenswürdiger Proxy eingetragen werden.

Beispiel in `configuration.yaml`:

```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 192.168.178.20
```

Dabei muss die IP des Proxy Managers verwendet werden.

Anschließend Home Assistant neu starten.

---

# Lokale Dateien

Die eigentlichen Proxy-Einträge werden gespeichert in:

```text
config.json
```

Lokale Einstellungen befinden sich in:

```text
settings.json
```

Diese Dateien sollten nicht in Git gespeichert werden.

Beispiel `.gitignore`:

```gitignore
.venv/
config.json
settings.json
__pycache__/
*.pyc
```

---

# settings.json

Beispiel:

```json
{
    "nginx_config_path": "/etc/nginx/sites-available/generated.conf",
    "nginx_ip": "192.168.178.20",

    "adguard_enabled": false,
    "adguard_url": "http://adguard.example.com",
    "adguard_username": "",
    "adguard_password": "",

    "update_enabled": true,
    "update_branch": "main",
    "update_version_url": "https://raw.githubusercontent.com/DEIN-GITHUB-USER/proxy-manager/main/VERSION"
}
```

Echte Zugangsdaten dürfen nicht in das öffentliche Repository committed werden.

Für das Repository kann stattdessen eine Datei wie:

```text
settings.example.json
```

mit Platzhaltern verwendet werden.

---

# Versionierung

Die aktuelle Version befindet sich in:

```text
VERSION
```

Beispiel:

```text
0.1.0
```

Für neue Versionen kann das Schema:

```text
MAJOR.MINOR.PATCH
```

verwendet werden.

Beispiele:

```text
0.1.0   Erste Version
0.1.1   Fehlerbehebung
0.2.0   Neue Funktionen
1.0.0   Erste stabile Hauptversion
```

---

# Updates

Der Proxy Manager kann die lokale Version mit der `VERSION`-Datei auf GitHub vergleichen.

Wenn eine neue Version vorhanden ist, wird auf der Konfigurationsseite beispielsweise angezeigt:

```text
Installierte Version: 0.1.0

Version 0.2.0 verfügbar

[ Update installieren ]
```

Das Update wird über den systemd-Dienst:

```text
proxy-manager-update.service
```

ausgeführt.

Dieser startet:

```text
update.sh
```

Der Update-Ablauf ist:

```text
GitHub prüfen
     │
     ▼
git fetch
     │
     ▼
neue Version vorhanden
     │
     ▼
git pull --ff-only
     │
     ▼
Python-Abhängigkeiten aktualisieren
     │
     ▼
optionale Migration
     │
     ▼
nginx prüfen
     │
     ▼
Proxy Manager neu starten
```

Lokale Dateien wie:

```text
settings.json
config.json
```

bleiben dabei erhalten.

---

# Update manuell ausführen

Ein Update kann bei Bedarf auch direkt auf dem Server gestartet werden:

```bash
systemctl start proxy-manager-update.service
```

Status anzeigen:

```bash
systemctl status proxy-manager-update.service
```

Logs anzeigen:

```bash
journalctl -u proxy-manager-update.service
```

---

# post_update.sh

Falls eine zukünftige Version Änderungen am System benötigt, kann optional eine:

```text
post_update.sh
```

mit dem Update ausgeliefert werden.

Damit können beispielsweise zukünftig:

```text
neue systemd-Dienste eingerichtet
Verzeichnisse angelegt
Konfigurationen migriert
Berechtigungen angepasst
```

werden.

Dadurch können bestehende Installationen auch bei größeren Änderungen weiter aktualisiert werden.

---

# Dienste

FastAPI:

```bash
systemctl status proxy-manager
```

Neustart:

```bash
systemctl restart proxy-manager
```

Logs:

```bash
journalctl -u proxy-manager
```

Live-Logs:

```bash
journalctl -u proxy-manager -f
```

nginx:

```bash
systemctl status nginx
```

Konfiguration prüfen:

```bash
nginx -t
```

nginx neu laden:

```bash
systemctl reload nginx
```

---

# Verzeichnisstruktur

Nach der Installation befindet sich das Projekt standardmäßig unter:

```text
/opt/proxy-manager
```

Beispiel:

```text
proxy-manager/
├── VERSION
├── main.py
├── installation.sh
├── update.sh
├── requirements.txt
├── config.json
├── settings.json
├── settings.example.json
│
├── templates/
│   ├── base.html
│   ├── home.html
│   ├── config.html
│   └── config_add.html
│
└── static/
    ├── style.css
    └── default-icon.svg
```

---

# Entwicklung

Repository klonen:

```bash
git clone https://github.com/DEIN-GITHUB-USER/proxy-manager.git
cd proxy-manager
```

Python-Umgebung erstellen:

## Windows

```powershell
py -m venv .venv
.\.venv\Scripts\Activate.ps1
```

Falls PowerShell die Aktivierung blockiert:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

Danach:

```powershell
.\.venv\Scripts\Activate.ps1
```

## Linux

```bash
python3 -m venv .venv
source .venv/bin/activate
```

Abhängigkeiten installieren:

```bash
pip install -r requirements.txt
```

Entwicklungsserver starten:

```bash
uvicorn main:app --reload
```

---

# Git Workflow

Änderungen prüfen:

```bash
git status
```

Änderungen hinzufügen:

```bash
git add .
```

Commit:

```bash
git commit -m "Beschreibung der Änderung"
```

Push:

```bash
git push
```

Bei einer neuen veröffentlichten Version zusätzlich die Datei:

```text
VERSION
```

anpassen.

Beispiel:

```text
0.1.0
```

ändern zu:

```text
0.2.0
```

und gemeinsam mit den Änderungen committen.

---

# Zeilenenden

Da die Shell-Skripte unter Linux ausgeführt werden, sollten sie mit LF-Zeilenenden gespeichert werden.

Empfohlene `.gitattributes`:

```gitattributes
*.sh text eol=lf
*.py text eol=lf
*.html text eol=lf
*.css text eol=lf
*.json text eol=lf
VERSION text eol=lf
```

---

# Sicherheit

Der Proxy Manager ist aktuell für den Einsatz in einem vertrauenswürdigen internen Netzwerk bzw. Homelab vorgesehen.

Die Verwaltungsoberfläche sollte nicht ohne zusätzliche Absicherung direkt aus dem Internet erreichbar gemacht werden.

Insbesondere sollten niemals folgende Dateien oder Daten öffentlich committed werden:

```text
settings.json
config.json
Passwörter
API-Zugangsdaten
Tokens
private IP-Konfigurationen, sofern diese nicht veröffentlicht werden sollen
```

Bei HTTPS-Zielsystemen mit selbstsignierten Zertifikaten kann die Favicon-Abfrage aktuell die Zertifikatsprüfung deaktivieren.

Das ist für interne Systeme praktisch, sollte bei einem Einsatz außerhalb eines vertrauenswürdigen Netzes jedoch entsprechend angepasst werden.

---

# Projektstatus

Das Projekt befindet sich aktuell in Entwicklung.

Aktuelle Version:

```text
0.1.0
```

Geplante bzw. mögliche Erweiterungen:

```text
HTTPS für Frontend-Domains
Let's Encrypt / eigene Zertifikate
Bearbeiten bestehender Proxy-Einträge
Update-Fortschritt in der Weboberfläche
Update-Historie
Authentifizierung der Konfigurationsseite
Favicon-Cache
Statusanzeige der Zielsysteme
Backup / Restore der Konfiguration
```

---

# Lizenz

Dieses Projekt steht unter der MIT License.

Du darfst den Code frei verwenden, verändern, weitergeben und auch in eigenen Projekten einsetzen.

Weitere Informationen befinden sich in der Datei `LICENSE`.