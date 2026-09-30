import 'package:antgrid/util/ssl_error_host.dart';
import 'package:flutter_test/flutter_test.dart';

class _AndroidLike {
  _AndroidLike(this.url);
  final String url;
  final String description = 'Hostname mismatch.';
}

class _WebKitLike {
  _WebKitLike(this.host);
  final String host;
  final int port = 443;
  final String description = 'untrusted';
}

class _DescriptionOnly {
  _DescriptionOnly(this.description);
  final String description;
}

void main() {
  group('sslErrorHost', () {
    test('reads the failing URL of an Android-style error', () {
      expect(
        sslErrorHost(_AndroidLike('https://cdn.example.com/app.js')),
        'cdn.example.com',
      );
    });

    test('reads the host of a WebKit-style error', () {
      expect(sslErrorHost(_WebKitLike('localhost')), 'localhost');
    });

    test('reads the URL out of a Windows-style description', () {
      expect(
        sslErrorHost(
          _DescriptionOnly(
            'SSL certificate error for https://localhost:5173/: '
            'certificateIsInvalid.',
          ),
        ),
        'localhost',
      );
    });

    test('is null when the platform names no host', () {
      expect(sslErrorHost(_DescriptionOnly('TLS certificate error')), isNull);
      expect(sslErrorHost(Object()), isNull);
    });
  });

  test('only loopback hosts are accepted', () {
    expect(isLoopbackCertificateHost('localhost'), isTrue);
    expect(isLoopbackCertificateHost('127.0.0.1'), isTrue);
    expect(isLoopbackCertificateHost('cdn.example.com'), isFalse);
    expect(isLoopbackCertificateHost(null), isFalse);
  });
}
