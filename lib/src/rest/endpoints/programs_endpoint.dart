import 'package:ansiwise_core/ansiwise_core.dart';
import '../api_message.dart';

/// What the client renders its form and its step list from.
///
/// The client has no hard-coded field and no hard-coded list of programs. It asks here and shows
/// what `deployment/` declares, so a new input appears in the form without a line of the client
/// changing — and a client pointed at a different deployment shows that one's programs.
final class ProgramsEndpoint {
  /// Answers from [catalogue].
  const ProgramsEndpoint(this.catalogue);

  /// The programs this deployment declares.
  final Catalogue catalogue;

  /// `GET /programs` — every program, with its steps.
  ApiResponse list() => Answered(<String, Object?>{
    'programs': <Object?>[
      for (final ResolvedProgram program in catalogue.programs) _describe(program),
    ],
  });

  /// `GET /programs/{name}` — one program.
  ApiResponse one(ProgramName name) {
    final ResolvedProgram? program = catalogue.byName(name);
    if (program == null) {
      return Refused.notFound('no program is called "$name"');
    }
    return Answered(_describe(program));
  }

  Map<String, Object?> _describe(ResolvedProgram program) => <String, Object?>{
    'name': program.declared.name.value,
    'roles': <String>[for (final Role role in program.declared.roles) role.value],
    'steps': <Object?>[for (final ResolvedStep step in program.steps) _describeStep(step)],
    // What the client builds its form out of. A field is described here or it does not exist, which
    // is what lets one app stand in front of any plugin.
    'answers': <Object?>[
      for (final ArgumentSpec spec in program.declared.answers.specs)
        <String, Object?>{
          'name': spec.name,
          'kind': spec.kind.name,
          'describes': spec.describes,
          'required': spec.required,
          'secret': spec.secret,
          // Absent where anything of the kind will do, so a client tells "one of these" from "any
          // text" by whether the key is there rather than by an empty list it has to interpret.
          if (spec.allowed.isNotEmpty) 'allowed': spec.allowed,
          // A secret has no default — the loader refuses one — so this can never carry a
          // credential out.
          if (spec.hasDefault) 'default': spec.defaultValue,
        },
    ],
  };

  Map<String, Object?> _describeStep(ResolvedStep resolved) {
    // The step is built in order to ask it whether it can be undone. The registry holds a factory
    // and not an instance, so there is no other way to know — and this is the one thing the client
    // cannot derive for itself, because it is a property of the class rather than of the program
    // file.
    //
    // WITH ITS DEFAULTS, or a step reading an argument it declared a default for is refused as it is
    // built and this endpoint answers with a failure instead of a description.
    final Step step = resolved.registered.create(resolved.argumentsWithDefaults);
    return <String, Object?>{
      'step': resolved.entry.step.value,
      'source': resolved.registered.source,
      'on_failure': resolved.entry.onFailure.name,
      'when': <String>[
        for (final RegisteredPredicate predicate in resolved.when) predicate.name.value,
      ],
      // What this RUN would be able to take back, which is not the same as what the step can do: a
      // program row saying `undo: false` leaves a reversible step standing. A client showing the
      // step's own capability where the program has switched it off would promise a way back that
      // this run does not have.
      'reversible': step is ReversibleStep && resolved.entry.undo,
      'undo': resolved.entry.undo,
      if (step is IrreversibleStep) 'irreversible_reason': step.irreversibleReason,
      'arguments': <Object?>[
        for (final ArgumentSpec spec in resolved.registered.arguments)
          <String, Object?>{
            'name': spec.name,
            'kind': spec.kind.name,
            'describes': spec.describes,
            'required': spec.required,
            'secret': spec.secret,
            // A secret is reported as set or unset and never by value. The client that typed it
            // does not need it back, and the description travels further than the run does.
            if (spec.secret)
              'set': resolved.entry.arguments.has(spec.name)
            // What this row will actually run with — and for a measured value that is a NAME and
            // not a value, because the value does not exist until the row that takes it has run.
            // Reporting the step's default instead would show a value this row never uses: the
            // default is what lets the step be built while the program is described, nothing more.
            else if (resolved.measurementFor(spec.name) case final MeasuredArgument measured)
              'measured': <String, Object?>{
                'name': measured.measurement.value,
                'produced_by': measured.publisher.value,
                'position': measured.position,
              }
            else
              'value': resolved.entry.arguments.raw(spec.name) ?? spec.defaultValue,
          },
      ],
    };
  }
}
