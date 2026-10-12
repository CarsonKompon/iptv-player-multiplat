import 'models.dart';

/// Incremental XMLTV scanner. Feed decoded text with [add]; complete
/// <channel> / <programme> elements are parsed as they arrive, so the whole
/// file never has to be held in memory. Only programmes for channels in
/// [idMap] and inside [minT, maxT) are kept.
class XmltvParser {
  XmltvParser({
    required Map<String, String> idMap,
    required Map<String, String> nameMap,
    required this.minT,
    required this.maxT,
  })  : _idMap = idMap,
        _nameMap = nameMap;

  /// lower-case xmltv channel id -> channel key
  final Map<String, String> _idMap;

  /// lower-case display name -> channel key
  final Map<String, String> _nameMap;
  final int minT;
  final int maxT;

  final Map<String, List<Program>> _out = {};
  String _buf = '';
  bool _chanDone = false;
  int programmes = 0;

  void add(String chunk) {
    _buf = _buf.isEmpty ? chunk : _buf + chunk;
    _process(false);
  }

  /// Flushes the buffer, sorts and de-overlaps every channel's listings.
  Map<String, List<Program>> finish() {
    _process(true);
    _buf = '';
    for (final key in _out.keys.toList()) {
      final list = _out[key]!..sort((a, b) => a.s.compareTo(b.s));
      final clean = <Program>[];
      for (var i = 0; i < list.length; i++) {
        final p = list[i];
        if (i + 1 < list.length && p.e > list[i + 1].s) p.e = list[i + 1].s;
        if (p.e > p.s) clean.add(p);
      }
      _out[key] = clean;
    }
    return _out;
  }

  void _process(bool last) {
    final s = _buf;
    var cur = 0;
    while (true) {
      final p = s.indexOf('<programme', cur);
      final c = _chanDone ? -1 : s.indexOf('<channel', cur);
      if (c >= 0 && (p < 0 || c < p)) {
        final gt = s.indexOf('>', c);
        if (gt < 0) break;
        if (s.codeUnitAt(gt - 1) == 0x2F) {
          cur = gt + 1;
          continue;
        }
        final e = s.indexOf('</channel>', gt);
        if (e < 0) break;
        _channel(s.substring(c, gt + 1), s.substring(gt + 1, e));
        cur = e + 10;
      } else if (p >= 0) {
        _chanDone = true;
        final gt = s.indexOf('>', p);
        if (gt < 0) break;
        if (s.codeUnitAt(gt - 1) == 0x2F) {
          cur = gt + 1;
          continue;
        }
        final e = s.indexOf('</programme>', gt);
        if (e < 0) break;
        _programme(s.substring(p, gt + 1), s.substring(gt + 1, e));
        cur = e + 12;
      } else {
        if (last) {
          cur = s.length;
        } else {
          // keep a small tail in case a tag start is split across chunks
          final keep = s.length - 16;
          if (keep > cur) cur = keep;
        }
        break;
      }
    }
    _buf = cur >= s.length ? '' : s.substring(cur);
  }

  void _channel(String head, String body) {
    final id = attr(head, 'id');
    if (id.isEmpty) return;
    final lid = id.toLowerCase();
    if (_idMap.containsKey(lid)) return;
    var o = body.indexOf('<display-name');
    while (o >= 0) {
      final gt = body.indexOf('>', o);
      if (gt < 0) return;
      final cl = body.indexOf('</display-name>', gt);
      if (cl < 0) return;
      final dn = xmlText(body.substring(gt + 1, cl)).toLowerCase();
      final key = _nameMap[dn];
      if (key != null) {
        _idMap[lid] = key;
        return;
      }
      o = body.indexOf('<display-name', cl);
    }
  }

  void _programme(String head, String body) {
    final key = _idMap[attr(head, 'channel').toLowerCase()];
    if (key == null) return;
    final st = xmltvTime(attr(head, 'start'));
    if (st == 0) return;
    final stopStr = attr(head, 'stop');
    var en = stopStr.isEmpty ? st + 1800 : xmltvTime(stopStr);
    if (en == 0) en = st + 1800;
    if (en <= minT || st >= maxT) return;

    String? opt(String v) => v.isEmpty ? null : v;
    var desc = tagText(body, 'desc');
    if (desc.length > 420) desc = '${desc.substring(0, 417)}...';
    final date = tagText(body, 'date');
    final rating = tagText(tagText(body, 'rating', decode: false), 'value');
    var title = tagText(body, 'title');
    if (title.isEmpty) title = 'Untitled';

    final prog = Program(
      st,
      en,
      title,
      sub: opt(tagText(body, 'sub-title')),
      desc: opt(desc),
      cat: opt(tagText(body, 'category')),
      rating: opt(rating),
      year: date.length >= 4 ? date.substring(0, 4) : null,
      ep: opt(episodeStr(body)),
      isNew: body.contains('<new'),
      hd: _hdRe.hasMatch(tagText(body, 'quality')),
      cc: body.contains('<subtitles'),
    );
    (_out[key] ??= <Program>[]).add(prog);
    programmes++;
  }
}

// ------------------------------------------------------------------ helpers

final _hdRe = RegExp(r'HD|720|1080|2160|4K', caseSensitive: false);

final _attrCache = <String, RegExp>{};

String attr(String head, String name) {
  final re = _attrCache[name] ??= RegExp('\\s$name\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\')');
  final m = re.firstMatch(head);
  if (m == null) return '';
  return m.group(1) ?? m.group(2) ?? '';
}

final _ws = RegExp(r'\s+');
final _entity = RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos);');

String xmlText(String raw) {
  var s = raw.trim();
  if (s.startsWith('<![CDATA[')) {
    s = s.substring(9);
    if (s.endsWith(']]>')) s = s.substring(0, s.length - 3);
    return s.trim();
  }
  s = s.replaceAll(_ws, ' ');
  if (!s.contains('&')) return s;
  return s.replaceAllMapped(_entity, (m) {
    final e = m.group(1)!;
    switch (e) {
      case 'amp':
        return '&';
      case 'lt':
        return '<';
      case 'gt':
        return '>';
      case 'quot':
        return '"';
      case 'apos':
        return "'";
    }
    final code = e.startsWith('#x') ? int.tryParse(e.substring(2), radix: 16) : int.tryParse(e.substring(1));
    if (code == null || code <= 0 || code > 0x10FFFF) return '';
    return String.fromCharCode(code);
  });
}

/// Text of the first <tag ...>text</tag>.
String tagText(String body, String tag, {bool decode = true}) {
  var o = body.indexOf('<$tag');
  while (o >= 0) {
    final n = o + tag.length + 1;
    if (n >= body.length) return '';
    final ch = body[n];
    if (ch == '>' || ch == ' ' || ch == '/' || ch == '\n' || ch == '\t' || ch == '\r') break;
    o = body.indexOf('<$tag', o + 1);
  }
  if (o < 0) return '';
  final gt = body.indexOf('>', o);
  if (gt < 0) return '';
  if (body.codeUnitAt(gt - 1) == 0x2F) return '';
  final cl = body.indexOf('</$tag>', gt);
  if (cl < 0) return '';
  final inner = body.substring(gt + 1, cl);
  return decode ? xmlText(inner) : inner;
}

String episodeStr(String body) {
  var onscreen = '';
  var ns = '';
  var o = body.indexOf('<episode-num');
  while (o >= 0) {
    final gt = body.indexOf('>', o);
    if (gt < 0) break;
    final cl = body.indexOf('</episode-num>', gt);
    if (cl < 0) break;
    final sys = attr(body.substring(o, gt + 1), 'system');
    final txt = xmlText(body.substring(gt + 1, cl));
    if (sys == 'onscreen' && onscreen.isEmpty) onscreen = txt;
    if (sys == 'xmltv_ns' && ns.isEmpty) ns = txt;
    o = body.indexOf('<episode-num', cl);
  }
  if (onscreen.isNotEmpty) return onscreen;
  if (ns.isEmpty) return '';
  final parts = ns.split('.');
  if (parts.length < 2) return '';
  final sp = parts[0].split('/').first.trim();
  final ep = parts[1].split('/').first.trim();
  final out = StringBuffer();
  final sn = int.tryParse(sp);
  final en = int.tryParse(ep);
  if (sn != null) out.write('S${sn + 1}');
  if (en != null) out.write(' E${en + 1}');
  return out.toString().trim();
}

/// "20260210170000 -0500" -> epoch seconds
final _digitsRe = RegExp(r'^\d+');
final _tzRe = RegExp(r'^([+-])(\d{2}):?(\d{2})');

int xmltvTime(String raw) {
  final s = raw.trim();
  final digits = _digitsRe.stringMatch(s) ?? '';
  if (digits.length < 12) return 0;
  final rest = s.substring(digits.length).trim();
  int n(int a, int b) => int.parse(digits.substring(a, b));
  final se = digits.length >= 14 ? n(12, 14) : 0;
  var t = DateTime.utc(n(0, 4), n(4, 6), n(6, 8), n(8, 10), n(10, 12), se).millisecondsSinceEpoch ~/ 1000;
  final m = _tzRe.firstMatch(rest);
  if (m != null) {
    final off = int.parse(m.group(2)!) * 3600 + int.parse(m.group(3)!) * 60;
    t = m.group(1) == '-' ? t + off : t - off;
  }
  return t;
}
