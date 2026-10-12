enum AppAction {
  up,
  down,
  left,
  right,
  ok,
  guide,
  back,
  options,
  digit0,
  digit1,
  digit2,
  digit3,
  digit4,
  digit5,
  digit6,
  digit7,
  digit8,
  digit9,
}

extension AppActionX on AppAction {
  String get label => switch (this) {
        AppAction.up => 'UP',
        AppAction.down => 'DOWN',
        AppAction.left => 'LEFT',
        AppAction.right => 'RIGHT',
        AppAction.ok => 'OK / SELECT',
        AppAction.guide => 'GUIDE',
        AppAction.back => 'BACK',
        AppAction.options => 'OPTIONS / MENU',
        _ => '$digit',
      };

  bool get isDigit => index >= AppAction.digit0.index;
  int get digit => index - AppAction.digit0.index;
  bool get isDirection =>
      this == AppAction.up || this == AppAction.down || this == AppAction.left || this == AppAction.right;

  static AppAction? byName(String n) {
    for (final a in AppAction.values) {
      if (a.name == n) return a;
    }
    return null;
  }

  static AppAction digitAction(int d) => AppAction.values[AppAction.digit0.index + d];
}

/// The buttons the setup wizard asks for, in order.
const requiredActions = [
  AppAction.up,
  AppAction.down,
  AppAction.left,
  AppAction.right,
  AppAction.ok,
  AppAction.guide,
  AppAction.back,
  AppAction.options,
];

/// Optional number buttons, in the order they're asked for.
final digitOrder = [1, 2, 3, 4, 5, 6, 7, 8, 9, 0].map(AppActionX.digitAction).toList();
