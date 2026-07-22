import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'project_status.dart';

class ProjectStatusCache {
  final Future<Directory> _rootDir;

  ProjectStatusCache._({required Future<Directory> rootDir})
    : _rootDir = rootDir;

  factory ProjectStatusCache() {
    return ProjectStatusCache._(rootDir: getApplicationSupportDirectory());
  }

  factory ProjectStatusCache.testInstance({required String root}) {
    return ProjectStatusCache._(rootDir: Future.value(Directory(root)));
  }

  Future<File> _fileFor(String projectId) async {
    final root = await _rootDir;
    return File(
      p.join(root.path, 'cache', 'project-status', '$projectId.json'),
    );
  }

  Future<void> write(String projectId, ProjectStatus status) async {
    final f = await _fileFor(projectId);
    await f.parent.create(recursive: true);
    // Unique tmp name per write so concurrent writers don't collide on the
    // tmp file. Windows `rename` fails if the target exists, so when the
    // final file already exists we fall back to delete-then-rename. We
    // accept a brief window where the file is absent during a write — this
    // is documented in the class contract (the cache is a best-effort
    // hydration source, not a transactional store).
    final tmp = File(
      '${f.path}.${DateTime.now().microsecondsSinceEpoch}.${identityHashCode(status)}.tmp',
    );
    await tmp.writeAsString(jsonEncode(status.toJson()), flush: true);
    try {
      await tmp.rename(f.path);
    } on FileSystemException {
      // Likely Windows + target exists. Best-effort replace.
      if (await f.exists()) {
        try {
          await f.delete();
        } on FileSystemException {
          // Another writer may have replaced it concurrently — ignore.
        }
      }
      try {
        await tmp.rename(f.path);
      } on FileSystemException {
        // Another writer won the race; drop our tmp.
        if (await tmp.exists()) {
          try {
            await tmp.delete();
          } on FileSystemException {
            // ignore
          }
        }
      }
    }
  }

  Future<ProjectStatus?> read(String projectId) async {
    final f = await _fileFor(projectId);
    if (!await f.exists()) return null;
    try {
      final raw = await f.readAsString();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return ProjectStatus.fromJson(json);
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Future<void> clear(String projectId) async {
    final f = await _fileFor(projectId);
    if (await f.exists()) await f.delete();
  }
}
