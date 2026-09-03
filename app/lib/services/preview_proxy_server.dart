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
  final void Function(
    WebSocketChannel channel,
    String path,
    Map<String, String> headers,
  )?
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
          // Captured before the upgrade: a cookie-authenticated dev server reads
          // its session off the WebSocket handshake, not the page load that
          // preceded it, so the upstream socket has to carry these or it opens
          // anonymously behind an authenticated page.
          final handshakeHeaders = _upstreamHandshakeHeaders(request);
          // Chromium refuses a 101 that answers its `Sec-WebSocket-Protocol`
          // with none ("Sent non-empty 'Sec-WebSocket-Protocol' header but no
          // response was received"), and every Vite-family dev server asks for
          // `vite-hmr`. The echo is optimistic: the upstream handshake has not
          // run yet — the bridge forwards the same list — so the browser hears
          // its own first choice, not the server's. Dev servers ask for one.
          return webSocketHandler(
            (WebSocketChannel channel, String? protocol) {
              onWebSocketConnect!(channel, '/${request.url}', handshakeHeaders);
            },
            protocols: _requestedSubprotocols(request),
          )(request);
        }
        return shelf.Response.forbidden('WebSocket not supported');
      }

      return _handleHttpRequest(request);
    };
  }

  /// The browser's `Sec-WebSocket-Protocol` list in its order of preference.
  /// shelf echoes the first REQUESTED entry it is also given, so handing it
  /// the request's own list is what makes the echo the browser's first choice.
  /// An empty list echoes nothing, exactly as a null would.
  ///
  /// `splitUpstreamWsHeaders` (`bridge/src/tunnel-manager.ts`) reads the same
  /// header to decide what is offered upstream, so ORDER and the trim/drop-
  /// empty rules must agree with it: a disagreement echoes the browser a
  /// subprotocol the dev server was never asked for, and neither end can
  /// detect that. Only the dedup is one-sided — Bun's WebSocket constructor
  /// refuses duplicates, and shelf takes this list as a set anyway.
  List<String> _requestedSubprotocols(shelf.Request request) {
    return (request.headers['sec-websocket-protocol'] ?? '')
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// The browser's handshake headers, with `Origin` repointed at the dev
  /// server's own origin. The WebView's origin is this proxy — a different port
  /// on a fallback bind, and always plain http for an https target — and a dev
  /// server that checks Origin would reject that as cross-site. The headers the
  /// upstream handshake owns (`Sec-WebSocket-*`, `Connection`, `Upgrade`,
  /// `Host`) are dropped by the bridge, which is what mints them — and it
  /// mints `Sec-WebSocket-Protocol` from the list this map still carries.
  Map<String, String> _upstreamHandshakeHeaders(shelf.Request request) {
    final headers = <String, String>{};
    request.headers.forEach((key, value) {
      headers[key] = value;
    });
    headers.removeWhere((k, _) => k.toLowerCase() == 'origin');
    headers['origin'] = '$targetScheme://localhost:$targetPort';
    return headers;
  }

  Future<shelf.Response> _handleHttpRequest(shelf.Request request) async {
    final requestId = const Uuid().v4();

    // Read request body if present. Any method may carry one (DELETE with a
    // payload is legal and some dev APIs use it) — only GET/HEAD are defined
    // as bodyless.
    String? body;
    if (request.method != 'GET' && request.method != 'HEAD') {
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
      // Remove framing/encoding headers: shelf re-frames the response, and the
      // bridge already decompressed the body (its fetch is transparent), so a
      // surviving content-encoding would make the WebView gunzip plain text —
      // garbled CSS/JS — and a stale content-length would truncate it.
      responseHeaders.remove('transfer-encoding');
      responseHeaders.remove('content-encoding');
      responseHeaders.remove('content-length');

      // Set-Cookie can repeat (e.g. a sign-in response mints the session and
      // clears its handoff cookie at once); the tunnel carries the values as a
      // list because the header map can't. Shelf emits a List<String> value as
      // repeated headers, so the WebView keeps every cookie — not just the last.
      if (response.setCookies.isNotEmpty) {
        responseHeaders['set-cookie'] = targetScheme == 'https'
            ? response.setCookies.map(_downgradeSecureCookie).toList()
            : response.setCookies;
      }

      // An absolute redirect back to the dev server would send the WebView
      // around the tunnel: on a fallback bind, localhost:<targetPort> is the
      // phone's own localhost; and an https target's redirect keeps `https://`,
      // which the plain-HTTP proxy can't serve even on the exact port. Repoint
      // both at the proxy origin. (Exact-port http redirects rewrite to
      // themselves — a no-op.)
      final location = responseHeaders['location'];
      if (location is String) {
        final rewritten = _rewriteRedirectLocation(location);
        if (rewritten != null) responseHeaders['location'] = rewritten;
      }

      // A String body makes shelf re-encode to UTF-8 on the way out, so decoding
      // to bytes here is not an extra pass — it replaces one.
      if (response.bodyEncoding == kTunnelGzipEncoding) {
        return shelf.Response(
          response.status,
          headers: responseHeaders,
          body: gzip.decode(base64Decode(response.body)),
          // shelf stamps `charset=utf-8` on a charset-less content-type only for
          // a String body, and gzip is the first encoding that puts TEXT on the
          // byte path. Restate it here or a charset-less `text/*` page decodes
          // as latin-1 in the WebView — `nosniff` denies it a second guess.
          encoding: _charsetlessTextType(responseHeaders['content-type'])
              ? utf8
              : null,
        );
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

  /// Text formats the bridge decoded as UTF-8, named without a charset. Passing
  /// an encoding for anything else would either mislabel binary bytes or
  /// overwrite a charset the dev server set deliberately.
  static bool _charsetlessTextType(Object? contentType) {
    if (contentType is! String) return false;
    final lower = contentType.toLowerCase();
    if (lower.contains('charset=')) return false;
    final mime = lower.split(';').first.trim();
    return mime.startsWith('text/') ||
        mime.endsWith('+json') ||
        mime.endsWith('+xml') ||
        const {
          'application/json',
          'application/javascript',
          'application/x-javascript',
          'application/ecmascript',
          'application/xml',
          'application/graphql',
        }.contains(mime);
  }

  /// Strips the attributes that make a cookie unstorable on this proxy's
  /// origin. The dev server speaks TLS and marks its session cookie `Secure`;
  /// the proxy serves the WebView plain HTTP, where a browser drops such a
  /// cookie without a word — so a sign-in against an https dev server would
  /// bounce back to its login page forever. `SameSite=None` goes with it: it is
  /// only legal alongside `Secure`, and a preview is same-origin anyway.
  /// Only applied to an https target; a plain-http one is passed through.
  ///
  /// A `__Host-`/`__Secure-` prefixed cookie is passed through UNTOUCHED: those
  /// prefixes make `Secure` mandatory, so stripping it has the browser reject
  /// the cookie outright rather than store it — the same sign-in loop, now
  /// caused by the fix. Left intact it is at least storable, since every engine
  /// the WebView runs on treats `http://localhost` as a trustworthy origin.
  static String _downgradeSecureCookie(String cookie) {
    if (_hasSecurePrefix(cookie)) return cookie;
    final kept = <String>[];
    for (final part in cookie.split(';')) {
      final attr = part.trim().toLowerCase();
      if (attr == 'secure') continue;
      kept.add(attr == 'samesite=none' ? ' SameSite=Lax' : part);
    }
    return kept.join(';');
  }

  /// Whether [cookie]'s NAME carries one of the two prefixes that make `Secure`
  /// part of the cookie's validity rather than one of its attributes.
  static bool _hasSecurePrefix(String cookie) {
    final name = cookie.split('=').first.trim().toLowerCase();
    return name.startsWith('__host-') || name.startsWith('__secure-');
  }

  /// Returns [location] repointed at the proxy origin if it's an absolute
  /// loopback URL on the target port, else null (relative or unrelated URLs
  /// are left untouched — they already resolve against the proxy origin).
  /// The scheme is forced to http: the proxy never speaks TLS, TLS to the dev
  /// server is the bridge's job.
  String? _rewriteRedirectLocation(String location) {
    final uri = Uri.tryParse(location);
    if (uri == null || !uri.hasScheme) return null;
    final isLoopback = uri.host == 'localhost' || uri.host == '127.0.0.1';
    if (!isLoopback || uri.port != targetPort) return null;
    return uri
        .replace(scheme: 'http', host: 'localhost', port: _localPort)
        .toString();
  }
}
