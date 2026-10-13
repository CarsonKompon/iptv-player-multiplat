import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'app.dart';
import 'core/settings.dart';
import 'platform/platform.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await initWindow();
  try {
    await WakelockPlus.enable();
  } catch (_) {}
  try {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  } catch (_) {}
  // The video output mode has to be chosen before the player is created.
  var hwAccel = AppSettings.hwAccelDefault;
  try {
    hwAccel = (await SharedPreferences.getInstance()).getBool(AppSettings.hwAccelKey) ?? hwAccel;
  } catch (_) {}
  runApp(IptvApp(hwAccel: hwAccel));
}
