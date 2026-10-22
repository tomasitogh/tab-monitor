#!/bin/bash
# Crea la clave con la que se firma el visor de Android para publicar. Se corre una sola vez.
#
#   Scripts/make-apk-key.sh
#
# Deja el keystore en ~/.tabmonitor/release.jks y su contraseña (al azar) en el llavero de sesión,
# como "dev.tabmonitor.apk". make-app.sh toma las dos solas.
#
# Hacele backup a las dos cosas: Android solo acepta actualizar el visor si viene firmado con la
# misma clave. Si se pierde, cada tablet tiene que desinstalarlo para recibir uno nuevo.
set -euo pipefail

keystore="$HOME/.tabmonitor/release.jks"
if [ -e "$keystore" ]; then
    echo "ya existe $keystore; no se pisa" >&2
    exit 1
fi
if security find-generic-password -s dev.tabmonitor.apk -a release >/dev/null 2>&1; then
    echo "ya hay una contraseña dev.tabmonitor.apk en el llavero; borrala antes a mano si es vieja" >&2
    exit 1
fi

studio_jdk="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
keytool="${JAVA_HOME:-$studio_jdk}/bin/keytool"

mkdir -p "$(dirname "$keystore")"
chmod 700 "$(dirname "$keystore")"
TABMONITOR_KEYSTORE_PASSWORD="$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)"
export TABMONITOR_KEYSTORE_PASSWORD
"$keytool" -genkeypair -keystore "$keystore" -storetype PKCS12 -alias tabmonitor \
    -keyalg RSA -keysize 4096 -validity 36500 -dname "CN=TabMonitor" \
    -storepass:env TABMONITOR_KEYSTORE_PASSWORD -keypass:env TABMONITOR_KEYSTORE_PASSWORD
chmod 600 "$keystore"
security add-generic-password -s dev.tabmonitor.apk -a release -l "TabMonitor: clave del visor" \
    -w "$TABMONITOR_KEYSTORE_PASSWORD"
echo "listo: $keystore, con la contraseña en el llavero (dev.tabmonitor.apk). Hacele backup a los dos."
