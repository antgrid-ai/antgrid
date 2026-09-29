import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:uuid/uuid.dart';

import '../util/ab_log.dart';

/// Opens the tunnel stream for one accepted local connection.
typedef TunnelTcpOpener = TunnelTcpChannel Function(String connId);

/// Listens on a loopback port and turns every accepted TCP connection into one
/// tunnel stream to the same port on the bridge's machine.
///
/// Nothing here parses HTTP: the WebView talks to its dev server byte for byte,
/// so headers, cookies, redirects, WebSockets and TLS all behave as they would
/// on the dev machine itself.
class PreviewPortForwarder {
  PreviewPortForwarder({
    required TunnelTcpOpener open,
    String Function()? mintConnId,
  }) : _open = open,
       _mintConnId = mintConnId ?? (() => const Uuid().v4());

  final TunnelTcpOpener _open;
  final String Function() _mintConnId;

  final List<ServerSocket> _servers = [];
  final Set<_Connection> _live = {};
  int _port = 0;
  bool _closed = false;

  /// The port the WebView must load. Differs from the requested one only when
  /// that port was already taken locally.
  int get port => _port;

  /// Binds IPv4 and IPv6 loopback on one shared port: [preferredPort] when both
  /// are free, otherwise an ephemeral port free on both. `localhost` resolves
  /// to either family depending on the platform, and a foreign listener on the
  /// other family's loopback would silently answer for the tab, so a port
  /// taken on one family is never used on the other. IPv6 is skipped only when
  /// the host has no IPv6 loopback at all.
  Future<int> start(int preferredPort) async {
    var port = preferredPort;
    for (var attempt = 0; attempt < _maxBindAttempts; attempt++) {
      final ServerSocket v4;
      try {
        v4 = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      } on SocketException {
        if (port == 0) rethrow;
        port = 0;
        continue;
      }
      ServerSocket? v6;
      try {
        v6 = await ServerSocket.bind(
          InternetAddress.loopbackIPv6,
          v4.port,
          v6Only: true,
        );
      } on SocketException {
        if (await _ipv6LoopbackExists()) {
          await v4.close();
          port = 0;
          continue;
        }
      }
      _port = v4.port;
      _servers.add(v4);
      v4.listen(_accept, onError: _onServerError);
      if (v6 != null) {
        _servers.add(v6);
        v6.listen(_accept, onError: _onServerError);
      }
      return _port;
    }
    throw const SocketException(
      'no loopback port was free on both IPv4 and IPv6',
    );
  }

  static const _maxBindAttempts = 8;

  static Future<bool> _ipv6LoopbackExists() async {
    try {
      final probe = await ServerSocket.bind(
        InternetAddress.loopbackIPv6,
        0,
        v6Only: true,
      );
      await probe.close();
      return true;
    } on SocketException {
      return false;
    }
  }

  void _onServerError(Object error) {
    AbLog.warn(
      'preview',
      'forwarder accept failed',
      fields: {'port': _port, 'error': '$error'},
    );
  }

  void _accept(Socket socket) {
    if (_closed) {
      socket.destroy();
      return;
    }
    // Small request/response exchanges dominate a dev-server preview; Nagle
    // would add its delay to every one of them.
    socket.setOption(SocketOption.tcpNoDelay, true);
    final connection = _Connection(socket, _open(_mintConnId()), _live.remove);
    _live.add(connection);
    connection.start();
  }

  /// Stops listening and aborts every live connection.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final server in _servers) {
      await server.close();
    }
    _servers.clear();
    for (final connection in _live.toList()) {
      connection.end(abort: true);
    }
    _live.clear();
  }
}

/// One accepted socket paired with its tunnel channel. An end in either
/// direction winds down the whole connection because the bridge cannot model a
/// half-close.
class _Connection {
  _Connection(this._socket, this._channel, this._onGone);

  final Socket _socket;
  final TunnelTcpChannel _channel;
  final void Function(_Connection) _onGone;

  StreamSubscription<Uint8List>? _localSub;
  StreamSubscription<Uint8List>? _remoteSub;
  bool _ended = false;

  void start() {
    // Held paused until the bridge has replied: raw bytes sent before the ready
    // record would be read by the bridge as part of the control record.
    _localSub = _socket.listen(
      _onLocalData,
      onDone: _onLocalDone,
      onError: (Object _) => end(abort: true),
      cancelOnError: true,
    )..pause();
    _channel.ready.then(
      (_) {
        if (_ended) return;
        _remoteSub = _channel.incoming.listen(
          _onRemoteData,
          onDone: _onRemoteDone,
          onError: (Object _) => end(abort: true),
          cancelOnError: true,
        );
        _localSub?.resume();
      },
      onError: (Object error) {
        AbLog.warn(
          'preview',
          'tunnel connection failed to open',
          fields: {'error': '$error'},
        );
        end(abort: true);
      },
    );
  }

  void _onLocalData(Uint8List data) {
    final sub = _localSub;
    if (sub == null) return;
    // The channel's queue resets the stream past its cap, so the socket stays
    // paused until each chunk has been handed over.
    sub.pause();
    _channel
        .send(data)
        .then((accepted) {
          if (_ended) return;
          if (!accepted) {
            end(abort: true);
            return;
          }
          sub.resume();
        })
        .catchError((Object _) {
          end(abort: true);
        });
  }

  void _onLocalDone() {
    if (_ended) return;
    // Our send half is over; the bridge answers with its own FIN once the
    // upstream has ended, which is what closes the local socket.
    unawaited(_channel.finish());
    // A bridge that never answers must not keep the connection alive.
    if (_remoteSub == null) end(abort: true);
  }

  void _onRemoteData(Uint8List data) {
    final sub = _remoteSub;
    if (sub == null) return;
    sub.pause();
    _socket.add(data);
    _socket.flush().then((_) {
      if (!_ended) sub.resume();
    }, onError: (Object _) => end(abort: true));
  }

  Future<void> _onRemoteDone() async {
    if (_ended) return;
    try {
      await _socket.flush();
    } on Object {
      // The peer is already gone; closing below is all that is left.
    }
    end(abort: false);
  }

  /// Idempotent. [abort] resets the tunnel stream; otherwise the bridge already
  /// ended its half and ours only needs a graceful finish.
  void end({required bool abort}) {
    if (_ended) return;
    _ended = true;
    unawaited(_localSub?.cancel());
    unawaited(_remoteSub?.cancel());
    if (abort) {
      _channel.abort();
      _socket.destroy();
    } else {
      unawaited(_channel.finish());
      unawaited(
        _socket.close().then<void>((_) {}, onError: (Object _) {}).whenComplete(
          _socket.destroy,
        ),
      );
    }
    _onGone(this);
  }
}
