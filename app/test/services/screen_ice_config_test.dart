import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/services/screen_ice_config.dart';

void main() {
  test('the default configuration is STUN alone', () async {
    // Nothing here is required for the feature to work: two devices on one
    // subnet connect on host candidates, which are always gathered.
    final servers = await defaultIceServers();
    expect(servers, hasLength(1));
    expect(servers.single.urls, kScreenShareStunUrls);
    expect(servers.single.urls.every((url) => url.startsWith('stun:')), isTrue);
  });

  test('a resolver that throws degrades to STUN rather than failing', () async {
    final servers = await resolveIceServersOrStun(
      () async => throw StateError('resolver down'),
    );
    expect(servers.single.urls, kScreenShareStunUrls);
  });

  test('a resolver that succeeds is used as-is', () async {
    const custom = IceServer(urls: ['stun:stun.example:3478']);
    final servers = await resolveIceServersOrStun(() async => const [custom]);
    expect(servers, [custom]);
  });

  test('encoding carries urls and nothing else', () {
    expect(encodeIceServers([kScreenShareStunServer]), [
      {'urls': kScreenShareStunUrls},
    ]);
  });
}
