import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:ansiwise_rest/ansiwise_rest.dart';
import 'package:test/test.dart';

import 'doubles.dart';

/// Replacing the service token of a machine that keeps answering the whole time.
///
/// The two things the surface could not do before are proved here against a bound socket, because
/// that is the only place the claim means anything: the service is never restarted, never
/// reconstructed, and never told anything — the token file is written under it exactly as an
/// operator would write it, and the next request is answered from what the file says now.
///
///  * NO WINDOW. Every request in the sequence below is made with the token the manager holds at
///    that moment, and every one of them is answered. There is no point at which the machine is
///    unreachable, including the instant the new token is placed and the instant the old one is
///    retired.
///  * THE OLD TOKEN DIES WHEN SOMEBODY SAYS SO. Placing the new token does not retire the old one:
///    it keeps working until its line is deleted, which is a second act at a time of the operator's
///    choosing.
void main() {
  const String oldToken = 'the-token-placed-at-installation';
  const String newToken = 'the-token-being-moved-to';

  late Directory home;
  late String tokenPath;
  late HttpServer bound;
  late Future<void> serving;

  /// The smallest surface that answers something: `GET /programs` over an empty catalogue.
  DeploymentApi api() => DeploymentApi(
    programs: ProgramsEndpoint(FixedCatalogue(<ResolvedProgram>[])),
    runs: RunsEndpoint(
      store: MemoryRunStore(),
      launcher: RecordingLauncher(),
      catalogue: FixedCatalogue(<ResolvedProgram>[]),
      gate: Gate(MemoryRunStore()),
      json: const PlainRecordJson(),
      commit: () async => 'abc1234',
    ),
    events: EventsEndpoint(store: MemoryRunStore(), json: const PlainRecordJson()),
  );

  /// Writes the token file the way an operator does: the whole file, every accepted token in it.
  void place(List<String> accepted) =>
      File(tokenPath).writeAsStringSync('${accepted.join('\n')}\n', flush: true);

  /// What the surface answers a caller presenting [token], as a status code.
  Future<int> asks(String token) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest ask = await client.getUrl(
        Uri.parse('http://127.0.0.1:${bound.port}/programs'),
      );
      ask.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final HttpClientResponse answer = await ask.close().timeout(const Duration(seconds: 10));
      await utf8.decodeStream(answer);
      return answer.statusCode;
    } finally {
      client.close(force: true);
    }
  }

  setUp(() async {
    home = Directory.systemTemp.createTempSync('token-rotation-test');
    tokenPath = '${home.path}${Platform.pathSeparator}token';
    place(<String>[oldToken]);
    final Completer<HttpServer> standing = Completer<HttpServer>();
    serving = ListeningHttpServer(
      api(),
      address: '127.0.0.1:0',
      tokens: ServiceTokenFile(tokenPath),
    ).serve(onBound: standing.complete);
    bound = await standing.future;
  });

  tearDown(() async {
    await bound.close(force: true);
    await serving;
    home.deleteSync(recursive: true);
  });

  test('a running installation is moved to a new token without ever being unreachable', () async {
    expect(await asks(oldToken), 200, reason: 'the placed token reaches the machine');
    expect(await asks(newToken), 401, reason: 'a token nobody placed reaches nothing');

    // 1. The new token is placed BESIDE the old one. Nothing is restarted and nothing is told.
    place(<String>[oldToken, newToken]);
    expect(
      await asks(oldToken),
      200,
      reason: 'the manager still holding the old token has not lost the machine',
    );
    expect(
      await asks(newToken),
      200,
      reason: 'the new token works at once — a restart here would be the window',
    );

    // 2. The manager moves to the new token. This request is the proof, and it is available while
    //    the old token still works, which is what makes step 3 safe to take.
    expect(await asks(newToken), 200);

    // 3. The old token is retired, at a moment somebody chose.
    place(<String>[newToken]);
    expect(await asks(newToken), 200, reason: 'the machine is reachable across the retirement');
    expect(await asks(oldToken), 401, reason: 'the retired token stops working');
  });

  test('placing the new token is not what retires the old one', () async {
    place(<String>[oldToken, newToken]);
    for (int request = 0; request < 5; request++) {
      expect(
        await asks(oldToken),
        200,
        reason: 'the old token is retired by deleting its line, by nothing else and by no clock',
      );
    }
  });

  test('the file being rewritten under the service refuses nobody', () async {
    // What a truncating writer leaves behind for an instant, met head on: the file is empty at the
    // moment the request arrives, and the set that was read last still decides.
    File(tokenPath).writeAsStringSync('', flush: true);
    expect(await asks(oldToken), 200);

    place(<String>[oldToken, newToken]);
    expect(
      await asks(newToken),
      200,
      reason: 'and the finished write is picked up as it always is',
    );
  });

  test('a caller holding neither token is refused in the same words either way', () async {
    final String withOne = await refusalFor(bound.port, 'not-a-token');
    place(<String>[oldToken, newToken]);
    final String withTwo = await refusalFor(bound.port, 'not-a-token');
    expect(
      withTwo,
      withOne,
      reason: 'a refusal may not say that this machine is in the middle of a replacement',
    );
  });
}

/// The body of the refusal the surface gives a caller presenting [token] on [port].
Future<String> refusalFor(int port, String token) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest ask = await client.getUrl(Uri.parse('http://127.0.0.1:$port/programs'));
    ask.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    final HttpClientResponse answer = await ask.close().timeout(const Duration(seconds: 10));
    return '${answer.statusCode} ${await utf8.decodeStream(answer)}';
  } finally {
    client.close(force: true);
  }
}
