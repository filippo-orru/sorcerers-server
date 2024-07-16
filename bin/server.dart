import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';

final websocketHandler = webSocketHandler((webSocket) {
  Stream stream = webSocket.stream;
  Sink sink = webSocket.sink;
  stream.listen((message) async {
    sink.add('echo $message');
    await Future.delayed(Duration(milliseconds: 500));
    sink.add('echo $message 2');
  });
});

// Configure routes.
final _router = Router()
  ..get('/', _rootHandler)
  ..get('/ws', (Request request) => websocketHandler(request));

Response _rootHandler(Request req) {
  return Response.ok('Hello!\n');
}

void main(List<String> args) async {
  // Use any available host or container IP (usually `0.0.0.0`).
  final ip = InternetAddress.anyIPv4;

  // Configure a pipeline that logs requests.
  final handler = Pipeline().addMiddleware(logRequests()).addHandler(_router.call);

  // For running in containers, we respect the PORT environment variable.
  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final server = await serve(handler, ip, port);
  print('Server listening on port ${server.port}');
}
