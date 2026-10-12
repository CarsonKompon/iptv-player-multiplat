import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// The whole UI is laid out on a fixed 1920x1080 canvas and scaled to fit.
const kCanvas = Size(1920, 1080);

/// PIP preview window in the guide.
const kPip = Rect.fromLTWH(1113, 36, 711, 400);

class Pal {
  static const navyTop = Color(0xFF26487F);
  static const navyBottom = Color(0xFF0B1C46);
  static const ink = Color(0xFF1C3567);
  static const yellow = Color(0xFFFFD84A);
  static const paleBlue = Color(0xFFCFE0F5);
  static const softBlue = Color(0xFF9FB6D8);
  static const frame = Color(0xFF86A9DB);
  static const pillGreen = Color(0xFF3F7F34);
  static const barGreen = Color(0xFF6DAA57);
  static const darkSlot = Color(0xFF0A1530);
  static const red = Color(0xFFD8282F);
}

const kBgGradient = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [Pal.navyTop, Pal.navyBottom],
);

const kCellGradient = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [Color(0xFFF4F5F8), Color(0xFFDDDFE5), Color(0xFFC3C6CF)],
  stops: [0, 0.5, 1],
);

const kCellFocusGradient = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [Color(0xFF76B25F), Color(0xFF4E8C3B), Color(0xFF396C29)],
  stops: [0, 0.5, 1],
);

const kChanGradient = LinearGradient(
  colors: [Color(0xFF80A8DE), Color(0xFFE2ECF9)],
);

const kHeaderGradient = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [Color(0xFF5E8AC8), Color(0xFF264E8C)],
);

const kBannerGradient = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [Color(0xFF284C88), Color(0xFF0A1A42)],
);

TextStyle tv(double size, {bool bold = false, Color color = Colors.white, double height = 1.1}) =>
    GoogleFonts.robotoCondensed(
      fontSize: size,
      fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
      color: color,
      height: height,
    );

/// Text positioned on the canvas.
class CanvasText extends StatelessWidget {
  const CanvasText(
    this.text, {
    super.key,
    required this.size,
    this.bold = false,
    this.color = Colors.white,
    this.align = TextAlign.left,
    this.maxLines = 1,
  });

  final String text;
  final double size;
  final bool bold;
  final Color color;
  final TextAlign align;
  final int maxLines;

  @override
  Widget build(BuildContext context) => Text(
        text,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        textAlign: align,
        softWrap: maxLines > 1,
        style: tv(size, bold: bold, color: color),
      );
}

/// Simple green-highlight list used by Setup.
class TvMenuList extends StatelessWidget {
  const TvMenuList({super.key, required this.items, required this.selected, required this.onTap, this.itemHeight = 62});
  final List<String> items;
  final int selected;
  final void Function(int) onTap;
  final double itemHeight;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < items.length; i++)
            GestureDetector(
              onTap: () => onTap(i),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Container(
                  height: itemHeight,
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  alignment: Alignment.centerLeft,
                  decoration: BoxDecoration(
                    gradient: i == selected ? kCellFocusGradient : null,
                    border: i == selected ? Border.all(color: Pal.yellow, width: 3) : null,
                  ),
                  child: CanvasText(items[i], size: 34, bold: true),
                ),
              ),
            ),
        ],
      );
}
