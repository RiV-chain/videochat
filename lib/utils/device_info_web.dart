// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as HTML;

class DeviceInfo {
  static String get label {
    return HTML.window.location.hostname!;
  }

  static String get userAgent {
    return 'flutter-webrtc/web-plugin 0.0.1 ' +
        ' ( ' +
        HTML.window.navigator.userAgent +
        ' )';
  }

  static String get origin {
    return HTML.window.location.origin;
  }

  static String get domain {
    return HTML.window.location.hostname!;
  }

  static String get signalingLocation {
    return "https://${HTML.window.location.hostname}:8086/ws";
  }
}
