# ansiwise-rest

The REST resources of a deployment, its two doors, and the programs that are those doors.

Neither the messages nor the endpoints know about a socket, a pipe or `dart:io`. That is what makes
every endpoint testable by calling it with a request and looking at what came back, and it is what
lets the same surface be served over an SSH channel today and over something else later without a
line of the endpoints changing.

## Two doors, two programs

| Program | Reached over | Authenticated by | Used for |
|---|---|---|---|
| `ansiwise serve` | the session's own stdin and stdout | sshd, before the process started | the FIRST installation of a machine, which has no service yet |
| `ansiwise service --listen <address> --service-token-file <path>` | an address in the tailnet | a service token, read again for every request | an installed machine a manager reaches without holding a session open |

Each is a program with its own name, its own required arguments and its own refusals. The resident
one is `ResidentService` in `lib/src/rest/resident_service.dart`. It used to be `serve --listen`,
which made two things a machine runs for different reasons into one word, told apart by whether an
option was typed.

`ResidentService.commandOf` composes the command that starts the service. The unit file a machine
boots is rendered from it rather than restating it, so a rename of the program or of one of its
options cannot leave a unit behind that starts something the binary refuses.

## Where its executable is composed, and why not here

Answering `GET /programs` and starting a run needs the plugin registry, and Dart ahead of time loads
no code that was not compiled in — so the registry is exactly what a composition root imports. This
package holds the resources and the two programs; it imports no plugin and no composition root, and
`test/rest/resident_service_test.dart` holds it to that. A `bin/` here would therefore serve an
empty catalogue, or depend on the thing that depends on it.

**So the executable is composed in
[`ansiwise-cli`](https://github.com/simetrixch/ansiwise-cli)**, which is where every plugin this
product ships is already named. Today that repository compiles ONE binary, and the resident service
is a program inside it, reached as `ansiwise service`. Whether it is also cut as an executable of
its own — same composition root, same plugin list, a second name in `executables:` — is open at
`simetrixch/ansiwise-rest#2`, and it is a question about that repository's `bin/`, never about this
one's.

What one binary buys, each of it real: one file to place, which is what
`simetrixch/hostyour-manager#14` does when it links `/usr/local/bin/ansiwise`; one plugin list, where
a served run and a deployment run on the same machine cannot resolve different registries with
nothing saying so; and a client that need not ask which of two a machine carries. What it costs is
that this service does not run on its own — it reaches a machine only through a release of
`ansiwise-cli`.

## One registry, by construction

The resident service is **handed** its `DeploymentApi`. It composes none, and this package depends
on no plugin and on no composition root — `test/rest/resident_service_test.dart` holds the manifest
to that. So there is no second registry for a served run to resolve against, rather than a second
one that is merely kept in step.
