import 'dart:io';

import 'package:path_provider/path_provider.dart';

Future<File> _file(String name) async {
  final dir = await getApplicationSupportDirectory();
  return File('${dir.path}${Platform.pathSeparator}$name');
}

Future<String?> readCache(String name) async {
  try {
    final f = await _file(name);
    if (await f.exists()) return await f.readAsString();
  } catch (_) {}
  return null;
}

Future<void> writeCache(String name, String data) async {
  try {
    final f = await _file(name);
    await f.parent.create(recursive: true);
    await f.writeAsString(data, flush: true);
  } catch (_) {}
}
