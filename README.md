# ansiwise-rest

The REST resources of a deployment, and the adapter that serves them over a session's own stdin and
stdout.

Neither the messages nor the endpoints know about a socket, a pipe or `dart:io`. That is what makes
every endpoint testable by calling it with a request and looking at what came back, and it is what
lets the same surface be served over an SSH channel today and over something else later without a
line of the endpoints changing.

It is a library. The only executable is the composition root in
[`ansiwise-cli`](https://github.com/simetrixch/ansiwise-cli) — two binaries would mean two plugin
lists to keep in step and a client having to know which of them a machine has.
