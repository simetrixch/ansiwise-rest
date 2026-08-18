import 'package:ansiwise_rest/ansiwise_rest.dart';
import 'dart:convert';

import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:test/test.dart';

import '../support/example_steps.dart';
import '../support/harness.dart';
import 'doubles.dart';

/// The feature the whole rebuild exists for: three modes, each unlocking the next.
///
/// The gate is in the engine and not in a user interface, so these tests go through the API the way
/// a client would — and the same rule holds for the command line and for any other caller, because
/// all three go through this one door.
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
              ArgumentSpec(
                name: 'credential',
                kind: ArgumentKind.text,
                describes: 'what it authenticates with',
                required: false,
                secret: true,
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
    ResolvedProgram program, {
    bool requireDryRun = true,
  }) {
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
          gate: Gate(store, requireDryRun: requireDryRun),
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

  group('a real run needs a clean dry run for the same input', () {
    test('without one it is refused, and nothing is started', () async {
      final ({DeploymentApi api, MemoryRunStore store, RecordingLauncher launcher}) it = build(
        deployCluster(),
      );

      final ApiResponse answer = await it.api.call(
        post('/runs', <String, Object?>{'program': 'deploy-cluster', 'mode': 'run'}),
      );

      expect(answer, isA<Refused>());
      expect((answer as Refused).status, 409);
      expect(answer.reason, contains('needs a successful dry'));
      expect(it.launcher.started, isEmpty, reason: 'the run must not have been started');
    });

    test('with one it is admitted, and it says which dry run let it through', () async {
      final ResolvedProgram program = deployCluster();
      final ({DeploymentApi api, MemoryRunStore store, RecordingLauncher launcher}) it = build(
        program,
      );
      it.store.runs.add(
        runRecord(
          id: 'the-dry-one',
          program: 'deploy-cluster',
          mode: Mode.dry,
          fingerprint: fingerprintOf(program: program, commit: commit, answers: Arguments.none),
          exitCode: 0,
        ),
      );

      final ApiResponse answer = await it.api.call(
        post('/runs', <String, Object?>{'program': 'deploy-cluster', 'mode': 'run'}),
      );

      expect(answer, isA<Answered>());
      expect((answer as Answered).status, 202);
      expect(switch (answer.payload) {
        final Map<String, Object?> body => body['admitted_by'],
        final Object other => throw StateError('answered with $other'),
      }, 'the-dry-one');
      expect(it.launcher.started, <(ProgramName, Mode)>[
        (const ProgramName('deploy-cluster'), Mode.run),
      ]);
    });

    test('a dry run of a DIFFERENT input does not admit it', () async {
      final ({DeploymentApi api, MemoryRunStore store, RecordingLauncher launcher}) it = build(
        deployCluster(),
      );
      // A clean dry run of the same program, at the same commit, with one answer changed.
      it.store.runs.add(
        runRecord(
          id: 'the-other-one',
          program: 'deploy-cluster',
          mode: Mode.dry,
          fingerprint: fingerprintOf(
            program: deployCluster(path: '/etc/somewhere-else'),
            commit: commit,
            answers: Arguments.none,
          ),
          exitCode: 0,
        ),
      );

      final ApiResponse answer = await it.api.call(
        post('/runs', <String, Object?>{'program': 'deploy-cluster', 'mode': 'run'}),
      );

      expect(answer, isA<Refused>());
      expect(it.launcher.started, isEmpty);
    });

    test('a dry run that FAILED does not admit it', () async {
      final ResolvedProgram program = deployCluster();
      final ({DeploymentApi api, MemoryRunStore store, RecordingLauncher launcher}) it = build(
        program,
      );
      it.store.runs.add(
        runRecord(
          id: 'the-failed-one',
          program: 'deploy-cluster',
          mode: Mode.dry,
          fingerprint: fingerprintOf(program: program, commit: commit, answers: Arguments.none),
          exitCode: 1,
        ),
      );

      final ApiResponse answer = await it.api.call(
        post('/runs', <String, Object?>{'program': 'deploy-cluster', 'mode': 'run'}),
      );

      expect(answer, isA<Refused>());
      expect(it.launcher.started, isEmpty);
    });
  });

  group('the first two modes are not gated', () {
    test('a test run starts with nothing before it', () async {
      final ({DeploymentApi api, MemoryRunStore store, RecordingLauncher launcher}) it = build(
        deployCluster(),
      );
      final ApiResponse answer = await it.api.call(
        post('/runs', <String, Object?>{'program': 'deploy-cluster', 'mode': 'test'}),
      );
      expect(answer, isA<Answered>());
      expect(it.launcher.started.single.$2, Mode.test);
    });

    test('a dry run starts with nothing before it', () async {
      final ({DeploymentApi api, MemoryRunStore store, RecordingLauncher launcher}) it = build(
        deployCluster(),
      );
      final ApiResponse answer = await it.api.call(
        post('/runs', <String, Object?>{'program': 'deploy-cluster', 'mode': 'dry'}),
      );
      expect(answer, isA<Answered>());
      expect(it.launcher.started.single.$2, Mode.dry);
    });
  });

  group('an installation that waived the gate', () {
    // WAIVING IS NOT FALSIFYING. An operator who knows what they are doing had no way past the gate
    // except to make the framework's guarantee meaningless everywhere, so it can be turned off — and
    // everything about the run then has to say that it was.

    test('starts a real run with no dry run behind it at all', () async {
      final ({DeploymentApi api, MemoryRunStore store, RecordingLauncher launcher}) it = build(
        deployCluster(),
        requireDryRun: false,
      );

      final ApiResponse answer = await it.api.call(
        post('/runs', <String, Object?>{'program': 'deploy-cluster', 'mode': 'run'}),
      );

      expect(answer, isA<Answered>());
      expect(it.store.runs, isEmpty, reason: 'there was no dry run, waived or otherwise');
      expect(it.launcher.started.single.$2, Mode.run);
    });

    test('says so in the answer, rather than going quiet', () async {
      // The trap this closes: with the gate waived there is no `admitted_by`, and an absent
      // `admitted_by` is also what a test or a dry run answers — so silence would read as "this
      // mode needed no proof" to the one operator who most needs to know it went without one.
      final ({DeploymentApi api, MemoryRunStore store, RecordingLauncher launcher}) it = build(
        deployCluster(),
        requireDryRun: false,
      );

      final ApiResponse answer = await it.api.call(
        post('/runs', <String, Object?>{'program': 'deploy-cluster', 'mode': 'run'}),
      );

      final Map<String, Object?> body = switch ((answer as Answered).payload) {
        final Map<String, Object?> payload => payload,
        final Object other => throw StateError('answered with $other'),
      };
      expect(body['waived'], <String>['dry']);
      expect(
        body.containsKey('admitted_by'),
        isFalse,
        reason: 'nothing admitted it, and naming a dry run here would be the lie',
      );
    });

    test('tells the run itself, so its record carries the waiver', () async {
      // The answer is read by whoever started the run; the record is read by everybody afterwards.
      // A waiver that reached only the first would leave a record nobody could tell apart from one
      // that was gated normally.
      final ({DeploymentApi api, MemoryRunStore store, RecordingLauncher launcher}) it = build(
        deployCluster(),
        requireDryRun: false,
      );

      await it.api.call(
        post('/runs', <String, Object?>{'program': 'deploy-cluster', 'mode': 'run'}),
      );

      expect(it.launcher.waivers.single, <Mode>[Mode.dry]);
    });

    test('a waived gate does not go looking for a dry run to name', () async {
      // A clean dry run of exactly this input is sitting in the store. The waived gate must not
      // reach for it: the operator decided to go without a proof, and reporting one they did not
      // ask for would put a measurement behind a run that has none.
      final ResolvedProgram program = deployCluster();
      final ({DeploymentApi api, MemoryRunStore store, RecordingLauncher launcher}) it = build(
        program,
        requireDryRun: false,
      );
      it.store.runs.add(
        runRecord(
          id: 'the-dry-one',
          program: 'deploy-cluster',
          mode: Mode.dry,
          fingerprint: fingerprintOf(program: program, commit: commit, answers: Arguments.none),
          exitCode: 0,
        ),
      );

      final ApiResponse answer = await it.api.call(
        post('/runs', <String, Object?>{'program': 'deploy-cluster', 'mode': 'run'}),
      );

      final Map<String, Object?> body = switch ((answer as Answered).payload) {
        final Map<String, Object?> payload => payload,
        final Object other => throw StateError('answered with $other'),
      };
      expect(body.containsKey('admitted_by'), isFalse);
      expect(body['waived'], <String>['dry']);
    });

    test('the two modes nothing precedes waive nothing', () async {
      // They were never gated, so there is no proof for them to have gone without. Reporting one
      // would be the same defect from the other side: a run claiming to have skipped something
      // nobody ever asked it for.
      final ({DeploymentApi api, MemoryRunStore store, RecordingLauncher launcher}) it = build(
        deployCluster(),
        requireDryRun: false,
      );

      for (final String mode in <String>['test', 'dry']) {
        final ApiResponse answer = await it.api.call(
          post('/runs', <String, Object?>{'program': 'deploy-cluster', 'mode': mode}),
        );
        final Map<String, Object?> body = switch ((answer as Answered).payload) {
          final Map<String, Object?> payload => payload,
          final Object other => throw StateError('answered with $other'),
        };
        expect(body.containsKey('waived'), isFalse, reason: 'a $mode run waived nothing');
      }
      expect(it.launcher.waivers, everyElement(isEmpty));
    });
  });

  group('what makes two runs the same input', () {
    test('the same program at the same commit fingerprints the same', () {
      expect(
        fingerprintOf(program: deployCluster(), commit: commit, answers: Arguments.none),
        fingerprintOf(program: deployCluster(), commit: commit, answers: Arguments.none),
      );
    });

    test('a different commit is a different input', () {
      expect(
        fingerprintOf(program: deployCluster(), commit: commit, answers: Arguments.none),
        isNot(fingerprintOf(program: deployCluster(), commit: 'def5678', answers: Arguments.none)),
      );
    });
  });
}
