import 'dart:convert';

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
/// deployment program on the machine. A file is read by the service alone and crosses into
/// nothing; its PATH may travel through argv and config freely, because the path is not the secret.
/// It also survives a reboot, which a resident service must, and it is the shape an init system's
/// own credential passing can point at later without a line here changing.
///
/// One of these is ONE credential. What a surface accepts is a [ServiceTokens], because replacing a
/// credential needs two of them accepted at once for as long as the replacement takes.
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
  ///
  /// A value with a line break inside it is refused for a second reason: the file a token is placed
  /// in holds ONE TOKEN PER LINE, so such a value cannot be written down and read back as itself.
  /// It would come back as two tokens, each of which lets in a caller nobody meant to let in.
  factory ServiceToken(String value) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('a service token must not be empty');
    }
    if (trimmed.contains('\n') || trimmed.contains('\r')) {
      throw ArgumentError('a service token is one line: it is placed in a file of one per line');
    }
    return ServiceToken._(utf8.encode(trimmed));
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

/// Every token the surface accepts at one moment.
///
/// WHY A SET AND NOT ONE TOKEN. A single accepted token cannot be replaced without a gap: the act
/// that writes the new value into the file is the same act that takes the old one away, so a
/// manager holding the old one loses the machine at that instant and finds out by being refused.
/// With a set, replacing a token is three acts, each done when whoever owns the machine says so:
///
///  1. the new token is placed BESIDE the old one. Both are accepted from then on, and nothing has
///     stopped working. No restart stands between the file being written and the machine agreeing —
///     `ServiceTokenFile` is read again for every decision.
///  2. the manager is moved to the new token. Any request it answers is the proof that this machine
///     accepts it, and that proof is available while the old token still works.
///  3. the old token is removed. THAT act is when it stops working, and it is not the act that
///     placed the new one.
///
/// The overlap lasts exactly as long as the operator leaves it: nothing here ends it, and a set
/// that still holds a token nobody uses any more accepts it until its line is deleted.
@immutable
final class ServiceTokens {
  /// Accepts every token in [accepted], and nothing else.
  ///
  /// An empty set is refused for the reason an empty [ServiceToken] is: what would come of it is a
  /// surface that answers every caller the same way while guarding nothing, and the refusal here
  /// turns that into a machine that does not serve.
  factory ServiceTokens.of(Iterable<ServiceToken> accepted) {
    final List<ServiceToken> tokens = List<ServiceToken>.unmodifiable(accepted);
    if (tokens.isEmpty) {
      throw ArgumentError('a surface accepts at least one service token');
    }
    return ServiceTokens._(tokens);
  }

  /// Reads the set out of the [contents] of a token file: ONE TOKEN PER LINE.
  ///
  /// Blank lines are not tokens, so a file holding one pasted value — with or without the trailing
  /// newline it was written with — is a set of exactly one, which is what every machine installed
  /// so far holds. Placing a token is appending a line and retiring one is deleting its line;
  /// nothing else in the file carries meaning, and there is no order to keep.
  factory ServiceTokens.parse(String contents) => ServiceTokens.of(
    contents
        .split('\n')
        .map((String line) => line.trim())
        .where((String line) => line.isNotEmpty)
        .map(ServiceToken.new),
  );

  const ServiceTokens._(this._accepted);

  final List<ServiceToken> _accepted;

  /// How many tokens are accepted: one on a machine that is not being rotated, two while it is.
  int get count => _accepted.length;

  /// Whether [presented] is one of the accepted tokens.
  ///
  /// EVERY token is compared, every time. The `|` is not `||`: both sides are evaluated, so a match
  /// on the first token does not end the loop and the answer costs the same whether the presented
  /// value matched the first, matched the last, or matched none. With `||` the time an answer took
  /// would say WHICH token the caller held — telling a manager already moved to the new token from
  /// one still on the old, and telling an attacker which of its guesses was the closer one — which
  /// is more than [ServiceToken.matches] gives away about a single token.
  ///
  /// What the timing does still say is HOW MANY tokens are accepted, because that is how many
  /// comparisons run. That says a replacement is in progress. It says nothing about the values.
  bool matches(String? presented) {
    bool accepted = false;
    for (final ServiceToken token in _accepted) {
      accepted |= token.matches(presented);
    }
    return accepted;
  }

  /// The count and nothing else, for the reason [ServiceToken.toString] says nothing.
  @override
  String toString() => 'ServiceTokens($count, redacted)';
}
