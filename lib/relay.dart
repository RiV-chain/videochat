import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'dart:convert';
import 'dart:io';

class Connection {
  final Function(String data) send;
  Connection({required this.send});
}

class Signaler {
  Connection? uiConn;
  final String domain;
  final int port;
  Signaler({required this.domain, required this.port});

  static final log = Logger('Signaler');

  forward(Map<String, dynamic> js, String message) async {
    try {
      var to = js['to'];
      if (domain == to) {
        throw Exception("Sending to myself");
      }
      var uri = Uri.parse("https://[$to]:$port/inbox");
      var resp = await http.post(uri, body: message, headers: {
        'Content-Type': 'application/json; charset=utf-8',
      });
      if (resp.statusCode != 204) {
        throw HttpException(
            "Unexpected HTTP response ${resp.statusCode} ${resp.reasonPhrase}",
            uri: uri);
      }
    } catch (e) {
      if (uiConn != null) {
        send(uiConn!, 'error', js['eventId'],
            {"message": e.toString(), "request": message});
      }
    }
  }

  void onMessageHandler(String message) {
    //log.fine('ui recv: $message');
    var js = json.decode(message);
    var type = js['type'];
    var data = js['data'];

    switch (type) {
      case 'httpget':
        httpGet(js['eventId'], data);
        break;
      default:
        if (js["to"] != null) {
          forward(js, message);
          return;
        }
        log.warning("Unkown request $js");
        break;
    }
  }

  httpGet(eventId, Map<String, dynamic> data) async {
    try {
      Map<String, String> reqHeaders = ((data["headers"] ?? {}) as Map)
          .map<String, String>(
              (key, value) => MapEntry<String, String>(key, value));
      final response =
          await http.get(Uri.parse(data["address"]), headers: reqHeaders);
      send(uiConn!, 'success', eventId, {
        "body": response.body,
        "statusCode": response.statusCode,
        "headers": response.headers
      });
    } catch (e) {
      send(uiConn!, 'error', eventId,
          {"message": e.toString(), "request": data});
    }
  }

  static send(Connection conn, event, int? eventId, data) {
    var request = {};
    if (eventId != null) {
      request["eventId"] = eventId;
    }
    request["type"] = event;
    request["data"] = data;

    var str = json.encode(request);
    //log.fine('send: $str');
    conn.send(str);
  }
}
