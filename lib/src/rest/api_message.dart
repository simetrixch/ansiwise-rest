/// What the API is asked, and what it answers — with no transport in either.
///
/// Neither of these knows about a socket, a pipe or `dart:io`. That is what makes every endpoint
/// testable by calling it with a request and looking at what came back, and it is what lets the same
/// API be served over an SSH channel today and over something else later without a line of the
/// endpoints changing.
library;

import 'package:meta/meta.dart';

/// One request.
@immutable
final class ApiRequest {
  /// Describes a request.
  const ApiRequest(this.method, this.uri, {this.body});

  /// The request method, upper case.
  final String method;

  /// The path and query asked for.
  final Uri uri;

  /// The body, or null when there is none.
  final String? body;

  /// The path split on slashes, with empty parts removed.
  List<String> get segments => uri.pathSegments.where((String s) => s.isNotEmpty).toList();

  /// The query value of [name], or null.
  String? query(String name) => uri.queryParameters[name];

  /// The query value of [name] as a whole number, or [orElse] when it is absent or not a number.
  int queryInt(String name, {required int orElse}) =>
      int.tryParse(uri.queryParameters[name] ?? '') ?? orElse;
}

/// What an endpoint answers with.
///
/// Sealed, so whatever carries it to the client has to handle every kind. The three are genuinely
/// different on the wire: one is a document, one is a stream that stays open while a run happens,
/// and one is a refusal.
@immutable
sealed class ApiResponse {
  const ApiResponse();

  /// The status code.
  int get status;
}

/// A document.
@immutable
final class Answered extends ApiResponse {
  /// Answers with [payload] at [status].
  const Answered(this.payload, {this.status = 200});

  /// What is sent, as maps, lists, strings, numbers and booleans.
  final Object payload;

  @override
  final int status;
}

/// A stream that stays open, one JSON object per line.
///
/// This is how a run is watched. The client reads lines as they arrive rather than waiting for the
/// run to end, and the stream closes when the run does.
@immutable
final class Streaming extends ApiResponse {
  /// Answers by streaming [items], each as one line of JSON.
  const Streaming(this.items);

  /// The objects to send, in order.
  final Stream<Object> items;

  @override
  int get status => 200;
}

/// A refusal.
///
/// Carries a reason written for whoever has to act on it, not a status code alone. An operator who
/// is told only "409" has to go and find out what this endpoint means by it.
@immutable
final class Refused extends ApiResponse {
  /// Refuses with [reason] at [status].
  const Refused(this.status, this.reason);

  /// Nothing is registered under the name that was asked for.
  const Refused.notFound(String what) : this(404, what);

  /// The request itself does not add up.
  const Refused.badRequest(String why) : this(400, why);

  /// The request is understood and not allowed yet.
  const Refused.notYet(String why) : this(409, why);

  @override
  final int status;

  /// What is wrong, in the operator's words.
  final String reason;
}
