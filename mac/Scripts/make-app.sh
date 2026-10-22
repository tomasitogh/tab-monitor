#!/bin/bash
# Compila TabMonitor.app desde el Swift Package, la firma y opcionalmente la instala.
#
#   Scripts/make-app.sh                    .build/TabMonitor.app, firmada con tu certificado Apple Development
#   Scripts/make-app.sh --install          …y reemplaza /Applications/TabMonitor.app (cierra la copia abierta)
#   Scripts/make-app.sh --install --open   …y la abre
#   TABMONITOR_SIGN_IDENTITY='Apple Development: …' Scripts/make-app.sh   (otra identidad)
#   TABMONITOR_SKIP_APK=1 Scripts/make-app.sh   (sin compilar el visor de Android)
#   Scripts/make-app.sh --release          para publicar: exige la clave del visor y el certificado,
#                                          y sella la firma con la hora de Apple (release.sh lo usa)
#
# La versión sale del último tag vX.Y.Z (TABMONITOR_VERSION la pisa) y el número de build, de la
# cantidad de commits; los dos van a la app de Mac y al visor.
#
# El visor se firma con la clave de release de ~/.tabmonitor/release.jks (TABMONITOR_KEYSTORE la
# pisa; se crea con Scripts/make-apk-key.sh) y su contraseña en el llavero. Sin ella, con la de
# debug: AdbBridge reinstala el visor si la firma cambia.
#
# El visor de Android (android/) se compila y viaja dentro de la app con su SHA-256: AdbBridge lo
# instala o actualiza en la tablet cuando el hash no coincide con el instalado.
#
# Los permisos de macOS (Grabación de pantalla, más adelante Accesibilidad) quedan atados al
# bundle ID y al certificado. Firmar siempre con el mismo Apple Development evita que macOS los
# vuelva a pedir tras cada compilación; la firma ad hoc ("-") los pierde en cada build.
set -euo pipefail
cd "$(dirname "$0")/.."

install=0; open_app=0; release=0
for arg in "$@"; do
    case "$arg" in
        --install) install=1 ;;
        --open) open_app=1 ;;
        --release) release=1 ;;
        *) echo "uso: $0 [--install] [--open] [--release]" >&2; exit 2 ;;
    esac
done

version="${TABMONITOR_VERSION:-$(git describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
version="${version:-0.1.0}"
build_number="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
if [ "$release" = 1 ] && [ "${TABMONITOR_SKIP_APK:-0}" = 1 ]; then
    echo "error: un release tiene que llevar el visor (sacá TABMONITOR_SKIP_APK)" >&2
    exit 1
fi

swift build -c release --product TabMonitor
bin="$(swift build -c release --product TabMonitor --show-bin-path)"

app=.build/TabMonitor.app
stage=.build/TabMonitor.app.partial   # se arma aparte para no dejar un bundle a medias
rm -rf "$stage"
mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources"
cp "$bin/TabMonitor" "$stage/Contents/MacOS/TabMonitor"
cp Packaging/Info.plist "$stage/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$stage/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$stage/Contents/Info.plist"
printf 'APPL????' > "$stage/Contents/PkgInfo"

if [ "${TABMONITOR_SKIP_APK:-0}" != 1 ]; then
    studio_jdk="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
    if [ -z "${JAVA_HOME:-}" ] && [ -d "$studio_jdk" ]; then export JAVA_HOME="$studio_jdk"; fi
    keystore="${TABMONITOR_KEYSTORE:-$HOME/.tabmonitor/release.jks}"
    if [ -f "$keystore" ]; then
        export TABMONITOR_KEYSTORE="$keystore"
        if [ -z "${TABMONITOR_KEYSTORE_PASSWORD:-}" ]; then
            TABMONITOR_KEYSTORE_PASSWORD="$(security find-generic-password -s dev.tabmonitor.apk -a release -w)"
            export TABMONITOR_KEYSTORE_PASSWORD
        fi
    elif [ "$release" = 1 ]; then
        echo "error: falta la clave del visor ($keystore); creala con Scripts/make-apk-key.sh" >&2
        exit 1
    else
        echo "aviso: sin clave de release del visor; se firma con la de debug" >&2
    fi
    (cd ../android && ./gradlew -q assembleRelease -PtabmonitorVersion="$version" -PtabmonitorBuild="$build_number")
    apk=../android/app/build/outputs/apk/release/app-release.apk
    cp "$apk" "$stage/Contents/Resources/TabMonitor.apk"
    shasum -a 256 "$apk" | awk '{ print $1 }' > "$stage/Contents/Resources/TabMonitor.apk.sha256"
fi

# La primera identidad Apple Development del llavero, por su hash SHA-1 (codesign rechaza un
# nombre que comparten dos certificados válidos, como pasa tras una renovación).
identity="${TABMONITOR_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development: / { print $2; exit }' || true)}"
if [ -z "$identity" ] && [ "$release" = 1 ]; then
    echo "error: --release necesita un certificado Apple Development en el llavero" >&2
    exit 1
elif [ -z "$identity" ]; then
    identity="-"
    echo "aviso: no hay identidad Apple Development en el llavero; se firma ad hoc y macOS va a" >&2
    echo "       pedir Grabación de pantalla de nuevo tras cada compilación." >&2
fi
# La hora de Apple mantiene válida la firma de un release después de que venza el certificado.
timestamp=--timestamp=none
if [ "$release" = 1 ]; then timestamp=--timestamp; fi
codesign --force --sign "$identity" "$timestamp" "$stage"
codesign --verify --strict "$stage"

rm -rf "$app"
mv "$stage" "$app"
echo "listo: $app $version ($build_number), firmada con $identity"

if [ "$install" = 1 ]; then
    dest="/Applications/TabMonitor.app"
    if pgrep -x TabMonitor >/dev/null; then
        osascript -e 'tell application id "dev.tabmonitor.mac" to quit' >/dev/null 2>&1 || pkill -x TabMonitor || true
        for _ in $(seq 1 50); do pgrep -x TabMonitor >/dev/null || break; sleep 0.1; done
    fi
    rm -rf "$dest"
    ditto "$app" "$dest"
    echo "instalada en $dest"
    if [ "$open_app" = 1 ]; then open "$dest"; fi
elif [ "$open_app" = 1 ]; then
    open "$app"
fi
