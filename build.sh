#!/usr/bin/env bash
# Builds release packages into ./dist/  (macOS / Linux)
#
#   ./build.sh                    # everything this machine can build
#   ./build.sh macos android      # just some
#   ./build.sh --split-apk ...    # per-CPU APKs instead of one universal APK
#
# Platforms: macos (Mac only), linux (Linux only), android, web.
# Windows builds need Windows: run .\build.ps1 there.
#
# Output (dist/):
#   IPTVGuide-macos.zip            IPTV Guide.app
#   IPTVGuide-linux-x64.tar.gz     run ./iptv_guide (needs libmpv: sudo apt install libmpv2 or libmpv1)
#   IPTVGuide-android.apk
#   IPTVGuide-web.zip
set -uo pipefail
cd "$(dirname "$0")"

command -v flutter >/dev/null || { echo "Flutter is not on PATH"; exit 1; }

SPLIT_APK=0
PLATFORMS=()
for a in "$@"; do
  case "$a" in
    --split-apk) SPLIT_APK=1 ;;
    *) PLATFORMS+=("$(echo "$a" | tr '[:upper:]' '[:lower:]')") ;;
  esac
done
if [ ${#PLATFORMS[@]} -eq 0 ]; then
  case "$(uname)" in
    Darwin) PLATFORMS=(macos android web) ;;
    *)      PLATFORMS=(linux android web) ;;
  esac
fi

DIST="$PWD/dist"
mkdir -p "$DIST"
SUMMARY=()

need() { [ -d "$1" ] || { echo "'$1' folder missing - run ./setup.sh first"; return 1; }; }

run() {  # run <name> <function>
  echo; echo "=== $1 ==="
  local start=$SECONDS
  if "$2"; then SUMMARY+=("$1|OK ($((SECONDS - start))s)"); else SUMMARY+=("$1|FAILED"); fi
}

build_macos() {
  [ "$(uname)" = "Darwin" ] || { echo "macOS builds need a Mac"; return 1; }
  need macos || return 1
  flutter build macos --release || return 1
  local app
  app=$(ls -d build/macos/Build/Products/Release/*.app | head -n 1)
  rm -f "$DIST/IPTVGuide-macos.zip"
  ditto -c -k --keepParent "$app" "$DIST/IPTVGuide-macos.zip"
}

build_linux() {
  [ "$(uname)" = "Linux" ] || { echo "Linux builds need Linux (or WSL)"; return 1; }
  need linux || return 1
  flutter build linux --release || return 1
  local arch
  arch=$(ls build/linux | head -n 1)   # x64 or arm64
  tar -C "build/linux/$arch/release" -czf "$DIST/IPTVGuide-linux-$arch.tar.gz" --transform 's,^bundle,IPTVGuide,' bundle
}

build_android() {
  need android || return 1
  if [ $SPLIT_APK -eq 1 ]; then
    flutter build apk --release --split-per-abi || return 1
    for f in build/app/outputs/flutter-apk/app-*-release.apk; do
      abi=$(basename "$f" | sed -e 's/^app-//' -e 's/-release\.apk$//')
      cp "$f" "$DIST/IPTVGuide-android-$abi.apk"
    done
  else
    flutter build apk --release || return 1
    cp build/app/outputs/flutter-apk/app-release.apk "$DIST/IPTVGuide-android.apk"
  fi
}

build_web() {
  need web || return 1
  flutter build web --release || return 1
  rm -f "$DIST/IPTVGuide-web.zip"
  (cd build/web && zip -qr "$DIST/IPTVGuide-web.zip" .)
}

flutter pub get || exit 1

for p in "${PLATFORMS[@]}"; do
  case "$p" in
    macos)   run macos build_macos ;;
    linux)   run linux build_linux ;;
    android) run android build_android ;;
    web)     run web build_web ;;
    windows) SUMMARY+=("windows|SKIPPED: build on Windows with .\\build.ps1") ;;
    *)       SUMMARY+=("$p|SKIPPED: unknown platform") ;;
  esac
done

echo; echo "=== Summary ==="
for s in "${SUMMARY[@]}"; do printf "  %-10s %s\n" "${s%%|*}" "${s#*|}"; done
echo; echo "Packages are in $DIST"; ls -lh "$DIST" | tail -n +2

# non-zero exit if anything failed (so CI notices)
for s in "${SUMMARY[@]}"; do [[ "${s#*|}" == FAILED* ]] && exit 1; done
exit 0
