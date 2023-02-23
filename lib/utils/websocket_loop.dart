import 'dart:io';

import '../relay.dart';
import 'package:logging/logging.dart';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

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
    var context = SecurityContext()
      ..useCertificateChain('configs/certs/cert.pem')
      ..usePrivateKey('configs/certs/key.pem');
    _svr = _Service(
        domain: Uri.parse(uri).host,
        port: Uri.parse(uri).port,
        securityContext: context);
    await _svr!.serve();
    _Service.log.info('Server running on $uri');
  }
}

class SimpleWebSocket {
  Function()? onOpen;
  Function(dynamic msg)? onMessage;
  Function(int? code, String? reason)? onClose;
  SimpleWebSocket(String uri) {
    _runSvr(uri);
    _svr!.signaler.uiConn = Connection(send: (data) {
      try {
        onMessage?.call(data);
      } catch (e) {
        onClose?.call(500, e.toString());
      }
    });
  }

  connect() async {
    try {
      onOpen?.call();
    } catch (e) {
      onClose?.call(500, e.toString());
    }
  }

  send(data) {
    _svr!.signaler.onMessageHandler(data);
  }

  close() {
    _svr!.signaler.uiConn = null;
  }
}

class _Service {
  _Service({
    required this.domain,
    required this.port,
    required this.securityContext,
  }) : signaler = Signaler(domain: domain, port: port);

  final String domain;
  final int port;
  final SecurityContext securityContext;
  Connection? uiConn;
  Signaler signaler;
  static final log = Logger('Signaler');

  Handler get handler {
    final router = Router();

    router.post("/inbox", (Request request) async {
      if (uiConn != null) {
        uiConn!.send(await request.readAsString());
      }
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
