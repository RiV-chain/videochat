import 'dart:io';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../relay.dart';
import '../defaults.dart';
import 'package:logging/logging.dart';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

Future<String> _getSelfAddr() async {
  final response =
      await http.get(Uri.parse("${Defaults.meshEndpoint}/api/self"));
  if (response.statusCode != 200) {
    Logger("").severe('GET /api/self failed: ${response.reasonPhrase}');
    return 'localhost';
  }
  final Map<String, dynamic> self = json.decode(response.body);
  return "[" + self["address"] + "]";
}

class SimpleWebSocket {
  String uri;
  Function()? onOpen;
  Function(dynamic msg)? onMessage;
  Function(int? code, String? reason)? onClose;
  SimpleWebSocket(this.uri);

  connect() async {
    uri = "https://" + await _getSelfAddr() + ":${Defaults.signallingPort}";
    await _runSvr(uri);
    _svr!.signaler.uiConn = Connection(send: (data) {
      try {
        _Service.log.finest('recv: $data');
        onMessage?.call(data);
      } catch (e) {
        onClose?.call(500, e.toString());
      }
    });
    try {
      onOpen?.call();
    } catch (e) {
      onClose?.call(500, e.toString());
    }
  }

  send(data) {
    _Service.log.finest('send: $data');
    _svr!.signaler.onMessageHandler(data);
  }

  close() {
    _svr!.signaler.uiConn = null;
  }
}

class MyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
  }
}

_runSvr(String uri) async {
  if (_svr == null) {
    HttpOverrides.global = MyHttpOverrides();
    final SecurityContext context = SecurityContext.defaultContext;

    final ByteData certificateChainBytes =
        await rootBundle.load(Defaults.tlsCertFn);
    context
        .useCertificateChainBytes(certificateChainBytes.buffer.asUint8List());

    final ByteData keyBytes = await rootBundle.load(Defaults.tlsKeyFn);
    context.usePrivateKeyBytes(keyBytes.buffer.asUint8List());
    _svr = _Service(
        domain: Uri.parse(uri).host,
        port: Uri.parse(uri).port,
        securityContext: context);
    await _svr!.serve();
    _Service.log.info('Server running on $uri');
  }
}

class _Service {
  _Service({
    required this.domain,
    required this.port,
    required this.securityContext,
  }) : signaler =
            Signaler(domain: domain, port: port, mesh: Defaults.meshEndpoint);

  final String domain;
  final int port;
  final SecurityContext securityContext;
  Signaler signaler;
  static final log = Logger('Signaler');

  Handler get handler {
    final router = Router();

    router.post("/inbox", (Request request) async {
      signaler.uiConn?.send(await request.readAsString());
      return Response(204);
    });

    return router;
  }

  Future<HttpServer> serve() async {
    return shelf_io.serve(handler, domain, port,
        securityContext: securityContext);
  }
}

_Service? _svr;
