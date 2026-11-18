#!/bin/bash
# DICOM-Importer – Installation/Update und Konfiguration per Mosyle (Custom Command, läuft als root)
#
# - lädt das neueste Release von GitHub und installiert/aktualisiert /Applications/DICOM-Importer.app
# - überspringt das Update, wenn die Version schon installiert ist oder die App gerade läuft
# - schreibt die systemweite Konfiguration (gilt für alle Benutzer, Felder in der App gesperrt)
#
# Empfohlen in Mosyle: Custom Command, "Execute as: root", Ausführung täglich bzw. bei Check-in.

set -euo pipefail

# ---- Einstellungen ---------------------------------------------------------
REPO="sommeru/dicom-importer"
APP_NAME="DICOM-Importer"
APP_PATH="/Applications/${APP_NAME}.app"

CONF_DIR="/Library/Application Support/DICOM-Importer"
CONF_FILE="${CONF_DIR}/dicom-importer.conf"

WEBDAV_URL="https://192.168.2.40:5001/Dicom"
WEBDAV_USER="team"
WEBDAV_PASSWORD="HIER_PASSWORT_EINTRAGEN"
CERT_SHA256="HIER_FINGERABDRUCK_EINTRAGEN"   # 32 Paare, z. B. AA:4D:…:6F
# -----------------------------------------------------------------------------

log() { echo "[dicom-importer] $*"; }

WORK="$(mktemp -d /tmp/dicom-importer.XXXXXX)"
MOUNT="${WORK}/mnt"
cleanup() {
  hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---- 1. Konfiguration schreiben (bei jedem Lauf, damit Änderungen ankommen) ----
mkdir -p "$CONF_DIR"
cat > "${CONF_FILE}.new" <<CONF
# Verwaltet durch Mosyle – lokale Änderungen werden überschrieben.
[archive]
type = webdav
url = ${WEBDAV_URL}
user = ${WEBDAV_USER}
password = "${WEBDAV_PASSWORD}"
certificate_sha256 = ${CERT_SHA256}

[general]
auto_scan = true
eject = true
capitalize_names = false
CONF
chown root:wheel "${CONF_FILE}.new"
chmod 644 "${CONF_FILE}.new"          # alle lokalen Benutzer müssen sie lesen können
mv -f "${CONF_FILE}.new" "$CONF_FILE"
log "Konfiguration geschrieben: $CONF_FILE"

# ---- 2. Neuestes Release ermitteln ----------------------------------------------
curl -fsSL --retry 3 -o "${WORK}/release.json" "https://api.github.com/repos/${REPO}/releases/latest"
LATEST_TAG="$(plutil -extract tag_name raw -o - "${WORK}/release.json")"
LATEST_VERSION="${LATEST_TAG#v}"

DMG_URL=""
ASSET_COUNT="$(plutil -extract assets raw -o - "${WORK}/release.json")"
for ((i = 0; i < ASSET_COUNT; i++)); do
  URL="$(plutil -extract "assets.${i}.browser_download_url" raw -o - "${WORK}/release.json")"
  if [[ "$URL" == *.dmg ]]; then DMG_URL="$URL"; break; fi
done
if [[ -z "$DMG_URL" ]]; then
  log "FEHLER: Kein DMG im Release ${LATEST_TAG} gefunden."
  exit 1
fi

INSTALLED_VERSION=""
if [[ -d "$APP_PATH" ]]; then
  INSTALLED_VERSION="$(defaults read "${APP_PATH}/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
fi
log "Installiert: ${INSTALLED_VERSION:-keine}, verfügbar: ${LATEST_VERSION}"

if [[ "$INSTALLED_VERSION" == "$LATEST_VERSION" ]]; then
  log "Bereits aktuell."
  exit 0
fi

# ---- 3. Nicht aktualisieren, solange die App läuft (Upload könnte laufen) ----------
if pgrep -xq "$APP_NAME"; then
  log "App läuft gerade – Update beim nächsten Lauf."
  exit 0
fi

# ---- 4. Herunterladen und installieren -------------------------------------------
log "Lade ${DMG_URL}"
curl -fsSL --retry 3 -o "${WORK}/app.dmg" "$DMG_URL"

mkdir -p "$MOUNT"
hdiutil attach "${WORK}/app.dmg" -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" -quiet
if [[ ! -d "${MOUNT}/${APP_NAME}.app" ]]; then
  log "FEHLER: ${APP_NAME}.app nicht im DMG gefunden."
  exit 1
fi

# Erst daneben kopieren, dann austauschen – nie eine halb kopierte App in /Applications.
ditto "${MOUNT}/${APP_NAME}.app" "${APP_PATH}.new"
rm -rf "$APP_PATH"
mv "${APP_PATH}.new" "$APP_PATH"
chown -R root:admin "$APP_PATH"
xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true

log "Installiert: $(defaults read "${APP_PATH}/Contents/Info" CFBundleShortVersionString)"
