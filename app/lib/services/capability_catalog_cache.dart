import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/capability_catalog.dart';

/// Disk-persisted cache of [CapabilityCatalog] keyed by a caller-built composite
/// `<sourceKey>__<toolKey>`. Mirrors ProjectStatusCache: best-effort,
/// tmp+rename write, never throws on read. The cache is a hydration seed, not a
/// transactional store — a live capabilities frame always overrides it.
class CapabilityCatalogCache {
  final Future<Directory> _rootDir;

  CapabilityCatalogCache._({required Future<Directory> rootDir})
    : _rootDir = rootDir;

  factory CapabilityCatalogCache() =>
      CapabilityCatalogCache._(rootDir: getApplicationSupportDirectory());

  factory CapabilityCatalogCache.testInstance({required String root}) =>
      CapabilityCatalogCache._(rootDir: Future.value(Directory(root)));

  // Composite keys carry ':' (machine:<uuid>), not a legal Windows filename
  // char. Collapse anything outside [A-Za-z0-9._-] so each key maps to one file.
  static String _safe(String key) =>
      key.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  Future<File> _fileFor(String key) async {
    final root = await _rootDir;
    return File(
      p.join(root.path, 'cache', 'capability-catalog', '${_safe(key)}.json'),
    );
  }

  Future<void> write(String key, CapabilityCatalog catalog) async {
    final f = await _fileFor(key);
    await f.parent.create(recursive: true);
    // Unique tmp per write so concurrent writers don't collide; Windows rename
    // fails if the target exists, so fall back to delete-then-rename.
    final tmp = File(
      '${f.path}.${DateTime.now().microsecondsSinceEpoch}.${identityHashCode(catalog)}.tmp',
    );
    await tmp.writeAsString(jsonEncode(catalog.toJson()), flush: true);
    try {
      await tmp.rename(f.path);
    } on FileSystemException {
      if (await f.exists()) {
        try {
          await f.delete();
        } on FileSystemException {
          // Another writer replaced it concurrently — ignore.
        }
      }
      try {
        await tmp.rename(f.path);
      } on FileSystemException {
        if (await tmp.exists()) {
          try {
            await tmp.delete();
          } on FileSystemException {
            // Lost the race; drop our tmp.
          }
        }
      }
    }
  }

  Future<CapabilityCatalog?> read(String key) async {
    final f = await _fileFor(key);
    if (!await f.exists()) return null;
    try {
      final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return CapabilityCatalog.fromJson(json);
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Future<void> clear(String key) async {
    final f = await _fileFor(key);
    if (await f.exists()) await f.delete();
  }
}
