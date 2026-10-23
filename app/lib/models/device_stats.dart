/// A device's own hardware as it reports it in `device:stats`. Mirror of
/// `DeviceStats` in `bridge/src/device-stats.ts`.
///
/// Every field is optional: each platform can read a different subset, and an
/// absent field must render as unknown rather than as zero.
class DeviceStats {
  final String? model;
  final int? ramTotalBytes;
  final int? ramAvailableBytes;
  final int? storageTotalBytes;
  final int? storageFreeBytes;

  /// Stamped by the bridge on receipt; absent on a report not yet sent.
  final String? reportedAt;

  const DeviceStats({
    this.model,
    this.ramTotalBytes,
    this.ramAvailableBytes,
    this.storageTotalBytes,
    this.storageFreeBytes,
    this.reportedAt,
  });

  /// Lenient: a malformed field drops to unknown instead of failing the whole
  /// roster, which is identity first and these numbers second.
  factory DeviceStats.fromJson(Map<String, dynamic> json) {
    int? bytes(String key) {
      final v = json[key];
      return v is num && v >= 0 ? v.toInt() : null;
    }

    final model = json['model'];
    final reportedAt = json['reportedAt'];
    return DeviceStats(
      model: model is String && model.isNotEmpty ? model : null,
      ramTotalBytes: bytes('ramTotalBytes'),
      ramAvailableBytes: bytes('ramAvailableBytes'),
      storageTotalBytes: bytes('storageTotalBytes'),
      storageFreeBytes: bytes('storageFreeBytes'),
      reportedAt: reportedAt is String ? reportedAt : null,
    );
  }

  /// The `device:stats` payload, omitting what this device couldn't read.
  Map<String, dynamic> toWire() => {
    'model': ?model,
    'ramTotalBytes': ?ramTotalBytes,
    'ramAvailableBytes': ?ramAvailableBytes,
    'storageTotalBytes': ?storageTotalBytes,
    'storageFreeBytes': ?storageFreeBytes,
  };

  bool get isEmpty =>
      model == null &&
      ramTotalBytes == null &&
      ramAvailableBytes == null &&
      storageTotalBytes == null &&
      storageFreeBytes == null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceStats &&
          model == other.model &&
          ramTotalBytes == other.ramTotalBytes &&
          ramAvailableBytes == other.ramAvailableBytes &&
          storageTotalBytes == other.storageTotalBytes &&
          storageFreeBytes == other.storageFreeBytes &&
          reportedAt == other.reportedAt;

  @override
  int get hashCode => Object.hash(
    model,
    ramTotalBytes,
    ramAvailableBytes,
    storageTotalBytes,
    storageFreeBytes,
    reportedAt,
  );
}

/// `3.2 GB`. Decimal units by default, as phones label their own storage;
/// [binary] counts in 1024s under the same labels, which is how every OS
/// labels RAM: a 32 GiB machine counted in 1000s reads "34.4 GB".
String formatBytes(int bytes, {bool binary = false}) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  final step = binary ? 1024 : 1000;
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= step && unit < units.length - 1) {
    value /= step;
    unit++;
  }
  final digits = unit == 0 || value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

/// `RAM 7.8 / 12.0 GB` (used / total) when both halves are known, the total
/// alone when only it is, null when the device said nothing about it.
String? usageLine(String label, {int? total, int? free, bool binary = false}) {
  if (total == null || total <= 0) return null;
  String fmt(int b) => formatBytes(b, binary: binary);
  if (free == null || free > total) return '$label ${fmt(total)}';
  final used = fmt(total - free);
  final all = fmt(total);
  // The unit once when both halves share it: the roster row is one line wide.
  final unit = all.substring(all.lastIndexOf(' '));
  final shown = used.endsWith(unit)
      ? used.substring(0, used.length - unit.length)
      : used;
  return '$label $shown / $all';
}

/// [usageLine] for RAM, in the binary units the device's own OS shows.
String? ramLine({int? total, int? free}) =>
    usageLine('RAM', total: total, free: free, binary: true);
