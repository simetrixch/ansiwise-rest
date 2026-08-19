import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:ansiwise_rest/ansiwise_rest.dart';
import 'package:test/test.dart';

import '../support/example_steps.dart';
import '../support/harness.dart';
import 'doubles.dart';

/// The listening form, and what makes it safe to leave standing.
///
/// A resident service is one process answering everyone, and its worst caller is its longest one: a
/// run being watched is a single response held open for the length of the run. What is proved here
/// is that such a response blocks nobody — a second request is answered WHILE the stream is open —
/// and that a caller who dies mid-answer takes only their own response with them, not the server
/// and not anyone else's answer. Neither can be proved over the channel form, whose one session is
/// one connection; these tests dial the same surface twice, which is exactly what a manager and an
/// operator do to the same machine.
/// The credential every caller on an address presents here. A test that served open would prove
/// nothing about the door this suite is measuring.
const String testTokenValue = 'a-token-for-the-tests';

/// How a line of a hand-built request ends on the wire.
const String crlf = '\r\n';
final ServiceToken testToken = ServiceToken(testTokenValue);

void main() {
  /// The same one-program surface the channel tests serve, over whichever store a test brings.
  DeploymentApi apiOver(RunStore store) {
    final ResolvedProgram program =
        ProgramResolver(
          registryOf(
            steps: <String, (String, Step Function(Arguments))>{
              'writes_a_file': ('x:1', (Arguments a) => WritesAFile(path: '/x', content: 'x')),
            },
          ),
        ).resolve(
          programOf('deploy-host', <(String, OnFailure, List<String>)>[
            ('writes_a_file', OnFailure.exit, <String>[]),
          ]),
        );
    final FixedCatalogue catalogue = FixedCatalogue(<ResolvedProgram>[program]);
    return DeploymentApi(
      programs: ProgramsEndpoint(catalogue),
      runs: RunsEndpoint(
        store: store,
        launcher: RecordingLauncher(),
        catalogue: catalogue,
        gate: Gate(store),
        json: const PlainRecordJson(),
        commit: () async => 'abc1234',
      ),
      events: EventsEndpoint(store: store, json: const PlainRecordJson()),
    );
  }

  /// Binds the surface on a loopback port the operating system picks.
  Future<(HttpServer, Future<void>)> listening(DeploymentApi api) async {
    final Completer<HttpServer> bound = Completer<HttpServer>();
    final Future<void> serving = ListeningHttpServer(
      api,
      address: '127.0.0.1:0',
      token: testToken,
    ).serve(onBound: bound.complete);
    return (await bound.future, serving);
  }

  /// One full GET against the bound server, returned as (status, body).
  Future<(int, String)> get(int port, String path) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest ask = await client.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
      // Presented on every request, because the address door demands it. A suite that served open
      // would be measuring a surface nobody will run.
      ask.headers.set(HttpHeaders.authorizationHeader, 'Bearer $testTokenValue');
      final HttpClientResponse answer = await ask.close().timeout(const Duration(seconds: 10));
      return (answer.statusCode, await utf8.decodeStream(answer));
    } finally {
      client.close(force: true);
    }
  }

  /// A watcher's request, written by hand so the response can be read while it is still open — and
  /// carrying the credential, because the address door demands one of every caller alike.
  const String rawWatch =
      'GET /runs/r1/events HTTP/1.1'
      '${crlf}Host: m'
      '${crlf}Authorization: Bearer $testTokenValue'
      '$crlf$crlf';

  Log event(int sequence) => Log(
    sequence: sequence,
    at: DateTime.utc(2026, 8, 7),
    step: const StepName('writes_a_file'),
    level: LogLevel.info,
    message: 'line $sequence',
  );

  test('a second request is answered while a streaming response is still open', () async {
    final HeldOpenStore store = HeldOpenStore(
      runRecord(id: 'r1', program: 'deploy-host', mode: Mode.dry, fingerprint: 'f', exitCode: 0),
    );
    final (HttpServer server, Future<void> serving) = await listening(apiOver(store));

    // The watcher, dialled raw so the response can be read byte by byte while it is still open.
    final Socket watcher = await Socket.connect('127.0.0.1', server.port);
    final StringBuffer seen = StringBuffer();
    final StreamSubscription<List<int>> reading = watcher.listen(
      (List<int> bytes) => seen.write(utf8.decode(bytes)),
    );
    watcher.write(rawWatch);
    await watcher.flush();

    store.feed.add(event(0));
    while (!seen.toString().contains('"sequence":0')) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    // The stream is open and mid-answer. This is the moment the old sequential loop spent blocked,
    // and the request below is the `GET /runs/{id}`-shaped call a manager makes to re-attach.
    final (int status, String body) = await get(server.port, '/programs');
    expect(status, 200);
    expect(body, contains('deploy-host'));
    expect(
      store.feed.hasListener,
      isTrue,
      reason: 'the streaming response must still have been open when the second was answered',
    );

    await store.feed.close();
    await reading.cancel();
    watcher.destroy();
    await server.close(force: true);
    await serving;
  });

  test('a caller killed mid-stream takes neither the server nor another answer with it', () async {
    final HeldOpenStore store = HeldOpenStore(
      runRecord(id: 'r1', program: 'deploy-host', mode: Mode.dry, fingerprint: 'f', exitCode: 0),
    );
    final (HttpServer server, Future<void> serving) = await listening(apiOver(store));

    final Socket watcher = await Socket.connect('127.0.0.1', server.port);
    final StringBuffer seen = StringBuffer();
    final StreamSubscription<List<int>> reading = watcher.listen(
      (List<int> bytes) => seen.write(utf8.decode(bytes)),
      onError: (Object _) {},
    );
    watcher.write(rawWatch);
    await watcher.flush();
    store.feed.add(event(0));
    while (!seen.toString().contains('"sequence":0')) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    // The caller dies mid-answer, and the run keeps happening: every one of these events is
    // written into the dead connection. Whether the operating system reports that at all is its
    // own affair — what must hold either way is that nothing of it reaches anyone else.
    await reading.cancel();
    watcher.destroy();
    for (int sequence = 1; sequence <= 20; sequence++) {
      store.feed.add(event(sequence));
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    final (int status, String body) = await get(server.port, '/programs');
    expect(status, 200, reason: 'one dead caller must not cost anyone else their answer');
    expect(body, contains('deploy-host'));

    await store.feed.close();
    await server.close(force: true);
    // Had a write into the dead connection escaped anywhere, it would surface here as this
    // future's error and rightly fail the test.
    await serving;
  });

  test('a response whose own event stream dies is abandoned without taking the server', () async {
    final HeldOpenStore store = HeldOpenStore(
      runRecord(id: 'r1', program: 'deploy-host', mode: Mode.dry, fingerprint: 'f', exitCode: 0),
    );
    final (HttpServer server, Future<void> serving) = await listening(apiOver(store));

    final Socket watcher = await Socket.connect('127.0.0.1', server.port);
    final StringBuffer seen = StringBuffer();
    final StreamSubscription<List<int>> reading = watcher.listen(
      (List<int> bytes) => seen.write(utf8.decode(bytes)),
      onError: (Object _) {},
    );
    watcher.write(rawWatch);
    await watcher.flush();
    store.feed.add(event(0));
    while (!seen.toString().contains('"sequence":0')) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    // The stream of events itself fails mid-response — a record that went away under the reader.
    // This is the deterministic half of "one response dies": unlike a killed connection, whose
    // reporting is the operating system's mood, this error arrives on every platform, and without
    // the guard around each answer it would be an unhandled asynchronous error ending the process.
    store.feed.addError(StateError('the record went away mid-read'));

    final (int status, String body) = await get(server.port, '/programs');
    expect(status, 200, reason: 'one dead response must not cost anyone else their answer');
    expect(body, contains('deploy-host'));

    await reading.cancel();
    watcher.destroy();
    await server.close(force: true);
    await serving;
  });

  group('an address that leaves the decision to this code is refused', () {
    Future<void> refused(String address, {required Pattern naming}) => expectLater(
      ListeningHttpServer(apiOver(MemoryRunStore()), address: address, token: testToken).serve(),
      throwsA(
        isA<FormatException>().having(
          (FormatException e) => e.message,
          'message',
          contains(naming),
        ),
      ),
    );

    test('a bare port, because the host would be a default nobody chose', () async {
      await refused(':9953', naming: 'host:port');
    });

    test('a word with no port at all', () async {
      await refused('nonsense', naming: 'host:port');
    });

    test('an IPv6 literal without brackets, whose port cannot be told apart', () async {
      await refused('::1:9953', naming: 'brackets');
    });

    test('unix: with no path behind it', () async {
      await refused('unix:', naming: 'names no path');
    });
  });
}

/// A store holding one run whose event stream is fed by the test.
final class HeldOpenStore implements RunStore {
  /// Holds [run] as the only run there is.
  HeldOpenStore(this.run);

  /// The one run everything asks about.
  final RunRecord run;

  /// Where the test pushes events from, standing in for a run that is still happening.
  final StreamController<RunEvent> feed = StreamController<RunEvent>();

  @override
  Stream<RunEvent> events(RunId id, {int from = 0}) => feed.stream;

  @override
  Future<List<RunRecord>> list({ProgramName? program, Mode? mode, int limit = 50}) async =>
      <RunRecord>[run];

  @override
  Future<RunRecord?> read(RunId id) async => run;

  @override
  Future<RunRecord?> lastCleanDryRun({
    required ProgramName program,
    required String fingerprint,
  }) async => null;
}
