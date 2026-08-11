#!/usr/bin/env bash

set -euo pipefail


# ============================================================
# Proxy Manager Installer
# ============================================================

APP_NAME="proxy-manager"
APP_USER="proxy-manager"

REPO_URL="https://github.com/racoon2code/proxy-manager.git"
RAW_BASE_URL="https://raw.githubusercontent.com/racoon2code/proxy-manager/main"
BRANCH="main"

APP_DIR="/opt/$APP_NAME"

NGINX_MAIN="/etc/nginx/sites-available/main"
NGINX_GENERATED="/etc/nginx/sites-available/generated.conf"

NGINX_STREAM_DIR="/etc/nginx/stream-enabled"
NGINX_STREAM_INCLUDE="/etc/nginx/stream.conf"
NGINX_STREAM_GENERATED="$NGINX_STREAM_DIR/generated-stream.conf"

SERVICE_FILE="/etc/systemd/system/proxy-manager.service"
UPDATE_SERVICE_FILE="/etc/systemd/system/proxy-manager-update.service"

APPLY_HELPER="/usr/local/sbin/proxy-manager-apply"
SUDOERS_FILE="/etc/sudoers.d/proxy-manager"


# ============================================================
# Funktionen
# ============================================================

print_header() {
    echo
    echo "=========================================="
    echo "       Proxy Manager Installation"
    echo "=========================================="
    echo
}


# ============================================================
# Root prüfen
# ============================================================

if [[ "$EUID" -ne 0 ]]; then
    echo "Bitte das Installationsscript als root ausführen."
    exit 1
fi


print_header


# ============================================================
# Domain abfragen
# ============================================================

DOMAIN_INPUT=""

if [[ -r /dev/tty ]]; then

    read -r -p \
        "Interne Domain [home.arpa]: " \
        DOMAIN_INPUT \
        < /dev/tty

fi

DOMAIN_INPUT="${DOMAIN_INPUT:-home.arpa}"


# Sowohl home.arpa als auch *.home.arpa akzeptieren

if [[ "$DOMAIN_INPUT" == "*."* ]]; then
    BASE_DOMAIN="${DOMAIN_INPUT:2}"
else
    BASE_DOMAIN="$DOMAIN_INPUT"
fi


# Einfache Plausibilitätsprüfung

if [[ ! "$BASE_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo "Ungültige Domain: $BASE_DOMAIN"
    exit 1
fi


WILDCARD_DOMAIN="*.$BASE_DOMAIN"


echo
echo "Basisdomain:"
echo "  $BASE_DOMAIN"
echo
echo "Wildcard:"
echo "  $WILDCARD_DOMAIN"


# ============================================================
# IP automatisch erkennen
# ============================================================

DETECTED_IP=""


# Zuerst Routing-Tabelle benutzen

DETECTED_IP=$(
    ip -4 route get 1.1.1.1 2>/dev/null |
    awk '{
        for (i = 1; i <= NF; i++) {
            if ($i == "src") {
                print $(i+1)
                exit
            }
        }
    }'
) || true


# Fallback: erste globale IPv4

if [[ -z "$DETECTED_IP" ]]; then

    DETECTED_IP=$(
        ip -o -4 addr show scope global |
        awk '{
            split($4, address, "/")
            print address[1]
            exit
        }'
    ) || true

fi


IP_INPUT=""

echo

if [[ -n "$DETECTED_IP" ]]; then

    echo "Erkannte IP-Adresse:"
    echo "  $DETECTED_IP"
    echo

    if [[ -r /dev/tty ]]; then

        read -r -p \
            "Diese IP verwenden? [$DETECTED_IP]: " \
            IP_INPUT \
            < /dev/tty

    fi

    NGINX_IP="${IP_INPUT:-$DETECTED_IP}"

else

    echo "IP-Adresse konnte nicht automatisch erkannt werden."

    if [[ -r /dev/tty ]]; then

        read -r -p \
            "IP-Adresse des Proxy Managers: " \
            NGINX_IP \
            < /dev/tty

    else

        echo "Keine interaktive Eingabe möglich."
        exit 1

    fi

fi


if [[ -z "$NGINX_IP" ]]; then
    echo "Keine IP-Adresse angegeben."
    exit 1
fi


echo
echo "Proxy-Manager-IP:"
echo "  $NGINX_IP"
echo


# ============================================================
# Pakete installieren
# ============================================================

echo "Installiere benötigte Pakete..."
echo

apt-get update

apt-get install -y \
    nginx \
    libnginx-mod-stream \
    git \
    python3 \
    python3-venv \
    sudo \
    ca-certificates


# ============================================================
# Systembenutzer
# ============================================================

if ! id "$APP_USER" >/dev/null 2>&1; then

    echo
    echo "Erstelle Systembenutzer $APP_USER..."

    useradd \
        --system \
        --user-group \
        --no-create-home \
        --shell /usr/sbin/nologin \
        "$APP_USER"

fi


# ============================================================
# Repository installieren
# ============================================================

echo

if [[ -d "$APP_DIR/.git" ]]; then

    echo "Bestehende Installation gefunden."
    echo "Aktualisiere Repository..."

    cd "$APP_DIR"

    git fetch origin "$BRANCH"
    git pull --ff-only origin "$BRANCH"

elif [[ -e "$APP_DIR" ]]; then

    echo
    echo "$APP_DIR existiert bereits,"
    echo "ist aber kein Git-Repository."
    echo
    echo "Installation wird abgebrochen."

    exit 1

else

    echo "Klone Repository..."

    git clone \
        --branch "$BRANCH" \
        --single-branch \
        "$REPO_URL" \
        "$APP_DIR"

fi


cd "$APP_DIR"


# ============================================================
# Python venv
# ============================================================

if [[ ! -d "$APP_DIR/.venv" ]]; then

    echo
    echo "Erstelle Python Virtual Environment..."

    python3 -m venv "$APP_DIR/.venv"

fi


echo
echo "Installiere Python-Abhängigkeiten..."

"$APP_DIR/.venv/bin/python" \
    -m pip install \
    -r "$APP_DIR/requirements.txt"


# ============================================================
# config.json
# ============================================================

if [[ ! -f "$APP_DIR/config.json" ]]; then

    echo
    echo "Erstelle config.json..."

    echo '[]' > "$APP_DIR/config.json"

fi


chown "$APP_USER:$APP_USER" \
    "$APP_DIR/config.json"

chmod 660 \
    "$APP_DIR/config.json"


# ============================================================
# settings.json
# ============================================================

if [[ ! -f "$APP_DIR/settings.json" ]]; then

    echo
    echo "Erstelle settings.json..."

    cat > "$APP_DIR/settings.json" <<EOF
{
    "base_domain": "$BASE_DOMAIN",

    "nginx_config_path": "$NGINX_GENERATED",
    "nginx_stream_config_path": "$NGINX_STREAM_GENERATED",
    "nginx_ip": "$NGINX_IP",

    "adguard_enabled": false,
    "adguard_url": "",
    "adguard_username": "",
    "adguard_password": "",

    "update_enabled": true,
    "update_branch": "$BRANCH",
    "update_version_url": "$RAW_BASE_URL/VERSION"
}
EOF

else

    echo
    echo "settings.json existiert bereits."
    echo "Datei wird nicht überschrieben."

fi


chown root:"$APP_USER" \
    "$APP_DIR/settings.json"

chmod 640 \
    "$APP_DIR/settings.json"


# ============================================================
# nginx HTTP Hauptkonfiguration
# ============================================================

echo
echo "Erstelle nginx HTTP-Grundkonfiguration..."

cat > "$NGINX_MAIN" <<EOF
server {
    listen 80 default_server;

    server_name $BASE_DOMAIN $WILDCARD_DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:8000;

        proxy_http_version 1.1;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF


# ============================================================
# generated.conf vorbereiten
# ============================================================

if [[ ! -f "$NGINX_GENERATED" ]]; then
    touch "$NGINX_GENERATED"
fi


chown "$APP_USER:$APP_USER" \
    "$NGINX_GENERATED"

chmod 664 \
    "$NGINX_GENERATED"


# ============================================================
# nginx HTTP Sites aktivieren
# ============================================================

rm -f /etc/nginx/sites-enabled/default


ln -sfn \
    "$NGINX_MAIN" \
    /etc/nginx/sites-enabled/main


ln -sfn \
    "$NGINX_GENERATED" \
    /etc/nginx/sites-enabled/generated.conf


# ============================================================
# nginx Stream / TLS Passthrough
# ============================================================

echo
echo "Richte nginx TLS-Passthrough ein..."


mkdir -p "$NGINX_STREAM_DIR"


cat > "$NGINX_STREAM_INCLUDE" <<EOF
stream {
    include $NGINX_STREAM_DIR/*.conf;
}
EOF


# Stream-Konfiguration auf Top-Level in nginx.conf einbinden.
# Darf NICHT innerhalb von http {} stehen.

if ! grep -qF \
    "include $NGINX_STREAM_INCLUDE;" \
    /etc/nginx/nginx.conf
then

    sed -i \
        "/^[[:space:]]*http[[:space:]]*{/i include $NGINX_STREAM_INCLUDE;\n" \
        /etc/nginx/nginx.conf

fi


# Generierte Stream-Konfiguration vorbereiten

if [[ ! -f "$NGINX_STREAM_GENERATED" ]]; then
    touch "$NGINX_STREAM_GENERATED"
fi


chown "$APP_USER:$APP_USER" \
    "$NGINX_STREAM_GENERATED"

chmod 664 \
    "$NGINX_STREAM_GENERATED"


# ============================================================
# FastAPI systemd Service
# ============================================================

echo
echo "Erstelle proxy-manager.service..."

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Proxy Manager
After=network.target

[Service]
Type=simple

User=$APP_USER
Group=$APP_USER

WorkingDirectory=$APP_DIR

ExecStart=$APP_DIR/.venv/bin/uvicorn main:app --host 127.0.0.1 --port 8000

Restart=on-failure
RestartSec=3

Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF


# ============================================================
# nginx Apply Helper
# ============================================================

echo
echo "Erstelle nginx Apply Helper..."

cat > "$APPLY_HELPER" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

nginx -t
systemctl reload nginx
EOF


chmod 755 "$APPLY_HELPER"
chown root:root "$APPLY_HELPER"


# ============================================================
# Update Service
# ============================================================

echo
echo "Erstelle Update-Service..."

cat > "$UPDATE_SERVICE_FILE" <<EOF
[Unit]
Description=Proxy Manager Update
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot

WorkingDirectory=$APP_DIR

ExecStart=/bin/bash $APP_DIR/update.sh
EOF


# WICHTIG:
# Kein chmod auf update.sh.
#
# Der Dateimodus wird durch Git verwaltet.
# Dadurch erzeugt der Installer keine lokale Git-Änderung,
# die später das automatische Update blockieren würde.


# ============================================================
# Begrenzte sudo-Rechte
# ============================================================

echo
echo "Richte benötigte sudo-Rechte ein..."

SYSTEMCTL_PATH="$(command -v systemctl)"


cat > "$SUDOERS_FILE" <<EOF
$APP_USER ALL=(root) NOPASSWD: $APPLY_HELPER
$APP_USER ALL=(root) NOPASSWD: $SYSTEMCTL_PATH start --no-block proxy-manager-update.service
EOF


chmod 440 "$SUDOERS_FILE"


if ! visudo -cf "$SUDOERS_FILE"; then

    echo
    echo "Fehler in der sudoers-Konfiguration."

    rm -f "$SUDOERS_FILE"

    exit 1

fi


# ============================================================
# systemd
# ============================================================

echo
echo "Aktualisiere systemd..."

systemctl daemon-reload

systemctl enable nginx
systemctl enable proxy-manager


# ============================================================
# nginx Konfiguration prüfen
# ============================================================

echo
echo "Prüfe nginx-Konfiguration..."
echo

if ! nginx -t; then

    echo
    echo "nginx-Konfiguration ist fehlerhaft."
    echo "Installation wird abgebrochen."

    exit 1

fi


# ============================================================
# Dienste starten
# ============================================================

echo
echo "Starte Dienste..."

systemctl restart nginx
systemctl restart proxy-manager


# ============================================================
# Funktionsprüfung
# ============================================================

echo
echo "Prüfe Proxy Manager..."

sleep 2


if systemctl is-active --quiet proxy-manager; then

    echo "Proxy Manager läuft."

else

    echo
    echo "Proxy Manager konnte nicht gestartet werden."
    echo
    echo "Logs:"
    echo
    echo "journalctl -u proxy-manager -n 50 --no-pager"

    exit 1

fi


# ============================================================
# Git Status prüfen
# ============================================================

cd "$APP_DIR"


if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then

    echo
    echo "WARNUNG:"
    echo "Das Git-Repository enthält lokale Änderungen:"
    echo

    git status --short

    echo

else

    echo
    echo "Git-Repository ist sauber."

fi


# ============================================================
# Abschluss
# ============================================================

echo
echo
echo "=========================================="
echo "       Installation abgeschlossen"
echo "=========================================="
echo
echo "Proxy Manager IP:"
echo
echo "  $NGINX_IP"
echo
echo "Interne Domain:"
echo
echo "  $BASE_DOMAIN"
echo
echo "Bitte im lokalen DNS folgenden"
echo "Wildcard-Eintrag erstellen:"
echo
echo "  $WILDCARD_DOMAIN -> $NGINX_IP"
echo
echo
echo "Danach ist der Proxy Manager erreichbar über:"
echo
echo "  http://nginx.$BASE_DOMAIN"
echo
echo "oder:"
echo
echo "  http://$NGINX_IP"
echo
echo
echo "Konfiguration:"
echo
echo "  http://nginx.$BASE_DOMAIN/config"
echo
echo
echo "TLS-Passthrough ist vorbereitet."
echo
echo "Beispiel Proxmox:"
echo
echo "  Domain:          proxmox.$BASE_DOMAIN"
echo "  Ziel:            Proxmox-IP"
echo "  Port:            8006"
echo "  Protokoll:       https"
echo "  TLS Passthrough: aktiviert"
echo
echo "Aufruf anschließend:"
echo
echo "  https://proxmox.$BASE_DOMAIN"
echo
echo
echo "Service:"
echo
echo "  systemctl status proxy-manager"
echo
echo "Logs:"
echo
echo "  journalctl -u proxy-manager -f"
echo
echo "=========================================="
echo