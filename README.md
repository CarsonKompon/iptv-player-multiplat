# IPTV Guide (multi-platform)

A Flutter rebuild of the Roku "Retro IPTV Guide", for **Windows, macOS, Linux, Android / Fire TV / Android TV and web**.

- Satellite-style guide: list pill, clock, program details, and a **live PIP** of the channel you were watching.
- A 90-minute, 5-row grid with glossy program blocks and a green highlight.
- **OK** shows the info banner: channel, show, episode, rating, progress bar and what's next.
- Instant channel flipping, with the stream starting once you stop. A tuning progress bar learns how fast your server is.
- Direct channel entry with number buttons.
- **M3U / M3U8** playlists. **XMLTV** guides as `.xml` or `.xml.gz`, in UTF-8 or Latin-1, parsed in the background and cached for 4 hours.
- Playback through **libmpv** (media_kit). Raw MPEG-TS, HLS, DASH and MP4 all play natively, so no `.ts` → `.m3u8` rewriting is needed outside the browser.
- The UI is drawn on a fixed 1920×1080 canvas and scaled to any window or TV.

## Input: anything works

On first launch a **Remote Setup** wizard asks you to:

1. Press any button, so it can detect the device.
2. Press **Up, Down, Left, Right, OK, Guide, Back, Options**.
3. Optionally press the **number buttons 1–9 and 0**. Press OK to skip them.

Supported devices:

- **TV remotes:** Fire TV, Android TV, and HDMI-CEC remotes on Android.
- **Keyboards**, with paste supported in URL fields.
- **Game controllers:** on Android they arrive as keys. On Windows, macOS, Linux and web they're read through the `gamepads` plugin, with sticks and triggers working as buttons and auto-repeat when held.
- **Mice:** click any guide cell to highlight it and click again to tune. The scroll wheel moves up and down. Right-click is Back. Extra mouse buttons can be bound.

You can redo the wizard any time under **Setup → Set up remote / controller**. A few keyboard defaults always work, so you can't lock yourself out:

| Key | Action |
|---|---|
| Arrow keys | Up / Down / Left / Right |
| Enter | OK |
| Esc | Back |
| G | Guide |
| M | Options |
| 0–9 | Numbers |

## Controls

| Where | Button | Action |
|---|---|---|
| Watching | OK | Show or hide the banner (or tune right away while flipping) |
| | Up / Down | Previous / next channel |
| | Left / Right | Volume down / up (retro green on-screen display, 0–30) |
| | Guide, Back | Open the guide (video shrinks into the PIP) |
| | Options | Setup |
| | 0–9 | Type a channel number. It tunes after 2 s, or immediately on OK. |
| Guide | Arrows | Move through channels and time |
| | Up from the first channel | Move to the **List** / **Setup** buttons |
| | OK | Tune the highlighted channel |
| | Guide / Back | Return to full-screen video |
| | 0–9 | Jump to a channel number |

## Getting started

1. Install Flutter 3.24 or newer.
2. In this folder, run:
   ```powershell
   .\setup.ps1          # Windows   (macOS/Linux: ./setup.sh)
   flutter run -d windows
   ```
   `setup.ps1` runs `flutter create` to generate the platform folders. It then patches:
   - **Android:** TV launcher, no touchscreen required, INTERNET permission, plain `http://` allowed.
   - **macOS:** network permission.
   - **Web:** hls.js.
3. Default URLs can go in `assets/config.json`, like the Roku version's `config.json`. URLs set in Setup override it until you change the file.

### Building

```powershell
flutter build windows              # build\windows\x64\runner\Release
flutter build apk --release        # Android / Fire TV / Android TV
flutter build macos
flutter build linux                # needs: sudo apt install libmpv-dev mpv
flutter build web                  # see web notes below
```

**Fire TV:** turn on Developer Options → ADB debugging, then `adb connect <fire-tv-ip>` and `adb install build\app\outputs\flutter-apk\app-release.apk`.

## Platform notes

- **Web** is the weakest target:
  - Browsers only play HLS (through hls.js) and MP4. `.ts` links are rewritten to `.m3u8` automatically.
  - The playlist and guide servers must send CORS headers, or the web build must be served from the same host.
  - There's no guide cache and no Exit option.
- **Linux** needs `libmpv` installed: `sudo apt install libmpv-dev mpv`.
- **Android:** the guide is parsed in a background isolate. Big guides (100 MB or more) still take a while on low-end Fire TV sticks. `epgHours` in `config.json` controls how many hours are kept.

## Layout

```
lib/main.dart                 startup (media_kit, window, wakelock)
lib/app.dart                  app shell: modes, playback, flipping, banner, setup, routing
lib/input/                    InputManager (keys / remotes / gamepads / mouse) + actions
lib/ui/remote_setup_screen    first-run button mapping wizard
lib/ui/guide_view.dart        the guide
lib/ui/overlays.dart          info banner, tuning toast, number entry, loading screen
lib/ui/settings_panel.dart    Setup + URL entry
lib/core/                     M3U + streaming XMLTV parsers, EPG model, loader/cache, settings
lib/player/tv_player.dart     libmpv wrapper (tuning, retries, tune timing)
lib/platform/                 desktop window / exit helpers (stubbed on web)
```
