import 'package:flutter_webrtc/flutter_webrtc.dart';

class StatsReportUtil {
  int lastBytesReceivedVideo = 0;
  int lastBytesSentVideo = 0;
  int lastBytesReceivedAudio = 0;
  int lastBytesSentAudio = 0;
  int lastFrameDecoded = 0;
  String value = "";

  void updateStatsReport(List<StatsReport> report) {
    String? codecIdVideo;
    String? codecIdAudio;
    String codecVideo = "";
    String codecAudio = "";
    int receivedBytesSRVideo = 0;
    int sentBytesSRVideo = 0;
    int receivedBytesSRAudio = 0;
    int sentBytesSRAudio = 0;
    int width = 0;
    int height = 0;
    int frameRate = 0;

    for (var stats in report) {
      if (stats.type == "inbound-rtp") {
        var members = stats.values;
        if (members["mediaType"] == "video") {
          codecIdVideo = members["codecId"];
          var bytes = members["bytesReceived"];
          receivedBytesSRVideo = bytes - lastBytesReceivedVideo;
          lastBytesReceivedVideo = bytes;
          var currentFrame = members["framesDecoded"];
          var lastFrame = lastFrameDecoded;
          frameRate =
              ((currentFrame - lastFrame) * 1000 / STATS_INTERVAL_MS).round();
          lastFrameDecoded = currentFrame;
        }
        if (members["mediaType"] == "audio") {
          codecIdAudio = members["codecId"];
          var bytes = members["bytesReceived"];
          receivedBytesSRAudio = bytes - lastBytesReceivedAudio;
          lastBytesReceivedAudio = bytes;
        }
      }
      if (stats.type == "outbound-rtp") {
        var members = stats.values;
        if (members["mediaType"] == "video") {
          var bytes = members["bytesSent"];
          sentBytesSRVideo = bytes - lastBytesSentVideo;
          lastBytesSentVideo = bytes;
        }
        if (members["mediaType"] == "audio") {
          var bytes = members["bytesSent"];
          sentBytesSRAudio = bytes - lastBytesSentAudio;
          lastBytesSentAudio = bytes;
        }
      }
      if (stats.type == "track") {
        var members = stats.values;
        if (members["kind"] == "video") {
          width = members["frameWidth"] ?? 0;
          height = members["frameHeight"] ?? 0;
        }
      }
    }
    for (var stats in report) {
      if (stats.id == codecIdVideo) {
        codecVideo = stats.values["mimeType"];
      }
      if (stats.id == codecIdAudio) {
        codecAudio = stats.values["mimeType"];
      }
    }
    value = """Codecs: $codecVideo $codecAudio
Resolution: ${width}x$height
Bitrate ⎚ ↓: ${receivedBytesSRVideo * 8 / STATS_INTERVAL_MS}kbps
Bitrate ⎚ ↑: ${sentBytesSRVideo * 8 / STATS_INTERVAL_MS}kbps
Bitrate 🔊 ↓: ${receivedBytesSRAudio * 8 / STATS_INTERVAL_MS}kbps
Bitrate 🔊 ↑: ${sentBytesSRAudio * 8 / STATS_INTERVAL_MS}kbps
FrameRate: $frameRate""";
  }

  static const int STATS_INTERVAL_MS = 5000;
}
