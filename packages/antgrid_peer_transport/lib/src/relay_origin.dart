/// Dev-only: accept a plaintext `http://` Iroh relay origin, for the local
/// stack that has no DNS name or publicly trusted certificate. The pinned
/// bindings expose no custom-CA API, so a private certificate cannot be trusted
/// and plaintext is the only relay a developer can stand up locally.
///
/// Compile-time on purpose. A release build cannot turn this on without a
/// `--dart-define=ANTGRID_DEV_INSECURE_RELAY=true` on the build command, so it
/// cannot be flipped by a runtime setting, an environment variable on a user's
/// machine, or anything an authorization snapshot says.
const bool kDevInsecureRelay =
    bool.fromEnvironment('ANTGRID_DEV_INSECURE_RELAY');

/// Whether [host] names a network the developer already controls.
///
/// Cleartext is confined to one: a LAN address is allowed because a phone or
/// emulator has to reach the dev stack, a public one is not, whatever the build
/// opted into. Mirrored by `relayUrlsSchema` in `packages/antgrid-wire` and by
/// the relay's own `Config::validate`.
bool _isLocalRelayHost(String host) {
  final value = host.toLowerCase();
  if (value == 'localhost' || value == '::1') return true;
  final octets = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$')
      .firstMatch(value)
      ?.groups(const [1, 2, 3, 4])
      .map((group) => int.parse(group!))
      .toList();
  if (octets != null) {
    final first = octets[0];
    final second = octets[1];
    return octets.every((octet) => octet <= 255) &&
        (first == 127 ||
            first == 10 ||
            (first == 192 && second == 168) ||
            (first == 172 && second >= 16 && second <= 31) ||
            (first == 169 && second == 254));
  }
  // Unique-local `fc00::/7` and link-local `fe80::/10`.
  return RegExp(r'^f[cd][0-9a-f]{0,2}:').hasMatch(value) ||
      RegExp(r'^fe[89ab][0-9a-f]:').hasMatch(value);
}

/// Whether [url] is a relay origin this build may dial.
///
/// The scheme check is what stops a hostile or compromised backend from
/// answering with a plaintext origin and downgrading the transport it is
/// supposed to be authorizing, so the decision reads [kDevInsecureRelay] —
/// fixed at compile time — and never anything carried in the snapshot.
bool isApprovedRelayOrigin(String url) {
  final Uri uri;
  try {
    uri = Uri.parse(url);
  } on FormatException {
    return false;
  }
  final schemeOk = uri.scheme == 'https' ||
      (kDevInsecureRelay && uri.scheme == 'http' && _isLocalRelayHost(uri.host));
  return schemeOk &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment &&
      (uri.path == '' || uri.path == '/');
}
