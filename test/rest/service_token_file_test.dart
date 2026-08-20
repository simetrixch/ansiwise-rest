import 'dart:io';

import 'package:ansiwise_rest/src/rest/service_token.dart';
import 'package:ansiwise_rest/src/rest/service_token_file.dart';
import 'package:test/test.dart';

/// The file the accepted tokens are written in, and what reading it again for every request buys.
///
/// The single-line file is what every machine installed so far holds, so it keeps working here
/// unchanged. What is new is that a second line is a second accepted token, that a line placed or
/// deleted under a running service is answered on the next request, and that a read which finds
/// nothing changes nothing — which is what a truncating writer's file looks like for the instant
/// between its truncate and its write.
void main() {
  const String theToken = 'sesame-open-42';
  const String theOtherToken = 'the-one-being-moved-to-99';

  late Directory home;
  late String path;
  setUp(() {
    home = Directory.systemTemp.createTempSync('service-token-file-test');
    path = '${home.path}${Platform.pathSeparator}token';
  });
  tearDown(() => home.deleteSync(recursive: true));

  void place(String contents) => File(path).writeAsStringSync(contents);

  group('what the file holds is what is accepted', () {
    test('one pasted value, with the trailing newline provisioning wrote', () async {
      place('$theToken\n');
      final ServiceTokens accepted = await ServiceTokenFile(path).read();
      expect(accepted.count, 1);
      expect(accepted.matches(theToken), isTrue);
    });

    test('one pasted value without a trailing newline is the same credential', () async {
      place(theToken);
      expect((await ServiceTokenFile(path).read()).matches(theToken), isTrue);
    });

    test('two lines are two tokens, and both are accepted', () async {
      place('$theToken\n$theOtherToken\n');
      final ServiceTokens accepted = await ServiceTokenFile(path).read();
      expect(accepted.count, 2);
      expect(accepted.matches(theToken), isTrue);
      expect(accepted.matches(theOtherToken), isTrue);
      expect(accepted.matches('neither-of-them'), isFalse);
    });

    test('blank lines and surrounding whitespace are not tokens', () async {
      place('\n  $theToken  \n\n\t$theOtherToken\n\n');
      final ServiceTokens accepted = await ServiceTokenFile(path).read();
      expect(accepted.count, 2, reason: 'a blank line is not a credential');
      expect(accepted.matches(theToken), isTrue);
      expect(accepted.matches(theOtherToken), isTrue);
    });
  });

  group('a machine whose token was never placed refuses to serve', () {
    test('a missing file fails with the path in it', () async {
      await expectLater(
        ServiceTokenFile('${home.path}${Platform.pathSeparator}never-placed').read(),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('an empty file refuses to become a set, naming the path', () async {
      place(' \n');
      await expectLater(
        ServiceTokenFile(path).read(),
        throwsA(isA<StateError>().having((StateError e) => e.message, 'message', contains(path))),
        reason: 'a machine whose token was never placed must refuse to serve, not serve openly',
      );
    });

    test('a line that is not a token fails as that same StateError, naming the path', () async {
      place('aaa\rbbb\n');
      await expectLater(
        ServiceTokenFile(path).read(),
        throwsA(isA<StateError>().having((StateError e) => e.message, 'message', contains(path))),
        reason: 'a third exception type is a stack trace where an operator message belongs',
      );
    });

    test('a file that was never read whole has nothing to fall back on', () async {
      await expectLater(
        ServiceTokenFile('${home.path}${Platform.pathSeparator}never-placed').accepted(),
        throwsA(isA<FileSystemException>()),
        reason: 'answering from a set nobody ever wrote is the one thing worse than refusing',
      );
    });
  });

  group('the file is read again for every decision', () {
    test(
      'a token placed beside the standing one is accepted, and so is the standing one',
      () async {
        place(theToken);
        final ServiceTokenFile file = ServiceTokenFile(path);
        expect((await file.accepted()).matches(theToken), isTrue);

        place('$theToken\n$theOtherToken\n');
        final ServiceTokens both = await file.accepted();
        expect(
          both.matches(theOtherToken),
          isTrue,
          reason: 'the new token works without a restart',
        );
        expect(
          both.matches(theToken),
          isTrue,
          reason: 'placing the new one may not be what retires the old one',
        );
      },
    );

    test('a token whose line is deleted is refused from the next decision on', () async {
      place('$theToken\n$theOtherToken\n');
      final ServiceTokenFile file = ServiceTokenFile(path);
      expect((await file.accepted()).matches(theToken), isTrue);

      place('$theOtherToken\n');
      final ServiceTokens left = await file.accepted();
      expect(left.matches(theToken), isFalse, reason: 'the retired token stops working');
      expect(left.matches(theOtherToken), isTrue);
    });
  });

  group('a read that finds nothing changes nothing', () {
    test('a file emptied under the service leaves the last set standing', () async {
      place(theToken);
      final ServiceTokenFile file = ServiceTokenFile(path);
      await file.accepted();

      place('');
      final ServiceTokens standing = await file.accepted();
      expect(
        standing.matches(theToken),
        isTrue,
        reason:
            'a writer that truncates before it writes leaves the file empty for an instant, '
            'and refusing everyone for it is the outage this avoids',
      );
    });

    test('a file taken away under the service leaves the last set standing', () async {
      place('$theToken\n$theOtherToken\n');
      final ServiceTokenFile file = ServiceTokenFile(path);
      await file.accepted();

      File(path).deleteSync();
      final ServiceTokens standing = await file.accepted();
      expect(standing.count, 2);
      expect(standing.matches(theToken), isTrue);
      expect(standing.matches(theOtherToken), isTrue);
    });

    test('a failed read never widens what is accepted', () async {
      place(theToken);
      final ServiceTokenFile file = ServiceTokenFile(path);
      await file.accepted();

      File(path).deleteSync();
      expect((await file.accepted()).matches(theOtherToken), isFalse);
    });
  });
}
