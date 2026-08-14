#!/usr/bin/env bash

set -euo pipefail


APP_DIR="/opt/proxy-manager"
BRANCH="main"


if [[ "$EUID" -ne 0 ]]; then
    echo "Update muss als root ausgeführt werden."
    exit 1
fi


echo
echo "=========================================="
echo "          Proxy Manager Update"
echo "=========================================="
echo


cd "$APP_DIR"


# ============================================================
# Git prüfen
# ============================================================

if [[ ! -d ".git" ]]; then
    echo "Kein Git-Repository gefunden."
    exit 1
fi


# Nur Änderungen an getrackten Dateien berücksichtigen.
# settings.json / config.json sind ignoriert.

if [[ -n "$(git status --porcelain --untracked-files=no -- . ':(exclude)settings.json')" ]]; then

    echo "Lokale Änderungen an Programmdateien gefunden."
    echo "Automatisches Update wird abgebrochen."

    git status --short

    exit 1

fi


# ============================================================
# Update suchen
# ============================================================

echo "Prüfe auf Updates..."

git fetch origin "$BRANCH"


LOCAL_COMMIT="$(git rev-parse HEAD)"
REMOTE_COMMIT="$(git rev-parse "origin/$BRANCH")"


if [[ "$LOCAL_COMMIT" == "$REMOTE_COMMIT" ]]; then

    echo "Proxy Manager ist bereits aktuell."
    exit 0

fi


# ============================================================
# Nur Fast Forward erlauben
# ============================================================

if ! git merge-base --is-ancestor \
    "$LOCAL_COMMIT" \
    "$REMOTE_COMMIT"
then

    echo "Lokaler und Remote-Stand sind auseinander gelaufen."
    echo "Automatisches Update wird abgebrochen."

    exit 1

fi


echo
echo "Update gefunden."
echo
echo "Lokal:  $LOCAL_COMMIT"
echo "Remote: $REMOTE_COMMIT"
echo


# ============================================================
# Update installieren
# ============================================================

git pull --ff-only origin "$BRANCH"


# ============================================================
# Python Dependencies
# ============================================================

echo "Aktualisiere Python-Abhängigkeiten..."

"$APP_DIR/.venv/bin/python" \
    -m pip install \
    -r "$APP_DIR/requirements.txt"


# ============================================================
# Optionale Migration
# ============================================================

if [[ -f "$APP_DIR/post_update.sh" ]]; then

    echo "Führe post_update.sh aus..."

    /bin/bash "$APP_DIR/post_update.sh"

fi


# ============================================================
# systemd neu einlesen
# ============================================================

systemctl daemon-reload


# ============================================================
# nginx prüfen
# ============================================================

nginx -t


# ============================================================
# Anwendung neu starten
# ============================================================

systemctl restart proxy-manager

systemctl reload nginx


echo
echo "=========================================="
echo "          Update erfolgreich"
echo "=========================================="
echo