#!/bin/bash
set -e
cd "$(dirname "$0")"
command -v zip >/dev/null || { echo "instale zip"; exit 1; }

cd BallKey
make clean && make package FINALPACKAGE=1
DEB=$(ls packages/*.deb | head -1)
cd ../BallKeyApp
make clean && make FINALPACKAGE=1
BIN=$(find .theos/obj -maxdepth 4 -type f -name "BallKeyApp" | head -1)
[ -n "$BIN" ] || { echo "binario nao gerado"; exit 1; }
cd ..

rm -rf Payload
mkdir -p Payload/BallKeyApp.app
cp "BallKeyApp/$BIN" Payload/BallKeyApp.app/BallKeyApp
cp BallKeyApp/Info.plist Payload/BallKeyApp.app/Info.plist
cp "BallKey/$DEB" Payload/BallKeyApp.app/
chmod +x Payload/BallKeyApp.app/BallKeyApp

if command -v ldid >/dev/null; then
  ldid -SBallKeyApp/entitlements.plist Payload/BallKeyApp.app/BallKeyApp
elif [ -x "$THEOS/bin/ldid" ]; then
  "$THEOS/bin/ldid" -SBallKeyApp/entitlements.plist Payload/BallKeyApp.app/BallKeyApp
fi

rm -f BallKey.tipa
zip -qr BallKey.tipa Payload
rm -rf Payload
echo "OK: $(pwd)/BallKey.tipa"
