import 'dart:io';

import 'service_token.dart';

/// The file every token the surface accepts is written in, read again for every decision.
///
/// The file IS the state: whichever tokens stand in it at the moment a request arrives are the
/// tokens that reach the machine. Placing a token is appending a line to it and retiring one is
/// deleting that line, both as root — see [ServiceTokens] for what those two acts amount to
/// together, which is replacing a credential without a gap.
///
/// WHY IT IS READ AGAIN FOR EVERY REQUEST, and not once at start-up. A set read once changes only
/// when the process restarts, and a restart is exactly the thing a rotation may not need: the
/// service is down for the length of it, so the manager cannot reach the machine — and the moment
/// it is down is the moment somebody is changing its credential, which is when they most need to
/// see whether the change worked. A timer that re-read every so often would trade that outage for a
/// lag between the operator's act and the machine agreeing to it, and the operator has no way to
/// see when the lag is over. Reading here has neither: the token placed a second ago works on the
/// next request, and the token retired a second ago is refused on the next request.
///
/// WHAT THE READ COSTS. One small file per request, on the same disk this surface already reads for
/// every request that touches a run — the core's `FileRunStore.list` walks the run directory, and
/// `FileRunStore.read` reads a run's record file. A request that touches no run, `GET /programs`
/// among them, is answered out of `Catalogue.programs` in memory and pays this read alone. A disk
/// that cannot answer takes this surface away whether or not the token is read from it.
///
/// WHAT A FAILED READ MEANS. Nothing changes: the last set that was read whole keeps deciding. The
/// ordinary way this file is written is a truncate followed by a write, so a reader that arrives in
/// between finds it empty — and a reader that believed it would refuse every caller until the next
/// write, which is the outage this whole type exists to avoid. A failed read never widens what is
/// accepted either; it only keeps what already was.
///
/// WHAT THAT COSTS AN OPERATOR WHO WANTS A TOKEN GONE. Emptying this file, or deleting it, retires
/// NOTHING while the service runs: both are failed reads, and the last set stands until the process
/// restarts. A token stops working by its line being deleted while at least one other line remains.
final class ServiceTokenFile {
  /// The tokens written at [path].
  ServiceTokenFile(this.path);

  /// Where the tokens stand. Placed by the operator app at installation, readable by root alone.
  final String path;

  /// The last set read whole, and what a later failed read falls back to.
  ServiceTokens? _lastRead;

  /// Reads the file and takes what it holds as the accepted set.
  ///
  /// Throws [FileSystemException] naming the path when the file is not there, and [StateError]
  /// naming it when it holds no token or holds a line that is not one: a machine whose token was
  /// never placed must refuse to serve, not serve openly. `ListeningHttpServer.serve` calls this
  /// before it binds, so an address is never stood on by a service that has nothing to guard it
  /// with.
  ///
  /// THOSE TWO ARE THE WHOLE SET. A line [ServiceToken] refuses — one holding a carriage return
  /// inside it, which `trim` does not take off — arrives here as an [ArgumentError], and it is
  /// turned into the same [StateError] rather than let out as a third type. Everything that acts on
  /// a failure to start reads one of these two and says what the machine's state is; a type neither
  /// of them names is a stack trace in the place where that sentence belongs.
  Future<ServiceTokens> read() async {
    final String raw = await File(path).readAsString();
    if (raw.trim().isEmpty) {
      throw StateError('the service token file at $path is empty');
    }
    final ServiceTokens tokens;
    try {
      tokens = ServiceTokens.parse(raw);
      // Caught because on this path a refused line is not a fault of the code but a file somebody
      // wrote by hand, and the only two failures anything acting on this start-up reads are the
      // ones above. The message carries no token value — `ServiceToken` refuses a line without
      // quoting it — so it is safe to write wherever a start-up failure is written.
      // ignore: avoid_catching_errors
    } on ArgumentError catch (malformed) {
      throw StateError(
        'the service token file at $path holds a line that is not a token: ${malformed.message}',
      );
    }
    _lastRead = tokens;
    return tokens;
  }

  /// The set to decide the request in hand with.
  ///
  /// [read], and the last set that read whole where this read did not — a file being rewritten, a
  /// file whose permissions changed under the service, a disk that answered with an error. Only a
  /// path that has never once been read whole has nothing to fall back on, and that one throws,
  /// because the alternative is answering a caller from a set nobody ever wrote.
  Future<ServiceTokens> accepted() async {
    try {
      return await read();
    } on Object {
      final ServiceTokens? standing = _lastRead;
      if (standing == null) {
        rethrow;
      }
      return standing;
    }
  }
}
