import 'package:ansiwise_rest/ansiwise_rest.dart';
import 'dart:convert';

import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:test/test.dart';

import '../support/example_steps.dart';
import '../support/harness.dart';
import 'doubles.dart';

/// What a client learns about a program's inputs, and what it is refused for getting them wrong.
///
/// The app renders its form out of `GET /programs` and hard-codes no field. That property is only
/// worth anything if the description actually carries every declaration — and if a secret's VALUE
/// never comes back out with it.
void main() {
  const DeclaredAnswers declared = DeclaredAnswers(<ArgumentSpec>[
    ArgumentSpec(
      name: 'fqdn',
      kind: ArgumentKind.text,
      describes: 'the domain name this installation is reached under',
    ),
    ArgumentSpec(
      name: 'workers',
      kind: ArgumentKind.integer,
      describes: 'how many workers to run',
      required: false,
      defaultValue: 3,
    ),
    ArgumentSpec(
      name: 'repo_pat',
      kind: ArgumentKind.text,
      describes: 'a credential that may clone the platform repository',
      secret: true,
    ),
  ]);

  ResolvedProgram program() =>
      ProgramResolver(
        registryOf(
          steps: <String, (String, Step Function(Arguments))>{
            'runs_a_command': (
              'lib/src/steps/runs_a_command.dart:9',
              (Arguments a) => RunsACommand(argv: const <String>['true'], leaves: '/m'),
            ),
          },
        ),
      ).resolve(
        programOf('deploy-thing', <(String, OnFailure, List<String>)>[
          ('runs_a_command', OnFailure.exit, <String>[]),
        ], answers: declared),
      );

  ResolvedProgram nothingNeeded() =>
      ProgramResolver(
        registryOf(
          steps: <String, (String, Step Function(Arguments))>{
            'runs_a_command': (
              'lib/src/steps/runs_a_command.dart:9',
              (Arguments a) => RunsACommand(argv: const <String>['true'], leaves: '/m'),
            ),
          },
        ),
      ).resolve(
        programOf('needs-nothing', <(String, OnFailure, List<String>)>[
          ('runs_a_command', OnFailure.exit, <String>[]),
        ]),
      );

  DeploymentApi apiOver(FileRunStore store, RunDirectory directory) {
    final FixedCatalogue catalogue = FixedCatalogue(<ResolvedProgram>[program()]);
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

  /// The first program of a listing, as the map the endpoint answered with.
  Future<Map<String, Object?>> firstProgram(DeploymentApi api) async {
    final ApiResponse response = await api.call(ApiRequest('GET', Uri.parse('/programs')));
    expect(response, isA<Answered>());
    final Map<String, Object?> payload = (response as Answered).payload as Map<String, Object?>;
    return (payload['programs']! as List<Object?>).first! as Map<String, Object?>;
  }

  group('GET /programs', () {
    test('carries every declaration, in the order the program wrote them', () async {
      final DeploymentApi api = apiOver(
        const FileRunStore(directory: RunDirectory('/nowhere')),
        const RunDirectory('/nowhere'),
      );

      final Map<String, Object?> first = await firstProgram(api);
      final List<Object?> answers = first['answers']! as List<Object?>;

      expect(answers.map((Object? a) => (a! as Map<String, Object?>)['name']), <String>[
        'fqdn',
        'workers',
        'repo_pat',
      ]);
      final Map<String, Object?> fqdn = answers.first! as Map<String, Object?>;
      expect(fqdn['kind'], 'text');
      expect(fqdn['required'], true);
      expect(fqdn['secret'], false);
      // Without this the form shows a bare field name to somebody who has never seen this system.
      expect(fqdn['describes'], contains('domain name'));
    });

    test('says an answer is secret and carries no value for it', () async {
      final DeploymentApi api = apiOver(
        const FileRunStore(directory: RunDirectory('/nowhere')),
        const RunDirectory('/nowhere'),
      );

      final Map<String, Object?> first = await firstProgram(api);
      final Map<String, Object?> pat =
          ((first['answers']! as List<Object?>).last)! as Map<String, Object?>;

      expect(pat['secret'], true);
      // The client needs to know it is secret, so it renders a field that does not echo. It does
      // not need the value, and a description that carried one would put a credential on the wire
      // every time anybody listed the programs.
      expect(pat.containsKey('default'), isFalse);
      expect(pat.values.whereType<String>(), isNot(contains('hunter2')));
    });

    test('a default travels, so the form can be filled in before anybody types', () async {
      final DeploymentApi api = apiOver(
        const FileRunStore(directory: RunDirectory('/nowhere')),
        const RunDirectory('/nowhere'),
      );

      final Map<String, Object?> first = await firstProgram(api);
      final Map<String, Object?> workers =
          ((first['answers']! as List<Object?>)[1])! as Map<String, Object?>;

      expect(workers['default'], 3);
      expect(workers['required'], false);
    });
  });

  group('POST /runs', () {
    Future<ApiResponse> post(DeploymentApi api, Object? answers) => api.call(
      ApiRequest(
        'POST',
        Uri.parse('/runs'),
        body: jsonEncode(<String, Object?>{
          'program': 'deploy-thing',
          'mode': 'test',
          'answers': ?answers,
        }),
      ),
    );

    test('refuses a missing required answer, and nothing is started', () async {
      final RecordingLauncher launcher = RecordingLauncher();
      final FixedCatalogue catalogue = FixedCatalogue(<ResolvedProgram>[program()]);
      const FileRunStore store = FileRunStore(directory: RunDirectory('/nowhere'));
      final DeploymentApi api = DeploymentApi(
        programs: ProgramsEndpoint(catalogue),
        runs: RunsEndpoint(
          store: store,
          launcher: launcher,
          catalogue: catalogue,
          gate: const Gate(store),
          json: const PlainRecordJson(),
          commit: () async => 'abc1234',
        ),
        events: const EventsEndpoint(store: store, json: PlainRecordJson()),
      );

      final ApiResponse response = await post(api, <String, Object?>{'fqdn': 'm1.example.com'});

      expect(response, isA<Refused>());
      final Refused refused = response as Refused;
      expect(refused.status, 400);
      expect(refused.reason, contains('repo_pat'));
      // The refusal is only worth anything if it happened BEFORE the launcher: an installation
      // stopped halfway for a value somebody could have typed at the start is the worst of both.
      expect(launcher.started, isEmpty);
    });

    test('names every problem at once rather than one per attempt', () async {
      final DeploymentApi api = apiOver(
        const FileRunStore(directory: RunDirectory('/nowhere')),
        const RunDirectory('/nowhere'),
      );

      final ApiResponse response = await post(api, <String, Object?>{
        'workers': 'three',
        'nonsense': 1,
      });

      expect(response, isA<Refused>());
      final Refused refused = response as Refused;
      expect(refused.status, 400);
      expect(refused.reason, contains('fqdn'));
      expect(refused.reason, contains('repo_pat'));
      expect(refused.reason, contains('nonsense'));
    });

    test('refuses answers that are not an object', () async {
      final DeploymentApi api = apiOver(
        const FileRunStore(directory: RunDirectory('/nowhere')),
        const RunDirectory('/nowhere'),
      );

      final ApiResponse response = await post(api, <Object?>['fqdn']);

      expect(response, isA<Refused>());
      final Refused refused = response as Refused;
      expect(refused.status, 400);
      expect(refused.reason, contains('must be a JSON object'));
    });

    test('what the operator supplied REACHES the launcher', () async {
      // The half that was missing, and the half an operator uses. The refusal path was tested and
      // the success path was not, which is why a run started over the API reached its steps with an
      // empty bag while the same program on the command line worked.
      final RecordingLauncher launcher = RecordingLauncher();
      final FixedCatalogue catalogue = FixedCatalogue(<ResolvedProgram>[program()]);
      const FileRunStore store = FileRunStore(directory: RunDirectory('/nowhere'));
      final DeploymentApi api = DeploymentApi(
        programs: ProgramsEndpoint(catalogue),
        runs: RunsEndpoint(
          store: store,
          launcher: launcher,
          catalogue: catalogue,
          gate: const Gate(store),
          json: const PlainRecordJson(),
          commit: () async => 'abc1234',
        ),
        events: const EventsEndpoint(store: store, json: PlainRecordJson()),
      );

      final ApiResponse response = await post(api, <String, Object?>{
        'fqdn': 'm1.example.com',
        'repo_pat': 'a-credential',
      });

      expect(response, isA<Answered>());
      expect(launcher.answers.single, <String, Object?>{
        'fqdn': 'm1.example.com',
        'repo_pat': 'a-credential',
      });
    });

    test('the raw set travels, not a copy with the defaults already filled in', () async {
      // The run checks the values again against the program's own declaration, and the process that
      // will ACT on a value is the one that has to be sure of it. Sending a pre-cooked bag would
      // make this endpoint the authority on what a default is, in a second place.
      final RecordingLauncher launcher = RecordingLauncher();
      final FixedCatalogue catalogue = FixedCatalogue(<ResolvedProgram>[program()]);
      const FileRunStore store = FileRunStore(directory: RunDirectory('/nowhere'));
      final DeploymentApi api = DeploymentApi(
        programs: ProgramsEndpoint(catalogue),
        runs: RunsEndpoint(
          store: store,
          launcher: launcher,
          catalogue: catalogue,
          gate: const Gate(store),
          json: const PlainRecordJson(),
          commit: () async => 'abc1234',
        ),
        events: const EventsEndpoint(store: store, json: PlainRecordJson()),
      );

      await post(api, <String, Object?>{'fqdn': 'm1.example.com', 'repo_pat': 'a-credential'});

      // `workers` has a default of 3 and was not supplied. It must NOT be in what travels.
      expect(launcher.answers.single.containsKey('workers'), isFalse);
    });

    test('a program that needs nothing starts with an empty set rather than none at all', () async {
      final RecordingLauncher launcher = RecordingLauncher();
      final FixedCatalogue catalogue = FixedCatalogue(<ResolvedProgram>[nothingNeeded()]);
      const FileRunStore store = FileRunStore(directory: RunDirectory('/nowhere'));
      final DeploymentApi api = DeploymentApi(
        programs: ProgramsEndpoint(catalogue),
        runs: RunsEndpoint(
          store: store,
          launcher: launcher,
          catalogue: catalogue,
          gate: const Gate(store),
          json: const PlainRecordJson(),
          commit: () async => 'abc1234',
        ),
        events: const EventsEndpoint(store: store, json: PlainRecordJson()),
      );

      final ApiResponse response = await api.call(
        ApiRequest(
          'POST',
          Uri.parse('/runs'),
          body: jsonEncode(<String, Object?>{'program': 'needs-nothing', 'mode': 'test'}),
        ),
      );

      expect(response, isA<Answered>());
      expect(launcher.answers.single, isEmpty);
    });
  });
}
