import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ansiwise_core/ansiwise_core.dart';
import 'package:ansiwise_rest/ansiwise_rest.dart';
import 'package:test/test.dart';

import 'doubles.dart';

/// The resident service as a PROGRAM: what starts it, what it refuses to start over, what it says
/// when it is up, and what this package may never be able to compose.
///
/// **THE DEFECT THIS EXISTS FOR.** The resident door was a flag — `serve --listen <address>` — so
/// the tool that runs deployments and the service a machine boots were one word told apart by
/// whether an option was typed. A machine asked for one could be given the other, and the option
/// that decided it was declared in the composition root, one repository away from the surface whose
/// interface it is. Here the word, the options, the refusals and the command a unit file carries
/// are all one statement, in the package the surface lives in.
///
/// **AND WHAT IT MAY NOT BECOME.** A second executable would have had to compose a plugin registry
/// of its own, and two registries on one machine is a served run and a deployment run resolving
/// different sets of steps with nothing saying so. The last group makes that impossible rather than
/// unlikely: this package's manifest may name no plugin, so there is nothing here to compose one
/// with, and the service is handed the surface the binary composed.
void main() {
  group('what starts the resident service', () {
    test('it is a word of its own, and not the word that serves a session', () {
      expect(
        ResidentService.program,
        isNot(ResidentService.sessionProgram),
        reason:
            'two things a machine runs for different reasons, and one word for both is how a '
            'machine asked for the tool comes up as the service',
      );
    });

    test('the command a unit carries is composed here, program word and all', () {
      expect(
        ResidentService.commandOf(
          executable: '/usr/local/bin/ansiwise',
          address: '100.64.0.7:8642',
          serviceTokenFile: '/etc/ansiwise/service-token',
        ),
        <String>[
          '/usr/local/bin/ansiwise',
          ResidentService.program,
          '--${ResidentService.addressOption}',
          '100.64.0.7:8642',
          '--${ResidentService.tokenFileOption}',
          '/etc/ansiwise/service-token',
        ],
        reason:
            'a unit that stated any of this a second time would go on starting the old spelling '
            'after a rename, and what reports that is a dead service in a journal nobody reads',
      );
    });

    test('nothing about the binary that carries it is composed here', () {
      // Where the programs stand, which configuration is active and where records are kept belong
      // to whichever binary carries this program. A command composed here that named them would be
      // this package deciding the layout of an installation it knows nothing about.
      expect(
        ResidentService.commandOf(
          executable: '/usr/local/bin/ansiwise',
          address: '100.64.0.7:8642',
          serviceTokenFile: '/etc/ansiwise/service-token',
        ).join(' '),
        allOf(
          isNot(contains('--programs')),
          isNot(contains('--config')),
          isNot(contains('--runs')),
        ),
      );
    });
  });

  group('what it refuses to start over', () {
    String refusalOf({String? address, String? serviceTokenFile}) {
      try {
        ResidentService.of(address: address, serviceTokenFile: serviceTokenFile);
        return '';
      } on ResidentServiceRefused catch (refused) {
        return refused.because;
      }
    }

    test('THE PLANTED DEFECT: an address with no token file behind it', () {
      // The one failure this whole seam exists to make impossible: a surface standing on an address
      // while nothing decides who may reach it.
      expect(
        refusalOf(address: '100.64.0.7:8642'),
        allOf(contains(ResidentService.tokenFileOption), contains('authenticated by nothing')),
        reason: 'a machine whose token was never placed must refuse to serve, not serve openly',
      );
    });

    test('THE PLANTED DEFECT: a token file and nowhere to stand', () {
      expect(
        refusalOf(serviceTokenFile: '/etc/ansiwise/service-token'),
        allOf(contains(ResidentService.addressOption), contains('no default')),
        reason:
            'a default address would be this code deciding which addresses may reach a machine\'s '
            'deployment surface',
      );
    });

    test('both missing is ONE refusal naming both, not the first of two', () {
      final String because = refusalOf();
      expect(
        because,
        allOf(contains(ResidentService.addressOption), contains(ResidentService.tokenFileOption)),
        reason:
            'a refusal naming one of two missing arguments costs whoever is installing this a '
            'second round trip to a machine',
      );
    });

    test('an argument that is only whitespace is no argument', () {
      expect(refusalOf(address: '   ', serviceTokenFile: '  '), isNotEmpty);
    });

    test('THE INNOCENT NEIGHBOUR: an invocation carrying both is accepted', () {
      final ResidentService service = ResidentService.of(
        address: '100.64.0.7:8642',
        serviceTokenFile: '/etc/ansiwise/service-token',
      );
      expect(service.address, '100.64.0.7:8642');
      expect(service.serviceTokenFile, '/etc/ansiwise/service-token');
    });
  });

  group('what it does once it is started', () {
    const String token = 'the-token-placed-at-installation';
    late Directory home;
    late String tokenPath;
    late HttpServer bound;
    late Future<void> serving;
    late String said;

    /// The smallest surface that answers something: `GET /programs` over an empty catalogue.
    DeploymentApi api() => DeploymentApi(
      programs: ProgramsEndpoint(FixedCatalogue(<ResolvedProgram>[])),
      runs: RunsEndpoint(
        store: MemoryRunStore(),
        launcher: RecordingLauncher(),
        catalogue: FixedCatalogue(<ResolvedProgram>[]),
        gate: Gate(MemoryRunStore()),
        json: const PlainRecordJson(),
        commit: () async => 'abc1234',
      ),
      events: EventsEndpoint(store: MemoryRunStore(), json: const PlainRecordJson()),
    );

    Future<int> asks(String? presented) async {
      final HttpClient client = HttpClient();
      try {
        final HttpClientRequest ask = await client.getUrl(
          Uri.parse('http://127.0.0.1:${bound.port}/programs'),
        );
        if (presented != null) {
          ask.headers.set(HttpHeaders.authorizationHeader, presented);
        }
        final HttpClientResponse answer = await ask.close().timeout(const Duration(seconds: 10));
        await utf8.decodeStream(answer);
        return answer.statusCode;
      } finally {
        client.close(force: true);
      }
    }

    setUp(() async {
      home = Directory.systemTemp.createTempSync('resident-service-test');
      tokenPath = '${home.path}${Platform.pathSeparator}token';
      File(tokenPath).writeAsStringSync('$token\n', flush: true);
      final Completer<HttpServer> standing = Completer<HttpServer>();
      // Port 0, so what the service announces is the only place the port exists at all.
      serving = ResidentService.of(
        address: '127.0.0.1:0',
        serviceTokenFile: tokenPath,
      ).serve(api(), standing: standing.complete);
      bound = await standing.future;
      said = ResidentService.announcement(bound);
    });

    tearDown(() async {
      await bound.close(force: true);
      await serving;
      home.deleteSync(recursive: true);
    });

    test('it says where it really stands, not where it was asked to', () {
      expect(said, 'serving on 127.0.0.1:${bound.port}');
      expect(
        said,
        isNot(contains(':0')),
        reason:
            'the address asked for port 0 and the operating system chose the real one — a line '
            'repeating the request tells a journal nothing about where the service is',
      );
    });

    test('the file it was named is the one it demands a token out of', () async {
      expect(await asks('Bearer $token'), 200);
      expect(await asks(null), 401, reason: 'the door stood open');
      expect(await asks('Bearer not-the-token'), 401);
    });
  });

  group('nothing in this package can compose a plugin registry', () {
    test('THE MANIFEST AS IT STANDS names no plugin and no composition root', () {
      // From the working directory, which `dart test` sets to the package.
      final String manifest = File('${Directory.current.path}/pubspec.yaml').readAsStringSync();

      expect(
        registryReachingDependencies(manifest),
        isEmpty,
        reason:
            'a package that can reach a plugin can compose a registry, and a second registry on a '
            'machine is a served run and a deployment run resolving different sets of steps with '
            'nothing saying so',
      );
    });

    for (final String planted in <String>['ansiwise_host', 'ansiwise_cli']) {
      test('THE PLANTED DEFECT: a manifest that reached $planted is reported', () {
        expect(
          registryReachingDependencies(
            'name: ansiwise_rest\n'
            'dependencies:\n'
            '  meta: ^1.15.0\n'
            '  ansiwise_core:\n'
            '    git:\n'
            '      url: https://github.com/simetrixch/ansiwise-core.git\n'
            '  $planted:\n'
            '    git:\n'
            '      url: https://github.com/simetrixch/ansiwise-plugins.git\n',
          ),
          <String>[planted],
        );
      });
    }

    test('THE INNOCENT NEIGHBOUR: the framework and the rule set are not registries', () {
      expect(
        registryReachingDependencies(
          'dependencies:\n'
          '  ansiwise_core:\n'
          '    git:\n'
          '      url: https://github.com/simetrixch/ansiwise-core.git\n'
          'dev_dependencies:\n'
          '  ansiwise_checks_tree:\n'
          '    git:\n'
          '      url: https://github.com/simetrixch/ansiwise-checks.git\n',
        ),
        isEmpty,
        reason: 'a rule that reported everything would pass the two probes above',
      );
    });
  });
}

/// The `ansiwise_` packages this surface may reach, and why each of them is not a registry.
///
/// An allowlist and not a pattern. Which packages carry plugins is not readable off a name — the
/// plugins of this product live in one repository under a dozen package names — so what is stated
/// is the short list that is known to carry none, and everything else is reported.
const Map<String, String> mayReach = <String, String>{
  'ansiwise_core':
      'the framework: the ports, the record types and the registry TYPE, and not one plugin',
  'ansiwise_checks_tree':
      'the rule set this tree is analysed against, and a dev dependency — nothing compiled reaches '
      'it',
};

/// Every dependency of [pubspecText] that would put a plugin registry inside this package.
///
/// Read line by line rather than parsed, so this check needs no dependency of its own to judge what
/// this package's dependencies are.
List<String> registryReachingDependencies(String pubspecText) {
  final List<String> found = <String>[];
  bool inDependencyBlock = false;
  for (final String raw in pubspecText.split('\n')) {
    final String line = raw.replaceAll('\r', '');
    final String content = line.trimLeft();
    if (content.isEmpty || content.startsWith('#')) {
      continue;
    }
    final int indent = line.length - content.length;
    if (indent == 0) {
      inDependencyBlock = content == 'dependencies:' || content == 'dev_dependencies:';
      continue;
    }
    if (!inDependencyBlock || indent != 2) {
      continue;
    }
    final String trimmed = content.trimRight();
    final int cut = trimmed.indexOf(':');
    final String name = cut < 0 ? trimmed : trimmed.substring(0, cut);
    if (name.startsWith('ansiwise_') && !mayReach.containsKey(name)) {
      found.add(name);
    }
  }
  found.sort();
  return found;
}
