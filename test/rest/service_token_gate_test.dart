import 'package:ansiwise_rest/src/rest/api_message.dart';
import 'package:ansiwise_rest/src/rest/service_token.dart';
import 'package:ansiwise_rest/src/rest/service_token_gate.dart';
import 'package:test/test.dart';

/// The gate in front of the surface: the accepted tokens, checked on every route, fail-closed.
void main() {
  const String theToken = 'sesame-open-42';
  const String theOtherToken = 'the-one-being-moved-to-99';

  ({ServiceTokenGate gate, List<ApiRequest> reached}) build([
    List<String> accepted = const <String>[theToken],
  ]) {
    final List<ApiRequest> reached = <ApiRequest>[];
    Future<ApiResponse> answering(ApiRequest request) async {
      reached.add(request);
      return const Answered(<String, Object?>{'ok': true});
    }

    final ServiceTokens tokens = ServiceTokens.of(accepted.map(ServiceToken.new));
    return (gate: ServiceTokenGate(answering, accepted: () async => tokens), reached: reached);
  }

  ApiRequest request([String path = '/programs']) => ApiRequest('GET', Uri.parse(path));

  group('the right token is let through', () {
    test('a Bearer header carrying the token reaches the API', () async {
      final ({ServiceTokenGate gate, List<ApiRequest> reached}) it = build();
      final ApiResponse answer = await it.gate.call(request(), authorization: 'Bearer $theToken');
      expect(answer, isA<Answered>());
      expect(it.reached, hasLength(1), reason: 'the request itself must have reached the API');
    });

    test('the scheme is matched case-insensitively, because HTTP says schemes are', () async {
      final ApiResponse answer = await build().gate.call(
        request(),
        authorization: 'bearer $theToken',
      );
      expect(answer, isA<Answered>());
    });
  });

  group('missing, empty and wrong are one and the same refusal', () {
    const List<String?> everyWayOfNotHoldingIt = <String?>[
      null,
      '',
      'Bearer ',
      'Bearer wrong',
      'Basic $theToken',
      // The right value in the wrong shape: one accepted spelling, not two.
      theToken,
      // Almost the token, from either end and by case — a prefix match may not read differently
      // from no match at all.
      'Bearer sesame-open-4',
      'Bearer $theToken-and-more',
      'Bearer SESAME-OPEN-42',
    ];

    test('every one of them gets the identical answer, and none reaches the API', () async {
      final ({ServiceTokenGate gate, List<ApiRequest> reached}) it = build();
      final Set<(int, String)> answers = <(int, String)>{};
      for (final String? authorization in everyWayOfNotHoldingIt) {
        final ApiResponse answer = await it.gate.call(request(), authorization: authorization);
        expect(answer, isA<Refused>(), reason: '"$authorization" must not pass');
        answers.add(((answer as Refused).status, answer.reason));
      }
      expect(
        answers,
        hasLength(1),
        reason: 'two distinguishable refusals tell a caller which half of a guess was right',
      );
      expect(it.reached, isEmpty, reason: 'a refused request may not have touched the API at all');
    });

    test('an unknown path is refused before the routing could say 404', () async {
      final ApiResponse answer = await build().gate.call(
        request('/something-else'),
        authorization: 'Bearer wrong',
      );
      expect(
        (answer as Refused).status,
        401,
        reason: 'an unauthenticated caller does not get to map which paths exist',
      );
    });

    test('the refusal never carries what was presented, nor the token itself', () async {
      final ApiResponse answer = await build().gate.call(
        request(),
        authorization: 'Bearer almost-$theToken',
      );
      final Refused refused = answer as Refused;
      expect(refused.reason, isNot(contains(theToken)));
      expect(refused.reason, isNot(contains('almost-')));
    });
  });

  group('what cannot guard the surface cannot even be built', () {
    test('empty and whitespace-only values are refused at construction', () {
      expect(() => ServiceToken(''), throwsArgumentError);
      expect(
        () => ServiceToken('  \n'),
        throwsArgumentError,
        reason: 'an empty expected token would let an empty presented one through',
      );
    });

    test('a value with a line break in it is refused, because a line is what holds it', () {
      expect(
        () => ServiceToken('$theToken\n$theOtherToken'),
        throwsArgumentError,
        reason: 'written into the token file it would come back as two tokens, not as itself',
      );
      expect(() => ServiceToken('$theToken\r$theOtherToken'), throwsArgumentError);
    });

    test('the token itself never appears in its own toString', () {
      expect(ServiceToken(theToken).toString(), isNot(contains(theToken)));
    });

    test('an empty set of accepted tokens is refused the same way', () {
      expect(
        () => ServiceTokens.of(<ServiceToken>[]),
        throwsArgumentError,
        reason: 'a surface that accepts nothing is not guarded, it is unreachable',
      );
    });

    test('a set says how many it holds and never what they are', () {
      final ServiceTokens two = ServiceTokens.of(<ServiceToken>[
        ServiceToken(theToken),
        ServiceToken(theOtherToken),
      ]);
      expect(two.count, 2);
      expect(two.toString(), isNot(contains(theToken)));
      expect(two.toString(), isNot(contains(theOtherToken)));
    });
  });

  group('two tokens are accepted at once, which is what a replacement stands in', () {
    test('both are let through, and the answer does not say which one it was', () async {
      final ({ServiceTokenGate gate, List<ApiRequest> reached}) it = build(<String>[
        theToken,
        theOtherToken,
      ]);
      final ApiResponse first = await it.gate.call(request(), authorization: 'Bearer $theToken');
      final ApiResponse second = await it.gate.call(
        request(),
        authorization: 'Bearer $theOtherToken',
      );
      expect(first, isA<Answered>());
      expect(second, isA<Answered>());
      expect((first as Answered).payload, (second as Answered).payload);
      expect(it.reached, hasLength(2), reason: 'the holder of either token reaches the API');
    });

    test('a token that is in neither line is refused as it was before', () async {
      final ApiResponse answer = await build(<String>[
        theToken,
        theOtherToken,
      ]).gate.call(request(), authorization: 'Bearer a-third-one');
      expect((answer as Refused).status, 401);
    });

    test('the refusal is word for word the one a single accepted token gives', () async {
      final Refused withOne =
          await build().gate.call(request(), authorization: 'Bearer wrong') as Refused;
      final Refused withTwo =
          await build(<String>[
                theToken,
                theOtherToken,
              ]).gate.call(request(), authorization: 'Bearer wrong')
              as Refused;
      expect(
        (withTwo.status, withTwo.reason),
        (withOne.status, withOne.reason),
        reason: 'a caller may not learn from a refusal that a replacement is under way',
      );
    });
  });
}
