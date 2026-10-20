#!/bin/bash
# Compila TabMonitor.app desde el Swift Package, la firma y opcionalmente la instala.
#
#   Scripts/make-app.sh                    .build/TabMonitor.app, firmada con tu certificado Apple Development
#   Scripts/make-app.sh --install          …y reemplaza /Applications/TabMonitor.app (cierra la copia abierta)
#   Scripts/make-app.sh --install --open   …y la abre
#   TABMONITOR_SIGN_IDENTITY='Apple Development: …' Scripts/make-app.sh   (otra identidad)
#
# Los permisos de macOS (Grabación de pantalla, más adelante Accesibilidad) quedan atados al
# bundle ID y al certificado. Firmar siempre con el mismo Apple Development evita que macOS los
# vuelva a pedir tras cada compilación; la firma ad hoc ("-") los pierde en cada build.
set -euo pipefail
cd "$(dirname "$0")/.."

install=0; open_app=0
for arg in "$@"; do
    case "$arg" in
        --install) install=1 ;;
        --open) open_app=1 ;;
        *) echo "uso: $0 [--install] [--open]" >&2; exit 2 ;;
    esac
done

swift build -c release --product TabMonitor
bin="$(swift build -c release --product TabMonitor --show-bin-path)"

app=.build/TabMonitor.app
stage=.build/TabMonitor.app.partial   # se arma aparte para no dejar un bundle a medias
rm -rf "$stage"
mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources"
cp "$bin/TabMonitor" "$stage/Contents/MacOS/TabMonitor"
cp Packaging/Info.plist "$stage/Contents/Info.plist"
build_number="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$stage/Contents/Info.plist"
printf 'APPL????' > "$stage/Contents/PkgInfo"

# La primera identidad Apple Development del llavero, por su hash SHA-1 (codesign rechaza un
# nombre que comparten dos certificados válidos, como pasa tras una renovación).
identity="${TABMONITOR_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development: / { print $2; exit }' || true)}"
if [ -z "$identity" ]; then
    identity="-"
    echo "aviso: no hay identidad Apple Development en el llavero; se firma ad hoc y macOS va a" >&2
    echo "       pedir Grabación de pantalla de nuevo tras cada compilación." >&2
fi
codesign --force --sign "$identity" --timestamp=none "$stage"
codesign --verify --strict "$stage"

rm -rf "$app"
mv "$stage" "$app"
echo "listo: $app (firmada con $identity)"

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
