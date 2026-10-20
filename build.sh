#!/bin/bash
# =============================================================================
# Build de Mixette : compile, empaquette Mixette.app, signe, puis vérifie.
#
# Signature stable (recommandé) : l'autorisation TCC « audio du système » est liée
# à l'exigence désignée ; épinglée sur un certificat, elle survit aux recompilations.
# Renseigner l'identité dans .signing.env (non versionné) :
#   SIGN_CN="Mon certificat"   KC="$HOME/Library/Keychains/xxx.keychain-db"   KCPASS="…"
# Sans identité, signature ad hoc : ça marche, mais l'autorisation est à redonner
# après chaque recompilation.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Mixette"
BUNDLE_ID="com.polat.mixette"
VERSION="${VERSION:-1.0.0}"
MIN_OS="14.4"          # process taps : 14.2+ ; CATapDescription stable à partir de 14.4

[ -f .signing.env ] && source .signing.env
SIGN_CN="${SIGN_CN:-}"
KC="${KC:-}"
KCPASS="${KCPASS:-}"

BUILD="build"
# Bureau synchronisé par iCloud : le File Provider recolle com.apple.FinderInfo et
# codesign refuse de signer. On assemble et signe hors iCloud, puis on copie.
STAGE="$HOME/Library/Caches/$BUNDLE_ID.build"
APP="$STAGE/$APP_NAME.app"
FINAL="$BUILD/$APP_NAME.app"

if [ -n "$SIGN_CN" ] && security find-identity ${KC:+"$KC"} 2>/dev/null | grep -q "\"$SIGN_CN\""; then
    [ -n "$KC" ] && [ -n "$KCPASS" ] && security unlock-keychain -p "$KCPASS" "$KC" 2>/dev/null || true
    CERT_SHA1=$(security find-certificate -c "$SIGN_CN" -Z ${KC:+"$KC"} | awk '/SHA-1/{print tolower($3)}')
    APP_REQ="identifier \"$BUNDLE_ID\" and certificate leaf = H\"$CERT_SHA1\""
    echo "→ Signature avec « $SIGN_CN »"
else
    SIGN_CN=""
    echo "→ Pas d'identité configurée : signature ad hoc"
fi

rm -rf "$APP" "$FINAL"; mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ Compilation…"
swiftc -O -target "arm64-apple-macos$MIN_OS" -parse-as-library \
    Sources/Core/*.swift Sources/App/*.swift -o "$APP/Contents/MacOS/$APP_NAME"

[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleDevelopmentRegion</key><string>fr</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSAudioCaptureUsageDescription</key><string>Mixette lit le son de chaque app pour en régler le volume et la sortie. Rien n'est enregistré ni envoyé.</string>
  <key>NSHumanReadableCopyright</key><string>Usage personnel — Polat Yilmaz</string>
</dict></plist>
PLIST

echo "→ Signature…"
xattr -cr "$APP" 2>/dev/null || true
if [ -n "$SIGN_CN" ]; then
    args=(--force --sign "$SIGN_CN" ${KC:+--keychain "$KC"} --identifier "$BUNDLE_ID" --requirements "=designated => $APP_REQ")
else
    args=(--force --sign - --identifier "$BUNDLE_ID")
fi
codesign "${args[@]}" "$APP" 2>/dev/null || { find "$APP" -exec xattr -c {} \; 2>/dev/null; codesign "${args[@]}" "$APP"; }
codesign --verify --strict --verbose=1 "$APP" 2>&1 | tail -1
ditto "$APP" "$FINAL"
codesign --verify ${APP_REQ:+-R="$APP_REQ"} "$FINAL" || { echo "✗ signature invalide après copie" >&2; exit 1; }
echo "✓ Construit : $FINAL"
echo "  Lancer : open \"$FINAL\"   (jamais le binaire interne)"
