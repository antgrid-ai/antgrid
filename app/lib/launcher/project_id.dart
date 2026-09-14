import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Dart mirror of `bridge/src/project-id.ts` `computeProjectId`.
///
/// SHA-256 of the canonicalized [folder] path; first 8 bytes (16 hex chars).
/// On Windows and macOS the path is lowercased before hashing.
///
/// **This is the hash, not the project identity.** A folder's identity is
/// `resolveProject` (bridge/src/worktrees/project-resolver.ts), which hashes
/// the repository's PRIMARY checkout — so for a linked worktree this answers
/// something no bridge holds, while still working as a transport key, which is
/// what makes the disagreement silent. Ask the host
/// (`LocalAgentLauncher.resolveProject`) wherever the answer is persisted or
/// leaves the machine; this is only the fallback for a host too old to have
/// the verb.
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
