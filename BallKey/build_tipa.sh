#!/bin/bash
set -e
cd "$(dirname "$0")"
command -v zip >/dev/null || { echo "instale zip"; exit 1; }

cd BallKey
make clean && make package FINALPACKAGE=1
DEB=$(ls packages/*.deb | head -1)
cd ../BallKeyApp
make clean && make package FINALPACKAGE=1
APP=$(find .theos/_ -maxdepth 8 -type d -name "*.app" | head -1)
[ -n "$APP" ] || APP=$(find .theos/obj -maxdepth 4 -type d -name "*.app" | head -1)
NAME=$(basename "$APP")
BIN="${NAME%.app}"
cd ..
rm -rf Payload && mkdir -p Payload
cp -R "BallKeyApp/$APP" Payload/
cp "BallKey/$DEB" "Payload/$NAME/"
if command -v ldid >/dev/null; then
  ldid -S BallKeyApp/entitlements.plist "Payload/$NAME/$BIN" || true
elif [ -x "$THEOS/bin/ldid" ]; then
  "$THEOS/bin/ldid" -S BallKeyApp/entitlements.plist "Payload/$NAME/$BIN" || true
fi
rm -f BallKey.tipa
zip -qr BallKey.tipa Payload
rm -rf Payload
echo "OK: $(pwd)/BallKey.tipa"
