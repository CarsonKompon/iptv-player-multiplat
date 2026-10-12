import 'dart:async';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'time_fmt.dart';

/// Reads a channel's HLS master playlist (without playing it) to find out
/// whether it's HD and whether it carries subtitles:
///   - height: RESOLUTION=WxH of the best variant; if the server doesn't
///     list resolutions, a bitrate >= 3.5 Mbps is taken as HD (720p).
///   - cc: an #EXT-X-MEDIA:TYPE=SUBTITLES rendition or CLOSED-CAPTIONS.
/// Returns null for anything that isn't an HLS master playlist.
Future<ChannelCaps?> probeChannel(http.Client client, Channel ch) async {
  final base = ch.url.split('?').first.toLowerCase();
  if (!base.endsWith('.m3u8')) return null;
  final headers = <String, String>{
    if (ch.ua.isNotEmpty) 'User-Agent': ch.ua,
    if (ch.ref.isNotEmpty) 'Referer': ch.ref,
  };
  final req = http.Request('GET', Uri.parse(ch.url))..headers.addAll(headers);
  final resp = await client.send(req).timeout(const Duration(seconds: 8));
  if (resp.statusCode != 200) return null;
  final bytes = <int>[];
  await for (final chunk in resp.stream) {
    bytes.addAll(chunk);
    if (bytes.length > 32768) break;
  }
  final body = String.fromCharCodes(bytes);
  if (!body.contains('#EXT-X-STREAM-INF')) return null;

  var height = 0;
  var bw = 0;
  for (final m in RegExp(r'RESOLUTION=(\d+)x(\d+)').allMatches(body)) {
    final h = int.parse(m.group(2)!);
    if (h > height) height = h;
  }
  for (final m in RegExp(r'[^-]BANDWIDTH=(\d+)').allMatches(body)) {
    final b = int.parse(m.group(1)!);
    if (b > bw) bw = b;
  }
  if (height == 0 && bw >= 3500000) height = 720;
  final cc = body.contains('TYPE=SUBTITLES') ||
      (body.contains('CLOSED-CAPTIONS=') && !body.contains('CLOSED-CAPTIONS=NONE'));
  return ChannelCaps(height, cc, probed: true, time: nowSecs());
}
