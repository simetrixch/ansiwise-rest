import 'package:ansiwise_rest/ansiwise_rest.dart';
import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:test/test.dart';

import '../support/example_steps.dart';
import '../support/harness.dart';
import 'doubles.dart';

/// What the client can ask for, and what it gets back.
void main() {
  ResolvedProgram program() =>
      ProgramResolver(
        registryOf(
          steps: <String, (String, Step Function(Arguments))>{
            'writes_a_file': (
              'deployment/lib/steps/writes_a_file.dart:12',
              (Arguments a) => WritesAFile(path: '/etc/thing', content: 'x'),
            ),
            'runs_a_command': (
              'deployment/lib/steps/runs_a_command.dart:9',
              (Arguments a) => RunsACommand(argv: const <String>['true'], leaves: '/m'),
            ),
          },
          arguments: <String, List<ArgumentSpec>>{
            'writes_a_file': const <ArgumentSpec>[
              ArgumentSpec(
                name: 'credential',
                kind: ArgumentKind.text,
                describes: 'what it authenticates with',
                required: false,
                secret: true,
              ),
            ],
          },
          predicates: <String, Predicate>{
            'has_two_nics': const Says(answer: true, because: 'two interfaces are up'),
          },
        ),
      ).resolve(
        programOf(
          'deploy-cluster',
          <(String, OnFailure, List<String>)>[
            ('writes_a_file', OnFailure.exit, <String>[]),
            ('runs_a_command', OnFailure.continueRun, <String>['has_two_nics']),
          ],
          arguments: <String, Arguments>{
            'writes_a_file': const Arguments(<String, Object>{
              'credential': 'hunter2-and-then-some',
            }),
          },
        ),
      );

  ({DeploymentApi api, MemoryRunStore store}) build() {
    final MemoryRunStore store = MemoryRunStore();
    final FixedCatalogue catalogue = FixedCatalogue(<ResolvedProgram>[program()]);
    return (
      api: DeploymentApi(
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
      ),
      store: store,
    );
  }

  Future<Map<String, Object?>> get(DeploymentApi api, String path) async {
    final ApiResponse answer = await api.call(ApiRequest('GET', Uri.parse(path)));
    expect(answer, isA<Answered>(), reason: 'GET $path should have answered');
    return switch ((answer as Answered).payload) {
      final Map<String, Object?> body => body,
      final Object other => throw StateError('answered with $other'),
    };
  }

  group('GET /programs', () {
    test('names every program, its roles and its steps', () async {
      final Map<String, Object?> body = await get(build().api, '/programs');
      final List<Object?> programs = listAt(body, 'programs');
      expect(programs, hasLength(1));

      final Map<String, Object?> first = objectAt(programs, 0);
      expect(first['name'], 'deploy-cluster');
      expect(first['roles'], <String>['master']);
      expect(listAt(first, 'steps'), hasLength(2));
    });

    test('a step names the file that defines it, so a failure points somewhere openable', () async {
      final Map<String, Object?> body = await get(build().api, '/programs/deploy-cluster');
      final Map<String, Object?> step = objectAt(listAt(body, 'steps'), 0);
      expect(step['source'], 'deployment/lib/steps/writes_a_file.dart:12');
      expect(step['on_failure'], 'exit');
    });

    test('a step says whether it can be taken back, and why not when it cannot', () async {
      final Map<String, Object?> body = await get(build().api, '/programs/deploy-cluster');
      final List<Object?> steps = listAt(body, 'steps');

      final Map<String, Object?> reversible = objectAt(steps, 0);
      expect(reversible['reversible'], isTrue);
      expect(reversible.containsKey('irreversible_reason'), isFalse);

      final Map<String, Object?> irreversible = objectAt(steps, steps.length - 1);
      expect(irreversible['reversible'], isFalse);
      expect(
        irreversible['irreversible_reason'],
        'the command it runs does not come with a way back',
      );
    });

    test('a step names the conditions that decide whether it runs', () async {
      final Map<String, Object?> body = await get(build().api, '/programs/deploy-cluster');
      final List<Object?> all = listAt(body, 'steps');
      final Map<String, Object?> guarded = objectAt(all, all.length - 1);
      expect(guarded['when'], <String>['has_two_nics']);
    });

    test('a secret is reported as set and NEVER by value', () async {
      final Map<String, Object?> body = await get(build().api, '/programs/deploy-cluster');
      final Map<String, Object?> step = objectAt(listAt(body, 'steps'), 0);
      final Map<String, Object?> credential = objectAt(listAt(step, 'arguments'), 0);

      expect(credential['secret'], isTrue);
      expect(credential['set'], isTrue);
      expect(credential.containsKey('value'), isFalse);
      expect(
        body.toString(),
        isNot(contains('hunter2-and-then-some')),
        reason: 'no part of a description may carry a secret',
      );
    });

    test('an unknown program is a 404 that names what was asked for', () async {
      final ApiResponse answer = await build().api.call(
        ApiRequest('GET', Uri.parse('/programs/nothing-like-this')),
      );
      expect(answer, isA<Refused>());
      expect((answer as Refused).status, 404);
      expect(answer.reason, contains('nothing-like-this'));
    });
  });

  group('the routing tells apart a wrong method and a wrong path', () {
    test('a known path under the wrong method is 405', () async {
      final ApiResponse answer = await build().api.call(ApiRequest('DELETE', Uri.parse('/runs')));
      expect((answer as Refused).status, 405);
    });

    test('an unknown path is 404', () async {
      final ApiResponse answer = await build().api.call(
        ApiRequest('GET', Uri.parse('/something-else')),
      );
      expect((answer as Refused).status, 404);
    });
  });

  group('GET /runs/{id}/events', () {
    test('from a sequence number, it skips what came before and misses nothing after', () async {
      final ({DeploymentApi api, MemoryRunStore store}) it = build();
      it.store.runs.add(
        runRecord(
          id: 'r1',
          program: 'deploy-cluster',
          mode: Mode.dry,
          fingerprint: 'f',
          exitCode: 0,
        ),
      );
      it.store.eventsById['r1'] = <RunEvent>[
        for (int i = 0; i < 5; i++)
          Log(
            sequence: i,
            at: DateTime.utc(2026, 8, 7),
            step: const StepName('writes_a_file'),
            level: LogLevel.info,
            message: 'line $i',
          ),
      ];

      final ApiResponse answer = await it.api.call(
        ApiRequest('GET', Uri.parse('/runs/r1/events?from=3')),
      );
      expect(answer, isA<Streaming>());
      final List<Object> lines = await (answer as Streaming).items.toList();
      expect(lines, hasLength(2));
      expect(objectAt(lines, 0)['sequence'], 3);
    });

    test('a negative sequence number is refused rather than treated as zero', () async {
      final ({DeploymentApi api, MemoryRunStore store}) it = build();
      it.store.runs.add(
        runRecord(
          id: 'r1',
          program: 'deploy-cluster',
          mode: Mode.dry,
          fingerprint: 'f',
          exitCode: 0,
        ),
      );
      final ApiResponse answer = await it.api.call(
        ApiRequest('GET', Uri.parse('/runs/r1/events?from=-1')),
      );
      expect((answer as Refused).status, 400);
    });

    test('an unknown run is a 404', () async {
      final ApiResponse answer = await build().api.call(
        ApiRequest('GET', Uri.parse('/runs/never-happened/events')),
      );
      expect((answer as Refused).status, 404);
    });
  });
}
