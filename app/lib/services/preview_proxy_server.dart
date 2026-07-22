import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/preview_models.dart';

/// Thrown by [PreviewProxyServer.start] when the exact target port can't be
/// bound on this device (in use, or privileged) and fallback wasn't allowed.
class PortInUseException implements Exception {
  final int port;
  const PortInUseException(this.port);

  @override
  String toString() => 'PortInUseException(port: $port)';
}

class PreviewProxyServer {
  final int targetPort;

  /// Scheme the bridge should use to reach the dev server ('http' | 'https').
  /// The proxy itself always serves the webview over plain HTTP.
  final String targetScheme;
  final Future<TunnelHttpResponse> Function(TunnelHttpRequest) onRequest;
  final void Function(WebSocketChannel channel, String path)?
  onWebSocketConnect;

  HttpServer? _server;
  int? _localPort;
  bool _rewriteHost = false;

  PreviewProxyServer({
    required this.targetPort,
    this.targetScheme = 'http',
    required this.onRequest,
    this.onWebSocketConnect,
  });

  int? get localPort => _localPort;

  /// Binds the local proxy. Prefers the exact [targetPort] so the WebView
  /// origin matches the dev server (host/origin headers and absolute
  /// `localhost:<port>` references line up). If that port can't be bound:
  /// throws [PortInUseException] when [allowFallback] is false; otherwise
  /// binds a random port and rewrites the forwarded Host so host-checking
  /// dev servers still accept tunneled requests.
  Future<int> start({bool allowFallback = false}) async {
    final handler = _createHandler();
    try {
      _server = await shelf_io.serve(handler, 'localhost', targetPort);
    } on SocketException {
      // Couldn't bind the exact port (taken or privileged). Without fallback,
      // surface it as the typed conflict so the caller can offer one. Platform
      // errno is unreliable here (Windows returns a synthetic code for an
      // in-use port), so we don't try to distinguish a true conflict from a
      // deeper fault at this point — if the cause is NOT port-specific, the
      // fallback bind below fails too and that SocketException propagates to
      // the caller (surfaced to the user), rather than being mislabeled.
      if (!allowFallback) {
        throw PortInUseException(targetPort);
      }
      _server = await shelf_io.serve(handler, 'localhost', 0);
      _rewriteHost = true;
    }
    _localPort = _server!.port;
    return _localPort!;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _localPort = null;
  }

  shelf.Handler _createHandler() {
    return (shelf.Request request) async {
      // Check for WebSocket upgrade
      if (request.headers['upgrade']?.toLowerCase() == 'websocket') {
        if (onWebSocketConnect != null) {
          return webSocketHandler((WebSocketChannel channel, String? protocol) {
            onWebSocketConnect!(channel, '/${request.url}');
          })(request);
        }
        return shelf.Response.forbidden('WebSocket not supported');
      }

      return _handleHttpRequest(request);
    };
  }

  Future<shelf.Response> _handleHttpRequest(shelf.Request request) async {
    final requestId = const Uuid().v4();

    // Read request body if present
    String? body;
    if (request.method == 'POST' ||
        request.method == 'PUT' ||
        request.method == 'PATCH') {
      body = await request.readAsString();
      if (body.isEmpty) body = null;
    }

    // Flatten headers (take first value for each key)
    final headers = <String, String>{};
    request.headers.forEach((key, value) {
      headers[key] = value;
    });

    // Fallback bind: the WebView origin is a different local port than the dev
    // server expects, so force the forwarded Host to the target port —
    // otherwise host-checking dev servers (Vite/webpack/Next) reject it.
    // Remove any case-variant the WebView sent first so we replace, not
    // duplicate, the host header.
    if (_rewriteHost) {
      headers.removeWhere((k, _) => k.toLowerCase() == 'host');
      headers['host'] = 'localhost:$targetPort';
    }

    final tunnelRequest = TunnelHttpRequest(
      requestId: requestId,
      port: targetPort,
      scheme: targetScheme,
      method: request.method,
      path: '/${request.url}',
      headers: headers,
      body: body,
    );

    try {
      final response = await onRequest(tunnelRequest);

      // Decode body based on encoding
      final responseHeaders = <String, Object>{...response.headers};
      // Remove transfer-encoding as shelf handles that
      responseHeaders.remove('transfer-encoding');

      // Set-Cookie can repeat (e.g. a sign-in response mints the session and
      // clears its handoff cookie at once); the tunnel carries the values as a
      // list because the header map can't. Shelf emits a List<String> value as
      // repeated headers, so the WebView keeps every cookie — not just the last.
      if (response.setCookies.isNotEmpty) {
        responseHeaders['set-cookie'] = response.setCookies;
      }

      // Fallback bind: the WebView's origin is our proxy port, not the dev
      // server's. An absolute redirect back to localhost:<targetPort> would
      // send the WebView straight at that port — which on a paired phone is the
      // phone's own localhost, outside the tunnel — so repoint it at the proxy
      // origin. (No-op when bound on the exact port; redirects already match.)
      if (_rewriteHost) {
        final location = responseHeaders['location'];
        if (location is String) {
          final rewritten = _rewriteRedirectLocation(location);
          if (rewritten != null) responseHeaders['location'] = rewritten;
        }
      }

      if (response.bodyEncoding == 'base64') {
        final bodyBytes = base64Decode(response.body);
        return shelf.Response(
          response.status,
          headers: responseHeaders,
          body: bodyBytes,
        );
      } else {
        return shelf.Response(
          response.status,
          headers: responseHeaders,
          body: response.body,
        );
      }
    } catch (e) {
      return shelf.Response.internalServerError(body: 'Tunnel error: $e');
    }
  }

  /// Returns [location] repointed at the proxy origin if it's an absolute
  /// loopback URL on the target port, else null (relative or unrelated URLs
  /// are left untouched — they already resolve against the proxy origin).
  String? _rewriteRedirectLocation(String location) {
    final uri = Uri.tryParse(location);
    if (uri == null || !uri.hasScheme) return null;
    final isLoopback = uri.host == 'localhost' || uri.host == '127.0.0.1';
    if (!isLoopback || uri.port != targetPort) return null;
    return uri.replace(host: 'localhost', port: _localPort).toString();
  }
}
