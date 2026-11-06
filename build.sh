#!/bin/sh
# Builds a signed, sandboxed build/TypoLearner.app.
set -eu
cd "$(dirname "$0")"

swift build -c release --product TypoLearner
bin="$(swift build -c release --show-bin-path)/TypoLearner"

app=build/TypoLearner.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/TypoLearner"
cp App/Info.plist "$app/Contents/Info.plist"
cp Resources/en_50k.txt Resources/ru_50k.txt App/AppIcon.icns "$app/Contents/Resources/"

# A stable identity keeps macOS permissions and the Keychain key across rebuilds.
# Without a development certificate, sign ad hoc ("-"); macOS then asks for permissions after each rebuild.
if [ -n "${SIGN_IDENTITY:-}" ]; then
  identity="$SIGN_IDENTITY"
elif security find-identity -v -p codesigning | grep -q "Apple Development"; then
  identity="Apple Development"
else
  identity="-"
fi
codesign --force --options runtime --timestamp=none \
  --entitlements App/TypoLearner.entitlements --sign "$identity" "$app"
codesign --verify --strict "$app"
echo "Built $app"
