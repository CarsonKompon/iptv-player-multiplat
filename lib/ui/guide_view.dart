import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/epg.dart';
import '../core/models.dart';
import '../core/time_fmt.dart';
import '../input/actions.dart';
import 'theme.dart';

/// Satellite-style guide: header (logo / list / clock / setup), program
/// details, PIP frame (the video is laid over it by the shell) and a
/// 90-minute, 5-row grid.
class GuideView extends StatefulWidget {
  const GuideView({
    super.key,
    required this.channels,
    required this.epg,
    required this.playingIndex,
    required this.status,
    required this.epgHours,
    required this.onTune,
    required this.onClose,
    required this.onSetup,
    this.showEpisodes = false,
    this.showLogos = false,
  });

  final bool showEpisodes;
  final bool showLogos;

  final List<Channel> channels;
  final EpgData epg;
  final int playingIndex;
  final String status;
  final int epgHours;
  final void Function(int index) onTune;
  final VoidCallback onClose;
  final VoidCallback onSetup;

  @override
  State<GuideView> createState() => GuideViewState();
}

class GuideViewState extends State<GuideView> {
  static const rows = 5;
  static const gx = 96.0;
  static const chw = 330.0;
  static const gap = 6.0;
  static const slot = 466.0;
  static const px0 = gx + chw + gap;
  static const hdrY = 462.0;
  static const hdrH = 52.0;
  static const rowY = 520.0;
  static const rowP = 100.0;
  static const rowH = 94.0;
  static const win = 5400;
  static const pxPerSec = slot / 1800.0;

  List<String> _groups = ['All Channels'];
  int _groupIdx = 0;
  List<int> _filt = [];
  int _topIdx = 0;
  int _focusRow = 0;
  int _ws = 0;
  int _anchorT = 0;
  int _focusS = 0;

  /// -1 = grid, 0 = List pill, 1 = Setup button
  int _header = -1;
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _buildGroups();
    openAt(widget.playingIndex, rebuild: false);
    _clock = Timer.periodic(const Duration(seconds: 10), (_) => _tick());
  }

  @override
  void didUpdateWidget(GuideView old) {
    super.didUpdateWidget(old);
    if (!identical(old.channels, widget.channels)) {
      _buildGroups();
      openAt(widget.playingIndex, rebuild: false);
    }
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  // ------------------------------------------------------------------ data

  void _buildGroups() {
    final seen = <String>{};
    _groups = ['All Channels'];
    for (final c in widget.channels) {
      if (c.group.isNotEmpty && seen.add(c.group)) _groups.add(c.group);
    }
    _applyFilter(0);
  }

  void _applyFilter(int gi) {
    _groupIdx = gi;
    final want = _groups[gi];
    _filt = [
      for (var i = 0; i < widget.channels.length; i++)
        if (gi == 0 || widget.channels[i].group == want) i
    ];
    _topIdx = 0;
    _focusRow = 0;
  }

  int get _focusIdx => _topIdx + _focusRow;

  Channel? get _focusChannel => _filt.isEmpty ? null : widget.channels[_filt[_focusIdx]];

  Segment _seg(Channel ch, int t) => widget.epg.segAt(ch, t);

  void _tick() {
    final now = nowSecs();
    if (_ws < floor30(now)) {
      _ws = floor30(now);
      if (_anchorT < now) _anchorT = now;
    }
    if (mounted) setState(() {});
  }

  /// Positions the guide on channel [index] (an index into all channels).
  void openAt(int index, {bool rebuild = true}) {
    var fpos = _filt.indexOf(index);
    if (fpos < 0) {
      _applyFilter(0);
      fpos = index.clamp(0, math.max(0, _filt.length - 1));
    }
    final n = _filt.length;
    _topIdx = fpos;
    if (_topIdx > n - rows) _topIdx = n - rows;
    if (_topIdx < 0) _topIdx = 0;
    _focusRow = fpos - _topIdx;
    final now = nowSecs();
    _ws = floor30(now);
    _anchorT = now;
    _header = -1;
    final ch = _focusChannel;
    if (ch != null) _focusS = _seg(ch, now).s;
    if (rebuild) setState(() {});
  }

  // ------------------------------------------------------------------ navigation

  void _moveRow(int d) {
    final n = _filt.length;
    if (n == 0) return;
    if (d == -1 && _focusIdx == 0) {
      _header = 0; // up from the first channel enters the header
      return;
    }
    var fi = _focusIdx + d;
    if (d.abs() == 1) {
      if (fi < 0) fi = n - 1;
      if (fi >= n) fi = 0;
    } else {
      _topIdx = (_topIdx + d).clamp(0, math.max(0, n - rows));
      fi = fi.clamp(0, n - 1);
    }
    if (fi < _topIdx) _topIdx = fi;
    if (fi >= _topIdx + rows) _topIdx = fi - rows + 1;
    _focusRow = fi - _topIdx;
    _focusS = _seg(_focusChannel!, math.max(_anchorT, _ws)).s;
  }

  void _moveRight() {
    final ch = _focusChannel;
    if (ch == null) return;
    final seg = _seg(ch, math.max(_focusS, _ws));
    final ns = seg.e;
    if (ns >= nowSecs() + widget.epgHours * 3600) return;
    while (ns >= _ws + win) {
      _ws += 1800;
    }
    _focusS = ns;
    _anchorT = ns;
  }

  void _moveLeft() {
    final ch = _focusChannel;
    if (ch == null) return;
    final minWs = floor30(nowSecs());
    if (_ws < minWs) _ws = minWs;
    final seg = _seg(ch, math.max(_focusS, _ws));
    if (seg.s < _ws) {
      if (_ws <= minWs) return;
      _ws -= 1800; // reveal the clipped program first
      _anchorT = math.max(seg.s, _ws);
      return;
    }
    if (seg.s == _ws) {
      if (_ws <= minWs) return;
      _ws -= 1800;
    }
    final prev = _seg(ch, seg.s - 1);
    _focusS = prev.s;
    while (prev.s < _ws && _ws > minWs) {
      _ws -= 1800;
    }
    _anchorT = math.max(prev.s, _ws);
  }

  void _nextList() {
    if (_groups.length <= 1) return;
    _applyFilter((_groupIdx + 1) % _groups.length);
    final ch = _focusChannel;
    if (ch != null) _focusS = _seg(ch, math.max(_anchorT, _ws)).s;
  }

  /// Returns true if the action was used.
  bool handle(AppAction a) {
    var used = true;
    if (a == AppAction.back || a == AppAction.guide) {
      widget.onClose();
      return true;
    }
    if (a == AppAction.options) {
      widget.onSetup();
      return true;
    }
    if (_header >= 0 || _filt.isEmpty) {
      if (_header < 0) _header = 0;
      switch (a) {
        case AppAction.left:
        case AppAction.right:
          _header = 1 - _header;
        case AppAction.ok:
          if (_header == 0) {
            _nextList();
          } else {
            widget.onSetup();
            return true;
          }
        case AppAction.down:
          if (_filt.isNotEmpty) _header = -1;
        case AppAction.up:
          // wrap around to the bottom of the channel list
          final n = _filt.length;
          if (n > 0) {
            _header = -1;
            _topIdx = math.max(0, n - rows);
            _focusRow = n - 1 - _topIdx;
            _focusS = _seg(_focusChannel!, math.max(_anchorT, _ws)).s;
          }
        default:
          used = false;
      }
    } else {
      switch (a) {
        case AppAction.up:
          _moveRow(-1);
        case AppAction.down:
          _moveRow(1);
        case AppAction.left:
          _moveLeft();
        case AppAction.right:
          _moveRight();
        case AppAction.ok:
          widget.onTune(_filt[_focusIdx]);
          return true;
        default:
          used = false;
      }
    }
    if (used) setState(() {});
    return used;
  }

  void pageRows(int d) => setState(() => _moveRow(d * rows));

  // ------------------------------------------------------------------ mouse

  void _tapCell(int row, Segment seg, Segment? focused) {
    if (row == _focusRow && _header < 0 && focused != null && seg.s == focused.s) {
      widget.onTune(_filt[_focusIdx]);
      return;
    }
    setState(() {
      _header = -1;
      _focusRow = row;
      _focusS = seg.s;
      _anchorT = math.max(seg.s, _ws);
    });
  }

  void _tapHeader(int which) {
    if (which == 0) {
      setState(() {
        _header = 0;
        _nextList();
      });
    } else {
      widget.onSetup();
    }
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final now = nowSecs();
    final fch = _focusChannel;
    final fSeg = fch == null ? null : _seg(fch, math.max(_focusS, _ws));
    final we = _ws + win;

    final children = <Widget>[
      // background + header band
      const Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(gradient: kBgGradient))),
      const Positioned(left: 0, top: 0, width: 1090, height: 172, child: ColoredBox(color: Color(0x8C081736))),

      // logo
      const Positioned(left: 96, top: 20, child: CanvasText('iptv', size: 84, bold: true)),
      const Positioned(left: 100, top: 110, width: 150, height: 5, child: ColoredBox(color: Pal.red)),
      const Positioned(left: 98, top: 118, child: CanvasText('G U I D E', size: 20, bold: true, color: Pal.paleBlue)),

      // list + setup + clock
      const Positioned(left: 300, top: 40, child: CanvasText('List:', size: 40, bold: true)),
      Positioned(
        left: 398,
        top: 30,
        width: 332,
        height: 68,
        child: _clickable(
          () => _tapHeader(0),
          Container(
            decoration: BoxDecoration(
              color: Pal.pillGreen,
              border: Border.all(color: _header == 0 ? Pal.yellow : Colors.transparent, width: 6),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.centerLeft,
            child: CanvasText(_groups[_groupIdx], size: 40, bold: true, color: const Color(0xFFEAF7E2)),
          ),
        ),
      ),
      Positioned(
        left: 744,
        top: 30,
        width: 172,
        height: 68,
        child: _clickable(
          () => _tapHeader(1),
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF2B4B85),
              border: Border.all(color: _header == 1 ? Pal.yellow : Colors.transparent, width: 6),
            ),
            alignment: Alignment.center,
            child: const CanvasText('Setup', size: 36, bold: true),
          ),
        ),
      ),
      Positioned(left: 300, top: 98, child: CanvasText('${fmtTime(now)} ${fmtDate(now)}', size: 36)),
      Positioned(
        left: 300,
        top: 140,
        width: 780,
        child: CanvasText(widget.status, size: 24, color: Pal.yellow),
      ),

      // details
      Positioned(
        left: 96,
        top: 180,
        width: 990,
        child: CanvasText(
          fSeg?.p?.title ?? fch?.name ?? '',
          size: 40,
          bold: true,
          align: TextAlign.center,
        ),
      ),
      Positioned(
        left: 96,
        top: 232,
        width: 990,
        height: 222,
        child: Text(
          fSeg?.p != null
              ? '${fmtRange(fSeg!.p!.s, fSeg.p!.e)}  ${fSeg.p!.details()}'
              : (fch == null ? '' : 'No program information available.'),
          textAlign: TextAlign.center,
          maxLines: 6,
          overflow: TextOverflow.ellipsis,
          style: tv(30, height: 1.15),
        ),
      ),

      // PIP frame (video goes on top)
      Positioned.fromRect(rect: kPip.inflate(6), child: const ColoredBox(color: Pal.frame)),
      Positioned.fromRect(
        rect: kPip,
        child: const ColoredBox(
          color: Colors.black,
          child: Center(child: CanvasText('No Signal', size: 36, bold: true, color: Color(0xFF5A6E90))),
        ),
      ),

      // header row
      _headerCell(gx, chw, fmtDate(_ws)),
      for (var i = 0; i < 3; i++) _headerCell(px0 + i * slot, slot - gap, fmtTime(_ws + i * 1800)),
    ];

    if (_filt.isEmpty) {
      children.add(const Positioned(
        left: gx,
        top: rowY,
        width: 1728,
        height: 300,
        child: Center(child: CanvasText('No channels in this list', size: 36, bold: true)),
      ));
    }

    for (var r = 0; r < rows; r++) {
      final fi = _topIdx + r;
      if (fi >= _filt.length) break;
      final ch = widget.channels[_filt[fi]];
      final y = rowY + r * rowP;
      children.add(_chanCell(ch, y));
      var t = _ws;
      var guard = 0;
      while (t < we && guard < 12) {
        guard++;
        final seg = _seg(ch, t);
        final x0 = math.max(seg.s, _ws);
        final x1 = math.min(seg.e, we);
        final left = px0 + (x0 - _ws) * pxPerSec;
        final width = math.max(4.0, (x1 - x0) * pxPerSec - gap);
        final focused = _header < 0 && r == _focusRow && fSeg != null && seg.s == fSeg.s;
        final row = r;
        children.add(Positioned(
          left: left,
          top: y,
          width: width,
          height: rowH,
          child: _clickable(
            () => _tapCell(row, seg, fSeg),
            _ProgramCell(seg.title, widget.showEpisodes ? (seg.p?.sub ?? seg.p?.ep) : null, focused, width),
          ),
        ));
        t = seg.e;
      }
    }

    return Listener(
      behavior: HitTestBehavior.translucent,
      child: Stack(clipBehavior: Clip.hardEdge, children: children),
    );
  }

  Widget _clickable(VoidCallback onTap, Widget child) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(onTap: onTap, behavior: HitTestBehavior.opaque, child: child),
      );

  Widget _headerCell(double x, double w, String text) => Positioned(
        left: x,
        top: hdrY,
        width: w,
        height: hdrH,
        child: Container(
          decoration: const BoxDecoration(
            gradient: kHeaderGradient,
            border: Border(top: BorderSide(color: Color(0x73FFFFFF), width: 2)),
          ),
          alignment: Alignment.center,
          child: CanvasText(text, size: 32, bold: true),
        ),
      );

  /// Badges come from the channel name: "HD" anywhere, and a "CC" marker
  /// ("Name-CC", "Name [CC]"...; stripped from the displayed name).
  (bool, bool) _badges(Channel ch) => (ch.hd, ch.cc);

  Widget _badge(String text, double size, {bool boxed = false}) => Container(
        margin: const EdgeInsets.only(right: 6, bottom: 2),
        padding: boxed ? const EdgeInsets.symmetric(horizontal: 4) : EdgeInsets.zero,
        decoration: boxed ? BoxDecoration(border: Border.all(color: Colors.white, width: 2)) : null,
        child: CanvasText(text, size: size, bold: true),
      );

  Widget _chanCell(Channel ch, double y) {
    final (hd, cc) = _badges(ch);
    final logo = widget.showLogos && ch.logo.isNotEmpty;
    return Positioned(
        left: gx,
        top: y,
        width: chw,
        height: rowH,
        child: Container(
          decoration: const BoxDecoration(gradient: kChanGradient),
          child: Stack(
            children: [
              const Positioned(
                left: 0,
                top: 0,
                right: 0,
                height: rowH / 2,
                child: ColoredBox(color: Color(0x2EFFFFFF)),
              ),
              if (logo)
                Positioned(
                  left: 10,
                  top: 6,
                  bottom: (hd || cc) ? 30 : 6,
                  width: 120,
                  child: Image.network(
                    ch.logo,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
              if (logo && (hd || cc))
                Positioned(
                  left: 12,
                  bottom: 2,
                  child: Row(children: [
                    if (hd) _badge('HD', 20),
                    if (cc) _badge('CC', 16, boxed: true),
                  ]),
                ),
              if (!logo && (hd || cc))
                Positioned(
                  left: 14,
                  top: 0,
                  bottom: 0,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (hd) _badge('HD', 30),
                      if (cc) _badge('CC', 20, boxed: true),
                    ],
                  ),
                ),
              Positioned(
                right: 14,
                top: 6,
                left: 14,
                child: CanvasText(ch.num, size: 34, bold: true, color: Pal.ink, align: TextAlign.right),
              ),
              Positioned(
                right: 14,
                top: 46,
                left: widget.showLogos ? 140 : 70,
                child: CanvasText(ch.name, size: 34, bold: true, color: Pal.ink, align: TextAlign.right),
              ),
            ],
          ),
        ),
      );
  }
}

class _ProgramCell extends StatelessWidget {
  const _ProgramCell(this.title, this.episode, this.focused, this.width);
  final String title;
  final String? episode;
  final bool focused;
  final double width;

  @override
  Widget build(BuildContext context) {
    final color = focused ? Colors.white : Pal.ink;
    final ep = episode;
    Widget? child;
    if (width > 40) {
      child = (ep == null || ep.isEmpty)
          ? Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: tv(36, bold: true, color: color, height: 1.05),
            )
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: tv(34, bold: true, color: color)),
                Text(ep,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: tv(26, color: focused ? const Color(0xFFE6F4DE) : const Color(0xFF3A4F7A))),
              ],
            );
    }
    return Container(
      decoration: BoxDecoration(
        gradient: focused ? kCellFocusGradient : kCellGradient,
        border: const Border(top: BorderSide(color: Color(0xB3FFFFFF), width: 2)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.center,
      child: child,
    );
  }
}
