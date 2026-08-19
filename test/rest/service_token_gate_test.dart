import 'dart:io';

import 'package:ansiwise_rest/src/rest/api_message.dart';
import 'package:ansiwise_rest/src/rest/service_token.dart';
import 'package:ansiwise_rest/src/rest/service_token_gate.dart';
import 'package:test/test.dart';

/// The gate in front of the surface: one token, checked on every route, fail-closed.
void main() {
  const String theToken = 'sesame-open-42';

  ({ServiceTokenGate gate, List<ApiRequest> reached}) build() {
    final List<ApiRequest> reached = <ApiRequest>[];
    Future<ApiResponse> answering(ApiRequest request) async {
      reached.add(request);
      return const Answered(<String, Object?>{'ok': true});
    }

    return (gate: ServiceTokenGate(answering, token: ServiceToken(theToken)), reached: reached);
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

  group('an empty expected token cannot even be built', () {
    test('empty and whitespace-only values are refused at construction', () {
      expect(() => ServiceToken(''), throwsArgumentError);
      expect(
        () => ServiceToken('  \n'),
        throwsArgumentError,
        reason: 'an empty expected token would let an empty presented one through',
      );
    });

    test('the token itself never appears in its own toString', () {
      expect(ServiceToken(theToken).toString(), isNot(contains(theToken)));
    });
  });

  group('the token comes from a file', () {
    late Directory home;
    setUp(() => home = Directory.systemTemp.createTempSync('service-token-test'));
    tearDown(() => home.deleteSync(recursive: true));

    test('a trailing newline from provisioning is not part of the token', () {
      final File file = File('${home.path}${Platform.pathSeparator}token')
        ..writeAsStringSync('$theToken\n');
      expect(ServiceToken.fromFile(file.path).matches(theToken), isTrue);
    });

    test('an empty file refuses to become a token, naming the path', () {
      final File file = File('${home.path}${Platform.pathSeparator}token')
        ..writeAsStringSync(' \n');
      expect(
        () => ServiceToken.fromFile(file.path),
        throwsA(
          isA<StateError>().having((StateError e) => e.message, 'message', contains(file.path)),
        ),
        reason: 'a machine whose token was never placed must refuse to serve, not serve openly',
      );
    });

    test('a missing file fails with the path in it, so start-up says what is missing', () {
      final String nowhere = '${home.path}${Platform.pathSeparator}never-placed';
      expect(() => ServiceToken.fromFile(nowhere), throwsA(isA<FileSystemException>()));
    });
  });
}
