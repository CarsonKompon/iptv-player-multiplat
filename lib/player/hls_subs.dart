import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class _Cue {
  _Cue(this.start, this.end, this.text);
  final double start; // stream time (seconds, MPEG-TS clock)
  final double end;
  final String text;
}

/// Follows a live HLS WebVTT subtitle playlist (#EXT-X-MEDIA TYPE=SUBTITLES)
/// and keeps the cues, so captions can be drawn by the app.
///
/// Why not let the player do it: libmpv/ffmpeg stalls on live WebVTT
/// renditions (see TvPlayer._resolveStream). Cue times are mapped onto the
/// video's MPEG-TS clock with X-TIMESTAMP-MAP, and the player runs with
/// rebase-start-time=no so its position uses that same clock.
class HlsSubtitles {
  HlsSubtitles(this.playlistUrl, this.headers);

  final String playlistUrl;
  final Map<String, String> headers;

  final List<_Cue> _cues = [];
  final Set<String> _seen = {};
  final _client = http.Client();
  Timer? _timer;
  bool _busy = false;
  bool _disposed = false;

  void start() {
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _client.close();
  }

  /// Correction added to the player position. 0 when the player and the
  /// subtitle timestamps share a clock (the normal case); otherwise
  /// estimated once from the live edge (players start ~3 segments behind it).
  double? _align;
  double _targetDur = 6;
  double _minStart = double.infinity;
  double _maxEnd = double.negativeInfinity;
  DateTime _lastLog = DateTime.fromMillisecondsSinceEpoch(0);

  /// Caption text at player position [t] (seconds), or ''.
  String textAt(double t) {
    if (_cues.isEmpty) return '';
    // (generous margins: quiet scenes can go minutes without a cue)
    bool near(double x) => x >= _minStart - 600 && x <= _maxEnd + 600;
    final inRange = near(t);
    if (_align == null || !near(t + _align!)) {
      _align = inRange ? 0 : (_maxEnd - 3 * _targetDur) - t;
      debugPrint('[subs] player at ${t.toStringAsFixed(1)}s, cues ${_minStart.toStringAsFixed(1)}'
          '..${_maxEnd.toStringAsFixed(1)}s -> offset ${_align!.toStringAsFixed(1)}s');
    }
    final tt = t + _align!;
    final now = DateTime.now();
    if (now.difference(_lastLog).inSeconds >= 15) {
      _lastLog = now;
      debugPrint('[subs] ${_cues.length} cues ${_minStart.toStringAsFixed(1)}..${_maxEnd.toStringAsFixed(1)}s, '
          'showing at ${tt.toStringAsFixed(1)}s');
    }
    final out = <String>[];
    for (final c in _cues) {
      if (c.start <= tt && tt < c.end && !out.contains(c.text)) out.add(c.text);
    }
    return out.join('\n');
  }

  Future<String?> _get(Uri u) async {
    final r = await _client.get(u, headers: headers).timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) return null;
    return utf8.decode(r.bodyBytes, allowMalformed: true);
  }

  Future<void> _poll() async {
    if (_busy || _disposed) return;
    _busy = true;
    try {
      final base = Uri.parse(playlistUrl);
      final pl = await _get(base);
      if (pl == null || _disposed) return;
      final td = RegExp(r'#EXT-X-TARGETDURATION:(\d+(?:\.\d+)?)').firstMatch(pl);
      if (td != null) _targetDur = double.parse(td.group(1)!);
      final segs = <Uri>[
        for (final raw in const LineSplitter().convert(pl))
          if (raw.trim().isNotEmpty && !raw.trim().startsWith('#')) base.resolve(raw.trim())
      ];
      for (final s in segs) {
        final key = s.toString();
        if (_seen.contains(key)) continue;
        _seen.add(key);
        final vtt = await _get(s);
        if (vtt == null || _disposed) continue;
        _parseVtt(vtt);
      }
      // keep the last few minutes only
      if (_cues.length > 400) _cues.removeRange(0, _cues.length - 400);
      if (_cues.isNotEmpty) {
        _minStart = _cues.map((c) => c.start).reduce((a, b) => a < b ? a : b);
        _maxEnd = _cues.map((c) => c.end).reduce((a, b) => a > b ? a : b);
      }
      if (segs.isNotEmpty && _cues.isEmpty) {
        debugPrint('[subs] ${segs.length} subtitle segments, no cues yet');
      }
      if (_seen.length > 600) {
        final keep = _seen.skip(_seen.length - 300).toList();
        _seen
          ..clear()
          ..addAll(keep);
      }
    } catch (e) {
      debugPrint('[subs] $e');
    } finally {
      _busy = false;
    }
  }

  static final _timeRe = RegExp(r'((?:\d+:)?\d{1,2}:\d{2}[.,]\d{3})\s*-->\s*((?:\d+:)?\d{1,2}:\d{2}[.,]\d{3})');
  static final _mapRe = RegExp(r'MPEGTS:(\d+)');
  static final _localRe = RegExp(r'LOCAL:((?:\d+:)?\d{1,2}:\d{2}[.,]\d{3})');
  static final _tagRe = RegExp(r'<[^>]*>');

  static double _secs(String ts) {
    final parts = ts.replaceAll(',', '.').split(':');
    var s = 0.0;
    for (final p in parts) {
      s = s * 60 + double.parse(p);
    }
    return s;
  }

  void _parseVtt(String vtt) {
    var offset = 0.0;
    final mapLine = vtt.split('\n').firstWhere((l) => l.contains('X-TIMESTAMP-MAP'), orElse: () => '');
    if (mapLine.isNotEmpty) {
      final mpegts = _mapRe.firstMatch(mapLine);
      final local = _localRe.firstMatch(mapLine);
      if (mpegts != null) {
        offset = int.parse(mpegts.group(1)!) / 90000.0 - (local != null ? _secs(local.group(1)!) : 0);
      }
    }
    final lines = const LineSplitter().convert(vtt);
    for (var i = 0; i < lines.length; i++) {
      final m = _timeRe.firstMatch(lines[i]);
      if (m == null) continue;
      final text = <String>[];
      var j = i + 1;
      while (j < lines.length && lines[j].trim().isNotEmpty) {
        text.add(lines[j].replaceAll(_tagRe, '').trim());
        j++;
      }
      i = j;
      if (text.isEmpty) continue;
      _cues.add(_Cue(_secs(m.group(1)!) + offset, _secs(m.group(2)!) + offset, text.join('\n')));
    }
  }
}
