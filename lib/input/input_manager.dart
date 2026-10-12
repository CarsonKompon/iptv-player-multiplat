import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:gamepads/gamepads.dart';

import 'actions.dart';

/// One physical button press from any device.
class RawInput {
  const RawInput(this.id, this.label, this.device, {this.repeat = false});

  /// Stable id used for bindings, e.g. "key:4294968068", "pad:button-0", "mouse:2"
  final String id;
  final String label;

  /// "Keyboard", "Remote", "Gamepad" or "Mouse"
  final String device;
  final bool repeat;
}

class ActionEvent {
  const ActionEvent(this.action, {this.repeat = false});
  final AppAction action;
  final bool repeat;
}

/// Turns keyboard, TV-remote, gamepad and mouse input into [AppAction]s
/// using the bindings made in the remote-setup wizard. A small set of
/// keyboard/remote defaults always works for anything not explicitly bound,
/// so the app can never become unusable.
class InputManager {
  InputManager._();
  static final instance = InputManager._();

  final _raw = StreamController<RawInput>.broadcast();
  final _actions = StreamController<ActionEvent>.broadcast();

  /// Every button press (used by the setup wizard).
  Stream<RawInput> get raw => _raw.stream;

  /// Mapped actions.
  Stream<ActionEvent> get actions => _actions.stream;

  /// input id -> action
  final Map<String, AppAction> bindings = {};

  /// When true, presses are only reported on [raw] (setup wizard).
  bool captureMode = false;

  /// When true, a text field is being edited: keyboard keys go to it, except
  /// Escape / Back which cancel.
  bool textEntry = false;

  bool _started = false;
  StreamSubscription<GamepadEvent>? _padSub;

  void start() {
    if (_started) return;
    _started = true;
    _initGamepads();
  }

  void setBindings(Map<String, String> stored) {
    bindings.clear();
    stored.forEach((id, name) {
      final a = AppActionX.byName(name);
      if (a != null) bindings[id] = a;
    });
  }

  Map<String, String> exportBindings() => bindings.map((k, v) => MapEntry(k, v.name));

  bool get hasBindings => bindings.isNotEmpty;

  /// First input id bound to [a], for display.
  String? idFor(AppAction a) {
    for (final e in bindings.entries) {
      if (e.value == a) return e.key;
    }
    return null;
  }

  // ------------------------------------------------------------------ keyboard / remote

  /// Called from the root Focus widget. Returns true if handled.
  bool handleKey(KeyEvent e) {
    if (e is KeyUpEvent) return false;
    final key = e.logicalKey;
    final repeat = e is KeyRepeatEvent;

    if (textEntry) {
      if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
        if (!repeat) _actions.add(const ActionEvent(AppAction.back));
        return true;
      }
      return false;
    }

    final label = keyLabel(key);
    return dispatch(RawInput('key:${key.keyId}', label, _deviceFor(key, label), repeat: repeat));
  }

  static String keyLabel(LogicalKeyboardKey key) {
    final l = key.keyLabel;
    if (l.trim().isNotEmpty && l != ' ') return l.length == 1 ? l.toUpperCase() : l;
    if (key == LogicalKeyboardKey.space) return 'Space';
    return key.debugName ?? 'Key ${key.keyId}';
  }

  static final _remoteKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.goBack,
    LogicalKeyboardKey.contextMenu,
    LogicalKeyboardKey.mediaPlayPause,
    LogicalKeyboardKey.mediaPlay,
    LogicalKeyboardKey.mediaPause,
    LogicalKeyboardKey.mediaRewind,
    LogicalKeyboardKey.mediaFastForward,
    LogicalKeyboardKey.channelUp,
    LogicalKeyboardKey.channelDown,
    LogicalKeyboardKey.info,
    LogicalKeyboardKey.guide,
    LogicalKeyboardKey.tvPower,
  };

  String _deviceFor(LogicalKeyboardKey key, String label) {
    if (label.toLowerCase().contains('game button')) return 'Gamepad';
    if (_remoteKeys.contains(key)) return 'Remote';
    return 'Keyboard';
  }

  /// Built-in defaults that work without (and alongside) setup.
  static final Map<String, AppAction> _fallback = {
    'key:${LogicalKeyboardKey.arrowUp.keyId}': AppAction.up,
    'key:${LogicalKeyboardKey.arrowDown.keyId}': AppAction.down,
    'key:${LogicalKeyboardKey.arrowLeft.keyId}': AppAction.left,
    'key:${LogicalKeyboardKey.arrowRight.keyId}': AppAction.right,
    'key:${LogicalKeyboardKey.enter.keyId}': AppAction.ok,
    'key:${LogicalKeyboardKey.numpadEnter.keyId}': AppAction.ok,
    'key:${LogicalKeyboardKey.select.keyId}': AppAction.ok,
    'key:${LogicalKeyboardKey.gameButtonA.keyId}': AppAction.ok,
    'key:${LogicalKeyboardKey.escape.keyId}': AppAction.back,
    'key:${LogicalKeyboardKey.goBack.keyId}': AppAction.back,
    'key:${LogicalKeyboardKey.browserBack.keyId}': AppAction.back,
    'key:${LogicalKeyboardKey.gameButtonB.keyId}': AppAction.back,
    'key:${LogicalKeyboardKey.keyG.keyId}': AppAction.guide,
    'key:${LogicalKeyboardKey.guide.keyId}': AppAction.guide,
    'key:${LogicalKeyboardKey.keyM.keyId}': AppAction.options,
    'key:${LogicalKeyboardKey.contextMenu.keyId}': AppAction.options,
    'key:${LogicalKeyboardKey.channelUp.keyId}': AppAction.up,
    'key:${LogicalKeyboardKey.channelDown.keyId}': AppAction.down,
    'mouse:$kSecondaryMouseButton': AppAction.back,
    'mouse:$kBackMouseButton': AppAction.back,
    'wheel:up': AppAction.up,
    'wheel:down': AppAction.down,
    for (var d = 0; d <= 9; d++) ...{
      'key:${LogicalKeyboardKey.digit0.keyId + d}': AppActionX.digitAction(d),
      'key:${LogicalKeyboardKey.numpad0.keyId + d}': AppActionX.digitAction(d),
    },
  };

  /// Routes a press: always to [raw]; to [actions] when bound (or a default).
  bool dispatch(RawInput r) {
    if (!r.repeat) _raw.add(r);
    if (captureMode) return true;
    final a = bindings[r.id] ?? _fallback[r.id];
    if (a == null) return false;
    if (r.repeat && !a.isDirection) return true;
    _actions.add(ActionEvent(a, repeat: r.repeat));
    return true;
  }

  /// Android/system back gesture that didn't arrive as a key event.
  void systemBack() {
    if (captureMode) {
      _raw.add(const RawInput('sys:back', 'Back', 'Remote'));
      return;
    }
    _actions.add(const ActionEvent(AppAction.back));
  }

  // ------------------------------------------------------------------ mouse

  /// Mouse buttons (only side/extra buttons and right-click map by default;
  /// left-click is handled by the widgets themselves).
  void pointerDown(int buttons) {
    // Never bind left click / touch: outside the wizard it is always left to
    // the widgets, so a binding made here could never fire.
    if (buttons == kPrimaryMouseButton) return;
    final name = switch (buttons) {
      kPrimaryMouseButton => 'Left click',
      kSecondaryMouseButton => 'Right click',
      kMiddleMouseButton => 'Middle click',
      kBackMouseButton => 'Mouse back',
      kForwardMouseButton => 'Mouse forward',
      _ => 'Mouse button $buttons',
    };
    dispatch(RawInput('mouse:$buttons', name, 'Mouse'));
  }

  void scroll(double dy) {
    if (dy == 0) return;
    dispatch(RawInput(dy < 0 ? 'wheel:up' : 'wheel:down', dy < 0 ? 'Scroll up' : 'Scroll down', 'Mouse'));
  }

  // ------------------------------------------------------------------ gamepads

  // Android delivers gamepad buttons as key events already, so the plugin is
  // only used on desktop / web.
  void _initGamepads() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) return;
    try {
      _padSub = Gamepads.events.listen(_onPad, onError: (_) {});
    } catch (_) {
      _padSub = null;
    }
  }

  final Map<String, double> _axisBase = {};
  final Map<String, String> _axisDir = {};
  final Map<String, Timer> _repeatTimers = {};

  void _onPad(GamepadEvent e) {
    if (e.type == KeyType.analog) {
      final String dir;
      if (e.key == 'pov') {
        // Windows (joyGetPosEx) hat: hundredths of a degree, 65535 = centred.
        final v = e.value.round();
        dir = (v < 0 || v >= 36000) ? '0' : const ['up', 'right', 'down', 'left'][((v + 4500) % 36000) ~/ 9000];
      } else {
        final v = _normAxis(e.key, e.value);
        final base = _axisBase.putIfAbsent(e.key, () => v.abs() > 0.9 ? v : 0.0);
        final delta = v - base;
        dir = delta > 0.6 ? '+' : (delta < -0.6 ? '-' : '0');
      }
      final prev = _axisDir[e.key] ?? '0';
      if (dir == prev) return;
      _axisDir[e.key] = dir;
      if (prev != '0') _padRelease('pad:${e.key}:$prev');
      if (dir != '0') _padPress('pad:${e.key}:$dir', 'Stick ${e.key} $dir');
    } else {
      final id = 'pad:${e.key}';
      if (e.value > 0.5) {
        if (!_repeatTimers.containsKey(id)) _padPress(id, 'Button ${e.key}');
      } else {
        _padRelease(id);
      }
    }
  }

  /// Scales raw axis values to about -1..1. gamepads 0.1.x reports raw
  /// numbers on Windows ("dwXpos" etc: 0..65535) and Linux (-32767..32767);
  /// macOS / web / newer Windows builds already report -1..1.
  double _normAxis(String key, double v) {
    if (key.startsWith('dw') && key.endsWith('pos')) return (v / 32767.5 - 1.0).clamp(-1.0, 1.0).toDouble();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux) return (v / 32767.0).clamp(-1.0, 1.0).toDouble();
    return v;
  }

  void _padPress(String id, String label) {
    dispatch(RawInput(id, label, 'Gamepad'));
    _repeatTimers[id]?.cancel();
    _repeatTimers[id] = Timer(const Duration(milliseconds: 420), () {
      _repeatTimers[id] = Timer.periodic(const Duration(milliseconds: 110), (_) {
        dispatch(RawInput(id, label, 'Gamepad', repeat: true));
      });
    });
  }

  void _padRelease(String id) {
    _repeatTimers.remove(id)?.cancel();
  }

  void dispose() {
    _padSub?.cancel();
    for (final t in _repeatTimers.values) {
      t.cancel();
    }
  }
}
