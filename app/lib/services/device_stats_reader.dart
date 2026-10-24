import 'dart:ffi';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:ffi/ffi.dart';

import '../models/device_stats.dart';
import '../util/ab_log.dart';

/// Reads THIS device's model, RAM and storage for `device:stats`.
///
/// Best effort per field: what a platform cannot say is left null, and a
/// failing probe yields an empty report rather than an error, because the
/// numbers decorate a roster row and must never block a connection.
Future<DeviceStats> readOwnDeviceStats([DeviceInfoPlugin? plugin]) async {
  final info = plugin ?? DeviceInfoPlugin();
  try {
    if (Platform.isAndroid) {
      final a = await info.androidInfo;
      return DeviceStats(
        model: _joinModel(a.manufacturer, a.model),
        // The plugin reports RAM in MB (disk sizes are already bytes).
        ramTotalBytes: a.physicalRamSize * _mb,
        ramAvailableBytes: a.availableRamSize * _mb,
        storageTotalBytes: a.totalDiskSize,
        storageFreeBytes: a.freeDiskSize,
      );
    }
    if (Platform.isIOS) {
      final i = await info.iosInfo;
      return DeviceStats(
        model: i.modelName,
        ramTotalBytes: i.physicalRamSize * _mb,
        ramAvailableBytes: i.availableRamSize * _mb,
        storageTotalBytes: i.totalDiskSize,
        storageFreeBytes: i.freeDiskSize,
      );
    }
    if (Platform.isWindows) {
      final w = await info.windowsInfo;
      final mem = _windowsMemory();
      final disk = _windowsDisk(Platform.environment['SystemDrive'] ?? 'C:');
      return DeviceStats(
        model: _windowsModel(),
        ramTotalBytes: mem?.total ?? w.systemMemoryInMegabytes * _mb,
        ramAvailableBytes: mem?.available,
        storageTotalBytes: disk?.total,
        storageFreeBytes: disk?.available,
      );
    }
    if (Platform.isMacOS) {
      final m = await info.macOsInfo;
      return DeviceStats(model: m.modelName, ramTotalBytes: m.memorySize);
    }
    if (Platform.isLinux) {
      final mem = await _linuxMemory();
      return DeviceStats(
        model: await _linuxModel(),
        ramTotalBytes: mem?.total,
        ramAvailableBytes: mem?.available,
      );
    }
  } catch (e) {
    AbLog.warn('DeviceStats', 'reading device stats failed', fields: {'error': '$e'});
  }
  return const DeviceStats();
}

const _mb = 1024 * 1024;

/// Firmware placeholders that name no product, so a row shows nothing rather
/// than two PCs both reading "To Be Filled By O.E.M.".
const _placeholderModels = {
  'to be filled by o.e.m.',
  'system product name',
  'system manufacturer',
  'default string',
  'not specified',
  'none',
  'o.e.m.',
};

/// The hardware the firmware names, never the OS product name: the roster
/// row's model is what tells two machines apart, and every Windows 11 Pro box
/// would read the same.
String? _joinFirmwareModel(String? maker, String? product) {
  String clean(String? s) {
    final t = (s ?? '').trim();
    return _placeholderModels.contains(t.toLowerCase()) ? '' : t;
  }

  final p = clean(product);
  if (p.isEmpty) return null;
  return _joinModel(clean(maker), p);
}

/// `/sys/class/dmi/id` is world-readable on x86; absent on most ARM boards,
/// which then report no model.
Future<String?> _linuxModel() async {
  Future<String?> read(String name) async {
    try {
      return await File('/sys/class/dmi/id/$name').readAsString();
    } on FileSystemException {
      return null;
    }
  }

  return _joinFirmwareModel(await read('sys_vendor'), await read('product_name'));
}

String? _joinModel(String maker, String model) {
  final m = model.trim();
  final b = maker.trim();
  if (m.isEmpty) return b.isEmpty ? null : b;
  // Pixel reports `Google` + `Pixel 9`, Samsung `samsung` + `SM-S921B`; a
  // model that already names its maker would read twice.
  if (b.isEmpty || m.toLowerCase().startsWith(b.toLowerCase())) return m;
  return '${b[0].toUpperCase()}${b.substring(1)} $m';
}

typedef _Pair = ({int total, int available});

/// `/proc/meminfo` reports kB; MemAvailable is what the kernel would hand a new
/// process, which is what "free" means to a reader (MemFree undercounts cache).
Future<_Pair?> _linuxMemory() async {
  final lines = await File('/proc/meminfo').readAsLines();
  int? kb(String key) {
    for (final line in lines) {
      if (!line.startsWith('$key:')) continue;
      return int.tryParse(line.split(RegExp(r'\s+'))[1]);
    }
    return null;
  }

  final total = kb('MemTotal');
  final available = kb('MemAvailable');
  if (total == null || available == null) return null;
  return (total: total * 1024, available: available * 1024);
}

final class _MemoryStatusEx extends Struct {
  @Uint32()
  external int dwLength;
  @Uint32()
  external int dwMemoryLoad;
  @Uint64()
  external int ullTotalPhys;
  @Uint64()
  external int ullAvailPhys;
  @Uint64()
  external int ullTotalPageFile;
  @Uint64()
  external int ullAvailPageFile;
  @Uint64()
  external int ullTotalVirtual;
  @Uint64()
  external int ullAvailVirtual;
  @Uint64()
  external int ullAvailExtendedVirtual;
}

final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

_Pair? _windowsMemory() {
  final globalMemoryStatusEx = _kernel32
      .lookupFunction<
        Int32 Function(Pointer<_MemoryStatusEx>),
        int Function(Pointer<_MemoryStatusEx>)
      >('GlobalMemoryStatusEx');
  final status = calloc<_MemoryStatusEx>();
  try {
    status.ref.dwLength = sizeOf<_MemoryStatusEx>();
    if (globalMemoryStatusEx(status) == 0) return null;
    return (total: status.ref.ullTotalPhys, available: status.ref.ullAvailPhys);
  } finally {
    calloc.free(status);
  }
}

final DynamicLibrary _advapi32 = DynamicLibrary.open('advapi32.dll');

String? _windowsModel() {
  final regGetValue = _advapi32
      .lookupFunction<
        Int32 Function(
          IntPtr,
          Pointer<Utf16>,
          Pointer<Utf16>,
          Uint32,
          Pointer<Uint32>,
          Pointer<Void>,
          Pointer<Uint32>,
        ),
        int Function(
          int,
          Pointer<Utf16>,
          Pointer<Utf16>,
          int,
          Pointer<Uint32>,
          Pointer<Void>,
          Pointer<Uint32>,
        )
      >('RegGetValueW');
  const hkeyLocalMachine = 0x80000002;
  const rrfRtRegSz = 0x2;
  const capacity = 256;

  String? read(String name) {
    final key = r'HARDWARE\DESCRIPTION\System\BIOS'.toNativeUtf16();
    final value = name.toNativeUtf16();
    final buf = calloc<Uint16>(capacity);
    final size = calloc<Uint32>()..value = capacity * sizeOf<Uint16>();
    try {
      final status = regGetValue(
        hkeyLocalMachine,
        key,
        value,
        rrfRtRegSz,
        nullptr,
        buf.cast(),
        size,
      );
      return status == 0 ? buf.cast<Utf16>().toDartString() : null;
    } finally {
      calloc
        ..free(key)
        ..free(value)
        ..free(buf)
        ..free(size);
    }
  }

  return _joinFirmwareModel(
    read('SystemManufacturer'),
    read('SystemProductName'),
  );
}

_Pair? _windowsDisk(String drive) {
  final getDiskFreeSpaceEx = _kernel32
      .lookupFunction<
        Int32 Function(
          Pointer<Utf16>,
          Pointer<Uint64>,
          Pointer<Uint64>,
          Pointer<Uint64>,
        ),
        int Function(
          Pointer<Utf16>,
          Pointer<Uint64>,
          Pointer<Uint64>,
          Pointer<Uint64>,
        )
      >('GetDiskFreeSpaceExW');
  final root = '$drive\\'.toNativeUtf16();
  final freeToCaller = calloc<Uint64>();
  final total = calloc<Uint64>();
  final free = calloc<Uint64>();
  try {
    if (getDiskFreeSpaceEx(root, freeToCaller, total, free) == 0) return null;
    return (total: total.value, available: freeToCaller.value);
  } finally {
    calloc
      ..free(root)
      ..free(freeToCaller)
      ..free(total)
      ..free(free);
  }
}
