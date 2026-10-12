import 'models.dart';
import 'time_fmt.dart';

/// A program, or a filler gap where there's no guide data.
class Segment {
  const Segment(this.s, this.e, this.title, this.p);
  final int s;
  final int e;
  final String title;
  final Program? p;
}

class EpgData {
  EpgData(this.byKey);
  final Map<String, List<Program>> byKey;

  static final empty = EpgData(const {});

  int get channelCount => byKey.length;

  /// Segment of [ch] containing time [t]. Gaps are split on half hours so
  /// navigation through channels without data still moves 30 minutes.
  Segment segAt(Channel ch, int t) {
    final list = byKey[ch.key];
    var prevEnd = 0;
    var nextStart = 9999999999; // (not 1 << 40: shifts are 32-bit on web)
    if (list != null && list.isNotEmpty) {
      var lo = 0, hi = list.length - 1, idx = -1;
      while (lo <= hi) {
        final md = (lo + hi) >> 1;
        if (list[md].s <= t) {
          idx = md;
          lo = md + 1;
        } else {
          hi = md - 1;
        }
      }
      if (idx >= 0) {
        final p = list[idx];
        if (t < p.e) return Segment(p.s, p.e, p.title, p);
        prevEnd = p.e;
      }
      if (idx + 1 < list.length) nextStart = list[idx + 1].s;
    }
    var gs = floor30(t);
    if (gs < prevEnd) gs = prevEnd;
    var ge = floor30(t) + 1800;
    if (ge > nextStart) ge = nextStart;
    if (ge <= gs) ge = gs + 60;
    return Segment(gs, ge, ch.name, null);
  }

  /// (now, next) for the info banner.
  (Program?, Program?) nowNext(String key, int t) {
    final list = byKey[key];
    if (list == null) return (null, null);
    for (var i = 0; i < list.length; i++) {
      final p = list[i];
      if (p.s <= t && t < p.e) return (p, i + 1 < list.length ? list[i + 1] : null);
      if (p.s > t) return (null, p);
    }
    return (null, null);
  }

  Map<String, dynamic> toJson() =>
      byKey.map((k, v) => MapEntry(k, v.map((p) => p.toJson()).toList()));

  static EpgData fromJson(Map<String, dynamic> j) => EpgData(j.map((k, v) =>
      MapEntry(k, (v as List).map((p) => Program.fromJson(p as List)).toList())));
}

/// Synthetic listings for the bundled demo channels.
Map<String, List<Program>> demoEpg(List<List<String>> channels, int now, int maxT) {
  const shows = [
    ['Morning Market Report', 'News'],
    ['Backyard Builders', 'Home/Garden'],
    ['Cosmic Cadets', 'Animated/Children'],
    ['The Late Late Quiz', 'Game Show'],
    ['Wild Coastlines', 'Nature'],
    ['Kitchen Clash', 'Cooking'],
    ['Gridiron Weekly', 'Sports'],
    ['Detective Marlowe Lane', 'Drama'],
    ['Retro Rewind', 'Music'],
    ['Space Station Seven', 'Science Fiction'],
    ['Garage Gold', 'Reality'],
    ['Tiny Inventors', 'Family/Children'],
    ['Midnight Movie Classic', 'Movie'],
    ['Weather Watch', 'Weather'],
    ['Pocket Science', 'Educational'],
    ['Laugh Track Theater', 'Comedy'],
    ['Around the World in 30', 'Travel'],
  ];
  final out = <String, List<Program>>{};
  for (var ci = 0; ci < channels.length; ci++) {
    final key = channels[ci][0];
    final name = channels[ci][3];
    final list = <Program>[];
    var t = floor30(now) - 3600;
    var slot = 0;
    while (t < maxT) {
      final sh = shows[(ci * 5 + slot * 3) % shows.length];
      final dur = (ci + slot) % 3 == 0 ? 3600 : 1800;
      final epn = (t ~/ 1800) % 40 + 1;
      list.add(Program(t, t + dur, sh[0],
          cat: sh[1],
          rating: 'TV-G',
          sub: 'Episode $epn',
          ep: 'S1 E$epn',
          desc: 'Demo listing for $name. Open Setup to use your own M3U playlist and XMLTV guide.'));
      t += dur;
      slot++;
    }
    out[key] = list;
  }
  return out;
}
