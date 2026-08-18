import 'package:ansiwise_core/ansiwise_core.dart';
import '../api_message.dart';

/// Watching a run happen, and coming back to one after the connection dropped.
///
/// One endpoint serves both. A finished run's events are read out and the stream ends; a running
/// one's arrive as they happen and the stream ends when the run does. The client does not have to
/// know which case it is in, which means there is no third case where it guesses wrong.
final class EventsEndpoint {
  /// Answers from [store].
  const EventsEndpoint({required this.store, required this.json});

  /// Where the events are read from.
  final RunStore store;

  /// What puts an event on the wire.
  final RecordJson json;

  /// `GET /runs/{id}/events?from=N` — the events of a run, from a sequence number.
  ///
  /// `from` is what makes a dropped connection cost nothing. Sequence numbers are dense and never
  /// reused, so a client that holds everything up to 1233 asks for `from=1234` and gets exactly what
  /// it missed: no gap, and nothing twice.
  Future<ApiResponse> stream(RunId id, ApiRequest request) async {
    final RunRecord? run = await store.read(id);
    if (run == null) {
      return Refused.notFound('no run is called "$id"');
    }

    final int from = request.queryInt('from', orElse: 0);
    if (from < 0) {
      return const Refused.badRequest('"from" is a sequence number and cannot be negative');
    }

    return Streaming(store.events(id, from: from).map(json.event));
  }
}
