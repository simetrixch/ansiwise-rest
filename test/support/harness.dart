import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:ansiwise_core/testing.dart';

/// Everything one run needs, built once so a test says what it is testing and not how to start it.
final class Harness {
  Harness({
    FakeShell? shell,
    FakeFiles? files,
    FakeHttp? http,
    FakeClock? clock,
    FakeEntropy? entropy,
    Iterable<String> secrets = const <String>[],
  }) : shell = shell ?? FakeShell(),
       files = files ?? FakeFiles(),
       http = http ?? FakeHttp(),
       clock = clock ?? FakeClock(),
       entropy = entropy ?? FakeEntropy() {
    recorder = MemoryRecorder(this.clock);
    redactor = Redactor(secrets);
    machine = Machine(
      shell: this.shell,
      files: this.files,
      http: this.http,
      clock: this.clock,
      entropy: this.entropy,
    );
  }

  final FakeShell shell;
  final FakeFiles files;
  final FakeHttp http;
  final FakeClock clock;
  final FakeEntropy entropy;

  late final MemoryRecorder recorder;
  late final Redactor redactor;
  late final Machine machine;

  Runner get runner => Runner(machine: machine, recorder: recorder, redactor: redactor);

  /// A run header with the values a test does not care about already filled in.
  RunRecord header({String program = 'example', Mode mode = Mode.run, String role = 'master'}) =>
      RunRecord(
        id: const RunId('20260807T000000Z-1'),
        program: ProgramName(program),
        mode: mode,
        argv: <String>['service', program],
        start: clock.now(),
        stage: const Stage('dev'),
        role: Role(role),
        fqdn: const Fqdn('m1.example.com'),
        commit: '0000000',
        fingerprint: 'test-fingerprint',
      );
}

/// Builds a registry from steps given as name, source, factory.
Registry registryOf({
  Map<String, (String, Step Function(Arguments))> steps =
      const <String, (String, Step Function(Arguments))>{},
  Map<String, Predicate> predicates = const <String, Predicate>{},
  Map<String, List<ArgumentSpec>> arguments = const <String, List<ArgumentSpec>>{},
  Map<String, List<MeasurementSpec>> publishes = const <String, List<MeasurementSpec>>{},
}) => Registry(
  steps: <StepName, RegisteredStep>{
    for (final MapEntry<String, (String, Step Function(Arguments))> e in steps.entries)
      StepName(e.key): RegisteredStep(
        name: StepName(e.key),
        source: e.value.$1,
        create: e.value.$2,
        arguments: arguments[e.key] ?? const <ArgumentSpec>[],
        publishes: publishes[e.key] ?? const <MeasurementSpec>[],
      ),
  },
  predicates: <PredicateName, RegisteredPredicate>{
    for (final MapEntry<String, Predicate> e in predicates.entries)
      PredicateName(e.key): RegisteredPredicate(
        name: PredicateName(e.key),
        source: 'test/support/example_steps.dart:1',
        predicate: e.value,
        describes: e.key,
      ),
  },
);

/// Builds a program from entries given as step name, failure policy and conditions.
Program programOf(
  String name,
  List<(String, OnFailure, List<String>)> entries, {
  List<String> roles = const <String>['master'],
  Map<String, Arguments> arguments = const <String, Arguments>{},
  Map<String, Map<String, MeasurementName>> reads = const <String, Map<String, MeasurementName>>{},
  DeclaredAnswers answers = DeclaredAnswers.none,
  Arguments defaults = Arguments.none,
  Set<String> undoOff = const <String>{},
  Set<String> keepOutput = const <String>{},
}) => Program(
  name: ProgramName(name),
  answers: answers,
  defaults: defaults,
  roles: roles.map(Role.new).toList(growable: false),
  steps: <ProgramStep>[
    for (final (String, OnFailure, List<String>) entry in entries)
      ProgramStep(
        step: StepName(entry.$1),
        onFailure: entry.$2,
        arguments: arguments[entry.$1] ?? Arguments.none,
        reads: reads[entry.$1] ?? const <String, MeasurementName>{},
        when: entry.$3.map(PredicateName.new).toList(growable: false),
        undo: !undoOff.contains(entry.$1),
        keepsOutput: keepOutput.contains(entry.$1),
      ),
  ],
);
