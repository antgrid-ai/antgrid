/// The host a platform WebView certificate error is about, or null when the
/// platform does not say.
///
/// The failing request can be a subresource of the page, so the page's own URL
/// says nothing about who presented the certificate. What each backend exposes
/// (webview_all 1.4): Android carries the failing URL as `url`, WebKit the
/// server's `host`, and Windows only names the URL inside its description text.
/// Linux gives a free-form description with no URL, so it yields null.
///
/// Read reflectively because those subclasses live in federated packages that
/// webview_all does not export. A renamed field then resolves to null, and the
/// caller treats null as a reason to refuse the certificate.
String? sslErrorHost(Object platformError) {
  final dynamic error = platformError;
  try {
    final url = error.url;
    if (url is String) return _nonEmpty(Uri.tryParse(url)?.host);
  } on NoSuchMethodError {
    // Not the Android error.
  }
  try {
    final host = error.host;
    if (host is String) return _nonEmpty(host);
  } on NoSuchMethodError {
    // Not the WebKit error.
  }
  try {
    final description = error.description;
    if (description is String) {
      final match = _windowsDescription.firstMatch(description);
      if (match != null) return _nonEmpty(Uri.tryParse(match.group(1)!)?.host);
    }
  } on NoSuchMethodError {
    // No description to read.
  }
  return null;
}

final _windowsDescription = RegExp(r'^SSL certificate error for (\S+): \w+\.$');

String? _nonEmpty(String? value) =>
    value == null || value.isEmpty ? null : value;

/// Certificates are only ever accepted for the loopback forwarder, whose dev
/// servers present self-signed certificates.
bool isLoopbackCertificateHost(String? host) =>
    host == 'localhost' || host == '127.0.0.1';
