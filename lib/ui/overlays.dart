import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/models.dart';
import '../core/time_fmt.dart';
import 'theme.dart';

/// Bottom-of-screen channel banner (OK button while watching).
class InfoBanner extends StatelessWidget {
  const InfoBanner({super.key, required this.channel, this.now, this.next});
  final Channel channel;
  final Program? now;
  final Program? next;

  @override
  Widget build(BuildContext context) {
    final t = nowSecs();
    final p = now;
    var frac = 0.0;
    if (p != null && p.e > p.s) frac = ((t - p.s) / (p.e - p.s)).clamp(0.0, 1.0).toDouble();
    final info = <String>[
      if (p?.ep != null) p!.ep!,
      if (p?.sub != null) p!.sub!,
      if (p?.rating != null) p!.rating!,
      if (p?.cat != null) p!.cat!,
      if (p?.year != null) p!.year!,
      if (p?.isNew == true) 'New',
    ];

    return Positioned(
      left: 96,
      top: 786,
      width: 1728,
      height: 228,
      child: Container(
        decoration: const BoxDecoration(
          gradient: kBannerGradient,
          border: Border(
            top: BorderSide(color: Pal.frame, width: 3),
            bottom: BorderSide(color: Color(0xFF2B4B85), width: 3),
          ),
        ),
        child: Stack(
          children: [
            // channel box
            Positioned(
              left: 16,
              top: 16,
              width: 280,
              height: 190,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFFD6E4F6), Color(0xFF92B4E2)],
                  ),
                ),
                child: Column(
                  children: [
                    const SizedBox(height: 6),
                    CanvasText(channel.num, size: 64, bold: true, color: Pal.ink, align: TextAlign.center),
                    CanvasText(channel.name, size: 30, bold: true, color: Pal.ink, align: TextAlign.center),
                    const SizedBox(height: 6),
                    Expanded(
                      child: channel.logo.isNotEmpty
                          ? Padding(
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                              child: Image.network(
                                channel.logo,
                                fit: BoxFit.contain,
                                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                              ),
                            )
                          : (channel.hd
                              ? const Center(child: CanvasText('HD', size: 40, bold: true, color: Color(0xFF2B4B85)))
                              : const SizedBox.shrink()),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 324,
              top: 16,
              width: 1000,
              child: CanvasText(p?.title ?? channel.name, size: 46, bold: true),
            ),
            Positioned(
              right: 20,
              top: 22,
              width: 420,
              child: CanvasText('${fmtTime(t)} ${fmtDate(t)}', size: 32, align: TextAlign.right),
            ),
            Positioned(
              left: 324,
              top: 74,
              width: 1384,
              child: CanvasText(p == null ? 'No program information' : info.join('   |   '),
                  size: 28, color: Pal.paleBlue),
            ),
            if (p != null) ...[
              Positioned(left: 324, top: 118, width: 130, child: CanvasText(fmtTime(p.s), size: 26)),
              Positioned(
                left: 460,
                top: 126,
                width: 760,
                height: 16,
                child: Container(
                  color: Pal.darkSlot,
                  padding: const EdgeInsets.all(2),
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: frac,
                    heightFactor: 1,
                    child: const ColoredBox(color: Pal.barGreen),
                  ),
                ),
              ),
              Positioned(left: 1234, top: 118, width: 130, child: CanvasText(fmtTime(p.e), size: 26)),
            ],
            if (next != null)
              Positioned(
                right: 20,
                top: 118,
                width: 360,
                child: CanvasText('Next: ${next!.title} ${fmtTime(next!.s)}',
                    size: 26, color: Pal.paleBlue, align: TextAlign.right),
              ),
            Positioned(
              left: 324,
              top: 156,
              width: 1384,
              height: 64,
              child: CanvasText(p?.desc ?? '', size: 25, color: const Color(0xFFE8EEF8), maxLines: 2),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Tuning ..." box with a progress estimate, or an error message.
/// Centers itself in whatever area it's given (full screen or the PIP), so it
/// follows the video while it animates.
class TuningToast extends StatelessWidget {
  const TuningToast({
    super.key,
    required this.title,
    required this.progress,
    required this.subtitle,
    required this.showBar,
    this.detail = '',
  });

  final String title;
  final double progress;
  final String subtitle;
  final bool showBar;

  /// Diagnostic text (recent player log) shown under the bar when stalled.
  final String detail;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final compact = c.maxWidth < 1000;
        final showDetail = detail.isNotEmpty && !compact;
        final w = showDetail ? 1400.0 : (c.maxWidth - 60).clamp(200.0, 800.0).toDouble();
        return Center(
          child: SizedBox(
            width: w,
            height: showDetail ? 330 : (compact ? 160 : 190),
            child: _box(compact),
          ),
        );
      });

  Widget _box(bool compact) => Container(
          color: const Color(0xA6000000),
          padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 10),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(title,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: tv(compact ? 30 : 36, bold: true)),
              if (showBar) ...[
                const SizedBox(height: 8),
                CanvasText(subtitle, size: 24, color: Pal.paleBlue, align: TextAlign.center),
                const SizedBox(height: 8),
                Container(
                  height: 14,
                  color: Pal.darkSlot,
                  padding: const EdgeInsets.all(2),
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: progress.clamp(0.0, 1.0).toDouble(),
                    heightFactor: 1,
                    child: const ColoredBox(color: Pal.barGreen),
                  ),
                ),
                if (detail.isNotEmpty && !compact) ...[
                  const SizedBox(height: 10),
                  Text(
                    detail,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.left,
                    style: tv(20, color: Pal.softBlue),
                  ),
                ],
              ],
            ],
          ),
        );
}

/// Old-school green on-screen volume display.
class VolumeOsd extends StatelessWidget {
  const VolumeOsd({super.key, required this.level, required this.max});
  final int level;
  final int max;

  static const _green = Color(0xFF52FF6E);

  static TextStyle _style(double size) => GoogleFonts.vt323(
        fontSize: size,
        color: _green,
        letterSpacing: 4,
        height: 1,
        shadows: const [Shadow(color: Color(0xCC000000), offset: Offset(3, 3))],
      );

  @override
  Widget build(BuildContext context) {
    const segW = 26.0;
    const gapW = 6.0;
    final width = max * (segW + gapW) - gapW;
    return Positioned(
      left: 0,
      right: 0,
      top: 760,
      child: IgnorePointer(
        child: Center(
         child: SizedBox(
          width: width,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('VOLUME', style: _style(84)),
                  Text('$level', style: _style(84)),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  for (var i = 0; i < max; i++)
                    Container(
                      width: segW,
                      height: 34,
                      margin: EdgeInsets.only(right: i == max - 1 ? 0 : gapW),
                      color: i < level ? _green : const Color(0x2E52FF6E),
                    ),
                ],
              ),
            ],
          ),
         ),
        ),
      ),
    );
  }
}

/// Captions drawn over the video.
class SubtitleText extends StatelessWidget {
  const SubtitleText(this.text, {super.key, this.raised = false});
  final String text;

  /// Move above the info banner / volume display.
  final bool raised;

  @override
  Widget build(BuildContext context) => Positioned(
        left: 160,
        right: 160,
        bottom: raised ? 330 : 70,
        child: IgnorePointer(
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
              color: const Color(0xB3000000),
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: tv(46, bold: true, height: 1.2),
              ),
            ),
          ),
        ),
      );
}

/// Channel number being typed ("1 7 _").
class NumberEntry extends StatelessWidget {
  const NumberEntry({super.key, required this.digits, this.error = ''});
  final String digits;
  final String error;

  @override
  Widget build(BuildContext context) => Positioned(
        right: 96,
        top: 60,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xE60A1A42),
            border: Border.all(color: Pal.yellow, width: 4),
          ),
          child: Text(
            error.isNotEmpty ? error : '${digits.split('').join(' ')} _',
            style: tv(error.isNotEmpty ? 34 : 64, bold: true, color: Pal.yellow),
          ),
        ),
      );
}

/// Shown while the playlist loads (and behind Setup on first run).
class LoadingScreen extends StatelessWidget {
  const LoadingScreen({super.key, required this.status, required this.detail});
  final String status;
  final String detail;

  @override
  Widget build(BuildContext context) => Container(
        decoration: const BoxDecoration(gradient: kBgGradient),
        child: Stack(
          children: [
            const Positioned(
              left: 0,
              right: 0,
              top: 370,
              child: CanvasText('iptv', size: 130, bold: true, align: TextAlign.center),
            ),
            const Positioned(left: 860, top: 515, width: 200, height: 6, child: ColoredBox(color: Pal.red)),
            const Positioned(
              left: 0,
              right: 0,
              top: 525,
              child: CanvasText('G U I D E', size: 32, bold: true, color: Pal.paleBlue, align: TextAlign.center),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 650,
              child: CanvasText(status, size: 36, color: Pal.yellow, align: TextAlign.center),
            ),
            Positioned(
              left: 160,
              right: 160,
              top: 706,
              child: CanvasText(detail, size: 26, color: Pal.paleBlue, align: TextAlign.center),
            ),
            const Positioned(
              left: 0,
              right: 0,
              bottom: 70,
              child: CanvasText('Press OPTIONS for Setup', size: 26, color: Pal.softBlue, align: TextAlign.center),
            ),
          ],
        ),
      );
}
