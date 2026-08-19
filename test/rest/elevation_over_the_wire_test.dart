import 'dart:convert';

import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:ansiwise_rest/ansiwise_rest.dart';
import 'package:test/test.dart';

import '../support/example_steps.dart';
import '../support/harness.dart';
import 'doubles.dart';

/// The password that raises a command to root, on its way from a caller to the run that needs it.
///
/// **WHY THIS SURFACE CARRIES IT AT ALL.** An installation may say the password comes from whoever
/// starts the run rather than from a file the machine keeps. This process is then the door it
/// arrives at — and it is NOT the process that uses it: what serves this request executes no step,
/// it starts a run in a process of its own, and that process is handed its own password with its own
/// answers.
///
/// **WHAT WENT WRONG WITHOUT THIS.** The shape a run is told by changed on one side only. This
/// surface handed the launcher a bare map of answers while the run had begun refusing exactly that
/// shape, so every run started here died before writing its header — the case that leaves a caller
/// holding an id whose run answers 404 for ever — while the same run started by hand went through.
/// Two doors, one of them speaking a shape the other had left behind, and no check reading both.
void main() {
  const DeclaredAnswers declared = DeclaredAnswers(<ArgumentSpec>[
    ArgumentSpec(name: 'fqdn', kind: ArgumentKind.text, describes: 'the name of the machine'),
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

  ({DeploymentApi api, RecordingLauncher launcher}) surface() {
    final RecordingLauncher launcher = RecordingLauncher();
    final FixedCatalogue catalogue = FixedCatalogue(<ResolvedProgram>[program()]);
    const FileRunStore store = FileRunStore(directory: RunDirectory('/nowhere'));
    return (
      api: DeploymentApi(
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
      ),
      launcher: launcher,
    );
  }

  Future<ApiResponse> post(DeploymentApi api, Map<String, Object?> body) => api.call(
    ApiRequest(
      'POST',
      Uri.parse('/runs'),
      body: jsonEncode(<String, Object?>{
        'program': 'deploy-thing',
        'mode': 'test',
        'answers': <String, Object?>{'fqdn': 'm1.example.com'},
        ...body,
      }),
    ),
  );

  test('a password handed to this surface reaches the run, and nothing else does', () async {
    final ({DeploymentApi api, RecordingLauncher launcher}) it = surface();

    final ApiResponse answered = await post(it.api, <String, Object?>{
      'elevation_password': 'what raises a command',
    });

    expect(answered, isA<Answered>());
    expect(it.launcher.passwords, <String?>['what raises a command']);
    // Asserted alongside, because a password that arrived and answers that did not is a run that
    // starts and fails at its first row.
    expect(it.launcher.answers.single, <String, Object?>{'fqdn': 'm1.example.com'});
  });

  test('THE INNOCENT NEIGHBOUR: a run told no password is started with none', () async {
    final ({DeploymentApi api, RecordingLauncher launcher}) it = surface();

    expect(await post(it.api, const <String, Object?>{}), isA<Answered>());
    expect(it.launcher.passwords, <String?>[null]);
  });

  test('a password that holds nothing usable is refused, and nothing is started', () async {
    for (final Object? nonsense in <Object?>[
      '',
      42,
      <String>['a'],
    ]) {
      final ({DeploymentApi api, RecordingLauncher launcher}) it = surface();

      final ApiResponse answered = await post(it.api, <String, Object?>{
        'elevation_password': nonsense,
      });

      expect(answered, isA<Refused>(), reason: 'accepted $nonsense as a password');
      expect((answered as Refused).status, 400);
      expect(
        it.launcher.started,
        isEmpty,
        reason: 'a run was started on a password this surface had already judged unusable',
      );
    }
  });
}
