import 'devices_api.dart' show CreatedDevice;

/// Test seam: matches the createDevice slice of [DevicesApi].
/// Both [DevicesApi] and test fakes implement this interface.
abstract class DevicesApiCreator {
  Future<CreatedDevice> createDevice({
    required String deviceUuid,
    required String ed25519Pub,
    required String x25519Pub,
    required String platform,
    required String displayName,

    /// Overrides the server's platform-derived kind. Only the desktop
    /// controller record passes one (`'app'`); every other caller leaves it
    /// null so a desktop stays `kind:"agent"` and a phone stays `kind:"app"`.
    String? kind,
  });
}
