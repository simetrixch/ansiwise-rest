import 'package:ansiwise_rest/ansiwise_rest.dart';
import 'dart:async';
import 'dart:convert';

import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:test/test.dart';

import '../support/example_steps.dart';
import '../support/harness.dart';
import 'doubles.dart';

/// REST over a channel, with nothing listening.
///
/// The bytes here go through a pair of in-memory pipes rather than an SSH session, and that is the
/// whole point: the server has no idea which it is. What is being proved is that a real
/// `HttpServer` serves over something that is not a socket — which is what lets the client start
/// this inside a session it already has, with no port to open and no second authentication.
void main() {
  DeploymentApi apiWithOneProgram() {
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
    final MemoryRunStore store = MemoryRunStore()
      ..runs.add(
        runRecord(id: 'r1', program: 'deploy-host', mode: Mode.dry, fingerprint: 'f', exitCode: 0),
      );
    store.eventsById['r1'] = <RunEvent>[
      for (int i = 0; i < 3; i++)
        Log(
          sequence: i,
          at: DateTime.utc(2026, 8, 7),
          step: const StepName('writes_a_file'),
          level: LogLevel.info,
          message: 'line $i',
        ),
    ];
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

  /// Sends one raw request down the channel and returns everything that came back.
  Future<String> ask(String request) async {
    final StreamController<List<int>> toServer = StreamController<List<int>>();
    final StreamController<List<int>> fromServer = StreamController<List<int>>();
    final List<int> answered = <int>[];
    final Future<void> collected = fromServer.stream.forEach(answered.addAll);

    final Future<void> served = ChannelHttpServer(
      apiWithOneProgram(),
      incoming: toServer.stream,
      outgoing: fromServer.sink,
    ).serve();

    toServer.add(utf8.encode(request));
    // The request says `Connection: close`, so the server answers and the channel ends — the same
    // shape as an SSH session whose command has finished.
    await served.timeout(const Duration(seconds: 5));
    await fromServer.close();
    await collected;
    await toServer.close();
    return utf8.decode(answered);
  }

  test('a real HttpServer answers over a pipe pair, with nothing listening', () async {
    final String answer = await ask(
      'GET /programs HTTP/1.1\r\nHost: machine\r\nConnection: close\r\n\r\n',
    );

    expect(answer, startsWith('HTTP/1.1 200 OK'));
    expect(answer, contains('application/json'));
    expect(answer, contains('deploy-host'));
  });

  test('a refusal comes back with its status and its reason', () async {
    final String answer = await ask(
      'GET /programs/nothing-like-this HTTP/1.1\r\nHost: m\r\nConnection: close\r\n\r\n',
    );

    expect(answer, startsWith('HTTP/1.1 404'));
    expect(answer, contains('nothing-like-this'));
  });

  test('a wrong method on a known path is 405, not 404', () async {
    final String answer = await ask(
      'DELETE /runs HTTP/1.1\r\nHost: m\r\nConnection: close\r\n\r\n',
    );
    expect(answer, startsWith('HTTP/1.1 405'));
  });

  test("a run's events arrive chunked, one JSON object per line", () async {
    final String answer = await ask(
      'GET /runs/r1/events HTTP/1.1\r\nHost: m\r\nConnection: close\r\n\r\n',
    );

    expect(
      answer,
      contains('transfer-encoding: chunked'),
      reason: 'a run being watched must reach the client as it happens, not when it ends',
    );
    expect(answer, contains('x-ndjson'));
    for (int i = 0; i < 3; i++) {
      expect(answer, contains('"sequence":$i'));
    }
  });

  test('starting a run answers 202 with its identifier, not when it finished', () async {
    const String body = '{"program":"deploy-host","mode":"test"}';
    final String answer = await ask(
      'POST /runs HTTP/1.1\r\nHost: m\r\n'
      'Content-Type: application/json\r\nContent-Length: ${body.length}\r\n'
      'Connection: close\r\n\r\n$body',
    );

    expect(answer, startsWith('HTTP/1.1 202'));
    expect(answer, contains('"run":'));
  });

  test('a real run without a clean dry run is refused over the wire too', () async {
    const String body = '{"program":"deploy-host","mode":"run"}';
    final String answer = await ask(
      'POST /runs HTTP/1.1\r\nHost: m\r\n'
      'Content-Type: application/json\r\nContent-Length: ${body.length}\r\n'
      'Connection: close\r\n\r\n$body',
    );

    expect(answer, startsWith('HTTP/1.1 409'));
    expect(answer, contains('needs a successful dry'));
  });
}
