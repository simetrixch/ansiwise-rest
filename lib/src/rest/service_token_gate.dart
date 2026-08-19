import 'api_message.dart';
import 'service_token.dart';

/// Closes the surface to every caller that does not hold the service token.
///
/// The gate stands BEFORE the routing, not inside the endpoints: what it wraps is the whole API as
/// one function, so every route is covered by construction — the six that exist, the 404s and 405s
/// between them, and whatever is added later without anyone remembering this gate exists. A
/// per-endpoint check is exactly the shape that leaves the seventh route open.
///
/// WHY THE STDIO DOOR DOES NOT PASS THROUGH HERE. The surface has two doors. Over an SSH session,
/// sshd already authenticated the caller, and the token cannot be demanded there without breaking
/// the one path that has to work first: on a bare machine no token exists yet — the operator app
/// places it during that very first SSH session. So each door carries its own authentication in
/// full: the channel server composes the API without this gate and sshd is the whole check there,
/// while the address server composes it with this gate and the token is the whole check here.
/// Neither door has a weaker second rule, which is how one of them would end up open.
///
/// WHY ONE REFUSAL FOR MISSING, EMPTY AND WRONG. A caller that is told "no token" when it sent
/// none, and "wrong token" when it sent one, has been told which half of its guess was right. Every
/// failure is the same status and the same words, and the comparison still runs when nothing was
/// presented, so the timing says no more than the text does.
///
/// The refusal also comes before the routing could say 404 or 405: an unauthenticated caller does
/// not get to map which paths exist.
final class ServiceTokenGate {
  /// Guards [api] with [token].
  const ServiceTokenGate(this.api, {required this.token});

  /// What answers once the caller is let through.
  final Future<ApiResponse> Function(ApiRequest request) api;

  /// What every caller must present.
  final ServiceToken token;

  /// One answer for every way of not holding the token. Static and const: a single object cannot
  /// drift into two wordings, and its text carries nothing the caller sent.
  static const Refused _refused = Refused(401, 'this surface is closed without the service token');

  /// Answers [request] when [authorization] carries the token, and refuses it otherwise.
  ///
  /// [authorization] is the request's `Authorization` header, or null where there was none. It is
  /// required rather than defaulted so no carrier can forget to pass it and serve open by accident
  /// — whoever calls this has to write down what the caller presented, even when that is nothing.
  Future<ApiResponse> call(ApiRequest request, {required String? authorization}) async {
    if (!token.matches(_presented(authorization))) {
      return _refused;
    }
    return api(request);
  }

  /// The token out of `Bearer <token>`, or null where the header has any other shape.
  ///
  /// One accepted shape only. The scheme is matched case-insensitively because HTTP says schemes
  /// are, but a bare token without the scheme is refused: a second accepted spelling is a second
  /// rule, and the null this returns still goes through the same comparison so a malformed header
  /// is indistinguishable from a wrong token in both text and time.
  static String? _presented(String? authorization) {
    const String scheme = 'bearer ';
    if (authorization == null || authorization.length <= scheme.length) {
      return null;
    }
    if (authorization.substring(0, scheme.length).toLowerCase() != scheme) {
      return null;
    }
    return authorization.substring(scheme.length);
  }
}
