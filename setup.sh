#!/usr/bin/env bash
# One-time project setup (macOS / Linux). See setup.ps1 for what it does.
set -euo pipefail
cd "$(dirname "$0")"

command -v flutter >/dev/null || { echo "Flutter is not on PATH"; exit 1; }

flutter create --project-name iptv_guide --org com.retroguide --platforms=android,windows,macos,linux,web .
rm -f test/widget_test.dart

M=android/app/src/main/AndroidManifest.xml
if [ -f "$M" ] && ! grep -q 'android.permission.INTERNET' "$M"; then
  perl -0pi -e 's#(<manifest[^>]*>)#$1\n    <uses-permission android:name="android.permission.INTERNET"/>\n    <uses-feature android:name="android.software.leanback" android:required="false"/>\n    <uses-feature android:name="android.hardware.touchscreen" android:required="false"/>#' "$M"
fi
if [ -f "$M" ] && ! grep -q 'usesCleartextTraffic' "$M"; then
  perl -0pi -e 's#<application#<application android:usesCleartextTraffic="true" android:banner="\@mipmap/ic_launcher"#' "$M"
fi
if [ -f "$M" ] && ! grep -q 'LEANBACK_LAUNCHER' "$M"; then
  perl -0pi -e 's#(<category android:name="android.intent.category.LAUNCHER"\s*/>)#$1\n                <category android:name="android.intent.category.LEANBACK_LAUNCHER"/>#' "$M"
fi
[ -f "$M" ] && perl -pi -e 's#android:label="iptv_guide"#android:label="IPTV Guide"#' "$M"

for f in macos/Runner/DebugProfile.entitlements macos/Runner/Release.entitlements; do
  if [ -f "$f" ] && ! grep -q 'network.client' "$f"; then
    perl -0pi -e 's#<dict>#<dict>\n\t<key>com.apple.security.network.client</key>\n\t<true/>#' "$f"
  fi
done

W=web/index.html
if [ -f "$W" ] && ! grep -q 'hls.js' "$W"; then
  perl -0pi -e 's#</head>#  <script src="https://cdn.jsdelivr.net/npm/hls.js\@1.5.17/dist/hls.min.js"></script>\n</head>#' "$W"
fi

flutter pub get
echo
echo "Done. Try:  flutter run -d macos   (or linux, android, chrome)"
if [ "$(uname)" = "Linux" ]; then
  echo "Linux needs libmpv:  sudo apt install libmpv-dev mpv"
fi
