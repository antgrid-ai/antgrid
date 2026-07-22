import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Dart mirror of `bridge/src/project-id.ts` `computeProjectId`.
///
/// SHA-256 of the canonicalized [folder] path; first 8 bytes (16 hex chars).
/// On Windows and macOS the path is lowercased before hashing.
Future<String> computeProjectId(String folder) async {
  String resolved;
  try {
    resolved = Directory(folder).resolveSymbolicLinksSync();
  } catch (_) {
    resolved = folder;
  }
  if (Platform.isWindows || Platform.isMacOS) {
    resolved = resolved.toLowerCase();
  }
  final digest = sha256.convert(utf8.encode(resolved));
  return digest.bytes
      .take(8)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}
