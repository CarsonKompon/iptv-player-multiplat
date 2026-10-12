import 'dart:convert';

import 'models.dart';

// key="value", key='value' or key=value
final _attrRe = RegExp(r'''([A-Za-z0-9_\-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s,"']+))''');

Map<String, String> _attrs(String s) {
  final m = <String, String>{};
  for (final a in _attrRe.allMatches(s)) {
    m[a.group(1)!.toLowerCase()] = a.group(2) ?? a.group(3) ?? a.group(4) ?? '';
  }
  return m;
}

/// Channel number from common stream URL shapes, e.g. ErsatzTV
/// ".../channel/27.m3u8" or ".../iptv/channel/27.ts", or "?channel=27".
final _urlNumRe = RegExp(r'/channels?/(\d+(?:\.\d+)?)(?:\.[A-Za-z0-9]+)?(?:[/?#]|$)');
final _queryNumRe = RegExp(r'[?&](?:channel|ch|chno)=(\d+)');

String _numberFromUrl(String url) =>
    _urlNumRe.firstMatch(url)?.group(1) ?? _queryNumRe.firstMatch(url)?.group(1) ?? '';

/// Entry point for compute(): [text, rewriteTs, firstNumber]
M3uResult parseM3uEntry(List<Object> args) =>
    parseM3u(args[0] as String, rewriteTs: args[1] as bool, firstNumber: args[2] as int);

M3uResult parseM3u(String text, {bool rewriteTs = false, int firstNumber = 1}) {
  if (text.startsWith('﻿')) text = text.substring(1);
  final chans = <Channel>[];
  Channel? pending;
  var epgUrl = '';

  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#EXTM3U')) {
      final a = _attrs(line);
      epgUrl = a['url-tvg'] ?? a['x-tvg-url'] ?? '';
      if (epgUrl.contains(',')) epgUrl = epgUrl.split(',').first.trim();
    } else if (line.startsWith('#EXTINF:')) {
      pending = _parseExtinf(line);
    } else if (line.startsWith('#EXTVLCOPT:')) {
      if (pending != null) {
        final opt = line.substring(11);
        final eq = opt.indexOf('=');
        if (eq > 0) {
          final k = opt.substring(0, eq).toLowerCase();
          final v = opt.substring(eq + 1);
          if (k == 'http-user-agent') pending.ua = v;
          if (k == 'http-referrer' || k == 'http-referer') pending.ref = v;
        }
      }
    } else if (line.startsWith('#EXTGRP:')) {
      if (pending != null && pending.group == 'Other') pending.group = line.substring(8).trim();
    } else if (line.startsWith('#')) {
      // other directives ignored
    } else if (pending != null) {
      // no number attribute: take it from the stream URL if it has one
      if (pending.num.isEmpty) pending.num = _numberFromUrl(line);
      pending.url = rewriteTs ? rewriteTsUrl(line) : line;
      chans.add(pending);
      pending = null;
    }
  }

  // Numbers: use tvg-chno when every channel has one (sorted), otherwise keep
  // playlist order and number the rest sequentially.
  var allNumbered = chans.isNotEmpty;
  var maxNum = firstNumber - 1;
  for (final c in chans) {
    if (c.num.isEmpty) {
      allNumbered = false;
    } else {
      c.numInt = int.tryParse(c.num.split('.').first) ?? 0;
      if (c.numInt > maxNum) maxNum = c.numInt;
    }
  }
  var next = maxNum + 1;
  for (final c in chans) {
    if (c.num.isEmpty) {
      c.numInt = next;
      c.num = '$next';
      next++;
    }
    if (c.name.isEmpty) c.name = 'Channel ${c.num}';
    c.key = c.id.isNotEmpty ? c.id : c.name;
  }
  if (allNumbered) {
    final indexed = List.generate(chans.length, (i) => (i, chans[i]));
    indexed.sort((a, b) {
      final d = a.$2.numInt.compareTo(b.$2.numInt);
      return d != 0 ? d : a.$1.compareTo(b.$1);
    });
    chans
      ..clear()
      ..addAll(indexed.map((e) => e.$2));
  }
  return M3uResult(chans, epgUrl);
}

Channel _parseExtinf(String line) {
  // The display name follows the first comma that is outside quotes.
  var cpos = -1;
  var inQ = false;
  for (var i = 8; i < line.length; i++) {
    final ch = line.codeUnitAt(i);
    if (ch == 0x22) {
      inQ = !inQ;
    } else if (ch == 0x2C && !inQ) {
      cpos = i;
      break;
    }
  }
  final head = cpos >= 0 ? line.substring(0, cpos) : line;
  final name = cpos >= 0 ? line.substring(cpos + 1).trim() : '';
  final a = _attrs(head);

  final c = Channel(
    name: name.isNotEmpty ? name : (a['tvg-name'] ?? ''),
    id: a['tvg-id'] ?? '',
    tname: a['tvg-name'] ?? '',
    logo: a['tvg-logo'] ?? '',
    group: (a['group-title'] ?? '').isNotEmpty ? a['group-title']! : 'Other',
    num: a['tvg-chno'] ??
        a['channel-number'] ??
        a['tvg-channel-no'] ??
        a['channel_number'] ??
        a['tvg-num'] ??
        a['lcn'] ??
        '',
    ua: a['http-user-agent'] ?? '',
    ref: a['http-referrer'] ?? '',
  );
  // CC marker: flag it and drop it from the displayed name
  final ccMatch = _ccRe.firstMatch(c.name);
  if (ccMatch != null) {
    c.cc = true;
    final stripped = c.name.replaceFirst(_ccRe, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (stripped.isNotEmpty) c.name = stripped;
  }
  final u = ' ${c.name.toUpperCase()} ';
  c.hd = u.contains(' HD ') || u.contains(' FHD ') || u.contains(' UHD ') || u.contains(' 4K ') || u.contains('HD ');
  return c;
}

/// "CC" as its own token: "Name-CC", "Name CC", "Name [CC]", "Name (CC)", "Name|CC"
final _ccRe = RegExp(r'[\s\-_|]*[\[(]?\bCC\b[\])]?[\s\-_|]*(?=$|\s)');

/// Xtream-style ".ts" links -> HLS (needed only where raw MPEG-TS can't play, e.g. web).
String rewriteTsUrl(String url) {
  final q = url.indexOf('?');
  final base = q >= 0 ? url.substring(0, q) : url;
  final query = q >= 0 ? url.substring(q) : '';
  if (base.toLowerCase().endsWith('.ts')) return '${base.substring(0, base.length - 3)}.m3u8$query';
  return url;
}
