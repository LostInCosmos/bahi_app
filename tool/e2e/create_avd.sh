#!/usr/bin/env bash
# Creates the Android virtual device the e2e flows run on (DAS-109), once.
# Pixel 7, Android 15 (API 35), Google APIs arm64 image, back camera = the
# emulator's virtual scene (tool/e2e/run.sh overrides the camera per run),
# hardware keyboard on so text entry is typed rather than tapped.
#
# Needs the SDK packages that `flutter doctor` lists plus the system image:
#   sdkmanager --install "system-images;android-35;google_apis;arm64-v8a" "emulator"
set -euo pipefail
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
AVD="${E2E_AVD:-dastavez_e2e}"
IMAGE="system-images;android-35;google_apis;arm64-v8a"

echo no | "$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager" create avd -n "$AVD" -d pixel_7 -k "$IMAGE" --force
CFG="$HOME/.android/avd/$AVD.avd/config.ini"
sed -i '' \
  -e 's/^hw.camera.back=.*/hw.camera.back=virtualscene/' \
  -e 's/^hw.keyboard=no/hw.keyboard=yes/' \
  -e 's/^hw.gpu.enabled=no/hw.gpu.enabled=yes/' \
  "$CFG"
grep -E '^(hw.camera.back|hw.keyboard|hw.ramSize|hw.gpu.enabled)=' "$CFG"
echo "created $AVD; boot it with: emulator -avd $AVD (tool/e2e/run.sh does this)"
