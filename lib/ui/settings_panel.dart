import 'package:flutter/material.dart';

import 'theme.dart';

class SettingsPanel extends StatelessWidget {
  const SettingsPanel({
    super.key,
    required this.items,
    required this.selected,
    required this.message,
    required this.playlistUrl,
    required this.epgUrl,
    required this.onTap,
  });

  final List<String> items;
  final int selected;
  final String message;
  final String playlistUrl;
  final String epgUrl;
  final void Function(int) onTap;

  @override
  Widget build(BuildContext context) => Stack(
        children: [
          const Positioned.fill(child: ColoredBox(color: Color(0xBF000000))),
          Positioned(
            left: 330,
            top: 30,
            width: 1260,
            height: 1020,
            child: Container(
              decoration: BoxDecoration(
                gradient: kBgGradient,
                border: Border.all(color: Pal.frame, width: 4),
              ),
              padding: const EdgeInsets.fromLTRB(40, 20, 40, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const CanvasText('Setup', size: 52, bold: true),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 70,
                    child: CanvasText(message, size: 26, color: Pal.yellow, maxLines: 2),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      child: TvMenuList(items: items, selected: selected, onTap: onTap, itemHeight: 54),
                    ),
                  ),
                  const SizedBox(height: 8),
                  CanvasText('Playlist: ${playlistUrl.isEmpty ? '(not set)' : playlistUrl}',
                      size: 24, color: Pal.paleBlue),
                  const SizedBox(height: 6),
                  CanvasText(
                      'Guide:    ${epgUrl.isEmpty ? '(not set - uses url-tvg from the playlist if present)' : epgUrl}',
                      size: 24,
                      color: Pal.paleBlue),
                  const SizedBox(height: 10),
                  const CanvasText('Up/Down to choose, OK to select, Back to close. Mouse works too.',
                      size: 20, color: Pal.softBlue),
                ],
              ),
            ),
          ),
        ],
      );
}

/// URL entry. Physical keyboards type directly (paste works); TV remotes get
/// the platform's on-screen keyboard.
class TextEntryDialog extends StatefulWidget {
  const TextEntryDialog({
    super.key,
    required this.title,
    required this.initial,
    required this.onSubmit,
    required this.onCancel,
    this.hint = '',
    this.submitLabel = 'Save',
    this.cancelLabel = 'Cancel',
  });

  final String title;
  final String hint;
  final String submitLabel;
  final String cancelLabel;
  final String initial;
  final void Function(String) onSubmit;
  final VoidCallback onCancel;

  @override
  State<TextEntryDialog> createState() => TextEntryDialogState();
}

class TextEntryDialogState extends State<TextEntryDialog> {
  late final TextEditingController _ctl = TextEditingController(text: widget.initial);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void submit() => widget.onSubmit(_ctl.text.trim());

  Widget _button(String label, VoidCallback onTap, {bool primary = false}) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 220,
            height: 64,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: primary ? kCellFocusGradient : kHeaderGradient,
              border: Border.all(color: Pal.frame, width: 2),
            ),
            child: CanvasText(label, size: 32, bold: true),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => Stack(
        children: [
          const Positioned.fill(child: ColoredBox(color: Color(0x99000000))),
          Positioned(
            left: 260,
            top: 290,
            width: 1400,
            height: 400,
            child: Container(
              decoration: BoxDecoration(
                gradient: kBgGradient,
                border: Border.all(color: Pal.yellow, width: 4),
              ),
              padding: const EdgeInsets.all(36),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  CanvasText(widget.title, size: 40, bold: true),
                  const SizedBox(height: 20),
                  Material(
                    color: Colors.white,
                    child: TextField(
                      controller: _ctl,
                      focusNode: _focus,
                      autocorrect: false,
                      enableSuggestions: false,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.done,
                      style: tv(34, color: Pal.ink),
                      cursorColor: Pal.ink,
                      decoration: const InputDecoration(
                        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        border: InputBorder.none,
                        hintText: 'http://...',
                      ),
                      onSubmitted: (_) => submit(),
                    ),
                  ),
                  if (widget.hint.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    CanvasText(widget.hint, size: 24, color: Pal.paleBlue),
                  ],
                  const Spacer(),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      _button('Clear', () => _ctl.clear()),
                      const SizedBox(width: 20),
                      _button(widget.cancelLabel, widget.onCancel),
                      const SizedBox(width: 20),
                      _button(widget.submitLabel, submit, primary: true),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      );
}
