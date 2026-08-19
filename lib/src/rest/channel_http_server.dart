import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'api_message.dart';
import 'service_token.dart';
import 'service_token_gate.dart';
import 'deployment_api.dart';
// Only the socket, by name: this file speaks dart:io's HttpRequest, and the framework has a port
// of its own under that name. Importing the whole library would shadow one with the other, and
// what the analyzer then reports is a missing getter rather than a collision.
import 'package:ansiwise_core/ansiwise_core.dart' show ChannelServerSocket, ChannelSocket;

/// Serves the REST surface over one channel, and returns when the channel closes.
///
/// This is one of the two places in the package that know the API is reached over HTTP at all — the
/// other is [ListeningHttpServer], which serves the same surface on an address. Everything above
/// them takes an [ApiRequest] and answers with an [ApiResponse]; this turns one into the other and
/// writes the bytes.
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

  /// Answers requests until the channel closes, and returns once every answer still in flight has
  /// been written.
  Future<void> serve() async {
    final HttpServer server = HttpServer.listenOn(
      ChannelServerSocket(ChannelSocket(incoming: incoming, outgoing: outgoing)),
    );
    // NO TOKEN AT THIS DOOR, and it is the composition that says so rather than a flag: sshd is the
    // whole authentication of a session, and a surface that demanded a token here could not be
    // reached on a machine that has none yet — which is every machine at its first installation.
    await _answerAll(server, (ApiRequest request, String? _) => api.call(request));
  }
}

/// Serves the same surface on an address, for callers that do not open a session.
///
/// This is the resident form. [ChannelHttpServer] serves one caller for the life of one session; a
/// machine that has been installed also runs the surface as a service on an address, so a manager
/// can start a run, crash, and come back to `GET /runs/{id}` without anyone holding an SSH session
/// open the whole time.
///
/// **The channel form is not replaced by this, and cannot be.** The first installation of a machine
/// happens before any service exists to listen: the operator app opens an SSH session, starts
/// `serve` inside it, and speaks HTTP over the session's own pipes — no port to have been opened,
/// no service to have been installed first. That path stays exactly as it is, and this one is what
/// an installed machine offers beside it.
///
/// **The address is an argument, never a constant.** Whether the surface stands on loopback behind
/// a tunnel, on a private interface, or on a public one is a fact of an installation's network, not
/// of this code — so there is no default to fall back to, because a default host would be this code
/// deciding who can reach a machine's deployment surface.
///
/// Two shapes are accepted:
///  * `host:port` — a TCP endpoint. The host may be a name, an IPv4 literal, or an IPv6 literal in
///    brackets (`[::1]:9953`), and it is required: a bare port would need a default host, and
///    `0.0.0.0` against `127.0.0.1` is exactly the decision that is not made here.
///  * `unix:<path>` — a Unix domain socket at that path, for installations that would rather guard
///    the surface with file permissions than with a port. The prefix is what keeps a socket path
///    and a host from ever being read as one another.
final class ListeningHttpServer {
  /// Serves [api] on [address], to callers holding [token].
  ///
  /// [token] is required and cannot be null. Nothing here can be configured into serving open: a
  /// door on an address is reached by whoever can reach the address, and the one that decides who
  /// that is has to be impossible to forget.
  const ListeningHttpServer(this.api, {required this.address, required this.token});

  /// What answers the requests.
  final DeploymentApi api;

  /// Where to listen, in one of the two shapes above.
  final String address;

  /// What every caller on this address must present.
  final ServiceToken token;

  /// Binds [address] and answers requests until the server is closed.
  ///
  /// [onBound] is told the bound server once it stands. That is how whoever started this learns
  /// what was actually bound — which matters when the address asked for port `0` and the operating
  /// system chose the real one — and how it is stopped: `HttpServer.close` ends the stream of
  /// requests, and this returns once every answer still in flight has been written.
  ///
  /// Throws [FormatException] when [address] is neither of the accepted shapes, and
  /// [SocketException] when it cannot be bound — both before a single request is read, so a
  /// service with a wrong address fails at start where an operator is looking, not at the first
  /// request when nobody is.
  Future<void> serve({void Function(HttpServer bound)? onBound}) async {
    final HttpServer server = await _bind(address);
    onBound?.call(server);
    final ServiceTokenGate gate = ServiceTokenGate(api.call, token: token);
    await _answerAll(
      server,
      (ApiRequest request, String? presented) => gate.call(request, authorization: presented),
    );
  }
}

/// Binds whichever of the two address shapes [address] holds.
Future<HttpServer> _bind(String address) async {
  if (address.startsWith('unix:')) {
    final String path = address.substring('unix:'.length);
    if (path.isEmpty) {
      throw const FormatException(
        'unix: names no path — a socket file is asked for as unix:/some/path.sock',
      );
    }
    return HttpServer.listenOn(
      await ServerSocket.bind(InternetAddress(path, type: InternetAddressType.unix), 0),
    );
  }

  final int cut = address.lastIndexOf(':');
  final int? port = cut < 0 ? null : int.tryParse(address.substring(cut + 1));
  if (cut < 1 || port == null || port < 0 || port > 65535) {
    throw FormatException(
      '"$address" does not name an address to serve on\n'
      'say host:port — 127.0.0.1:9953, or [::1]:9953 — or unix:<path> for a socket file; the '
      'host is not optional, because which addresses may reach this surface is the '
      "installation's decision",
    );
  }
  String host = address.substring(0, cut);
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.substring(1, host.length - 1);
  } else if (host.contains(':')) {
    throw FormatException('an IPv6 address is written in brackets: [$host]:$port');
  }
  return HttpServer.bind(host, port);
}

/// Answers every request of [server] until its stream of requests ends, and returns once the
/// answers still in flight have been written.
///
/// CONCURRENTLY, and that is load-bearing. A run being watched is one response held open for as
/// long as the run takes — an hour, for a deployment — and a loop that answered one request to the
/// end before reading the next would let that single watcher stop every other caller on the
/// machine, including the `GET /runs/{id}` a manager asks to find a run again after its own
/// restart. So each request is dispatched and the next one read; what orders the answers is how
/// long each takes, and nothing here needs them ordered.
Future<void> _answerAll(HttpServer server, _Answering answering_) async {
  final Set<Future<void>> pending = <Future<void>>{};
  final Completer<void> noMoreRequests = Completer<void>();
  server.listen(
    (HttpRequest request) {
      late final Future<void> answering;
      answering = _answer(answering_, request).whenComplete(() => pending.remove(answering));
      pending.add(answering);
    },
    // A connection that breaks or talks nonsense reports here, and it is that connection's end,
    // not the server's: ending the loop for it would take the surface away from every other
    // caller on the machine for one peer's failure.
    onError: (Object _) {},
    onDone: noMoreRequests.complete,
  );
  await noMoreRequests.future;
  await Future.wait(pending);
}

/// Answers one request, and never throws.
///
/// Never, because the future this returns is not awaited by the dispatch above — an error escaping
/// here would be an unhandled asynchronous error, which ends the process. Two different things are
/// swallowed into that guarantee: an endpoint that throws is answered `500` where the headers have
/// not gone out yet, and a response whose caller vanished mid-write is simply abandoned — its
/// failed write already told the only party that could have cared. Neither disturbs any other
/// response: each request's answer holds no state but its own.
Future<void> _answer(_Answering answering, HttpRequest request) async {
  try {
    final ApiResponse answer = await answering(
      ApiRequest(request.method, request.uri, body: await utf8.decoder.bind(request).join()),
      _credentialIn(request),
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
        //
        // `bufferOutput` is off because `flush` alone does not do what it says here: dart:io holds
        // small writes in an internal buffer that a flush provably leaves a line behind in, so a
        // watcher would see each event only when the next one pushed it out — or at the end, which
        // is the one time it no longer matters. The flush below still earns its keep as
        // backpressure: it completes when the socket accepted the bytes, so a slow reader slows
        // the reading of its own run's events instead of growing an unbounded buffer here.
        request.response
          ..bufferOutput = false
          ..statusCode = 200
          ..headers.contentType = ContentType('application', 'x-ndjson', charset: 'utf-8');

        // How a vanished caller is noticed. A write to a dead socket does not throw here: dart:io
        // swallows it and reports the failure once, through `done` — so a loop that only wrote
        // would follow a run's events into a dead socket for the rest of the run. `done` is
        // watched instead, and the following ends the moment the response is over, whichever way
        // it ended.
        final Completer<void> over = Completer<void>();
        void ended([Object? _, Object? _]) {
          if (!over.isCompleted) {
            over.complete();
          }
        }

        unawaited(request.response.done.then(ended, onError: ended));

        final Completer<void> drained = Completer<void>();
        late final StreamSubscription<Object> following;
        following = items.listen(
          (Object item) {
            request.response.writeln(jsonEncode(item));
            // Backpressure, not delivery: the pause holds the next event back until the socket
            // accepted this one, so a slow reader slows the reading of its own run's events
            // instead of growing an unbounded buffer here. A flush that fails is not the ending —
            // `done` above is — so its error is dropped rather than left unhandled.
            following.pause(request.response.flush().then((void _) {}, onError: (Object _) {}));
          },
          onError: drained.completeError,
          onDone: drained.complete,
        );
        try {
          await Future.any(<Future<void>>[drained.future, over.future]);
        } finally {
          await following.cancel();
        }
    }

    await request.response.close();
  } on Object catch (_) {
    try {
      // Meaningful only while nothing has been written: a caller whose endpoint threw is told the
      // machine failed, not handed an empty 200. Once the headers are out this line throws, and
      // the close below still runs.
      request.response.statusCode = 500;
    } on Object catch (_) {}
    try {
      await request.response.close();
    } on Object catch (_) {}
  }
}

/// What answers one request: the surface, and what the caller presented as its credential.
///
/// A function rather than the surface itself, because the two doors differ in exactly this and in
/// nothing else — one hands the request straight to the API, the other puts a gate in front of it.
typedef _Answering = Future<ApiResponse> Function(ApiRequest request, String? authorization);

/// What [request] presented as its credential, or null where it presented none usable.
///
/// Read as a LIST and refused unless there is exactly one. `HttpHeaders.value` throws when a header
/// arrives twice, and a handler that threw on a duplicated header would be a handler an attacker
/// ends by sending two — so two credentials are no credential, and so is none.
String? _credentialIn(HttpRequest request) {
  final List<String>? presented = request.headers[HttpHeaders.authorizationHeader];
  return presented != null && presented.length == 1 ? presented.single : null;
}
