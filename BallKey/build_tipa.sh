#!/bin/bash
set -e
cd BallKey
make clean && make package FINALPACKAGE=1
DEB=$(ls packages/*.deb | head -1)
cd ../BallKeyApp
make clean && make package FINALPACKAGE=1
APP=$(ls -d .theos/_/Applications/BallKeyApp.app)
rm -rf ../Payload && mkdir -p ../Payload
cp -R "$APP" ../Payload/
cp "../BallKey/$DEB" ../Payload/BallKeyApp.app/
ldid -S entitlements.plist ../Payload/BallKeyApp.app/BallKeyApp
cd .. && rm -f BallKey6.tipa
zip -r BallKey6.tipa Payload >/dev/null
rm -rf Payload
echo "OK: BallKey6.tipa"
