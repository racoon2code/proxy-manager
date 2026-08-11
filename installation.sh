#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# Proxy Manager Installer
# ============================================================

APP_NAME="proxy-manager"
APP_USER="proxy-manager"

REPO_URL="https://github.com/racoon2code/proxy-manager.git"
BRANCH="main"

APP_DIR="/opt/$APP_NAME"

NGINX_MAIN="/etc/nginx/sites-available/main"
NGINX_GENERATED="/etc/nginx/sites-available/generated.conf"

SERVICE_FILE="/etc/systemd/system/proxy-manager.service"
UPDATE_SERVICE_FILE="/etc/systemd/system/proxy-manager-update.service"

APPLY_HELPER="/usr/local/sbin/proxy-manager-apply"
SUDOERS_FILE="/etc/sudoers.d/proxy-manager"


# ============================================================
# Root prüfen
# ============================================================

if [[ "$EUID" -ne 0 ]]; then
    echo "Bitte als root ausführen."
    exit 1
fi


echo
echo "=========================================="
echo "       Proxy Manager Installation"
echo "=========================================="
echo


# ============================================================
# Domain abfragen
# ============================================================

read -rp "Interne Domain [home.arpa]: " DOMAIN_INPUT

DOMAIN_INPUT="${DOMAIN_INPUT:-home.arpa}"

# Eingaben wie *.home.arpa ebenfalls akzeptieren
DOMAIN_INPUT="${DOMAIN_INPUT#\*.}"

if [[ ! "$DOMAIN_INPUT" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo "Ungültige Domain."
    exit 1
fi

BASE_DOMAIN="$DOMAIN_INPUT"
WILDCARD_DOMAIN="*.$BASE_DOMAIN"


echo
echo "Basisdomain:     $BASE_DOMAIN"
echo "Wildcard-Domain: $WILDCARD_DOMAIN"


# ============================================================
# IP automatisch erkennen
# ============================================================

DETECTED_IP=""

# Zuerst über Routing-Tabelle versuchen
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


echo

if [[ -n "$DETECTED_IP" ]]; then

    read -rp "IP der nginx-LXC [$DETECTED_IP]: " IP_INPUT

    NGINX_IP="${IP_INPUT:-$DETECTED_IP}"

else

    read -rp "IP der nginx-LXC: " NGINX_IP

fi


if [[ -z "$NGINX_IP" ]]; then
    echo "Keine IP angegeben."
    exit 1
fi


echo
echo "nginx-IP: $NGINX_IP"
echo


# ============================================================
# Pakete installieren
# ============================================================

echo "Installiere benötigte Pakete..."

apt-get update

apt-get install -y \
    nginx \
    git \
    python3 \
    python3-venv \
    sudo \
    ca-certificates


# ============================================================
# Systembenutzer
# ============================================================

if ! id "$APP_USER" >/dev/null 2>&1; then

    echo "Erstelle Benutzer $APP_USER..."

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

if [[ -d "$APP_DIR/.git" ]]; then

    echo "Bestehende Installation gefunden."
    echo "Aktualisiere Repository..."

    cd "$APP_DIR"

    git fetch origin "$BRANCH"
    git pull --ff-only origin "$BRANCH"

elif [[ -e "$APP_DIR" ]]; then

    echo "$APP_DIR existiert, ist aber kein Git-Repository."
    echo "Installation wird abgebrochen."
    exit 1

else

    echo "Klone Repository..."

    git clone \
        --branch "$BRANCH" \
        "$REPO_URL" \
        "$APP_DIR"

fi


cd "$APP_DIR"


# ============================================================
# Python venv
# ============================================================

if [[ ! -d "$APP_DIR/.venv" ]]; then

    echo "Erstelle Python venv..."

    python3 -m venv "$APP_DIR/.venv"

fi


echo "Installiere Python-Abhängigkeiten..."

"$APP_DIR/.venv/bin/python" \
    -m pip install \
    -r "$APP_DIR/requirements.txt"


# ============================================================
# config.json
# ============================================================

if [[ ! -f "$APP_DIR/config.json" ]]; then

    echo '[]' > "$APP_DIR/config.json"

fi

chown "$APP_USER:$APP_USER" "$APP_DIR/config.json"
chmod 660 "$APP_DIR/config.json"


# ============================================================
# settings.json
# ============================================================

if [[ ! -f "$APP_DIR/settings.json" ]]; then

    cat > "$APP_DIR/settings.json" <<EOF
{
    "base_domain": "$BASE_DOMAIN",
    "nginx_config_path": "$NGINX_GENERATED",
    "nginx_ip": "$NGINX_IP",

    "adguard_enabled": false,
    "adguard_url": "",
    "adguard_username": "",
    "adguard_password": "",

    "update_enabled": true,
    "update_branch": "$BRANCH"
}
EOF

else

    echo "settings.json existiert bereits und wird nicht überschrieben."

fi


chown root:"$APP_USER" "$APP_DIR/settings.json"
chmod 640 "$APP_DIR/settings.json"


# ============================================================
# nginx main
# ============================================================

echo "Erstelle nginx-Grundkonfiguration..."

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
# generated.conf
# ============================================================

if [[ ! -f "$NGINX_GENERATED" ]]; then
    touch "$NGINX_GENERATED"
fi

chown "$APP_USER:$APP_USER" "$NGINX_GENERATED"
chmod 664 "$NGINX_GENERATED"


# ============================================================
# nginx aktivieren
# ============================================================

rm -f /etc/nginx/sites-enabled/default

ln -sfn \
    "$NGINX_MAIN" \
    /etc/nginx/sites-enabled/main

ln -sfn \
    "$NGINX_GENERATED" \
    /etc/nginx/sites-enabled/generated.conf


# ============================================================
# FastAPI Service
# ============================================================

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

cat > "$APPLY_HELPER" <<'EOF'
#!/usr/bin/env bash

set -e

nginx -t
systemctl reload nginx
EOF

chmod 755 "$APPLY_HELPER"
chown root:root "$APPLY_HELPER"


# ============================================================
# Update Service
# ============================================================

cat > "$UPDATE_SERVICE_FILE" <<EOF
[Unit]
Description=Proxy Manager Update
After=network-online.target

[Service]
Type=oneshot
WorkingDirectory=$APP_DIR
ExecStart=/bin/bash $APP_DIR/update.sh
EOF


chmod +x "$APP_DIR/update.sh"


# ============================================================
# sudo Rechte stark begrenzen
# ============================================================

SYSTEMCTL_PATH="$(command -v systemctl)"

cat > "$SUDOERS_FILE" <<EOF
$APP_USER ALL=(root) NOPASSWD: $APPLY_HELPER
$APP_USER ALL=(root) NOPASSWD: $SYSTEMCTL_PATH start --no-block proxy-manager-update.service
EOF

chmod 440 "$SUDOERS_FILE"

visudo -cf "$SUDOERS_FILE"


# ============================================================
# systemd
# ============================================================

systemctl daemon-reload

systemctl enable nginx
systemctl enable proxy-manager

systemctl restart proxy-manager


# ============================================================
# nginx prüfen
# ============================================================

echo
echo "Prüfe nginx..."

nginx -t

systemctl reload nginx


# ============================================================
# Abschluss
# ============================================================

echo
echo "=========================================="
echo "       Installation abgeschlossen"
echo "=========================================="
echo
echo "IP:"
echo "  $NGINX_IP"
echo
echo "Domain:"
echo "  $BASE_DOMAIN"
echo
echo "Bitte im DNS einen Wildcard-Eintrag anlegen:"
echo
echo "  $WILDCARD_DOMAIN -> $NGINX_IP"
echo
echo "Danach z.B.:"
echo
echo "  http://nginx.$BASE_DOMAIN"
echo
echo "oder direkt:"
echo
echo "  http://$NGINX_IP"
echo