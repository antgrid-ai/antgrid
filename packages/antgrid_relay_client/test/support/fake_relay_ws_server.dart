// Not a `_test.dart` file — `dart test` won't try to run this as a suite.
//
// A minimal in-process WebSocket server standing in for the relay, so
// RelayService.connect()/reconnect exercises its REAL hello/backoff state
// machine against a live loopback socket instead of a hand-mocked
// WebSocketChannel (RelayService opens its own `WebSocketChannel.connect(...)`
// internally — there's no injection seam for the channel itself, only for
// higher-level fakes like `debugHandleFrame`, which can't drive reconnect
// timing/backoff).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One accepted WebSocket connection attempt, with its decoded `hello` frame
/// already parsed out for convenience (RelayService always sends `hello` as
/// its first — and, in these tests, only relevant — text frame).
class FakeRelayConnection {
  FakeRelayConnection(this.socket, this.hello);
  final WebSocket socket;
  final Map<String, dynamic> hello;

  void sendJson(Map<String, dynamic> obj) => socket.add(jsonEncode(obj));

  Future<void> close() => socket.close();
}

class FakeRelayWsServer {
  FakeRelayWsServer._(this._server);

  final HttpServer _server;
  final _connections = StreamController<FakeRelayConnection>.broadcast();

  /// Fires once per (re)connect attempt, after that attempt's `hello` frame
  /// has arrived and been decoded.
  Stream<FakeRelayConnection> get connections => _connections.stream;

  static Future<FakeRelayWsServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final s = FakeRelayWsServer._(server);
    unawaited(s._serve());
    return s;
  }

  Future<void> _serve() async {
    // Fire-and-forget per request: a reconnect's new upgrade must not wait
    // behind the PREVIOUS connection's `ws.first` (which, in these tests,
    // often never resolves once the server side has moved on).
    await for (final req in _server) {
      unawaited(_handleUpgrade(req));
    }
  }

  Future<void> _handleUpgrade(HttpRequest req) async {
    if (!WebSocketTransformer.isUpgradeRequest(req)) {
      req.response.statusCode = HttpStatus.badRequest;
      await req.response.close();
      return;
    }
    final ws = await WebSocketTransformer.upgrade(req);
    // RelayService sends `hello` as the very first frame on every attempt.
    final first = await ws.first as String;
    final hello = jsonDecode(first) as Map<String, dynamic>;
    if (!_connections.isClosed) {
      _connections.add(FakeRelayConnection(ws, hello));
    }
  }

  String get wsUrl => 'ws://${_server.address.address}:${_server.port}/ws';

  Future<void> close() async {
    await _connections.close();
    await _server.close(force: true);
  }
}
