// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as HTML;

class DeviceInfo {
  static String get userAgent {
    return 'flutter-webrtc/web-plugin 0.0.1 ' +
        ' ( ' +
        HTML.window.navigator.userAgent +
        ' )';
  }

  static String get domain {
    return HTML.window.location.hostname!;
  }

  static String get signalingLocation {
    return "https://${HTML.window.location.hostname}:8086";
  }
}
