import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'api_message.dart';
import 'deployment_api.dart';
// Only the socket, by name: this file speaks dart:io's HttpRequest, and the framework has a port
// of its own under that name. Importing the whole library would shadow one with the other, and
// what the analyzer then reports is a missing getter rather than a collision.
import 'package:ansiwise_core/ansiwise_core.dart' show ChannelServerSocket, ChannelSocket;

/// Serves the REST surface over one channel, and returns when the channel closes.
///
/// This is the only place in the package that knows the API is reached over HTTP at all. Everything
/// above it takes an [ApiRequest] and answers with an [ApiResponse]; this turns one into the other
/// and writes the bytes.
///
/// Nothing listens. `HttpServer.listenOn` is given a [ChannelServerSocket] holding the session's own
/// standard input and output, so there is no port to open, nothing to authenticate a second time,
/// and no process left when the session ends.
final class ChannelHttpServer {
  /// Serves [api] over the bytes of [incoming] and [outgoing].
  const ChannelHttpServer(this.api, {required this.incoming, required this.outgoing});

  /// What answers the requests.
  final DeploymentApi api;

  /// The channel's standard input.
  final Stream<List<int>> incoming;

  /// The channel's standard output.
  final StreamSink<List<int>> outgoing;

  /// Answers requests until the channel closes.
  Future<void> serve() async {
    final HttpServer server = HttpServer.listenOn(
      ChannelServerSocket(ChannelSocket(incoming: incoming, outgoing: outgoing)),
    );
    await for (final HttpRequest request in server) {
      await _answer(request);
    }
  }

  Future<void> _answer(HttpRequest request) async {
    final ApiResponse answer = await api.call(
      ApiRequest(request.method, request.uri, body: await utf8.decoder.bind(request).join()),
    );

    switch (answer) {
      case Answered(:final int status, :final Object payload):
        request.response
          ..statusCode = status
          ..headers.contentType = ContentType.json;
        request.response.write(jsonEncode(payload));

      case Refused(:final int status, :final String reason):
        request.response
          ..statusCode = status
          ..headers.contentType = ContentType.json;
        request.response.write(jsonEncode(<String, Object?>{'refused': reason}));

      case Streaming(:final Stream<Object> items):
        // One JSON object per line, flushed as it arrives. `transfer-encoding: chunked` comes out
        // of dart:io by itself once the length is unknown, so a run being watched reaches the
        // client as it happens rather than when it ends — which for a deployment is an hour later.
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType('application', 'x-ndjson', charset: 'utf-8');
        await for (final Object item in items) {
          request.response.writeln(jsonEncode(item));
          await request.response.flush();
        }
    }

    await request.response.close();
  }
}
