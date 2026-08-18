import 'package:ansiwise_core/ansiwise_core.dart';

/// A catalogue holding whatever a test put in it.
final class FixedCatalogue implements Catalogue {
  FixedCatalogue(this.programs);

  @override
  final List<ResolvedProgram> programs;

  @override
  ResolvedProgram? byName(ProgramName name) {
    for (final ResolvedProgram program in programs) {
      if (program.declared.name == name) {
        return program;
      }
    }
    return null;
  }
}

/// A store holding runs in a list.
final class MemoryRunStore implements RunStore {
  final List<RunRecord> runs = <RunRecord>[];
  final Map<String, List<RunEvent>> eventsById = <String, List<RunEvent>>{};

  @override
  Future<List<RunRecord>> list({ProgramName? program, Mode? mode, int limit = 50}) async => runs
      .where((RunRecord r) => program == null || r.program == program)
      .where((RunRecord r) => mode == null || r.mode == mode)
      .take(limit)
      .toList();

  @override
  Future<RunRecord?> read(RunId id) async {
    for (final RunRecord run in runs) {
      if (run.id == id) {
        return run;
      }
    }
    return null;
  }

  @override
  Stream<RunEvent> events(RunId id, {int from = 0}) => Stream<RunEvent>.fromIterable(
    (eventsById[id.value] ?? const <RunEvent>[]).where((RunEvent e) => e.sequence >= from),
  );

  @override
  Future<RunRecord?> lastCleanDryRun({
    required ProgramName program,
    required String fingerprint,
  }) async {
    for (final RunRecord run in runs.reversed) {
      if (run.program == program &&
          run.mode == Mode.dry &&
          run.exitCode == 0 &&
          run.fingerprint == fingerprint) {
        return run;
      }
    }
    return null;
  }
}

/// A launcher that records what it was asked for instead of starting anything.
final class RecordingLauncher implements RunLauncher {
  final List<(ProgramName, Mode)> started = <(ProgramName, Mode)>[];

  /// What each start was told, in the same order — so a test asserts that the VALUES reached the
  /// launcher and not only that a bad set was refused before it.
  final List<Map<String, Object?>> answers = <Map<String, Object?>>[];

  /// The run each start was told it continues, or null where it starts fresh. Kept for the same
  /// reason as the answers: a refusal that never reached the launcher proves nothing about what a
  /// run that WAS started was told.
  final List<RunId?> resumed = <RunId?>[];

  /// The proofs each start was told the run goes without. Kept for the same reason as the rest: an
  /// answer that MENTIONS a waiver proves nothing about what the run itself was told.
  final List<List<Mode>> waivers = <List<Mode>>[];
  int next = 1;

  @override
  Future<RunId> start({
    required ProgramName program,
    required Mode mode,
    Map<String, Object?> answers = const <String, Object?>{},
    RunId? resumes,
    List<Mode> waived = const <Mode>[],
  }) async {
    started.add((program, mode));
    this.answers.add(answers);
    resumed.add(resumes);
    waivers.add(waived);
    return RunId('run-${next++}');
  }
}

/// A minimal wire format, so an API test asserts on the API and not on a codec.
final class PlainRecordJson implements RecordJson {
  const PlainRecordJson();

  @override
  Map<String, Object?> run(RunRecord record) => <String, Object?>{
    'id': record.id.value,
    'program': record.program.value,
    'mode': record.mode.name,
    'exit': record.exitCode,
    'fingerprint': record.fingerprint,
  };

  @override
  Map<String, Object?> event(RunEvent event) => <String, Object?>{
    'sequence': event.sequence,
    'kind': event.kind,
    'step': event.step?.value,
  };
}

/// A run header with everything a test does not care about already filled in.
RunRecord runRecord({
  required String id,
  required String program,
  required Mode mode,
  required String fingerprint,
  int? exitCode,
}) => RunRecord(
  id: RunId(id),
  program: ProgramName(program),
  mode: mode,
  argv: const <String>['ansiwise-api'],
  start: DateTime.utc(2026, 8, 7),
  stage: const Stage('dev'),
  role: const Role('master'),
  fqdn: const Fqdn('m1.example.com'),
  commit: 'abc1234',
  fingerprint: fingerprint,
  end: exitCode == null ? null : DateTime.utc(2026, 8, 7, 1),
  exitCode: exitCode,
);

/// Reads [key] out of a decoded JSON object as a [List].
///
/// A test that wrote `map[key] as List<Object?>` would be casting a nullable value, and the only
/// way the analyser accepts that is the null assertion this package forbids. This says what it
/// wants and fails with the actual value when it is not there.
List<Object?> listAt(Map<String, Object?> map, String key) => switch (map[key]) {
  final List<Object?> value => value,
  final Object? other => throw StateError('$key is $other, not a list'),
};

/// Reads one element of a decoded JSON list as an object.
Map<String, Object?> objectAt(List<Object?> list, int index) => switch (list[index]) {
  final Map<String, Object?> value => value,
  final Object? other => throw StateError('element $index is $other, not an object'),
};
