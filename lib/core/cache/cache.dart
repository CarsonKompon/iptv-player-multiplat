// Small file cache. No-op on web.
export 'cache_stub.dart' if (dart.library.io) 'cache_io.dart';
