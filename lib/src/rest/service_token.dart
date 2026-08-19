import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

/// The credential of the surface when it is reached over an address.
///
/// Over an SSH channel the surface never needed one: the session WAS the authentication. On an
/// address there is no session, so the surface carries its own — one token, placed by the operator
/// app at the machine's first installation, allowed to do everything the surface can do. That
/// breadth is the owner's decision, not an omission: one machine, one operator, one credential, and
/// a scoping model would be complexity spent guarding the machine from the only party who owns it.
///
/// WHY A FILE AND NOT ARGV OR THE ENVIRONMENT. A value in argv is in every process listing on the
/// machine. A value in the environment is inherited by every child the service starts — and this
/// service exists to start detached runs (`Process.start` in the core's DetachedLauncher passes no
/// `environment:`, so a child gets the parent's whole one), which would hand the token to every
/// deployment program on the machine. A file is read once, held in memory, and crosses into
/// nothing; its PATH may travel through argv and config freely, because the path is not the secret.
/// It also survives a reboot, which a resident service must, and it is the shape an init system's
/// own credential passing can point at later without a line here changing.
///
/// WHY NOTHING HERE ROTATES. Rotation is deferred, deliberately. This type keeps it cheap rather
/// than hard: the token is a plain value handed in at construction, nothing caches it beyond the
/// process, so rotating later is writing a new file and restarting the service.
@immutable
final class ServiceToken {
  /// Holds [value] as the expected token.
  ///
  /// Surrounding whitespace is not part of a token — a file written with a trailing newline and a
  /// value pasted without one must be the same credential.
  ///
  /// An empty value is refused here, at construction, because an empty expected token would let an
  /// empty presented one through — the surface would stand open while looking guarded. Failing to
  /// start is the fail-closed answer.
  factory ServiceToken(String value) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('a service token must not be empty');
    }
    return ServiceToken._(utf8.encode(trimmed));
  }

  /// Reads the token from the file at [path].
  ///
  /// A missing file throws with the path in it, and an empty file is refused the same way an empty
  /// value is: a machine whose token was never placed must refuse to serve, not serve openly.
  factory ServiceToken.fromFile(String path) {
    final String raw = File(path).readAsStringSync();
    if (raw.trim().isEmpty) {
      throw StateError('the service token file at $path is empty');
    }
    return ServiceToken(raw);
  }

  const ServiceToken._(this._expected);

  /// The expected token's bytes. Bytes rather than the string, so nothing here re-encodes on every
  /// request and no accessor exists that hands the value back out.
  final List<int> _expected;

  /// Whether [presented] is the token.
  ///
  /// In constant time over the expected length: every byte is folded into one accumulator and the
  /// loop never leaves early, so a caller measuring response times learns nothing about how much of
  /// a guess was right. An early-out comparison would leak the matching prefix's length, and a
  /// token can be recovered from that one byte at a time.
  ///
  /// A null is compared like everything else rather than answered before the loop, so a missing
  /// credential takes the same time as a wrong one.
  bool matches(String? presented) {
    final List<int> given = utf8.encode(presented ?? '');
    int difference = given.length ^ _expected.length;
    for (int i = 0; i < _expected.length; i++) {
      difference |= _expected[i] ^ (i < given.length ? given[i] : 0);
    }
    return difference == 0;
  }

  /// Never the value: this object reaches error messages and debug output by accident, and what it
  /// says there must be safe to write anywhere.
  @override
  String toString() => 'ServiceToken(redacted)';
}
