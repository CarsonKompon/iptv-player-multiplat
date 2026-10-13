<#
  Builds release packages into .\dist\

    .\build.ps1                              # everything this PC can build
    .\build.ps1 -Platforms windows,android   # just some
    .\build.ps1 -Platforms linux             # Linux via WSL (see below)
    .\build.ps1 -SplitApk                    # per-CPU APKs instead of one universal APK

  Platforms: windows, android, web, linux, macos
    windows / android / web  build directly on Windows.
    linux                    builds inside WSL (Ubuntu) if it's installed and has
                             Flutter + the Linux toolchain (see README).
    macos                    can only be built on a Mac: run ./build.sh there.

  Output (dist\):
    IPTVGuide-windows-x64.zip       unzip anywhere, run iptv_guide.exe
    IPTVGuide-android.apk           Android / Fire TV / Android TV (sideload)
    IPTVGuide-web.zip               static site, host on any web server
    IPTVGuide-linux-x64.tar.gz      from WSL
#>
param(
    [string[]]$Platforms = @('windows', 'android', 'web'),
    [switch]$SplitApk,
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$Platforms = $Platforms | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ }

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) { throw 'Flutter is not on PATH.' }

# With no -Platforms given, skip Android quietly when there's no Android SDK.
function Test-AndroidSdk {
    foreach ($p in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, (Join-Path $env:LOCALAPPDATA 'Android\Sdk'))) {
        if ($p -and (Test-Path (Join-Path $p 'platform-tools'))) { return $true }
    }
    return $false
}
$skipAndroid = (-not $PSBoundParameters.ContainsKey('Platforms')) -and -not (Test-AndroidSdk)

# With no -Platforms given, include Linux when WSL has Flutter installed.
$linuxNote = $null
if (-not $PSBoundParameters.ContainsKey('Platforms')) {
    if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
        $linuxNote = 'SKIPPED: needs WSL (run: wsl --install), then Flutter + Linux build tools inside it - see README'
    } else {
        & wsl bash -lc 'command -v flutter >/dev/null 2>&1' 2>$null
        if ($LASTEXITCODE -eq 0) {
            $Platforms += 'linux'
        } else {
            $linuxNote = 'SKIPPED: WSL has no Flutter installed - see README "Linux via WSL"'
        }
    }
}

$dist = Join-Path $PSScriptRoot 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$results = [ordered]@{}

function Step([string]$name, [scriptblock]$body) {
    Write-Host ""
    Write-Host "=== $name ===" -ForegroundColor Cyan
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        & $body
        $results[$name] = "OK  ($([int]$sw.Elapsed.TotalSeconds)s)"
    } catch {
        Write-Host $_ -ForegroundColor Red
        $results[$name] = "FAILED: $($_.Exception.Message)"
    }
}

# (not named "Flutter": PowerShell names are case-insensitive, so it would call itself)
$flutterExe = (Get-Command flutter -CommandType Application, ExternalScript | Select-Object -First 1).Source
function Invoke-Flutter([string[]]$argList) {
    & $flutterExe @argList
    if ($LASTEXITCODE -ne 0) { throw "flutter $($argList -join ' ') exited with $LASTEXITCODE" }
}

function Require-Folder([string]$folder) {
    if (-not (Test-Path $folder)) { throw "'$folder' folder missing - run .\setup.ps1 first." }
}

function Zip-Folder([string]$src, [string]$zip) {
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path (Join-Path $src '*') -DestinationPath $zip
}

if ($Clean) { Invoke-Flutter @('clean') }
Invoke-Flutter @('pub', 'get')

foreach ($p in $Platforms) {
    switch ($p) {
        'windows' {
            Step 'windows' {
                Require-Folder 'windows'
                Invoke-Flutter @('build', 'windows', '--release')
                $out = 'build\windows\x64\runner\Release'
                $stage = Join-Path $dist 'windows\IPTVGuide'
                if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
                New-Item -ItemType Directory -Force -Path $stage | Out-Null
                Copy-Item (Join-Path $out '*') $stage -Recurse
                Zip-Folder $stage (Join-Path $dist 'IPTVGuide-windows-x64.zip')
            }
        }
        'android' {
            if ($skipAndroid) {
                $results['android'] = 'SKIPPED: no Android SDK found (install Android Studio, then run again)'
                continue
            }
            Step 'android' {
                Require-Folder 'android'
                if ($SplitApk) {
                    Invoke-Flutter @('build', 'apk', '--release', '--split-per-abi')
                    Get-ChildItem 'build\app\outputs\flutter-apk\app-*-release.apk' | ForEach-Object {
                        $abi = $_.Name -replace '^app-', '' -replace '-release\.apk$', ''
                        Copy-Item $_.FullName (Join-Path $dist "IPTVGuide-android-$abi.apk") -Force
                    }
                } else {
                    Invoke-Flutter @('build', 'apk', '--release')
                    Copy-Item 'build\app\outputs\flutter-apk\app-release.apk' (Join-Path $dist 'IPTVGuide-android.apk') -Force
                }
            }
        }
        'web' {
            Step 'web' {
                Require-Folder 'web'
                Invoke-Flutter @('build', 'web', '--release')
                Zip-Folder 'build\web' (Join-Path $dist 'IPTVGuide-web.zip')
            }
        }
        'linux' {
            Step 'linux (WSL)' {
                if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) { throw 'WSL is not installed (wsl --install), or build on a Linux PC with ./build.sh linux' }
                Require-Folder 'linux'
                $wslPath = (& wsl wslpath -a ($PSScriptRoot -replace '\\', '/')).Trim()
                & wsl bash -lc "cd '$wslPath' && chmod +x ./build.sh && ./build.sh linux"
                if ($LASTEXITCODE -ne 0) { throw "WSL build exited with $LASTEXITCODE" }
                # WSL's `pub get` rewrote package paths for Linux; restore them for Windows
                Invoke-Flutter @('pub', 'get')
            }
        }
        'macos' {
            $results['macos'] = 'SKIPPED: macOS apps can only be built on a Mac (run ./build.sh there)'
        }
        default {
            $results[$p] = "SKIPPED: unknown platform '$p' (use windows, android, web, linux, macos)"
        }
    }
}

if ($linuxNote) { $results['linux'] = $linuxNote }
$results['macos'] = 'SKIPPED: macOS apps can only be built on a Mac (run ./build.sh there)'

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
foreach ($k in $results.Keys) {
    $v = $results[$k]
    $color = if ($v -like 'OK*') { 'Green' } elseif ($v -like 'SKIPPED*') { 'Yellow' } else { 'Red' }
    Write-Host ("  {0,-14} {1}" -f $k, $v) -ForegroundColor $color
}
Write-Host ""
Write-Host "Packages are in $dist"
Get-ChildItem $dist -File | ForEach-Object { Write-Host ("  {0,-36} {1,8:N1} MB" -f $_.Name, ($_.Length / 1MB)) }

# non-zero exit if anything failed (so CI notices)
if ($results.Values | Where-Object { $_ -like 'FAILED*' }) { exit 1 }
