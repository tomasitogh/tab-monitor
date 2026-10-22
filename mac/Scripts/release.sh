#!/bin/bash
# Publica una versión de TabMonitor: GitHub Release con el zip de la app y cask en el tap.
#
#   Scripts/release.sh 0.2.0             compila, prueba, crea el tag v0.2.0, el release y actualiza el cask
#   Scripts/release.sh 0.2.0 --dry-run   solo compila y arma el zip y el cask en .build/dist/
#
# Necesita: árbol limpio en main, gh con sesión iniciada, la clave del visor
# (Scripts/make-apk-key.sh) y el certificado Apple Development. El tap es el repo
# tomasitogh/homebrew-tap (TABMONITOR_TAP lo pisa) y tiene que existir.
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "error: $*" >&2; exit 1; }

version="${1:-}"; dry_run=0
[ "${2:-}" = --dry-run ] && dry_run=1
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "uso: $0 X.Y.Z [--dry-run]"
tag="v$version"
tap="${TABMONITOR_TAP:-tomasitogh/homebrew-tap}"
repo=tomasitogh/tab-monitor

if [ "$dry_run" = 0 ]; then
    [ -z "$(git status --porcelain)" ] || die "hay cambios sin commitear"
    [ "$(git rev-parse --abbrev-ref HEAD)" = main ] || die "los releases salen de main"
    git fetch -q origin main
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "main no está igual que origin/main"
    ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null || die "el tag $tag ya existe"
    gh auth status >/dev/null 2>&1 || die "gh no tiene sesión iniciada (gh auth login)"
    gh repo view "$tap" >/dev/null 2>&1 || die "no existe el tap $tap (gh repo create $tap --public)"
fi

echo "== tests"
swift test
studio_jdk="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
if [ -z "${JAVA_HOME:-}" ] && [ -d "$studio_jdk" ]; then export JAVA_HOME="$studio_jdk"; fi
(cd ../android && ./gradlew -q testDebugUnitTest)

echo "== app $version"
TABMONITOR_VERSION="$version" Scripts/make-app.sh --release

dist=.build/dist
rm -rf "$dist"; mkdir -p "$dist"
zip="$dist/TabMonitor-$version.zip"
ditto -c -k --sequesterRsrc --keepParent .build/TabMonitor.app "$zip"
sha="$(shasum -a 256 "$zip" | awk '{ print $1 }')"
sed -e "s/@VERSION@/$version/" -e "s/@SHA256@/$sha/" Packaging/tabmonitor.rb.in > "$dist/tabmonitor.rb"
echo "zip: $zip ($sha)"

if [ "$dry_run" = 1 ]; then
    echo "listo (--dry-run): no se creó tag ni release; el cask quedó en $dist/tabmonitor.rb"
    exit 0
fi

echo "== release $tag"
git tag -a "$tag" -m "TabMonitor $version"
git push -q origin "$tag"
gh release create "$tag" "$zip" --repo "$repo" --title "TabMonitor $version" --generate-notes

echo "== cask en $tap"
tapdir="$(mktemp -d)"
trap 'rm -rf "$tapdir"' EXIT
gh repo clone "$tap" "$tapdir" -- -q
mkdir -p "$tapdir/Casks"
cp "$dist/tabmonitor.rb" "$tapdir/Casks/tabmonitor.rb"
git -C "$tapdir" add Casks/tabmonitor.rb
git -C "$tapdir" commit -q -m "tabmonitor $version"
git -C "$tapdir" push -q
echo "listo: brew update && brew upgrade --cask tabmonitor"
