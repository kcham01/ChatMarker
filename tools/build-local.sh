#!/usr/bin/env bash
# Builds the APK without Gradle, using Ubuntu's Android tool packages:
#   sudo apt-get install aapt zipalign apksigner dalvik-exchange
# plus an API 34 android.jar (pass its path as ANDROID_JAR).
#
# Usage: ANDROID_JAR=/path/android-34.jar KEYSTORE=/path/key.jks KEY_PASS=... tools/build-local.sh out.apk
set -euo pipefail

OUT_APK="${1:-PDF-to-Images.apk}"
: "${ANDROID_JAR:?set ANDROID_JAR to an API 34 android.jar}"
: "${KEYSTORE:?set KEYSTORE to a signing keystore}"
: "${KEY_PASS:?set KEY_PASS to the keystore password}"
VERSION_CODE="${VERSION_CODE:-1}"
VERSION_NAME="${VERSION_NAME:-1.0.$VERSION_CODE}"
PACKAGE=com.kcham01.pdftopng

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/app/src/main"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/gen" "$WORK/classes"

# Gradle takes the package from `namespace`; aapt needs it in the manifest itself.
sed "s|<manifest |<manifest package=\"$PACKAGE\" |" "$SRC/AndroidManifest.xml" > "$WORK/AndroidManifest.xml"

aapt package -f -m \
  -J "$WORK/gen" \
  -S "$SRC/res" \
  -M "$WORK/AndroidManifest.xml" \
  -I "$ANDROID_JAR" \
  --min-sdk-version 26 --target-sdk-version 34 \
  --version-code "$VERSION_CODE" --version-name "$VERSION_NAME" \
  -F "$WORK/unsigned.apk"

find "$SRC/java" "$WORK/gen" -name '*.java' > "$WORK/sources.txt"
javac -nowarn -Xlint:-options -encoding UTF-8 -source 8 -target 8 \
  -bootclasspath "$ANDROID_JAR" -d "$WORK/classes" @"$WORK/sources.txt"

dalvik-exchange --dex --min-sdk-version=26 --output="$WORK/classes.dex" "$WORK/classes"
(cd "$WORK" && zip -q unsigned.apk classes.dex)

zipalign -f 4 "$WORK/unsigned.apk" "$WORK/aligned.apk"
apksigner sign --ks "$KEYSTORE" --ks-pass "pass:$KEY_PASS" --out "$OUT_APK" "$WORK/aligned.apk"
apksigner verify "$OUT_APK"
echo "Built $OUT_APK"
