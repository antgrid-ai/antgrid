import 'package:antgrid/launcher/host_control_client.dart';
import 'package:antgrid/models/device_stats.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a malformed field drops to unknown, not the whole report', () {
    final s = DeviceStats.fromJson({
      'model': 'Pixel 9',
      'ramTotalBytes': -5,
      'ramAvailableBytes': 'lots',
      'storageTotalBytes': 128000000000,
    });
    expect(s.model, 'Pixel 9');
    expect(s.ramTotalBytes, isNull);
    expect(s.ramAvailableBytes, isNull);
    expect(s.storageTotalBytes, 128000000000);
  });

  test('toWire omits what the device could not read', () {
    expect(const DeviceStats(ramTotalBytes: 10).toWire(), {
      'ramTotalBytes': 10,
    });
    expect(const DeviceStats().isEmpty, isTrue);
  });

  test('usageLine shows used of total, or the total alone', () {
    expect(
      usageLine('RAM', total: 12000000000, free: 4000000000),
      'RAM 8.0 / 12.0 GB',
    );
    // Halves in different units keep both.
    expect(
      usageLine('RAM', total: 1500000000, free: 700000000),
      'RAM 800 MB / 1.5 GB',
    );
    expect(usageLine('RAM', total: 12000000000), 'RAM 12.0 GB');
    // Free larger than total is a bad report, not negative usage.
    expect(usageLine('RAM', total: 10, free: 20), 'RAM 10 B');
    expect(usageLine('RAM', free: 20), isNull);
  });

  test('formatBytes uses decimal units', () {
    expect(formatBytes(999), '999 B');
    expect(formatBytes(1500000), '1.5 MB');
    expect(formatBytes(256000000000), '256 GB');
  });

  test('RAM is counted in 1024s, as the device itself labels it', () {
    const gib = 1024 * 1024 * 1024;
    expect(ramLine(total: 32 * gib, free: 14 * gib), 'RAM 18.0 / 32.0 GB');
    expect(formatBytes(32 * gib), '34.4 GB');
  });

  test('a roster row from an older bridge has no stats', () {
    final row = PairedPhoneSummary.fromJson({
      'phonePubkey': 'pk',
      'phoneDeviceId': 'id',
      'pairedAt': 'x',
      'lastSeenAt': 'y',
    });
    expect(row.stats, isNull);
  });
}
