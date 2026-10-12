/// Plain data classes. Everything here is sendable between isolates.
library;

class Channel {
  Channel({
    required this.name,
    this.id = '',
    this.tname = '',
    this.logo = '',
    this.group = 'Other',
    this.num = '',
    this.url = '',
    this.ua = '',
    this.ref = '',
  });

  /// EPG lookup key: tvg-id, or the name when tvg-id is missing.
  String key = '';
  String id;
  String tname;
  String name;
  String logo;
  String group;
  String num;
  int numInt = 0;
  String url;
  String ua;
  String ref;
  /// "HD" in the channel name.
  bool hd = false;

  /// A CC marker in the channel name ("Name-CC", "Name CC", "Name [CC]").
  bool cc = false;

  String get label => '$num $name';
}

class Program {
  Program(
    this.s,
    this.e,
    this.title, {
    this.sub,
    this.desc,
    this.cat,
    this.rating,
    this.year,
    this.ep,
    this.isNew = false,
    this.hd = false,
    this.cc = false,
  });

  /// From XMLTV <video><quality> (HDTV / 720p / 1080p / UHD...)
  final bool hd;

  /// From XMLTV <subtitles>
  final bool cc;

  /// Start / end in epoch seconds (UTC).
  final int s;
  int e;
  final String title;
  final String? sub;
  final String? desc;
  final String? cat;
  final String? rating;
  final String? year;
  final String? ep;
  final bool isNew;

  List<Object?> toJson() => [s, e, title, sub, desc, cat, rating, year, ep, isNew ? 1 : 0, hd ? 1 : 0, cc ? 1 : 0];

  static Program fromJson(List<dynamic> j) => Program(
        (j[0] as num).toInt(),
        (j[1] as num).toInt(),
        j[2] as String,
        sub: j[3] as String?,
        desc: j[4] as String?,
        cat: j[5] as String?,
        rating: j[6] as String?,
        year: j[7] as String?,
        ep: j[8] as String?,
        isNew: j[9] == 1,
        hd: j.length > 10 && j[10] == 1,
        cc: j.length > 11 && j[11] == 1,
      );

  /// Detail paragraph, satellite-guide style.
  String details() {
    final b = StringBuffer();
    void add(String? v, [String sep = '  ']) {
      if (v != null && v.isNotEmpty) b.write('$v$sep');
    }

    add(rating);
    add(ep);
    add(sub);
    add(cat, '. ');
    add(desc, ' ');
    if (year != null && year!.isNotEmpty) b.write('($year) ');
    if (isNew) b.write('(New)');
    return b.toString().trim();
  }
}

/// What we know about a channel's stream: from a background scan of its HLS
/// master playlist ([probed] = true, refreshed daily) or, more reliably,
/// from actually playing it.
class ChannelCaps {
  const ChannelCaps(this.height, this.cc, {this.probed = false, this.time = 0});

  /// Picture height in lines (0 = unknown).
  final int height;
  final bool cc;
  final bool probed;

  /// When this was recorded (epoch seconds).
  final int time;

  Map<String, Object> toJson() => {'h': height, 'cc': cc, 'p': probed, 't': time};
  static ChannelCaps fromJson(Map<String, dynamic> j) => ChannelCaps(
        (j['h'] as num?)?.toInt() ?? 0,
        j['cc'] == true,
        probed: j['p'] == true,
        time: (j['t'] as num?)?.toInt() ?? 0,
      );
}

class M3uResult {
  M3uResult(this.channels, this.epgUrl);
  final List<Channel> channels;
  final String epgUrl;
}
