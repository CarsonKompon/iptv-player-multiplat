import 'dart:async';

import 'package:flutter/material.dart';

import '../input/actions.dart';
import '../input/input_manager.dart';
import 'theme.dart';

enum _Stage { detect, required, digits, review }

/// First-run wizard: "press any button", then each required button, then
/// (optionally) the number buttons. Works with any device InputManager sees.
class RemoteSetupScreen extends StatefulWidget {
  const RemoteSetupScreen({super.key, required this.onDone});
  final void Function(Map<String, String> bindings) onDone;

  @override
  State<RemoteSetupScreen> createState() => _RemoteSetupScreenState();
}

class _RemoteSetupScreenState extends State<RemoteSetupScreen> {
  _Stage _stage = _Stage.detect;
  int _step = 0;
  final Map<AppAction, RawInput> _assigned = {};
  String _device = '';
  String _warn = '';
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  StreamSubscription<RawInput>? _sub;

  @override
  void initState() {
    super.initState();
    InputManager.instance.captureMode = true;
    _sub = InputManager.instance.raw.listen(_onRaw);
  }

  @override
  void dispose() {
    _sub?.cancel();
    InputManager.instance.captureMode = false;
    super.dispose();
  }

  void _restart() {
    setState(() {
      _stage = _Stage.detect;
      _step = 0;
      _assigned.clear();
      _warn = '';
    });
  }

  AppAction? _usedBy(String id) {
    for (final e in _assigned.entries) {
      if (e.value.id == id) return e.key;
    }
    return null;
  }

  void _onRaw(RawInput r) {
    final now = DateTime.now();
    // ignore bounces / duplicate events from one press
    if (now.difference(_last).inMilliseconds < 220) return;
    _last = now;

    setState(() {
      _warn = '';
      switch (_stage) {
        case _Stage.detect:
          _device = r.device;
          _stage = _Stage.required;
          _step = 0;
        case _Stage.required:
          final target = requiredActions[_step];
          final used = _usedBy(r.id);
          if (used != null) {
            _warn = '"${r.label}" is already set as ${used.label}. Press a different button.';
            return;
          }
          _assigned[target] = r;
          _step++;
          if (_step >= requiredActions.length) {
            _stage = _Stage.digits;
            _step = 0;
          }
        case _Stage.digits:
          if (r.id == _assigned[AppAction.ok]?.id) {
            _stage = _Stage.review;
            return;
          }
          final used = _usedBy(r.id);
          if (used != null) {
            _warn = '"${r.label}" is already set as ${used.label}. Press a different button, or OK to skip.';
            return;
          }
          _assigned[digitOrder[_step]] = r;
          _step++;
          if (_step >= digitOrder.length) _stage = _Stage.review;
        case _Stage.review:
          if (r.id == _assigned[AppAction.ok]?.id) {
            _finish();
          } else if (r.id == _assigned[AppAction.back]?.id) {
            _restart();
          }
      }
    });
  }

  void _finish() {
    final out = <String, String>{};
    _assigned.forEach((action, input) => out[input.id] = action.name);
    widget.onDone(out);
  }

  String get _prompt {
    switch (_stage) {
      case _Stage.detect:
        return 'Press any button on the remote, controller or keyboard you want to use';
      case _Stage.required:
        return 'Press the  ${requiredActions[_step].label}  button';
      case _Stage.digits:
        final d = digitOrder[_step].digit;
        return _step == 0
            ? 'Does your remote have number buttons?\nPress  1  now, or press OK to skip'
            : 'Press the  $d  button   (or OK to skip the rest)';
      case _Stage.review:
        return 'All set!\nPress OK to save, or BACK to start over';
    }
  }

  @override
  Widget build(BuildContext context) {
    final okLabel = _assigned[AppAction.ok]?.label;
    return Container(
      decoration: const BoxDecoration(gradient: kBgGradient),
      child: Stack(
        children: [
          const Positioned(
            left: 120,
            top: 70,
            child: CanvasText('Remote Setup', size: 64, bold: true),
          ),
          Positioned(
            left: 120,
            top: 150,
            width: 1680,
            child: CanvasText(
              _device.isEmpty ? 'Works with TV remotes, game controllers, keyboards and mice.' : 'Using: $_device',
              size: 30,
              color: Pal.paleBlue,
            ),
          ),
          // prompt box
          Positioned(
            left: 120,
            top: 230,
            width: 1680,
            height: 250,
            child: Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0x66000000),
                border: Border.all(color: Pal.frame, width: 4),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                _prompt,
                textAlign: TextAlign.center,
                style: tv(56, bold: true, color: Colors.white, height: 1.25),
              ),
            ),
          ),
          Positioned(
            left: 120,
            top: 500,
            width: 1680,
            height: 50,
            child: CanvasText(_warn, size: 32, bold: true, color: Pal.yellow, align: TextAlign.center),
          ),
          // assignments
          Positioned(
            left: 120,
            top: 580,
            width: 1680,
            child: Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                for (final a in requiredActions) _chip(a),
                for (final a in digitOrder) _chip(a, small: true),
              ],
            ),
          ),
          // touch / mouse users: skip and use the built-in keyboard defaults
          Positioned(
            right: 120,
            top: 70,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => widget.onDone(const {'_skipped': 'none'}),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                  decoration: BoxDecoration(border: Border.all(color: Pal.frame, width: 2)),
                  child: const CanvasText('Skip (tap / click)', size: 28, color: Pal.paleBlue),
                ),
              ),
            ),
          ),
          Positioned(
            left: 120,
            bottom: 50,
            width: 1680,
            child: CanvasText(
              _stage == _Stage.review
                  ? 'You can redo this any time from Setup.'
                  : (okLabel == null
                      ? 'Tip: hold nothing down - just tap each button once.'
                      : 'Numbers are optional. Press "$okLabel" to skip them.'),
              size: 26,
              color: Pal.softBlue,
              align: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(AppAction a, {bool small = false}) {
    final assigned = _assigned[a];
    final isCurrent = (_stage == _Stage.required && requiredActions[_step] == a) ||
        (_stage == _Stage.digits && digitOrder[_step] == a);
    return Container(
      width: small ? 152 : 400,
      height: small ? 96 : 110,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        gradient: assigned != null ? kCellFocusGradient : (isCurrent ? kHeaderGradient : null),
        color: assigned == null && !isCurrent ? const Color(0x33000000) : null,
        border: Border.all(color: isCurrent ? Pal.yellow : Pal.frame, width: isCurrent ? 4 : 2),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CanvasText(a.label, size: small ? 30 : 32, bold: true),
          CanvasText(assigned?.label ?? (isCurrent ? 'waiting...' : '-'), size: small ? 20 : 24, color: Pal.paleBlue),
        ],
      ),
    );
  }
}
