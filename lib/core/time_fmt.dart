int nowSecs() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

int floor30(int t) => t - (t % 1800);

String pad2(int n) => n < 10 ? '0$n' : '$n';

DateTime _local(int t) => DateTime.fromMillisecondsSinceEpoch(t * 1000);

/// "3:19pm"
String fmtTime(int t) {
  final d = _local(t);
  final suffix = d.hour >= 12 ? 'pm' : 'am';
  var h = d.hour % 12;
  if (h == 0) h = 12;
  return '$h:${pad2(d.minute)}$suffix';
}

const _days = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

/// "Sat 2/05"
String fmtDate(int t) {
  final d = _local(t);
  return '${_days[d.weekday % 7]} ${d.month}/${pad2(d.day)}';
}

/// "5:00-5:30pm" / "11:30am-12:00pm"
String fmtRange(int s, int e) {
  var a = fmtTime(s);
  final b = fmtTime(e);
  if (a.substring(a.length - 2) == b.substring(b.length - 2)) a = a.substring(0, a.length - 2);
  return '$a-$b';
}
