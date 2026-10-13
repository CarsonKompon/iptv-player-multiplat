import 'dart:convert';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/platform.dart';

/// Persistent settings. Defaults come from assets/config.json; URLs entered in
/// Setup override them until config.json itself changes (then it wins again).
class AppSettings {
  AppSettings._(this._prefs);
  final SharedPreferences _prefs;

  String playlistUrl = '';
  String epgUrl = '';
  int epgHours = 24;
  bool rewriteTs = false;
  int firstChannelNumber = 1;

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final s = AppSettings._(prefs);

    Map<String, dynamic> cfg = {};
    try {
      cfg = jsonDecode(await rootBundle.loadString('assets/config.json')) as Map<String, dynamic>;
    } catch (_) {}
    final jsonPl = (cfg['playlistUrl'] as String?) ?? '';
    final jsonEpg = (cfg['epgUrl'] as String?) ?? '';
    s.epgHours = (cfg['epgHours'] as num?)?.toInt() ?? 24;
    s.rewriteTs = (cfg['rewriteTsToHls'] as bool? ?? false) || prefersHlsRewrite;
    s.firstChannelNumber = (cfg['firstChannelNumber'] as num?)?.toInt() ?? 1;

    if (prefs.getString('jsonPlaylistUrl') == jsonPl && prefs.getString('jsonEpgUrl') == jsonEpg) {
      s.playlistUrl = prefs.getString('playlistUrl') ?? jsonPl;
      s.epgUrl = prefs.getString('epgUrl') ?? jsonEpg;
    } else {
      s.playlistUrl = jsonPl;
      s.epgUrl = jsonEpg;
      await prefs.setString('jsonPlaylistUrl', jsonPl);
      await prefs.setString('jsonEpgUrl', jsonEpg);
      await prefs.remove('playlistUrl');
      await prefs.remove('epgUrl');
    }
    return s;
  }

  Future<void> saveUrls() async {
    await _prefs.setString('playlistUrl', playlistUrl);
    await _prefs.setString('epgUrl', epgUrl);
  }

  String get lastChannelUrl => _prefs.getString('lastChan') ?? '';
  set lastChannelUrl(String v) => _prefs.setString('lastChan', v);

  int get avgTuneMs => _prefs.getInt('avgTuneMs') ?? 4000;
  set avgTuneMs(int v) => _prefs.setInt('avgTuneMs', v);

  /// Learned: this server's channels play as .m3u8 rather than .ts.
  bool get preferHls => _prefs.getBool('preferHls') ?? false;
  set preferHls(bool v) => _prefs.setBool('preferHls', v);

  /// GPU video output (read once at startup, see main.dart). Off by default
  /// on Windows, where media_kit's GPU path draws a diagonal seam through
  /// the picture on some GPUs/drivers.
  static const hwAccelKey = 'hwAccel';
  static bool get hwAccelDefault => kIsWeb || defaultTargetPlatform != TargetPlatform.windows;
  bool get hwAccel => _prefs.getBool(hwAccelKey) ?? hwAccelDefault;
  set hwAccel(bool v) => _prefs.setBool(hwAccelKey, v);

  /// Show subtitles when the stream offers them.
  bool get subtitles => _prefs.getBool('subtitles') ?? false;
  set subtitles(bool v) => _prefs.setBool('subtitles', v);

  /// Volume step 0..[volumeMax]
  static const volumeMax = 30;
  int get volumeLevel => _prefs.getInt('volumeLevel') ?? 22;
  set volumeLevel(int v) => _prefs.setInt('volumeLevel', v);

  /// Guide shows the episode title under the show name.
  bool get showEpisodes => _prefs.getBool('showEpisodes') ?? false;
  set showEpisodes(bool v) => _prefs.setBool('showEpisodes', v);

  /// Animated zoom of the video into / out of the guide's PIP.
  bool get animateGuide => _prefs.getBool('animateGuide') ?? false;
  set animateGuide(bool v) => _prefs.setBool('animateGuide', v);

  /// Channel logos in the guide's channel column.
  bool get showLogos => _prefs.getBool('showLogos') ?? false;
  set showLogos(bool v) => _prefs.setBool('showLogos', v);

  /// input id -> action name
  Map<String, String> get bindings {
    final raw = _prefs.getString('bindings');
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map<String, dynamic>).map((k, v) => MapEntry(k, v as String));
    } catch (_) {
      return {};
    }
  }

  set bindings(Map<String, String> b) => _prefs.setString('bindings', jsonEncode(b));
}
