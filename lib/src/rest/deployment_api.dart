import 'package:ansiwise_core/ansiwise_core.dart';
import 'api_message.dart';
import 'endpoints/events_endpoint.dart';
import 'endpoints/programs_endpoint.dart';
import 'endpoints/runs_endpoint.dart';

/// The whole surface, in one place.
///
/// Six routes and no framework. A table of routes matched by hand is longer to read than a
/// declaration, and it is the thing a reader can follow from a request to the code that answers it
/// without learning anything first — which matters more here than the lines saved.
///
/// Nothing in this class or below it knows how a request arrived. That is what lets the same API be
/// served over an SSH channel today, be tested by calling it with a request, and be carried by
/// something else later without an endpoint changing.
final class DeploymentApi {
  /// Composes the endpoints.
  const DeploymentApi({required this.programs, required this.runs, required this.events});

  /// What answers about programs.
  final ProgramsEndpoint programs;

  /// What answers about runs.
  final RunsEndpoint runs;

  /// What answers about a run's events.
  final EventsEndpoint events;

  /// Answers [request].
  Future<ApiResponse> call(ApiRequest request) async {
    final List<String> path = request.segments;
    final String method = request.method.toUpperCase();

    return switch ((method, path)) {
      ('GET', ['programs']) => programs.list(),
      ('GET', ['programs', final String name]) => programs.one(ProgramName(name)),
      ('GET', ['runs']) => runs.list(request),
      ('POST', ['runs']) => runs.start(request),
      ('GET', ['runs', final String id]) => runs.one(RunId(id)),
      ('GET', ['runs', final String id, 'events']) => events.stream(RunId(id), request),
      // A path that exists under another method is a different answer from one that does not exist
      // at all: the first is a mistake in the client, the second may be an older client talking to a
      // newer machine, and an operator reading a failure needs to be able to tell them apart.
      (_, ['programs']) ||
      (_, ['programs', _]) ||
      (_, ['runs']) ||
      (_, ['runs', _]) ||
      (_, ['runs', _, 'events']) => Refused(405, '$method is not how this is asked for'),
      _ => Refused.notFound('${request.uri.path} is not part of this API'),
    };
  }
}
