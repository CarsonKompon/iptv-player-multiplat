import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

bool get isDesktop => Platform.isWindows || Platform.isMacOS || Platform.isLinux;
bool get isAndroid => Platform.isAndroid;
bool get canExit => true;

/// mpv plays raw MPEG-TS fine, so no rewriting needed on native platforms.
bool get prefersHlsRewrite => false;

Future<void> initWindow() async {
  if (!isDesktop) return;
  try {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        title: 'IPTV Guide',
        size: Size(1280, 720),
        minimumSize: Size(640, 360),
        center: true,
        backgroundColor: Color(0xFF000000),
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  } catch (_) {}
}

Future<void> toggleFullscreen() async {
  if (!isDesktop) return;
  try {
    final fs = await windowManager.isFullScreen();
    await windowManager.setFullScreen(!fs);
  } catch (_) {}
}

void exitApp() {
  if (Platform.isAndroid) {
    SystemNavigator.pop();
  } else {
    exit(0);
  }
}
