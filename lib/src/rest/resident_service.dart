import 'dart:io';

import 'channel_http_server.dart';
import 'deployment_api.dart';
import 'service_token_file.dart';

/// Why the resident service will not start.
///
/// Everything that is wrong at once, one per line. A program that named one of two missing
/// arguments costs whoever is installing it a second round trip to a machine.
final class ResidentServiceRefused implements Exception {
  /// Refuses [because].
  const ResidentServiceRefused(this.because);

  /// What stands in the way, in the words whoever started this reads.
  final String because;

  @override
  String toString() => because;
}

/// The REST surface as a PROGRAM of its own, and the second of the surface's two doors.
///
/// **WHY THIS TYPE EXISTS, AND WHAT IT IS THE ANSWER TO.** The resident door used to be a FLAG:
/// `serve --listen <address>` — the same word that serves one SSH session, switched into a service
/// by an option. Two things a machine runs for different reasons, told apart by whether an option
/// was typed. So a machine could be asked to run the deployment tool and get the service, or asked
/// for the service and get a tool that reads its own standard input for a connection nobody opened.
/// Here the two are two programs: [program] takes an address and demands a token, [sessionProgram]
/// takes neither and speaks over the session's own pipes, and neither can turn into the other.
///
/// **WHY IT LIVES IN THIS PACKAGE AND NOT IN THE COMPOSITION ROOT.** The service's arguments, its
/// refusals, the word that starts it and the command that has to appear in a unit file are one
/// interface, and this is the package that interface belongs to. Kept in the composition root they
/// would be a second statement of it, and the unit a machine boots is written from that statement.
///
/// **WHAT IT CANNOT DO, WHICH IS THE POINT.** It does not compose a [DeploymentApi] — it is handed
/// one. Which plugins exist is a fact of what the binary was compiled with, and this package
/// depends on no plugin and cannot reach one, so a served run and a run started from the command
/// line resolve the same registry because there is only one and neither program built it.
final class ResidentService {
  const ResidentService._({required this.address, required this.serviceTokenFile});

  /// The word that starts this program.
  ///
  /// A word and not a flag, and the same word the unit's `ExecStart` carries — [commandOf] is where
  /// those two meet, so a rename here reaches the installer and the running service at once.
  static const String program = 'service';

  /// The word that starts the other door: the surface over one session's own standard input and
  /// output, which is how a machine that has no service yet is reached at its first installation.
  static const String sessionProgram = 'serve';

  /// How the address is named on the command line, without its dashes.
  static const String addressOption = 'listen';

  /// How the file holding the accepted tokens is named on the command line, without its dashes.
  static const String tokenFileOption = 'service-token-file';

  /// Where the surface is to stand, as `host:port` or `unix:<path>`.
  final String address;

  /// The file holding what every caller on [address] must present.
  ///
  /// The PATH and never the value. A credential handed on a command line stands in every process
  /// listing on the machine.
  final String serviceTokenFile;

  /// The service that stands on [address] and demands the tokens in [serviceTokenFile], or a
  /// refusal naming everything the invocation left out.
  ///
  /// Neither has a default, and neither may. A default address would be this code deciding who can
  /// reach a machine's deployment surface, and a default token file would be a machine serving
  /// openly because nobody typed anything.
  ///
  /// The SHAPE of [address] is not judged here — [ListeningHttpServer.serve] judges it, before it
  /// binds, and a second judgement of it here would be a second grammar to keep in step.
  factory ResidentService.of({String? address, String? serviceTokenFile}) {
    final String where = (address ?? '').trim();
    final String tokens = (serviceTokenFile ?? '').trim();
    final List<String> problems = <String>[
      if (where.isEmpty)
        '$program was not told where to stand: say --$addressOption <host:port>\n'
            'there is no default, because which addresses may reach a machine\'s deployment '
            'surface is the installation\'s decision and not this program\'s',
      if (tokens.isEmpty)
        '$program was not told which tokens to accept: say --$tokenFileOption <path>\n'
            'a session is authenticated by sshd; an address is authenticated by nothing until this '
            'says so, and a surface standing where nothing guards it is the one thing this program '
            'refuses to be',
    ];
    if (problems.isNotEmpty) {
      throw ResidentServiceRefused(problems.join('\n'));
    }
    return ResidentService._(address: where, serviceTokenFile: tokens);
  }

  /// The command that starts this program, [executable] first and each argument as its own entry.
  ///
  /// **The one statement of how the service is started.** Whoever writes a unit file, and whoever
  /// starts the service by hand, composes it here. A unit that named this program or its options in
  /// any other place would be a copy of an interface it cannot see change: the service then comes
  /// up, refuses the option it was handed, and is restarted for ever with the reason in a journal
  /// nobody reads.
  ///
  /// What the BINARY needs beside this — where the programs stand, which configuration is active,
  /// where records are kept — is not here. Those belong to whatever binary carries this program,
  /// and this package neither knows nor may decide them.
  static List<String> commandOf({
    required String executable,
    required String address,
    required String serviceTokenFile,
  }) => <String>[
    executable,
    program,
    '--$addressOption',
    address,
    '--$tokenFileOption',
    serviceTokenFile,
  ];

  /// Binds [address] and answers [api] until the server is closed.
  ///
  /// [standing] is told the bound server the moment the bind holds. That is both how whoever
  /// started this learns what was really bound — an address asked for as port `0` is answered with
  /// the port the operating system chose — and how it is stopped, which nothing on a machine does:
  /// there a service manager ends the process. [announcement] is the sentence to write about it.
  ///
  /// Throws whatever [ListeningHttpServer.serve] throws and adds nothing: a [FormatException] for
  /// an address in neither accepted shape, a [SocketException] for one that cannot be bound, and a
  /// [FileSystemException] or [StateError] for a token file that is missing or holds no token —
  /// every one of them before a single request is read.
  Future<void> serve(DeploymentApi api, {required void Function(HttpServer bound) standing}) async {
    await ListeningHttpServer(
      api,
      address: address,
      tokens: ServiceTokenFile(serviceTokenFile),
    ).serve(onBound: standing);
  }

  /// The one line a resident service says about itself when it is up.
  ///
  /// Written from the BOUND server and not from what was asked for, because those are two different
  /// facts whenever the address named port `0` — and the journal of a service is the only place the
  /// second one exists.
  static String announcement(HttpServer bound) => 'serving on ${_boundName(bound)}';
}

/// Where [bound] stands, as a caller would dial it: `host:port`, or the path of a socket file.
String _boundName(HttpServer bound) => bound.address.type == InternetAddressType.unix
    ? bound.address.address
    : '${bound.address.address}:${bound.port}';
