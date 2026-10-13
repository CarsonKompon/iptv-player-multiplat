import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart' show Video, NoVideoControls;

import 'core/epg.dart';
import 'core/loader.dart';
import 'core/models.dart';
import 'core/settings.dart';
import 'input/actions.dart';
import 'input/input_manager.dart';
import 'platform/platform.dart';
import 'player/tv_player.dart';
import 'ui/guide_view.dart';
import 'ui/overlays.dart';
import 'ui/remote_setup_screen.dart';
import 'ui/settings_panel.dart';
import 'ui/theme.dart';

class IptvApp extends StatelessWidget {
  const IptvApp({super.key, this.hwAccel = true});
  final bool hwAccel;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'IPTV Guide',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: false),
        home: AppShell(hwAccel: hwAccel),
      );
}

enum _Mode { starting, remoteSetup, loading, play, guide }

class AppShell extends StatefulWidget {
  const AppShell({super.key, this.hwAccel = true});
  final bool hwAccel;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final _rootFocus = FocusNode(debugLabel: 'root');
  final _guideKey = GlobalKey<GuideViewState>();
  final _textKey = GlobalKey<TextEntryDialogState>();
  final _textKeyEpg = GlobalKey<TextEntryDialogState>();
  late final TvPlayer _tv;
  AppSettings? _settings;

  _Mode _mode = _Mode.starting;
  _Mode _modeBeforeRemap = _Mode.loading;

  List<Channel> _channels = [];
  EpgData _epg = EpgData.empty;
  String _epgStatus = '';
  String _playlistEpgUrl = '';
  String _loadingStatus = 'Starting...';
  String _loadingDetail = '';
  bool _loadingPlaylist = false;

  int _curIdx = -1;
  int _prevIdx = -1;
  int _pendingIdx = -1;
  bool _banner = false;
  String _digits = '';
  String _digitError = '';

  bool _settingsOpen = false;
  int _settingsSel = 0;
  String _settingsMsg = '';
  String? _textEditing; // 'pl' | 'epg'

  Timer? _bannerTimer;
  Timer? _flipTimer;
  Timer? _epgTimer;
  Timer? _progressTimer;
  Timer? _digitTimer;
  Timer? _lingerTimer;
  StreamSubscription<ActionEvent>? _actionSub;

  /// Guide kept on screen (non-interactive) while the video zooms back out.
  bool _guideLinger = false;

  Duration get _anim =>
      (_settings?.animateGuide ?? false) ? const Duration(milliseconds: 260) : const Duration(milliseconds: 1);

  @override
  void initState() {
    super.initState();
    _tv = TvPlayer(hwAccel: widget.hwAccel);
    _tv.onTuned = _recordTune;
    _tv.status.addListener(_onTvStatus);
    _tv.message.addListener(_onTvStatus);
    _tv.subtitle.addListener(_onTvStatus);
    _actionSub = InputManager.instance.actions.listen(_onAction);
    // Window close / app exit: stop the stream cleanly first, so the server
    // can end its session (State.dispose doesn't run when a desktop window
    // is closed).
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await _shutdown();
        return AppExitResponse.exit;
      },
      onDetach: () => _shutdown(),
    );
    InputManager.instance.start();
    _progressTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted && _tv.status.value == TuneStatus.tuning) setState(() {});
    });
    _init();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _actionSub?.cancel();
    for (final t in [_bannerTimer, _flipTimer, _epgTimer, _progressTimer, _digitTimer, _lingerTimer, _volumeTimer]) {
      t?.cancel();
    }
    _tv.dispose();
    _rootFocus.dispose();
    super.dispose();
  }

  late final AppLifecycleListener _lifecycle;
  bool _shutDown = false;

  Future<void> _shutdown() async {
    if (_shutDown) return;
    _shutDown = true;
    for (final t in [_epgTimer, _flipTimer]) {
      t?.cancel();
    }
    try {
      await _tv.shutdown().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  /// Exit from the Setup menu.
  Future<void> _exit() async {
    await _shutdown();
    exitApp();
  }

  void _onTvStatus() {
    if (mounted) setState(() {});
  }

  // ------------------------------------------------------------------ startup

  Future<void> _init() async {
    final s = await AppSettings.load();
    _settings = s;
    _tv.preferHls = s.preferHls;
    _tv.subtitlesEnabled = s.subtitles;
    _tv.onStreamInfo = (ch, h, cc) => debugPrint('[player] ${ch.label}: ${h}p, subtitles: $cc');
    _tv.setVolume(s.volumeLevel * 100 / AppSettings.volumeMax);
    _tv.onPreferHlsChanged = (v) {
      debugPrint('[player] remembering preferred format: ${v ? 'm3u8' : 'ts'}');
      s.preferHls = v;
    };
    InputManager.instance.setBindings(s.bindings);
    // (a skipped wizard stores {"_skipped": "none"}, so it isn't shown again)
    if (s.bindings.isEmpty) {
      setState(() {
        _modeBeforeRemap = _Mode.starting;
        _mode = _Mode.remoteSetup;
      });
    } else {
      _start();
    }
  }

  void _start() {
    final s = _settings!;
    if (s.playlistUrl.isEmpty) {
      _beginUrlSetup();
    } else {
      _loadPlaylist();
    }
  }

  // First-run wizard steps 2 and 3 (after the remote): playlist URL, then the
  // optional guide URL. Pre-filled from config.json when it has them.
  int _urlStep = 0; // 0 = not in the wizard, 1 = playlist, 2 = guide

  void _beginUrlSetup() {
    setState(() {
      _mode = _Mode.loading;
      _loadingStatus = 'Welcome!';
      _loadingDetail = 'Let\'s add your channels';
      _settingsOpen = false;
      _urlStep = 1;
    });
    _openText('pl');
  }

  Future<void> _loadPlaylist() async {
    final s = _settings!;
    await _tv.player.stop();
    setState(() {
      _mode = _Mode.loading;
      _loadingStatus = 'Loading channels...';
      _loadingDetail = s.playlistUrl == demoPlaylistUrl ? 'Demo channels' : s.playlistUrl;
      _loadingPlaylist = true;
      _channels = [];
      _epg = EpgData.empty;
      _curIdx = -1;
      _prevIdx = -1;
    });
    try {
      final res = await loadPlaylist(s.playlistUrl, rewriteTs: s.rewriteTs, firstNumber: s.firstChannelNumber);
      if (!mounted) return;
      _channels = res.channels;
      _playlistEpgUrl = res.epgUrl;
      debugPrint('[playlist] ${_channels.length} channels, e.g. ${_channels.first.url}');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingPlaylist = false;
        _loadingStatus = "Couldn't load channels";
      });
      _openSettings('$e');
      return;
    }
    var idx = _channels.indexWhere((c) => c.url == s.lastChannelUrl);
    if (idx < 0) idx = 0;
    setState(() {
      _loadingPlaylist = false;
      _mode = _Mode.play;
      _settingsOpen = false;
    });
    _tune(idx);
    _loadEpg(false);
    _epgTimer?.cancel();
    _epgTimer = Timer.periodic(const Duration(hours: 3), (_) => _loadEpg(true));
  }

  String get _effectiveEpgUrl {
    final s = _settings!;
    return s.epgUrl.isNotEmpty ? s.epgUrl : _playlistEpgUrl;
  }

  Future<void> _loadEpg(bool force) async {
    final url = _effectiveEpgUrl;
    if (url.isEmpty) {
      setState(() => _epgStatus = 'No guide data URL set - open Setup to add one');
      return;
    }
    final chans = _channels;
    setState(() => _epgStatus = 'Loading guide data...');
    try {
      final data = await loadEpg(url, chans, hours: _settings!.epgHours, force: force);
      if (!mounted) return;
      if (!identical(chans, _channels)) {
        debugPrint('[epg] result discarded: channel list was reloaded meanwhile');
        return;
      }
      setState(() {
        _epg = data;
        _epgStatus = data.channelCount == 0 ? 'Guide loaded, but no channels matched (check tvg-id)' : '';
      });
    } catch (e) {
      debugPrint('[epg] failed: $e');
      if (!mounted) return;
      setState(() => _epgStatus = 'Guide: $e');
    }
  }

  // ------------------------------------------------------------------ playback

  void _tune(int idx) {
    if (idx < 0 || idx >= _channels.length) return;
    _flipTimer?.cancel();
    _pendingIdx = -1;
    if (idx != _curIdx) _prevIdx = _curIdx;
    _curIdx = idx;
    final ch = _channels[idx];
    _tv.tune(ch);
    _settings!.lastChannelUrl = ch.url;
    if (_mode == _Mode.play) _showBanner();
    setState(() {});
  }

  void _flip(int d) {
    final n = _channels.length;
    if (n == 0) return;
    var base = _pendingIdx >= 0 ? _pendingIdx : _curIdx;
    if (base < 0) base = 0;
    _pendingIdx = (base + d + n) % n;
    _showBanner();
    _flipTimer?.cancel();
    _flipTimer = Timer(const Duration(milliseconds: 600), () {
      if (_pendingIdx >= 0) _tune(_pendingIdx);
    });
  }

  void _recordTune(int ms) {
    if (ms < 200 || ms > 60000) return;
    final s = _settings!;
    s.avgTuneMs = (s.avgTuneMs * 0.7 + ms * 0.3).round();
  }

  // ------------------------------------------------------------------ volume

  bool _volumeShown = false;
  Timer? _volumeTimer;

  void _changeVolume(int d) {
    final s = _settings!;
    final level = (s.volumeLevel + d).clamp(0, AppSettings.volumeMax);
    s.volumeLevel = level;
    _tv.setVolume(level * 100 / AppSettings.volumeMax);
    _bannerTimer?.cancel();
    _volumeTimer?.cancel();
    _volumeTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted) setState(() => _volumeShown = false);
    });
    setState(() {
      _banner = false;
      _volumeShown = true;
    });
  }

  void _showBanner() {
    _volumeTimer?.cancel();
    _volumeShown = false;
    _bannerTimer?.cancel();
    _bannerTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _banner = false);
    });
    setState(() => _banner = true);
  }

  void _hideBanner() {
    _bannerTimer?.cancel();
    setState(() => _banner = false);
  }

  // ------------------------------------------------------------------ numbers

  void _digit(int d) {
    _digitTimer?.cancel();
    setState(() {
      _digitError = '';
      _digits = (_digits + '$d');
      if (_digits.length > 4) _digits = _digits.substring(_digits.length - 4);
    });
    _digitTimer = Timer(const Duration(milliseconds: 2000), _commitDigits);
  }

  void _commitDigits() {
    _digitTimer?.cancel();
    final typed = _digits;
    if (typed.isEmpty) return;
    final n = int.tryParse(typed);
    var idx = _channels.indexWhere((c) => c.num == typed);
    if (idx < 0 && n != null) idx = _channels.indexWhere((c) => c.numInt == n);
    if (idx < 0) {
      setState(() {
        _digits = '';
        _digitError = 'No channel $typed';
      });
      _digitTimer = Timer(const Duration(milliseconds: 1500), () {
        if (mounted) setState(() => _digitError = '');
      });
      return;
    }
    setState(() => _digits = '');
    if (_mode == _Mode.guide) {
      _guideKey.currentState?.openAt(idx);
    } else {
      _tune(idx);
    }
  }

  // ------------------------------------------------------------------ guide

  void _openGuide() {
    if (_channels.isEmpty) return;
    if (_pendingIdx >= 0) _tune(_pendingIdx);
    _bannerTimer?.cancel();
    final wasLingering = _guideLinger;
    _lingerTimer?.cancel();
    setState(() {
      _guideLinger = false;
      _banner = false;
      _mode = _Mode.guide;
    });
    // a still-mounted guide (mid close animation) won't re-run initState
    if (wasLingering) _guideKey.currentState?.openAt(_curIdx);
  }

  /// Leaves the guide; with transitions on, the guide stays visible behind
  /// the video while it zooms back to full screen.
  void _leaveGuide() {
    final animate = _settings?.animateGuide ?? false;
    _lingerTimer?.cancel();
    setState(() {
      _mode = _Mode.play;
      _guideLinger = animate;
    });
    if (animate) {
      _lingerTimer = Timer(_anim, () {
        if (mounted) setState(() => _guideLinger = false);
      });
    }
  }

  void _closeGuide() => _leaveGuide();

  void _guideTune(int idx) {
    _leaveGuide();
    if (idx == _curIdx) {
      _showBanner();
    } else {
      _tune(idx);
    }
  }

  // ------------------------------------------------------------------ settings

  List<(String, VoidCallback)> get _settingsItems => [
        ('Set playlist URL (M3U / M3U8)', () => _openText('pl')),
        ('Set guide URL (XMLTV .xml / .xml.gz)', () => _openText('epg')),
        ('Save and reload channels', _saveReload),
        (
          'Refresh guide data now',
          () {
            _closeSettings();
            if (_channels.isNotEmpty) _loadEpg(true);
          }
        ),
        if (!kReleaseMode) ('Load demo channels', _loadDemo),
        (
          'Subtitles (when the channel has them):  ${_settings!.subtitles ? 'ON' : 'OFF'}',
          () => setState(() {
                _settings!.subtitles = !_settings!.subtitles;
                _tv.subtitlesEnabled = _settings!.subtitles;
              })
        ),
        (
          'Show episode names in guide:  ${_settings!.showEpisodes ? 'ON' : 'OFF'}',
          () => setState(() {
                _settings!.showEpisodes = !_settings!.showEpisodes;
              })
        ),
        (
          'Show channel logos in guide:  ${_settings!.showLogos ? 'ON' : 'OFF'}',
          () => setState(() {
                _settings!.showLogos = !_settings!.showLogos;
              })
        ),
        (
          'Hardware video acceleration:  ${_settings!.hwAccel ? 'ON' : 'OFF'}'
              '${_settings!.hwAccel != widget.hwAccel ? '  (restart to apply)' : ''}',
          () => setState(() {
                _settings!.hwAccel = !_settings!.hwAccel;
              })
        ),
        (
          'Animated guide transitions:  ${_settings!.animateGuide ? 'ON' : 'OFF'}',
          () => setState(() {
                _settings!.animateGuide = !_settings!.animateGuide;
              })
        ),
        ('Set up remote / controller', _remap),
        if (isDesktop) ('Toggle fullscreen', () => toggleFullscreen()),
        if (canExit) ('Exit app', _exit),
      ];

  void _openSettings(String msg) {
    _hideBannerSilently();
    setState(() {
      _settingsOpen = true;
      _settingsSel = 0;
      _settingsMsg = msg;
    });
  }

  void _hideBannerSilently() {
    _bannerTimer?.cancel();
    _banner = false;
  }

  void _closeSettings() {
    if (_channels.isEmpty && !_loadingPlaylist) {
      if (_settings!.playlistUrl.isNotEmpty) {
        setState(() => _settingsOpen = false);
        _loadPlaylist();
      } else {
        setState(() => _settingsMsg = 'Set a playlist URL (or load the demo channels) to continue.');
      }
      return;
    }
    setState(() => _settingsOpen = false);
  }

  void _saveReload() {
    final s = _settings!;
    if (s.playlistUrl.isEmpty) {
      setState(() => _settingsMsg = 'Set a playlist URL first.');
      return;
    }
    s.saveUrls();
    setState(() => _settingsOpen = false);
    _loadPlaylist();
  }

  void _loadDemo() {
    final s = _settings!;
    s.playlistUrl = demoPlaylistUrl;
    s.epgUrl = demoEpgUrl;
    s.saveUrls();
    setState(() => _settingsOpen = false);
    _loadPlaylist();
  }

  void _remap() {
    setState(() {
      _settingsOpen = false;
      _modeBeforeRemap = _mode;
      _mode = _Mode.remoteSetup;
    });
  }

  void _onRemoteDone(Map<String, String> bindings) {
    _settings!.bindings = bindings;
    InputManager.instance.setBindings(bindings);
    final back = _modeBeforeRemap;
    if (back == _Mode.starting) {
      _beginUrlSetup(); // first run: continue with the URL steps
    } else if (_channels.isEmpty) {
      setState(() => _mode = _Mode.loading);
      _start();
    } else {
      setState(() => _mode = back == _Mode.remoteSetup ? _Mode.play : back);
    }
  }

  void _openText(String which) {
    InputManager.instance.textEntry = true;
    setState(() => _textEditing = which);
  }

  void _closeText() {
    InputManager.instance.textEntry = false;
    setState(() => _textEditing = null);
    _rootFocus.requestFocus();
  }

  void _submitText(String v) {
    final s = _settings!;
    if (_urlStep == 1 && v.isEmpty) return; // a playlist is required
    if (_textEditing == 'pl') s.playlistUrl = v;
    if (_textEditing == 'epg') s.epgUrl = v;
    s.saveUrls();
    if (_urlStep == 1) {
      setState(() {
        _urlStep = 2;
        _textEditing = 'epg';
      });
      return;
    }
    if (_urlStep == 2) {
      _urlStep = 0;
      _closeText();
      _loadPlaylist();
      return;
    }
    _closeText();
  }

  /// Back / Cancel in the URL dialog.
  void _cancelText() {
    if (_urlStep == 2) {
      // guide is optional: skip it
      _urlStep = 0;
      _closeText();
      _loadPlaylist();
      return;
    }
    if (_urlStep == 1) {
      _urlStep = 0;
      _closeText();
      _openSettings('A playlist URL is needed to continue.');
      return;
    }
    _closeText();
  }

  GlobalKey<TextEntryDialogState> get _activeTextKey => _textEditing == 'epg' ? _textKeyEpg : _textKey;

  void _settingsAction(AppAction a) {
    final items = _settingsItems;
    switch (a) {
      case AppAction.up:
        setState(() => _settingsSel = (_settingsSel - 1 + items.length) % items.length);
      case AppAction.down:
        setState(() => _settingsSel = (_settingsSel + 1) % items.length);
      case AppAction.ok:
        items[_settingsSel.clamp(0, items.length - 1)].$2();
      case AppAction.back:
      case AppAction.options:
      case AppAction.guide:
        _closeSettings();
      default:
        break;
    }
  }

  // ------------------------------------------------------------------ input routing

  void _onAction(ActionEvent ev) {
    final a = ev.action;
    if (_mode == _Mode.remoteSetup || _mode == _Mode.starting) return;

    if (_textEditing != null) {
      if (a == AppAction.back) _cancelText();
      if (a == AppAction.ok) _activeTextKey.currentState?.submit();
      return;
    }
    if (_settingsOpen) {
      _settingsAction(a);
      return;
    }
    if (a.isDigit && (_mode == _Mode.play || _mode == _Mode.guide)) {
      _digit(a.digit);
      return;
    }
    if (a == AppAction.ok && _digits.isNotEmpty) {
      _commitDigits();
      return;
    }

    switch (_mode) {
      case _Mode.loading:
        if (a == AppAction.options || a == AppAction.ok) _openSettings('');
      case _Mode.play:
        _playAction(a);
      case _Mode.guide:
        _guideKey.currentState?.handle(a);
      default:
        break;
    }
  }

  void _playAction(AppAction a) {
    switch (a) {
      case AppAction.ok:
        if (_pendingIdx >= 0) {
          _tune(_pendingIdx); // tune now instead of waiting for the flip delay
        } else if (_banner) {
          _hideBanner();
        } else {
          _showBanner();
        }
      case AppAction.up:
        _flip(-1); // matches the guide: up = channel above
      case AppAction.down:
        _flip(1);
      case AppAction.left:
        _changeVolume(-1);
      case AppAction.right:
        _changeVolume(1);
      case AppAction.guide:
      case AppAction.back:
        _openGuide();
      case AppAction.options:
        _openSettings('');
      default:
        break;
    }
  }

  // ------------------------------------------------------------------ build

  Channel? get _bannerChannel {
    final i = _pendingIdx >= 0 ? _pendingIdx : _curIdx;
    return (i >= 0 && i < _channels.length) ? _channels[i] : null;
  }

  Widget? _toast() {
    final st = _tv.status.value;
    if (st != TuneStatus.tuning && st != TuneStatus.failed) return null;
    if (_mode != _Mode.play && _mode != _Mode.guide) return null;
    final ch = _tv.channel;
    if (st == TuneStatus.failed) {
      return TuningToast(title: _tv.message.value, progress: 0, subtitle: '', showBar: false);
    }
    final elapsed = _tv.tuneWatch.elapsedMilliseconds;
    final avg = _settings?.avgTuneMs ?? 4000;
    var f = elapsed / avg;
    if (f > 0.9) f = 0.9 + (f - 0.9) * 0.05;
    if (f > 0.97) f = 0.97;
    final remain = ((avg - elapsed) / 1000).ceil();
    final sub = remain >= 1
        ? 'about $remain sec'
        : 'taking longer than usual... (${elapsed ~/ 1000} sec)';
    return TuningToast(
      detail: remain < 1 ? _tv.recentLog.join('\n') : '',
      title: 'Tuning ${ch?.label ?? ''}',
      progress: f,
      subtitle: sub,
      showBar: true,
    );
  }

  /// Canvas layers drawn under the video (the guide).
  List<Widget> _belowLayers() {
    final layers = <Widget>[];
    if (_mode == _Mode.guide || _guideLinger) {
      layers.add(Positioned.fill(
        child: IgnorePointer(
         ignoring: _mode != _Mode.guide,
         child: GuideView(
          key: _guideKey,
          showEpisodes: _settings?.showEpisodes ?? false,
          showLogos: _settings?.showLogos ?? false,
          channels: _channels,
          epg: _epg,
          playingIndex: _curIdx,
          status: _epgStatus,
          epgHours: _settings?.epgHours ?? 24,
          onTune: _guideTune,
          onClose: _closeGuide,
          onSetup: () => _openSettings(''),
         ),
        ),
      ));
    }
    return layers;
  }

  /// The video, positioned in real screen pixels (snapped to whole pixels)
  /// rather than inside the scaled 1920x1080 canvas: drawing the video
  /// texture through a fractional scale transform leaves a thin diagonal
  /// seam where its two triangles meet. Overlays on the video (PIP label,
  /// tuning box) are scaled back to canvas units inside it, so they still
  /// follow the zoom into / out of the PIP.
  Widget? _videoLayer(double scale, Offset origin, double dpr) {
    if (_tv.channel == null || scale <= 0) return null; // (0 while minimized)
    final watching = _mode == _Mode.play || _mode == _Mode.guide;
    final inGuide = _mode == _Mode.guide;
    final r = inGuide ? kPip : Offset.zero & kCanvas;
    // snap to whole *physical* pixels (display scaling can be 125%, 150%...)
    double snap(double v) => (v * dpr).roundToDouble() / dpr;
    final screen = Rect.fromLTRB(
      snap(origin.dx + r.left * scale),
      snap(origin.dy + r.top * scale),
      snap(origin.dx + r.right * scale),
      snap(origin.dy + r.bottom * scale),
    );
    // (Rendering at the exact on-screen size via VideoController.setSize was
    // tried: it didn't remove the seam with GPU output, and with software
    // output media_kit shows garbage lines after each resize. The seam is
    // avoided by software output instead - see AppSettings.hwAccel.)
    final toast = _toast();
    return AnimatedPositioned.fromRect(
        key: const ValueKey('video'),
        duration: _anim,
        curve: Curves.easeInOut,
        rect: screen,
        child: Offstage(
          offstage: !watching,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (_mode == _Mode.guide) {
                _closeGuide();
              } else if (_banner) {
                _hideBanner();
              } else {
                _showBanner();
              }
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                Video(controller: _tv.controller, controls: NoVideoControls, fill: Colors.black),
                // overlays in canvas units, scaled to the video's on-screen size
                IgnorePointer(
                  child: LayoutBuilder(
                    builder: (context, c) => FittedBox(
                      fit: BoxFit.fill,
                      child: SizedBox(
                        width: c.maxWidth / scale,
                        height: c.maxHeight / scale,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (inGuide || _guideLinger)
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                height: 54,
                                child: Container(
                                  color: const Color(0xCC3A64A0),
                                  padding: const EdgeInsets.symmetric(horizontal: 16),
                                  alignment: Alignment.centerLeft,
                                  child: CanvasText(_tv.channel!.label, size: 36, bold: true),
                                ),
                              ),
                            if (toast != null) toast,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
  }

  /// Canvas layers drawn over the video.
  List<Widget> _aboveLayers() {
    final layers = <Widget>[];
    final bch = _bannerChannel;
    if (_mode == _Mode.play && _banner && bch != null) {
      final (now, next) = _epg.nowNext(bch.key, DateTime.now().millisecondsSinceEpoch ~/ 1000);
      layers.add(InfoBanner(channel: bch, now: now, next: next));
    }

    final caption = _tv.subtitle.value;
    if (_mode == _Mode.play && caption.isNotEmpty && _tv.status.value == TuneStatus.playing) {
      layers.add(SubtitleText(caption, raised: _banner || _volumeShown));
    }

    if (_mode == _Mode.play && _volumeShown && _settings != null) {
      layers.add(VolumeOsd(level: _settings!.volumeLevel, max: AppSettings.volumeMax));
    }

    if (_digits.isNotEmpty || _digitError.isNotEmpty) {
      layers.add(NumberEntry(digits: _digits, error: _digitError));
    }

    if (_mode == _Mode.loading) {
      layers.add(Positioned.fill(child: LoadingScreen(status: _loadingStatus, detail: _loadingDetail)));
    }
    if (_mode == _Mode.starting) {
      layers.add(const Positioned.fill(child: ColoredBox(color: Pal.navyBottom)));
    }

    if (_settingsOpen && _settings != null) {
      final items = _settingsItems;
      layers.add(Positioned.fill(
        child: SettingsPanel(
          items: [for (final i in items) i.$1],
          selected: _settingsSel.clamp(0, items.length - 1),
          message: _settingsMsg,
          playlistUrl: _settings!.playlistUrl == demoPlaylistUrl ? 'Demo channels' : _settings!.playlistUrl,
          epgUrl: _settings!.epgUrl == demoEpgUrl ? 'Demo listings' : _settings!.epgUrl,
          onTap: (i) {
            setState(() => _settingsSel = i);
            items[i].$2();
          },
        ),
      ));
    }

    if (_textEditing != null && _settings != null) {
      final pl = _textEditing == 'pl';
      final cur = pl ? _settings!.playlistUrl : _settings!.epgUrl;
      layers.add(Positioned.fill(
        child: TextEntryDialog(
          key: _activeTextKey,
          title: switch (_urlStep) {
            1 => 'Step 2 of 3  -  Playlist URL (M3U / M3U8)',
            2 => 'Step 3 of 3  -  Guide URL (XMLTV)',
            _ => pl ? 'Playlist URL (M3U / M3U8)' : 'Guide URL (XMLTV)',
          },
          hint: switch (_urlStep) {
            1 => 'The address of your channel list, e.g. http://192.168.1.10:8409/channels.m3u',
            2 => 'Optional. Leave blank to use the guide named in the playlist (url-tvg), if any.',
            _ => '',
          },
          submitLabel: _urlStep == 0 ? 'Save' : (_urlStep == 1 ? 'Next' : 'Finish'),
          cancelLabel: _urlStep == 2 ? 'Skip' : 'Cancel',
          initial: (cur == demoPlaylistUrl || cur == demoEpgUrl) ? '' : cur,
          onSubmit: _submitText,
          onCancel: _cancelText,
        ),
      ));
    }

    if (_mode == _Mode.remoteSetup) {
      layers.add(Positioned.fill(child: RemoteSetupScreen(onDone: _onRemoteDone)));
    }
    return layers;
  }

  /// A 1920x1080 design canvas scaled to fit the window.
  Widget _canvas(List<Widget> children) => Center(
        child: FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            width: kCanvas.width,
            height: kCanvas.height,
            child: ClipRect(child: Stack(children: children)),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) InputManager.instance.systemBack();
      },
      child: Focus(
        focusNode: _rootFocus,
        autofocus: true,
        onKeyEvent: (node, event) =>
            InputManager.instance.handleKey(event) ? KeyEventResult.handled : KeyEventResult.ignored,
        child: Listener(
          onPointerDown: (e) => InputManager.instance.pointerDown(e.buttons),
          onPointerSignal: (e) {
            if (e is PointerScrollEvent) InputManager.instance.scroll(e.scrollDelta.dy);
          },
          // Material gives Text a proper default style (without it Flutter
          // draws its yellow "missing Material" debug underline).
          child: Material(
            color: Colors.black,
            child: LayoutBuilder(builder: (context, c) {
              // same fit as the canvas FittedBoxes: contain, centered
              final scale = (c.maxWidth / kCanvas.width) < (c.maxHeight / kCanvas.height)
                  ? c.maxWidth / kCanvas.width
                  : c.maxHeight / kCanvas.height;
              final origin = Offset(
                (c.maxWidth - kCanvas.width * scale) / 2,
                (c.maxHeight - kCanvas.height * scale) / 2,
              );
              final video = _videoLayer(scale, origin, MediaQuery.of(context).devicePixelRatio);
              return Stack(
                children: [
                  Positioned.fill(child: _canvas(_belowLayers())),
                  if (video != null) video,
                  Positioned.fill(child: _canvas(_aboveLayers())),
                ],
              );
            }),
          ),
        ),
      ),
    );
  }
}
