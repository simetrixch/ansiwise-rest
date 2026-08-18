import 'package:ansiwise_core/ansiwise_core.dart';

/// A step that writes a file. Reversible: the undo puts back whatever was there, or deletes it when
/// there was nothing.
final class WritesAFile extends ReversibleStep<String?> with FileStep {
  WritesAFile({required this.path, required this.content});

  final String path;

  final String content;

  @override
  String pathFor(StepContext context) => path;

  @override
  int get mode => 0x1a4;

  @override
  Future<FileContent> contentFor(StepContext context) async => FileContent.text(content);

  @override
  Future<String?> capture(StepContext context) => contentBefore(context);

  @override
  Future<void> undo(StepContext context, String? captured) async {
    if (captured == null) {
      await context.files.delete(path);
      return;
    }
    await context.files.write(path, captured, mode: mode);
  }
}

/// A step that runs a command it declares as changing something, and whose postcondition is a file
/// the command is supposed to leave behind.
final class RunsACommand extends IrreversibleStep with CommandStep {
  RunsACommand({required this.argv, required this.leaves});

  final List<String> argv;

  /// The file the command is supposed to produce, which is what proves it worked.
  final String leaves;

  @override
  String get irreversibleReason => 'the command it runs does not come with a way back';

  @override
  Command commandFor(StepContext context) => Command(argv.first, argv.sublist(1));

  @override
  Future<CheckResult> check(StepContext context) async => await context.files.exists(leaves)
      ? CheckResult.satisfied('$leaves is there')
      : const CheckResult.ready();
}

/// A step that tries to change something from inside its own check.
///
/// It exists to be refused. Nothing in the framework stops a step being written this way, and that
/// is exactly why the port has to.
final class MutatesWhileChecking extends IrreversibleStep {
  const MutatesWhileChecking();

  @override
  String get irreversibleReason => 'it is only here to be refused';

  @override
  Future<CheckResult> check(StepContext context) async {
    await context.files.write('/tmp/never', 'this must not be written', mode: 0x1a4);
    return const CheckResult.ready();
  }

  @override
  Future<StepPlan> plan(StepContext context) async => const StepPlan.nothing('nothing');

  @override
  Future<void> apply(StepContext context) async {}
}

/// A step whose plan reaches for a command it did not declare as only looking.
final class MutatesWhilePlanning extends IrreversibleStep {
  const MutatesWhilePlanning();

  @override
  String get irreversibleReason => 'it is only here to be refused';

  @override
  Future<CheckResult> check(StepContext context) async => const CheckResult.ready();

  @override
  Future<StepPlan> plan(StepContext context) async {
    await context.shell.run(const Command('rm', <String>['-rf', '/']));
    return const StepPlan.nothing('nothing');
  }

  @override
  Future<void> apply(StepContext context) async {}
}

/// A step that does its work and whose postcondition never holds afterwards.
///
/// The shape of every phase the shell had that reported success over a real failure: the command
/// returns zero, and the machine is not in the state the step is supposed to produce.
final class ClaimsSuccessWithout extends IrreversibleStep {
  const ClaimsSuccessWithout();

  @override
  String get irreversibleReason => 'it is only here to fail its own postcondition';

  @override
  Future<CheckResult> check(StepContext context) async => const CheckResult.ready();

  @override
  Future<StepPlan> plan(StepContext context) async => const StepPlan.nothing('nothing');

  @override
  Future<void> apply(StepContext context) async {
    await context.shell.run(const Command('true'));
  }
}

/// A step that cannot run, and says which precondition is missing.
final class Blocks extends IrreversibleStep {
  const Blocks(this.reason);

  final String reason;

  @override
  String get irreversibleReason => 'it never runs';

  @override
  Future<CheckResult> check(StepContext context) async => CheckResult.blocked(reason);

  @override
  Future<StepPlan> plan(StepContext context) async => const StepPlan.nothing('nothing');

  @override
  Future<void> apply(StepContext context) async {}
}

/// A condition that answers whatever it was built with.
final class Says implements Predicate {
  const Says({required this.answer, required this.because});

  final bool answer;
  final String because;

  @override
  Future<PredicateResult> evaluate(PredicateContext context) async =>
      answer ? PredicateResult.holds(because) : PredicateResult.doesNotHold(because);
}

/// A condition that cannot answer, because what it reads says nothing it can make sense of.
final class CannotSay implements Predicate {
  const CannotSay(this.because);

  final String because;

  @override
  Future<PredicateResult> evaluate(PredicateContext context) async =>
      throw ConditionUnanswerable(because);
}

/// A step that throws something the engine has no name for.
final class ThrowsSomethingElse extends IrreversibleStep {
  const ThrowsSomethingElse();

  @override
  String get irreversibleReason => 'it never gets far enough to change anything';

  @override
  Future<CheckResult> check(StepContext context) async => const CheckResult.ready();

  @override
  Future<StepPlan> plan(StepContext context) async => const StepPlan.nothing('would throw');

  @override
  Future<void> apply(StepContext context) async =>
      throw StateError('the machine did not come back');
}

/// A step that only measures the machine and finds it as it should be.
///
/// There is nothing to take it back from, which is exactly what makes it worth having here: a
/// question about what a run leaves behind must not answer "this step" for something that leaves
/// nothing. Only its KIND says so — the class is neither reversible nor irreversible — so a reader
/// asking merely "is it a ReversibleStep" gets the wrong answer about it.
final class Measures extends ObservingStep {
  const Measures(this.because);

  final String because;

  @override
  Future<CheckResult> check(StepContext context) async => CheckResult.satisfied(because);

  @override
  Future<StepPlan> plan(StepContext context) async => StepPlan.nothing(because);
}

/// A wait whose command comes from the program row, so its answer rests on the row's word.
///
/// The row declares that the command only looks. No code chose that command, so the framework
/// cannot verify the claim — the step says so through its trust flag, and the engine stamps every
/// row of it declared, however the wait comes out.
final class WaitsOnTheRowsWord extends ObservingStep with WaitStep {
  const WaitsOnTheRowsWord({required this.command});

  /// What the row said to ask.
  final String command;

  @override
  bool get answersOnTrust => true;

  @override
  Duration get deadline => const Duration(seconds: 60);

  @override
  Duration get interval => const Duration(seconds: 10);

  @override
  String get waitingFor => 'the command the row names to answer';

  @override
  Future<({bool held, String? saw})> holds(StepContext context) async {
    final CommandResult answered = await context.shell.run(
      Command.detailed(command, observes: true, timeout: deadline),
    );
    return answered.ok && answered.trimmed.isNotEmpty
        ? (held: true, saw: null)
        : (held: false, saw: 'it answered "${answered.trimmed}"');
  }
}

/// A gate whose whole job is verifying an earlier step, asked before that step has run.
///
/// The one row in this framework that ends up declared. Its check cannot hold in a mode where
/// nothing was applied — what it looks for is not there, through no fault of the machine — so the
/// engine carries the run past it on the strength of what it says it WOULD check. Nothing measured
/// that, and the record has to say so rather than count the row among the measured ones.
final class VerifiesWhatRanBefore extends ObservingStep {
  const VerifiesWhatRanBefore();

  @override
  bool get restsOnAnEarlierStep => true;

  @override
  Future<CheckResult> check(StepContext context) async =>
      const CheckResult.blocked('the file the earlier step writes is not there');

  @override
  Future<StepPlan> plan(StepContext context) async =>
      const StepPlan.nothing('would read back what the earlier step wrote');
}

/// A step that reads the machine and publishes what it read, the way a real measuring step does.
///
/// It measures inside its CHECK, which is where an observing step has to: its apply does nothing and
/// is never reached once the check is satisfied. So it publishes in every mode, and what a mode that
/// changes nothing does with the value is the engine's decision rather than this step's.
final class MeasuresAndPublishes extends ObservingStep {
  const MeasuresAndPublishes({required this.file, required this.publishes});

  /// The file it reads the value out of.
  final String file;

  /// The name it publishes under.
  final MeasurementName publishes;

  @override
  Future<CheckResult> check(StepContext context) async {
    if (!await context.files.exists(file)) {
      // Nothing read is not a value. A step answering with one here would put a sentence in the
      // record about a machine nobody measured.
      return CheckResult.blocked('$file could not be read, so nothing here says what it holds');
    }
    final String found = (await context.files.read(file)).trim();
    context.measurements.publish(publishes, found);
    return CheckResult.satisfied('$file says $found');
  }
}

/// A step that publishes a name its registry entry does not declare.
final class PublishesWhatItNeverDeclared extends ObservingStep {
  const PublishesWhatItNeverDeclared(this.name);

  final MeasurementName name;

  @override
  Future<CheckResult> check(StepContext context) async {
    context.measurements.publish(name, 'something');
    return const CheckResult.satisfied('published');
  }
}

/// A step that publishes an empty reading, which is not a reading.
final class PublishesNothing extends ObservingStep {
  const PublishesNothing(this.name);

  final MeasurementName name;

  @override
  Future<CheckResult> check(StepContext context) async {
    context.measurements.publish(name, '');
    return const CheckResult.satisfied('published');
  }
}

/// A step that writes whatever its `content` argument holds, reading it as an optional one.
///
/// The shape a step takes when a row may fill one of its arguments from a measurement: the value is
/// absent while the program is being examined, and the step still builds.
final class WritesWhatItWasGiven extends ReversibleStep<String?> with FileStep {
  WritesWhatItWasGiven({required this.path, required this.content});

  factory WritesWhatItWasGiven.fromArguments(Arguments arguments) => WritesWhatItWasGiven(
    path: arguments.text('path'),
    content: arguments.optionalText('content') ?? '',
  );

  /// What this step accepts. `content` is not required, so the step builds while the value that
  /// fills it does not exist yet.
  static const List<ArgumentSpec> arguments = <ArgumentSpec>[
    ArgumentSpec(name: 'path', kind: ArgumentKind.text, describes: 'the file it writes'),
    ArgumentSpec(
      name: 'content',
      kind: ArgumentKind.text,
      describes: 'what goes in it',
      required: false,
    ),
  ];

  final String path;

  final String content;

  @override
  String pathFor(StepContext context) => path;

  @override
  int get mode => 0x1a4;

  @override
  Future<FileContent> contentFor(StepContext context) async => FileContent.text(content);

  @override
  Future<String?> capture(StepContext context) => contentBefore(context);

  @override
  Future<void> undo(StepContext context, String? captured) async => captured == null
      ? context.files.delete(path)
      : context.files.write(path, captured, mode: mode);
}

/// A step that reads its value while it is being built, so it cannot be built without one.
final class NeedsItsValueToBeBuilt extends ObservingStep {
  const NeedsItsValueToBeBuilt(this.content);

  factory NeedsItsValueToBeBuilt.fromArguments(Arguments arguments) =>
      NeedsItsValueToBeBuilt(arguments.text('content'));

  static const List<ArgumentSpec> arguments = <ArgumentSpec>[
    ArgumentSpec(
      name: 'content',
      kind: ArgumentKind.text,
      describes: 'what it was given',
      required: false,
    ),
  ];

  final String content;

  @override
  Future<CheckResult> check(StepContext context) async => CheckResult.satisfied(content);
}

/// A step that changes something and THEN throws, which is the partial apply an undo exists for.
///
/// The shape every real one has: it does several things and the second fails. `patch_container_
/// arguments_and_ports` in this platform's plugin patches a workload declaration and then replaces
/// the pods, and a delete that returns non-zero throws with the declaration already changed.
final class ChangesThenThrows extends ReversibleStep<String?> with FileStep {
  ChangesThenThrows({required this.path});

  final String path;

  @override
  String pathFor(StepContext context) => path;

  @override
  int get mode => 0x1a4;

  @override
  Future<FileContent> contentFor(StepContext context) async => const FileContent.text('written');

  @override
  Future<String?> capture(StepContext context) => contentBefore(context);

  @override
  Future<void> apply(StepContext context) async {
    await super.apply(context);
    throw CommandFailed(
      argv: const <String>['second'],
      exitCode: 1,
      stdout: '',
      stderr: 'the second act failed',
    );
  }

  @override
  Future<void> undo(StepContext context, String? captured) async => captured == null
      ? context.files.delete(path)
      : context.files.write(path, captured, mode: mode);
}
