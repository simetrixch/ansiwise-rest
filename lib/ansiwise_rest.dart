/// The REST surface of a deployment: what it is asked, what it answers, and how it is served.
///
/// Neither the messages nor the endpoints know about a socket, a pipe or `dart:io`. That is what
/// makes every endpoint testable by calling it with a request and looking at what came back, and it
/// is what lets the same surface be served over an SSH channel today and over something else later
/// without a line of the endpoints changing.
library;

export 'src/rest/api_message.dart';
export 'src/rest/channel_http_server.dart';
export 'src/rest/deployment_api.dart';
export 'src/rest/endpoints/events_endpoint.dart';
export 'src/rest/endpoints/programs_endpoint.dart';
export 'src/rest/endpoints/runs_endpoint.dart';
