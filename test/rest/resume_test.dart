import 'package:ansiwise_rest/ansiwise_rest.dart';
import 'dart:convert';

import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:test/test.dart';

import '../support/example_steps.dart';
import '../support/harness.dart';
import 'doubles.dart';

/// Continuing a run that stopped, over the API.
///
/// **Resuming does not skip anything, and these tests are written around that.** A resumed run walks
/// the same program from the top; every step that already did its work answers that there is nothing
/// to do, which is what idempotence is for. Skipping to a remembered position would be faster and
/// worse — a machine somebody touched between the two runs would never be re-measured, and the
/// second half would build on a state nobody checked.
///
/// So what the identifier changes is the RECORD. Without it a resumed run is a second, unrelated
/// run, and an operator reading the history sees two halves of one story with nothing joining them.
/// Everything below therefore measures where the identifier travels and when it is refused, and
/// nothing measures a shortened walk, because there is none.
void main() {
  const String commit = 'abc1234';

  ResolvedProgram deployCluster({String path = '/etc/thing'}) =>
      ProgramResolver(
        registryOf(
          steps: <String, (String, Step Function(Arguments))>{
            'writes_a_file': (
              'deployment/lib/steps/writes_a_file.dart:12',
              (Arguments a) => WritesAFile(path: a.text('path'), content: 'the content'),
            ),
          },
          arguments: <String, List<ArgumentSpec>>{
            'writes_a_file': const <ArgumentSpec>[
              ArgumentSpec(
                name: 'path',
                kind: ArgumentKind.text,
                describes: 'the file to write',
                defaultValue: '/etc/thing',
              ),
            ],
          },
        ),
      ).resolve(
        programOf(
          'deploy-cluster',
          <(String, OnFailure, List<String>)>[('writes_a_file', OnFailure.exit, <String>[])],
          arguments: <String, Arguments>{
            'writes_a_file': Arguments(<String, Object>{'path': path}),
          },
        ),
      );

  ({DeploymentApi api, MemoryRunStore store, RecordingLauncher launcher}) build(
    ResolvedProgram program,
  ) {
    final MemoryRunStore store = MemoryRunStore();
    final RecordingLauncher launcher = RecordingLauncher();
    final FixedCatalogue catalogue = FixedCatalogue(<ResolvedProgram>[program]);
    return (
      api: DeploymentApi(
        programs: ProgramsEndpoint(catalogue),
        runs: RunsEndpoint(
          store: store,
          launcher: launcher,
          catalogue: catalogue,
          gate: Gate(store),
          json: const PlainRecordJson(),
          commit: () async => commit,
        ),
        events: EventsEndpoint(store: store, json: const PlainRecordJson()),
      ),
      store: store,
      launcher: launcher,
    );
  }

  ApiRequest post(String path, Map<String, Object?> body) =>
      ApiRequest('POST', Uri.parse(path), body: jsonEncode(body));

  /// A dry run of [program] that ended clean, which is what the gate wants to see before a real one.
  void admit(MemoryRunStore store, ResolvedProgram program, {String id = 'the-dry-one'}) {
    store.runs.add(
      runRecord(
        id: id,
        program: 'deploy-cluster',
        mode: Mode.dry,
        fingerprint: fingerprintOf(program: program, commit: commit, answers: Arguments.none),
        exitCode: 0,
      ),
    );
  }

  Map<String, Object?> bodyOf(ApiResponse answer) => switch ((answer as Answered).payload) {
    final Map<String, Object?> body => body,
    final Object other => throw StateError('answered with $other'),
  };

  group('starting a run that continues an earlier one', () {
    test('the identifier reaches the launcher and comes back in the answer', () async {
      final ResolvedProgram program = deployCluster();
      final ({DeploymentApi api, MemoryRunStore store, RecordingLauncher launcher}) it = build(
        program,
      );
      admit(it.store, program);
      it.store.runs.add(
        runRecord(
          id: 'the-one-that-stopped',
          program: 'deploy-cluster',
          mode: Mode.run,
          fingerprint: fingerprintOf(program: program, commit: commit, answers: Arguments.none),
          exitCode: 1,
        ),
      );

      final ApiResponse answer = await it.api.call(
        post('/runs', <String, Object?>{
          'program': 'deploy-cluster',
          'mode': 'run',
          'resumes': 'the-one-that-stopped',
        }),
      );

      expect(answer, isA<Answered>());
      expect((answer as Answered).status, 202);
      expect(bodyOf(answer)['resumes'], 'the-one-that-stopped');
      expect(
        it.launcher.resumed,
        <RunId?>[const RunId('the-one-that-stopped')],
        reason:
            'an answer that says "resumes" while the launcher was told nothing is a run that '
            'joins nothing',
      );
    });

    test('a run that names none says so by leaving the key out', () async {
      // Absent rather than null, so a client tells "fresh" from "continues" by whether the key is
      // there rather than by reading a value that means nothing.
      final ResolvedProgram program = deployCluster();
      final ({DeploymentApi api, MemoryRunStore store, RecordingLauncher launcher}) it = build(
        program,
      );
      admit(it.store, program);

      final ApiResponse answer = await it.api.call(
        post('/runs', <String, Object?>{'program': 'deploy-cluster', 'mode': 'run'}),
      );

      expect(bodyOf(answer).containsKey('resumes'), isFalse);
      expect(it.launcher.resumed, <RunId?>[null]);
    });
  });

  group('what it refuses, before anything is started', () {
    test('a run nobody has heard of', () async {
      final ResolvedProgram program = deployCluster();
      final ({DeploymentApi api, MemoryRunStore store, RecordingLauncher launcher}) it = build(
        program,
      );
      admit(it.store, program);

      final ApiResponse answer = await it.api.call(
        post('/runs', <String, Object?>{
          'program': 'deploy-cluster',
          'mode': 'run',
          'resumes': 'never-existed',
        }),
      );

      expect(answer, isA<Refused>());
      expect((answer as Refused).status, 404);
      expect(answer.reason, contains('never-existed'));
      expect(it.launcher.started, isEmpty);
    });

    test('a run of a DIFFERENT input, because that would not be continuing it', () async {
      // The whole point of the identifier is that the two halves are one story. A run whose input
      // was something else is a different story, and joining them in the record would say the
      // machine was taken from a state it was never in.
      final ResolvedProgram program = deployCluster();
      final ({DeploymentApi api, MemoryRunStore store, RecordingLauncher launcher}) it = build(
        program,
      );
      admit(it.store, program);
      it.store.runs.add(
        runRecord(
          id: 'the-other-one',
          program: 'deploy-cluster',
          mode: Mode.run,
          fingerprint: fingerprintOf(
            program: deployCluster(path: '/etc/somewhere-else'),
            commit: commit,
            answers: Arguments.none,
          ),
          exitCode: 1,
        ),
      );

      final ApiResponse answer = await it.api.call(
        post('/runs', <String, Object?>{
          'program': 'deploy-cluster',
          'mode': 'run',
          'resumes': 'the-other-one',
        }),
      );

      expect(answer, isA<Refused>());
      expect((answer as Refused).status, 400);
      expect(answer.reason, contains('a different input'));
      expect(it.launcher.started, isEmpty, reason: 'a refusal that started the run anyway is none');
    });

    test('a value that is not an identifier at all', () async {
      final ResolvedProgram program = deployCluster();
      final ({DeploymentApi api, MemoryRunStore store, RecordingLauncher launcher}) it = build(
        program,
      );
      admit(it.store, program);

      for (final Object empty in <Object>[<String>[], '']) {
        final ApiResponse answer = await it.api.call(
          post('/runs', <String, Object?>{
            'program': 'deploy-cluster',
            'mode': 'run',
            'resumes': empty,
          }),
        );
        expect(answer, isA<Refused>(), reason: '$empty was taken for a run identifier');
        expect((answer as Refused).status, 400);
      }
      expect(it.launcher.started, isEmpty);
    });
  });

  group('counter-probe', () {
    // Every refusal above would also be reported by an endpoint that refused EVERY resume. These
    // are what tell the two apart.

    test('the same request without "resumes" is admitted', () async {
      final ResolvedProgram program = deployCluster();
      final ({DeploymentApi api, MemoryRunStore store, RecordingLauncher launcher}) it = build(
        program,
      );
      admit(it.store, program);

      final ApiResponse answer = await it.api.call(
        post('/runs', <String, Object?>{'program': 'deploy-cluster', 'mode': 'run'}),
      );

      expect(answer, isA<Answered>());
      expect(it.launcher.started, hasLength(1));
    });

    test('a run that ended CLEAN may be continued too, and that is deliberate', () async {
      // Nothing here reads the earlier run's exit code. A run that ended clean can still leave work
      // undone — a step that reported an issue rather than failing, an operator who stopped it — and
      // a rule that refused would be a rule about what somebody meant rather than about the record.
      // The walk is the same either way, so the worst a needless resume costs is a run that finds
      // nothing to do.
      final ResolvedProgram program = deployCluster();
      final ({DeploymentApi api, MemoryRunStore store, RecordingLauncher launcher}) it = build(
        program,
      );
      admit(it.store, program);
      it.store.runs.add(
        runRecord(
          id: 'the-clean-one',
          program: 'deploy-cluster',
          mode: Mode.run,
          fingerprint: fingerprintOf(program: program, commit: commit, answers: Arguments.none),
          exitCode: 0,
        ),
      );

      final ApiResponse answer = await it.api.call(
        post('/runs', <String, Object?>{
          'program': 'deploy-cluster',
          'mode': 'run',
          'resumes': 'the-clean-one',
        }),
      );

      expect(answer, isA<Answered>());
      expect(it.launcher.resumed, <RunId?>[const RunId('the-clean-one')]);
    });
  });
}
