import 'dart:io';
import 'dart:convert';
import 'dart:async' show Future;
import 'package:coriv/relay.dart';
import 'package:logging/logging.dart';
import "package:ini/ini.dart";
import "package:coriv/defaults.dart";

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:shelf_static/shelf_static.dart' as shelf_static;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:http/http.dart' as http;

class MyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
  }
}

void main(List<String> arguments) async {
  /// DELME disable HTTPS host certificate verification
  HttpOverrides.global = MyHttpOverrides();
  Logger.root.level = Level.ALL; // defaults to Level.INFO
  Logger.root.onRecord.listen((record) {
    print(
        '${record.time}: ${record.level.name}: ${record.loggerName}: ${record.message}');
  });
  var configFn = "configs/config.ini";
  if (arguments.isNotEmpty) {
    configFn = arguments[0];
  }
  Config config = Config.fromStrings(File(configFn).readAsLinesSync());
  var mesh = config.get("general", "mesh") ?? Defaults.meshEndpoint;
  String? domain = config.get("general", "domain");
  if (domain == null) {
    final response = await http.get(Uri.parse("$mesh/api/self"));
    if (response.statusCode != 200) {
      Logger("").severe('GET /api/self failed: ${response.reasonPhrase}');
      throw Exception('GET /api/self failed: ${response.reasonPhrase}');
    }
    final Map<String, dynamic> self = json.decode(response.body);
    domain = "[" + self["address"] + "]";
  }
  int port = int.parse(
      config.get("general", "port") ?? Defaults.signallingPort.toString());
  var chain = config.get("general", "cert") ?? Defaults.tlsCertFn;
  var key = config.get("general", "key") ?? Defaults.tlsKeyFn;

  var context = SecurityContext()
    ..useCertificateChain(chain)
    ..usePrivateKey(key);

  var htmlRoot = config.get("general", "html_root") ?? "web";

  final service = Service(
      domain: domain,
      port: port,
      securityContext: context,
      htmlRoot: htmlRoot,
      mesh: mesh);
  HttpServer svr = await service.serve();
  service.ip = svr.address;
  Logger('Main').info('Server is running on https://$domain:$port');
}

class Service {
  Service({
    required this.domain,
    required this.port,
    required this.securityContext,
    required this.htmlRoot,
    required this.mesh,
  }) : signaler = Signaler(domain: domain, port: port, mesh: mesh);

  final String htmlRoot;
  final String domain;
  final int port;
  final String mesh;
  final SecurityContext securityContext;
  InternetAddress? ip;
  Connection? uiConn;
  Signaler signaler;
  Handler? wssHandler;
  static final log = Logger('Signaler');

  // The [Router] can be used to create a handler, which can be used with
  // [shelf_io.serve].
  Handler get handler {
    final router = Router();

    wssHandler = webSocketHandler(
      (WebSocketChannel webSocket) async {
        uiConn = Connection(send: webSocket.sink.add);
        signaler.uiConn = uiConn;
        webSocket.stream.listen((message) {
          signaler.onMessageHandler(message);
        }, onDone: () {
          log.severe("Web socket closed");
          uiConn = null;
//          signaler.onCloseHandler(conn);
        }, onError: (e) {
          log.severe("Web socket error $e");
          uiConn = null;
//          signaler.onCloseHandler(conn);
        });
      },
//        allowedOrigins: ["https://$domain:$port"],
//        pingInterval: Duration(seconds: 2)
    );

    router.get("/ws", (Request request) {
      if (uiConn != null) {
        return Response(403);
      }
      var lastRequestClientAddress =
          (request.context["shelf.io.connection_info"] as HttpConnectionInfo)
              .remoteAddress;
      if (lastRequestClientAddress != ip) {
        log.warning(
            "Access attempt from ${lastRequestClientAddress.address} to ${ip!.address}");
//        return Response(409);
      }
      return wssHandler!(request);
    });

    router.post("/inbox", (Request request) async {
      if (uiConn != null) {
        uiConn!.send(await request.readAsString());
      }
      return Response(204);
    });

    return Pipeline().addMiddleware(logRequests()).addHandler(Cascade()
        .add(router)
        .add(shelf_static.createStaticHandler(htmlRoot,
            defaultDocument: 'index.html'))
        .handler);
  }

  Future<HttpServer> serve() async {
    return shelf_io.serve(handler, domain, port,
        securityContext: securityContext);
  }
}
