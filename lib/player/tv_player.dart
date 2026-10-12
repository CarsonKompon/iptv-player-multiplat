import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/models.dart';
import 'hls_subs.dart';

enum TuneStatus { idle, tuning, playing, failed }

/// Wraps a single media_kit (libmpv) player: tuning, first-frame detection,
/// retries and tune-time measurement.
class TvPlayer {
  TvPlayer() {
    player = Player(configuration: const PlayerConfiguration(logLevel: MPVLogLevel.info));
    controller = VideoController(player);
    // mpv log -> `flutter run` console, and the last few lines are kept so the
    // tuning box can show what's going on when a channel won't start.
    _subs.add(player.stream.log.listen((l) {
      final line = '${l.prefix}: ${l.text.trim()}';
      debugPrint('[mpv] $line');
      recentLog.add(line);
      if (recentLog.length > 4) recentLog.removeAt(0);
      // Fatal open errors only show up in the log (not on stream.error),
      // so catch them here instead of waiting for the 25 s timeout.
      final t = l.text;
      if (status.value == TuneStatus.tuning &&
          _fresh &&
          (t.contains('avformat_open_input() failed') ||
              t.contains('Failed to open') ||
              t.contains('Error when loading first segment'))) {
        _retry(line);
      }
    }));
    // (ignore events until the new stream has been open for 300ms: earlier
    // ones can belong to the previous channel)
    _subs.add(player.stream.position.listen((p) {
      if (status.value == TuneStatus.tuning && _fresh && p > Duration.zero) _markPlaying();
      if (status.value == TuneStatus.playing) _updateSubtitle(p);
    }));
    _configure();
    _subs.add(player.stream.width.listen((w) {
      if (status.value == TuneStatus.tuning && _fresh && (w ?? 0) > 0) _markPlaying();
    }));
    _subs.add(player.stream.height.listen((_) => _reportInfo()));
    _subs.add(player.stream.tracks.listen((_) => _reportInfo()));
    _subs.add(player.stream.error.listen((e) {
      if (_fresh) _onError(e);
    }));
    _subs.add(player.stream.completed.listen((done) {
      if (done && _channel != null && status.value == TuneStatus.playing) _retry('Signal lost');
    }));
  }

  late final Player player;
  late final VideoController controller;

  final status = ValueNotifier<TuneStatus>(TuneStatus.idle);
  final message = ValueNotifier<String>('');
  final Stopwatch tuneWatch = Stopwatch();

  /// Called with the time it took to start playing (ms).
  void Function(int ms)? onTuned;

  /// Called once the playing stream's resolution / subtitle availability is
  /// known, so the guide can show HD / CC badges for that channel.
  void Function(Channel ch, int height, bool hasSubs)? onStreamInfo;
  String _lastInfo = '';

  void _reportInfo() {
    final ch = _channel;
    if (ch == null || status.value != TuneStatus.playing || !_fresh) return;
    final h = player.state.height ?? 0;
    if (h <= 0) return;
    final hasSubs =
        _subUrl != null || player.state.tracks.subtitle.any((t) => t.id != 'auto' && t.id != 'no');
    final sig = '${ch.url}|$h|$hasSubs';
    if (sig == _lastInfo) return;
    _lastInfo = sig;
    onStreamInfo?.call(ch, h, hasSubs);
  }

  /// Last few mpv log lines (shown on screen when tuning stalls).
  final List<String> recentLog = [];

  /// Some servers (e.g. ErsatzTV) offer each channel as both `.ts` and
  /// `.m3u8`, and one of them may not work from this device. When a tune
  /// fails, the other variant is tried; whichever works is remembered here.
  bool preferHls = false;
  void Function(bool preferHls)? onPreferHlsChanged;

  Channel? _channel;
  String _url = '';
  bool _triedSwap = false;
  int _retries = 0;
  Timer? _retryTimer;
  Timer? _pollTimer;
  final _subs = <StreamSubscription<dynamic>>[];

  Channel? get channel => _channel;

  static (String, String) _split(String url) {
    final q = url.indexOf('?');
    return q >= 0 ? (url.substring(0, q), url.substring(q)) : (url, '');
  }

  static bool _isTs(String url) => _split(url).$1.toLowerCase().endsWith('.ts');
  static bool _isM3u8(String url) => _split(url).$1.toLowerCase().endsWith('.m3u8');

  /// .ts <-> .m3u8 (unchanged for other URLs)
  static String _swap(String url) {
    final (base, query) = _split(url);
    if (_isTs(url)) return '${base.substring(0, base.length - 3)}.m3u8$query';
    if (_isM3u8(url)) return '${base.substring(0, base.length - 5)}.ts$query';
    return url;
  }

  int _gen = 0;
  bool _resolving = false;
  final Stopwatch _openWatch = Stopwatch();

  /// The open-ended timing guard for "is the NEW stream playing" events.
  bool get _fresh => !_resolving && _openWatch.elapsedMilliseconds > 300;

  /// HLS master playlists that declare separate subtitle renditions
  /// (#EXT-X-MEDIA:TYPE=SUBTITLES, e.g. ErsatzTV Next) make libmpv/ffmpeg wait
  /// on the live WebVTT playlist and never start. Like most TV players, we
  /// skip subtitles: fetch the master, pick the best video variant and play
  /// that directly. Anything else is returned unchanged.
  Future<String> _resolveStreamUrl(String url, Map<String, String> headers) async {
    if (!_isM3u8(url)) return url;
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(url))..headers.addAll(headers);
      final resp = await client.send(req).timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return url;
      final bytes = <int>[];
      await for (final chunk in resp.stream) {
        bytes.addAll(chunk);
        if (bytes.length > 65536) break;
      }
      final body = String.fromCharCodes(bytes);
      if (!body.contains('#EXT-X-STREAM-INF') || !body.contains('TYPE=SUBTITLES')) return url;

      final lines = body.split(RegExp(r'\r?\n')).map((l) => l.trim()).toList();
      String? best;
      var bestBw = -1;
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].startsWith('#EXT-X-STREAM-INF')) continue;
        final bw = int.tryParse(RegExp(r'BANDWIDTH=(\d+)').firstMatch(lines[i])?.group(1) ?? '') ?? 0;
        for (var j = i + 1; j < lines.length; j++) {
          final l = lines[j];
          if (l.isEmpty || l.startsWith('#')) continue;
          if (bw > bestBw) {
            bestBw = bw;
            best = l;
          }
          break;
        }
      }
      if (best == null) return url;
      final resolved = Uri.parse(url).resolve(best).toString();
      debugPrint('[player] master playlist has separate subtitles - playing video variant $resolved');

      // remember the subtitle rendition (DEFAULT=YES preferred) for HlsSubtitles
      String? sub;
      for (final l in lines) {
        if (!l.startsWith('#EXT-X-MEDIA') || !l.contains('TYPE=SUBTITLES')) continue;
        final u = RegExp(r'URI="([^"]+)"').firstMatch(l)?.group(1);
        if (u == null) continue;
        if (sub == null || l.contains('DEFAULT=YES')) sub = Uri.parse(url).resolve(u).toString();
      }
      _subUrl = sub;
      return resolved;
    } catch (e) {
      debugPrint('[player] could not pre-read $url: $e');
      return url;
    } finally {
      client.close();
    }
  }

  // ------------------------------------------------------------------ subtitles

  /// Current caption text (empty when none / disabled).
  final subtitle = ValueNotifier<String>('');
  bool _subsEnabled = false;
  String? _subUrl;
  HlsSubtitles? _captions;
  Map<String, String> _headers = const {};

  bool get subtitlesEnabled => _subsEnabled;
  set subtitlesEnabled(bool v) {
    _subsEnabled = v;
    _restartSubs();
  }

  void _restartSubs() {
    _captions?.dispose();
    _captions = null;
    subtitle.value = '';
    final u = _subUrl;
    if (_subsEnabled && u != null) {
      debugPrint('[subs] following $u');
      _captions = HlsSubtitles(u, _headers)..start();
    } else if (_subsEnabled) {
      debugPrint('[subs] this channel has no separate subtitle track');
    }
  }

  void _updateSubtitle(Duration pos) {
    final s = _captions;
    if (s == null) return;
    final text = s.textAt(pos.inMicroseconds / 1e6);
    if (text != subtitle.value) subtitle.value = text;
  }

  /// Player position on the stream's own clock (see HlsSubtitles).
  Future<void> _configure() async {
    try {
      final p = player.platform;
      if (p is NativePlayer) {
        await p.setProperty('rebase-start-time', 'no');
        debugPrint('[player] rebase-start-time=no');
      }
    } catch (e) {
      debugPrint('[player] could not set rebase-start-time: $e');
    }
  }

  Future<void> tune(Channel ch) async {
    _retryTimer?.cancel();
    _channel = ch;
    _retries = 0;
    _triedSwap = false;
    _url = (preferHls && _isTs(ch.url)) ? _swap(ch.url) : ch.url;
    await _open();
  }

  Future<void> retune() async {
    if (_channel == null) return;
    _retries = 0;
    await _open();
  }

  Future<void> _open() async {
    final ch = _channel;
    if (ch == null) return;
    message.value = '';
    status.value = TuneStatus.tuning;
    tuneWatch
      ..reset()
      ..start();
    final headers = <String, String>{};
    if (ch.ua.isNotEmpty) headers['User-Agent'] = ch.ua;
    if (ch.ref.isNotEmpty) headers['Referer'] = ch.ref;
    if (_url.isEmpty) _url = ch.url;
    recentLog.clear();
    _pollTimer?.cancel();

    // Resolve HLS master playlists that would stall the player (see
    // _resolveStreamUrl). The previous channel keeps playing meanwhile, so
    // its events are ignored until the new one is opened.
    final gen = ++_gen;
    _resolving = true;
    _subUrl = null;
    final playUrl = await _resolveStreamUrl(_url, headers);
    if (gen != _gen || !identical(_channel, ch)) return; // flipped away meanwhile
    _resolving = false;
    _headers = headers;
    _restartSubs();

    debugPrint('[player] open ${ch.label}: $playUrl');
    _openWatch
      ..reset()
      ..start();
    // Poll as well as listening to events, in case an event is missed;
    // give up (and retry) if nothing plays within 25 s.
    _pollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (status.value != TuneStatus.tuning) {
        _pollTimer?.cancel();
        return;
      }
      final st = player.state;
      if (_openWatch.elapsedMilliseconds > 300 && (st.position > Duration.zero || (st.width ?? 0) > 0)) {
        _markPlaying();
      } else if (tuneWatch.elapsedMilliseconds > 25000) {
        _retry(recentLog.isNotEmpty ? recentLog.last : 'No picture after 25 seconds');
      }
    });
    try {
      await player.open(Media(playUrl, httpHeaders: headers.isEmpty ? null : headers), play: true);
    } catch (e) {
      _retry('$e');
    }
  }

  void _markPlaying() {
    if (status.value != TuneStatus.tuning) return;
    _pollTimer?.cancel();
    status.value = TuneStatus.playing;
    tuneWatch.stop();
    debugPrint('[player] playing after ${tuneWatch.elapsedMilliseconds} ms');
    _retries = 0;
    _reportInfo();
    // remember which variant works for this server
    final ch = _channel;
    if (ch != null && (_isTs(ch.url) || _isM3u8(ch.url))) {
      final hls = _isM3u8(_url);
      if (_isTs(ch.url) && hls != preferHls) {
        preferHls = hls;
        onPreferHlsChanged?.call(hls);
      } else if (_isM3u8(ch.url) && preferHls && !hls) {
        preferHls = false;
        onPreferHlsChanged?.call(false);
      }
    }
    onTuned?.call(tuneWatch.elapsedMilliseconds);
  }

  void _onError(String e) {
    debugPrint('[player] $e');
    if (status.value != TuneStatus.tuning) return;
    _retry(e);
  }

  void _retry(String reason) {
    _retryTimer?.cancel();
    _pollTimer?.cancel();
    debugPrint('[player] tune failed: $reason');
    final alt = _swap(_url);
    if (!_triedSwap && alt != _url) {
      _triedSwap = true;
      _url = alt;
      debugPrint('[player] trying the other stream format: $alt');
      status.value = TuneStatus.failed;
      message.value = 'Trying alternate stream format...';
      _retryTimer = Timer(const Duration(milliseconds: 400), _open);
      return;
    }
    if (_retries < 2) {
      _retries++;
      status.value = TuneStatus.failed;
      message.value = 'Acquiring signal...';
      _retryTimer = Timer(const Duration(seconds: 3), _open);
    } else {
      status.value = TuneStatus.failed;
      message.value = 'Unable to tune this channel\n$reason';
      _dumpServerResponse(_channel?.url ?? _url);
    }
  }

  /// Diagnostics: print what the server actually returns for the stream URL.
  Future<void> _dumpServerResponse(String url) async {
    try {
      final client = http.Client();
      try {
        final resp = await client.send(http.Request('GET', Uri.parse(url))).timeout(const Duration(seconds: 15));
        final bytes = <int>[];
        await for (final chunk in resp.stream) {
          bytes.addAll(chunk);
          if (bytes.length > 800) break;
        }
        final body = String.fromCharCodes(bytes.take(800).map((b) => (b >= 32 && b < 127) || b == 10 ? b : 46));
        debugPrint('[player] server says: HTTP ${resp.statusCode}, content-type: ${resp.headers['content-type']}');
        debugPrint('[player] ---- first bytes of $url ----\n$body\n[player] ----');
      } finally {
        client.close();
      }
    } catch (e) {
      debugPrint('[player] could not fetch $url for diagnostics: $e');
    }
  }

  /// 0..100
  Future<void> setVolume(double v) => player.setVolume(v.clamp(0.0, 100.0).toDouble());

  Future<void> dispose() async {
    _retryTimer?.cancel();
    _pollTimer?.cancel();
    _captions?.dispose();
    for (final s in _subs) {
      await s.cancel();
    }
    await player.dispose();
  }
}
