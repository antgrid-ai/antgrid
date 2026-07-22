import 'dart:io';

/// Reserve an ephemeral port, then release it — returns a port number that was
/// free a moment ago. Good enough for tests (negligible reuse race).
Future<int> freePort() async {
  final s = await ServerSocket.bind('localhost', 0);
  final port = s.port;
  await s.close();
  return port;
}
