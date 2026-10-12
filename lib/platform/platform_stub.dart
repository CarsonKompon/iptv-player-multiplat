bool get isDesktop => false;
bool get isAndroid => false;
bool get canExit => false;

/// Web reports raw MPEG-TS as unsupported, so .ts links get rewritten to HLS.
bool get prefersHlsRewrite => true;

Future<void> initWindow() async {}

Future<void> toggleFullscreen() async {}

void exitApp() {}
