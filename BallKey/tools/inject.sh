#!/bin/bash
set -e
IPA="$1"
DYLIB="$2"
OUT="$3"
[ -z "$OUT" ] && OUT="FreeFire_BallKey.ipa"
[ -f "$IPA" ] && [ -f "$DYLIB" ] || { echo "uso: $0 entrada.ipa BallKey.dylib [saida.ipa]"; exit 1; }

WORK=$(mktemp -d)
unzip -q "$IPA" -d "$WORK"
APP=$(ls -d "$WORK"/Payload/*.app | head -1)
[ -n "$APP" ] || { echo "Payload sem .app"; exit 1; }

mkdir -p "$APP/Frameworks"
cp "$DYLIB" "$APP/Frameworks/BallKey.dylib"

EXEC="$APP/$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$APP/Info.plist")"
insert_dylib --strip-codesig --inplace '@executable_path/Frameworks/BallKey.dylib' "$EXEC"

rm -rf "$WORK/Payload/__MACOSX"
(cd "$WORK" && zip -qr "$OLDPWD/$OUT" Payload)
rm -rf "$WORK"
echo "pronto: $OUT"
echo "agora reassine com Sideloadly, AltStore ou TrollStore"
