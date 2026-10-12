import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import 'cache/cache.dart';
import 'epg.dart';
import 'm3u.dart';
import 'models.dart';
import 'time_fmt.dart';
import 'xmltv.dart';

const demoPlaylistUrl = 'asset:sample';
const demoEpgUrl = 'demo';

class LoadException implements Exception {
  LoadException(this.message);
  final String message;
  @override
  String toString() => message;
}

// ------------------------------------------------------------------ playlist

Future<M3uResult> loadPlaylist(String url, {required bool rewriteTs, required int firstNumber}) async {
  String text;
  if (url == demoPlaylistUrl) {
    text = await rootBundle.loadString('assets/sample/playlist.m3u');
  } else {
    final http.Response resp;
    try {
      resp = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw LoadException('Timed out loading playlist');
    } catch (e) {
      throw LoadException('Could not reach playlist server ($e)');
    }
    if (resp.statusCode != 200) throw LoadException('Playlist HTTP ${resp.statusCode}');
    text = utf8.decode(resp.bodyBytes, allowMalformed: true);
  }
  // show one entry, to help diagnose numbering / attribute issues
  final firstInf = text.indexOf('#EXTINF');
  if (firstInf >= 0) {
    final end = text.indexOf('\n', firstInf);
    debugPrint('[playlist] first entry: ${text.substring(firstInf, end < 0 ? text.length : end).trim()}');
  }
  final res = text.length > 200000
      ? await compute(parseM3uEntry, <Object>[text, rewriteTs, firstNumber])
      : parseM3u(text, rewriteTs: rewriteTs, firstNumber: firstNumber);
  if (res.channels.isEmpty) throw LoadException('The playlist contains no channels.');
  return res;
}

// ------------------------------------------------------------------ guide

class EpgRequest {
  EpgRequest({required this.url, required this.channels, required this.minT, required this.maxT});
  final String url;

  /// [key, id, tname, name] per channel
  final List<List<String>> channels;
  final int minT;
  final int maxT;
}

// (v2: programmes carry HD / CC flags - older caches are re-downloaded)
String _signature(String url, List<Channel> chans) =>
    'v2|$url|${chans.length}|${chans.isEmpty ? '' : chans.first.key}|${chans.isEmpty ? '' : chans.last.key}';

/// Loads guide data, using a <4h old on-disk cache unless [force].
Future<EpgData> loadEpg(String url, List<Channel> chans, {required int hours, bool force = false}) async {
  final now = nowSecs();
  final sig = _signature(url, chans);

  if (!force && url != demoEpgUrl) {
    final cached = await readCache('epg_cache.json');
    if (cached != null) {
      try {
        final data = await compute(_decodeCache, <Object>[cached, sig, now]);
        if (data != null) {
          debugPrint('[epg] using cached guide (${data.channelCount} channels)');
          return data;
        }
      } catch (_) {}
    }
  }

  final req = EpgRequest(
    url: url,
    channels: [for (final c in chans) [c.key, c.id, c.tname, c.name]],
    minT: now - 4 * 3600,
    maxT: now + hours * 3600,
  );
  final sw = Stopwatch()..start();
  debugPrint('[epg] loading $url');
  final map = kIsWeb ? await fetchEpg(req) : await compute(fetchEpg, req);
  final data = EpgData(map);
  final progs = map.values.fold<int>(0, (n, l) => n + l.length);
  debugPrint('[epg] ${data.channelCount}/${chans.length} channels matched, $progs programmes, ${sw.elapsedMilliseconds} ms');
  // Cache in the background - don't make the guide wait for it.
  if (url != demoEpgUrl) unawaited(_saveCache(data, sig, now));
  return data;
}

Future<void> _saveCache(EpgData data, String sig, int now) async {
  try {
    final json = await compute(_encodeCache, <Object>[data, sig, now]);
    await writeCache('epg_cache.json', json);
  } catch (e) {
    debugPrint('[epg] cache write failed: $e');
  }
}

EpgData? _decodeCache(List<Object> a) {
  final j = jsonDecode(a[0] as String) as Map<String, dynamic>;
  if (j['sig'] != a[1]) return null;
  final t = (j['time'] as num).toInt();
  if ((a[2] as int) - t > 4 * 3600) return null;
  return EpgData.fromJson(j['epg'] as Map<String, dynamic>);
}

String _encodeCache(List<Object> a) =>
    jsonEncode({'sig': a[1], 'time': a[2], 'epg': (a[0] as EpgData).toJson()});

/// Downloads + parses XMLTV. Runs in a background isolate (except on web).
Future<Map<String, List<Program>>> fetchEpg(EpgRequest r) async {
  if (r.url == demoEpgUrl) return demoEpg(r.channels, nowSecs(), r.maxT);

  final idMap = <String, String>{};
  final nameMap = <String, String>{};
  void put(Map<String, String> m, String k, String v) {
    if (k.isNotEmpty) m.putIfAbsent(k.toLowerCase(), () => v);
  }

  for (final c in r.channels) {
    put(idMap, c[1], c[0]);
  }
  for (final c in r.channels) {
    put(idMap, c[2], c[0]);
    put(idMap, c[3], c[0]);
    put(nameMap, c[3], c[0]);
    put(nameMap, c[2], c[0]);
  }
  final xml = XmltvParser(idMap: idMap, nameMap: nameMap, minT: r.minT, maxT: r.maxT);
  final parser = _ParserSink(xml);

  final client = http.Client();
  try {
    final http.StreamedResponse resp;
    try {
      resp = await client.send(http.Request('GET', Uri.parse(r.url))).timeout(const Duration(seconds: 60));
    } on TimeoutException {
      throw LoadException('Guide download timed out');
    } catch (e) {
      throw LoadException('Could not reach guide server ($e)');
    }
    if (resp.statusCode != 200) throw LoadException('Guide HTTP ${resp.statusCode}');

    Sink<List<int>>? sink;
    List<Uint8List>? gzChunks;
    await for (final chunk in resp.stream) {
      if (sink == null && gzChunks == null) {
        if (chunk.length >= 2 && chunk[0] == 0x1f && chunk[1] == 0x8b) {
          gzChunks = [];
        } else {
          sink = _decoderFor(chunk).startChunkedConversion(parser);
        }
      }
      if (gzChunks != null) {
        gzChunks.add(Uint8List.fromList(chunk));
      } else {
        sink!.add(chunk);
      }
    }
    if (gzChunks != null) {
      final total = gzChunks.fold<int>(0, (n, c) => n + c.length);
      final all = Uint8List(total);
      var o = 0;
      for (final c in gzChunks) {
        all.setRange(o, o + c.length, c);
        o += c.length;
      }
      gzChunks = null;
      final bytes = Uint8List.fromList(GZipDecoder().decodeBytes(all));
      final s = _decoderFor(bytes).startChunkedConversion(parser);
      const step = 1 << 20;
      for (var i = 0; i < bytes.length; i += step) {
        s.add(Uint8List.sublistView(bytes, i, i + step > bytes.length ? bytes.length : i + step));
      }
      s.close();
    } else {
      sink?.close();
    }
  } finally {
    client.close();
  }
  return xml.finish();
}

class _ParserSink implements Sink<String> {
  _ParserSink(this.parser);
  final XmltvParser parser;
  @override
  void add(String data) => parser.add(data);
  @override
  void close() {}
}

Converter<List<int>, String> _decoderFor(List<int> firstBytes) {
  final n = firstBytes.length < 300 ? firstBytes.length : 300;
  final head = latin1.decode(firstBytes.sublist(0, n), allowInvalid: true).toLowerCase();
  if (head.contains('iso-8859') || head.contains('windows-1252') || head.contains('latin1')) {
    return const Latin1Decoder(allowInvalid: true);
  }
  return const Utf8Decoder(allowMalformed: true);
}
