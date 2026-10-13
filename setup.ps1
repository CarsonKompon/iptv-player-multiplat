<#
  One-time project setup (Windows). Generates the platform folders with
  `flutter create`, then patches them for TV remotes / IPTV:

    - Android / Fire TV / Android TV: leanback launcher, no touchscreen
      required, INTERNET permission, cleartext http (most IPTV servers)
    - macOS: network client entitlement
    - web: hls.js for HLS playback in browsers

  Run from this folder:   .\setup.ps1
  Then:                   flutter run -d windows   (or android, macos, linux, chrome)
#>
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw 'Flutter is not on PATH. Install it from https://docs.flutter.dev/get-started/install'
}

# Flutter plugins on Windows need symlinks, which require Developer Mode.
$devMode = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense
if ($devMode -ne 1 -and -not $env:CI) {
    Write-Host 'Windows Developer Mode is OFF - Flutter needs it to build apps with plugins.' -ForegroundColor Yellow
    Write-Host 'Opening Settings: turn on "Developer Mode", then run flutter again.' -ForegroundColor Yellow
    Start-Process 'ms-settings:developers'
}

flutter create --project-name iptv_guide --org com.retroguide --platforms=android,windows,macos,linux,web .
if (Test-Path 'test\widget_test.dart') { Remove-Item 'test\widget_test.dart' }

function Patch-File([string]$path, [scriptblock]$fn) {
    if (-not (Test-Path $path)) { Write-Host "  (skip, missing) $path"; return }
    $text = Get-Content $path -Raw
    $new = & $fn $text
    if ($new -ne $text) { Set-Content -Path $path -Value $new -NoNewline -Encoding UTF8; Write-Host "  patched $path" }
}

Write-Host 'Patching Android manifest...'
Patch-File 'android\app\src\main\AndroidManifest.xml' {
    param($t)
    if ($t -notmatch 'android.permission.INTERNET') {
        $t = $t -replace '(<manifest[^>]*>)', "`$1`n    <uses-permission android:name=`"android.permission.INTERNET`"/>`n    <uses-feature android:name=`"android.software.leanback`" android:required=`"false`"/>`n    <uses-feature android:name=`"android.hardware.touchscreen`" android:required=`"false`"/>"
    }
    if ($t -notmatch 'usesCleartextTraffic') {
        $t = $t -replace '<application', '<application android:usesCleartextTraffic="true" android:banner="@mipmap/ic_launcher"'
    }
    if ($t -notmatch 'LEANBACK_LAUNCHER') {
        $t = $t -replace '(<category android:name="android.intent.category.LAUNCHER"\s*/>)', "`$1`n                <category android:name=`"android.intent.category.LEANBACK_LAUNCHER`"/>"
    }
    $t = $t -replace 'android:label="iptv_guide"', 'android:label="IPTV Guide"'
    $t
}

Write-Host 'Patching macOS entitlements...'
foreach ($f in @('macos\Runner\DebugProfile.entitlements', 'macos\Runner\Release.entitlements')) {
    Patch-File $f {
        param($t)
        if ($t -notmatch 'network.client') {
            $t = $t -replace '<dict>', "<dict>`n`t<key>com.apple.security.network.client</key>`n`t<true/>"
        }
        $t
    }
}

Write-Host 'Patching web/index.html...'
Patch-File 'web\index.html' {
    param($t)
    if ($t -notmatch 'hls.js') {
        $t = $t -replace '</head>', "  <script src=`"https://cdn.jsdelivr.net/npm/hls.js@1.5.17/dist/hls.min.js`"></script>`n</head>"
    }
    $t
}

flutter pub get
Write-Host ''
Write-Host 'Done. Try:  flutter run -d windows' -ForegroundColor Green
